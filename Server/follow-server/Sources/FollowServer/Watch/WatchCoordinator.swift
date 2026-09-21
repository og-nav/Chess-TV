// What to watch, and when to say something about a tournament.
//
// Every five minutes: read the follow list, ask Lichess what is on, decide which rounds deserve a
// connection, and work out whether any followed tournament crossed a line. Rounds with no
// follower are not watched at all, which is both the plan's rule and what keeps this server
// inside Lichess's patience.
//
// Two rules that the plan is explicit about and that are easy to get wrong:
//
//   * A round is live when the round JSON says `ongoing`, never because the clock passed
//     `startsAt`. Rounds slip; a guess would be wrong most evenings.
//   * A tournament has finished when **every round in the tour's round list** is finished. The
//     current round being over says nothing — there is usually another one tomorrow.

import Foundation
import FollowKit
import Logging

public actor WatchCoordinator {

    private let store: FollowStore
    private let source: any BroadcastSource
    private let pipeline: FollowPipeline
    private let configuration: ServerConfig
    private let logger: Logger
    private let now: @Sendable () -> Date

    private var watchers: [String: (watcher: RoundWatcher, task: Task<Void, Never>)] = [:]
    private var lastLichessEventAt: Date?
    /// One round JSON fetch per round per poll, at most, however many questions get asked of it.
    /// Cleared at the start of every poll so nothing here is ever more than five minutes old.
    private var roundDetails: [String: BroadcastRoundDetail] = [:]

    public init(
        store: FollowStore,
        source: any BroadcastSource,
        pipeline: FollowPipeline,
        configuration: ServerConfig,
        logger: Logger = ServerLog.make("coordinator"),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.source = source
        self.pipeline = pipeline
        self.configuration = configuration
        self.logger = logger
        self.now = now
    }

    public var watchedRoundCount: Int { watchers.count }
    public var lastEventAt: Date? { lastLichessEventAt }
    public var watchedRoundIds: [String] { watchers.keys.sorted() }

    public func run() async {
        while !Task.isCancelled {
            do {
                try await pollOnce()
            } catch BroadcastSourceError.rateLimited {
                retryNotBefore = now().addingTimeInterval(60)
                logger.warning("rate limited by Lichess on the poll")
                try? await Task.sleep(for: configuration.rateLimitBackoff)
            } catch {
                logger.error("poll failed", metadata: ["error": .string(String(describing: type(of: error)))])
            }
            do { try await Task.sleep(for: configuration.pollInterval) } catch { break }
        }
        await stopAll()
    }

    private var pollKick: Task<Void, Never>?
    private var pollAgain = false
    private var retryNotBefore = Date.distantPast

    /// Coalesces rapid follow/pin edits. The API only schedules work; it never waits for Lichess.
    ///
    /// Two seconds after the first edit, and never sooner than `minimumPollGap` after the last
    /// poll began: every poll is a `top` fetch plus a round JSON per live event, so a burst of
    /// pin/unpin taps across the user base must not turn into a burst of Lichess requests.
    public func requestPoll() {
        if isPolling { pollAgain = true; return }
        guard pollKick == nil else { return }
        let sinceLast = lastPollStartedAt.map { now().timeIntervalSince($0) } ?? .infinity
        let wait = max(2, Self.minimumPollGap - sinceLast)
        pollKick = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            guard let self else { return }
            await self.runRequestedPoll()
        }
    }

    static let minimumPollGap: TimeInterval = 30
    private var lastPollStartedAt: Date?

    private func runRequestedPoll() async {
        pollKick = nil
        do { try await pollOnce() }
        catch BroadcastSourceError.rateLimited { retryNotBefore = now().addingTimeInterval(60) }
        catch { logger.warning("requested poll failed", metadata: ["error": .string(String(describing: type(of: error)))]) }
    }

    /// Cancels every watcher and waits for it to return. Waiting matters: the caller is about to
    /// close the store, and a watcher still inside a query would otherwise reach a closed SQLite
    /// handle.
    public func stopAll() async {
        pollKick?.cancel()
        pollKick = nil
        let stopping = watchers.values.map(\.task)
        watchers.removeAll()
        for task in stopping { task.cancel() }
        for task in stopping { await task.value }
    }

    // MARK: - The poll

    private var isPolling = false
    public func pollOnce() async throws {
        guard now() >= retryNotBefore else { return }
        guard !isPolling else { return }
        isPolling = true
        lastPollStartedAt = now()
        defer {
            isPolling = false
            if pollAgain { pollAgain = false; requestPoll() }
        }
        // A Live Activity cannot outlive ActivityKit's own limit, and the app does not always get
        // to say when one ended. Without this sweep a single registration would hold a stream open
        // against Lichess for as long as the process ran.
        if let expired = try? await store.expireActivities(olderThan: configuration.activityLifetime), expired > 0 {
            logger.info("expired stale activity registrations", metadata: ["count": .stringConvertible(expired)])
        }

        let follows = try await store.allFollows()
        // Pinning a game is a request to be told about it just as much as following one is. A
        // device that pinned a Live Activity without following anything used to produce no
        // watcher, so its activity was registered and then never updated again.
        let pinnedRounds = (try? await store.activeActivityRoundIds()) ?? []
        guard !follows.isEmpty || !pinnedRounds.isEmpty else {
            await stopAll()
            return
        }

        var requestedRounds: Set<String> = pinnedRounds
        var tourIds: Set<String> = []
        var fideIds: Set<Int> = []
        for entry in follows {
            switch entry.follow.target {
            case .game(let roundId, _): requestedRounds.insert(roundId)
            case .tournament(let tourId): tourIds.insert(tourId)
            case .player(let fideId): fideIds.insert(fideId)
            }
        }
        // A followed game is never unfollowed when it ends, so without this every finished game
        // would hold a stream open against Lichess for as long as the follow existed, and once
        // twelve of them had finished no live round could get a watcher slot at all. The round
        // record is written by the watcher itself on every connection; an unknown round is
        // watched so that it can be found out.
        var explicitRounds: Set<String> = []
        for roundId in requestedRounds {
            if let record = try? await store.round(id: roundId), record.finished { continue }
            explicitRounds.insert(roundId)
        }

        let top = fideIds.isEmpty ? BroadcastTop() : try await source.top()
        lastLichessEventAt = now()
        roundDetails.removeAll()

        var rounds = explicitRounds
        var events: [TournamentEvent] = []
        var observations: [Observation] = []

        for tourId in tourIds {
            guard let tour = try? await source.tour(id: tourId) else {
                logger.warning("followed tour could not be read", metadata: ["tour": .string(tourId)])
                continue
            }
            let evaluation = await evaluate(tour: tour)
            events.append(contentsOf: evaluation.events)
            observations.append(contentsOf: evaluation.observations)
            for round in tour.rounds where round.ongoing { rounds.insert(round.id) }
        }

        // A followed player has to be found: the only way to know which board Carlsen is on today
        // is to read the round JSONs that are live. Bounded by what `top` returns, which is a few
        // dozen, and cached for the rest of this poll.
        if !fideIds.isEmpty {
            for entry in top.active {
                guard rounds.count < configuration.maximumWatchedRounds else { break }
                guard let round = await roundDetail(entry.round.id) else { continue }
                let present = round.games.contains { game in
                    (game.white.fideId.map(fideIds.contains) ?? false) || (game.black.fideId.map(fideIds.contains) ?? false)
                }
                if present { rounds.insert(entry.round.id) }
            }
        }

        // Dispatch, *then* record that the transition was seen. The other order — which is what
        // this did — writes "already told everybody" before anybody has been told, so a crash
        // between the two loses the alert permanently: the next poll reads the marker and stays
        // quiet forever. This way a crash costs a repeat of the candidate on the next poll, and
        // the outbox's `UNIQUE(device_id, dedupe_key)` turns that repeat into nothing for every
        // device that already has the row.
        try await pipeline.dispatch(tournamentEvents: events, now: now())
        for observation in observations {
            _ = try? await store.observeTournamentEvent(tourId: observation.tourId, roundId: observation.roundId, kind: observation.kind)
        }
        // Rounds someone asked for by name come first when the cap bites; rounds found by
        // searching for a player fill what is left.
        let ordered = explicitRounds.sorted() + rounds.subtracting(explicitRounds).sorted()
        await reconcile(rounds: ordered)
        await sweepIfDue()
    }

    private var lastSweepAt: Date?

    /// Retention, once an hour. Nothing here is needed after a week: the dedupe index only has to
    /// hold for as long as an event can be re-observed, and a broadcast round is a same-day thing.
    private func sweepIfDue() async {
        let current = now()
        if let last = lastSweepAt, current.timeIntervalSince(last) < 3600 { return }
        lastSweepAt = current
        do {
            let removed = try await store.sweep(now: current)
            if removed > 0 { logger.info("swept old rows", metadata: ["count": .stringConvertible(removed)]) }
        } catch {
            logger.warning("sweep failed", metadata: ["error": .string(String(describing: type(of: error)))])
        }
    }

    /// "The server has told everyone it is going to tell about this transition." Written only
    /// after the dispatch that made it true.
    private struct Observation {
        var tourId: String
        var roundId: String
        var kind: String
    }

    /// The round JSON, fetched at most once per poll.
    private func roundDetail(_ roundId: String) async -> BroadcastRoundDetail? {
        if let cached = roundDetails[roundId] { return cached }
        guard let fetched = try? await source.round(id: roundId) else { return nil }
        roundDetails[roundId] = fetched
        return fetched
    }

    /// The transitions of one followed tour, and the markers to write once they have gone out.
    private func evaluate(tour: BroadcastTourDetail) async -> (events: [TournamentEvent], observations: [Observation]) {
        var events: [TournamentEvent] = []
        var observations: [Observation] = []
        let timestamp = now()
        /// False as soon as any round of this tour turns out to be new to the store, which is how
        /// "the server has never seen this event before" is told from "the event just ended".
        var knownRounds = true

        func observed(_ roundId: String, _ kind: String) async -> Bool {
            // `true` on a read failure, because the safe answer to "have we already told them?"
            // is yes: a missed alert is a disappointment, a duplicated one is a nuisance that
            // repeats every five minutes.
            (try? await store.hasObservedTournamentEvent(tourId: tour.tour.id, roundId: roundId, kind: kind)) ?? true
        }

        if tour.isFinished {
            var allKnown = true
            for round in tour.rounds {
                if (try? await store.round(id: round.id)) == nil { allKnown = false }
            }
            if !allKnown {
                _ = try? await store.observeTournamentEvent(tourId: tour.tour.id, roundId: "-", kind: "tournamentFinished")
            }
        }
        for round in tour.rounds {
            let known = (try? await store.round(id: round.id)) != nil

            // The baseline rule again, for rounds rather than boards. A round the server is
            // seeing for the first time that has *already* gone live or already finished is
            // recorded as seen and says nothing: following an event on its third day must not
            // announce the first two. A round that is still upcoming is not baselined, because
            // its starting-soon alert is about the future and is exactly what was asked for.
            //
            // These markers are written *before* the round record, and immediately rather than
            // after the dispatch: they exist to suppress, so a crash that loses them costs one
            // more silent first sight, whereas a crash between saving the round and writing them
            // would make the next poll announce a round that started yesterday.
            if !known {
                knownRounds = false
                if round.ongoing || round.finished {
                    _ = try? await store.observeTournamentEvent(tourId: tour.tour.id, roundId: round.id, kind: "roundLive")
                    _ = try? await store.observeTournamentEvent(tourId: tour.tour.id, roundId: round.id, kind: "startingSoon")
                    if round.finished {
                        _ = try? await store.observeTournamentEvent(tourId: tour.tour.id, roundId: round.id, kind: "roundFinished")
                    }
                }
            }

            try? await store.save(
                RoundRecord(
                    roundId: round.id,
                    tourId: tour.tour.id,
                    name: round.name,
                    startsAt: round.startsAt,
                    ongoing: round.ongoing,
                    finished: round.finished,
                    updatedAt: timestamp
                )
            )
            if !known, round.ongoing || round.finished { continue }

            // Starting soon. The window is per device (each follow has its own lead time), so the
            // candidate is raised whenever the round is still in the future and the policy
            // decides who is close enough to care. Repetition is handled by the outbox's dedupe
            // key, which is why a `startsAt` that moves later cannot produce a second alert.
            if !round.ongoing, !round.finished, let startsAt = round.startsAt, timestamp < startsAt {
                events.append(
                    TournamentEvent(
                        kind: .startingSoon,
                        tourId: tour.tour.id,
                        tourName: tour.tour.name,
                        roundId: round.id,
                        roundName: round.name,
                        startsAt: startsAt,
                        bannerURL: tour.tour.imageURL,
                        at: timestamp
                    )
                )
                observations.append(Observation(tourId: tour.tour.id, roundId: round.id, kind: "startingSoon"))
            }

            // Live. One alert for the round, not one per board — this is raised from the round's
            // own flag, so the board count is the only thing the round JSON is read for.
            let alreadyLive = await observed(round.id, "roundLive")
            if round.ongoing, !alreadyLive {
                let boards = await roundDetail(round.id)?.games.count
                events.append(
                    TournamentEvent(
                        kind: .roundLive,
                        tourId: tour.tour.id,
                        tourName: tour.tour.name,
                        roundId: round.id,
                        roundName: round.name,
                        startsAt: round.startsAt,
                        boardCount: boards,
                        bannerURL: tour.tour.imageURL,
                        at: timestamp
                    )
                )
                observations.append(Observation(tourId: tour.tour.id, roundId: round.id, kind: "roundLive"))
            }

            // Finished. Lichess's `finished` flag is the first signal; a round whose every board
            // has a result is the second, because the flag can lag by a poll or two and the
            // summary is the alert that covers all the boards the top-boards rule left out.
            let alreadyFinished = await observed(round.id, "roundFinished")
            if !alreadyFinished {
                var games: [BroadcastGameInfo]?
                if round.finished || round.ongoing { games = await roundDetail(round.id)?.games }
                let complete = round.finished || (games.map { !$0.isEmpty && $0.allSatisfy(\.isFinished) } ?? false)
                if complete {
                    events.append(
                        TournamentEvent(
                            kind: .roundFinished,
                            tourId: tour.tour.id,
                            tourName: tour.tour.name,
                            roundId: round.id,
                            roundName: round.name,
                            boardCount: games?.count,
                            results: Self.results(from: games ?? []),
                            bannerURL: tour.tour.imageURL,
                            at: timestamp
                        )
                    )
                    observations.append(Observation(tourId: tour.tour.id, roundId: round.id, kind: "roundFinished"))
                }
            }
        }

        // The event itself. Only when every round in the list is finished — the current round
        // being over is not the same question and answering it with this alert would tell someone
        // the World Championship ended after game one.
        guard knownRounds else {
            // First sight of an event that is already over: record it and say nothing.
            if tour.isFinished {
                _ = try? await store.observeTournamentEvent(tourId: tour.tour.id, roundId: "-", kind: "tournamentFinished")
            }
            return (events, observations)
        }
        let alreadyOver = await observed("-", "tournamentFinished")
        if tour.isFinished, !alreadyOver {
            events.append(
                TournamentEvent(
                    kind: .tournamentFinished,
                    tourId: tour.tour.id,
                    tourName: tour.tour.name,
                    roundName: tour.rounds.last?.name,
                    bannerURL: tour.tour.imageURL,
                    at: timestamp
                )
            )
            observations.append(Observation(tourId: tour.tour.id, roundId: "-", kind: "tournamentFinished"))
        }

        return (events, observations)
    }

    /// `"Carlsen 1–0 Nepomniachtchi"`, board order, at most five. The payload has 4 KB and the
    /// body has one line.
    static func results(from games: [BroadcastGameInfo]) -> [String]? {
        let lines = games.filter(\.isFinished).prefix(5).map { game in
            PushWording.resultLine(white: game.white.name, black: game.black.name, status: game.status)
        }
        return lines.isEmpty ? nil : Array(lines)
    }

    // MARK: - Watchers

    /// `rounds` is in priority order: the ones that survive the cap are the first ones.
    private func reconcile(rounds: [String]) async {
        let wanted = Array(rounds.prefix(configuration.maximumWatchedRounds))
        if rounds.count > wanted.count {
            logger.warning("watching fewer rounds than followed", metadata: [
                "wanted": .stringConvertible(rounds.count),
                "cap": .stringConvertible(configuration.maximumWatchedRounds),
            ])
        }

        for roundId in watchers.keys where !wanted.contains(roundId) {
            watchers[roundId]?.task.cancel()
            watchers[roundId] = nil
            logger.info("stopped watching", metadata: ["round": .string(roundId)])
        }

        for roundId in wanted where watchers[roundId] == nil {
            let watcher = RoundWatcher(
                roundId: roundId,
                source: source,
                pipeline: pipeline,
                store: store,
                configuration: configuration,
                logger: logger,
                now: now
            )
            let task = Task { await watcher.run() }
            watchers[roundId] = (watcher, task)
            logger.info("watching", metadata: ["round": .string(roundId)])
        }
    }
}
