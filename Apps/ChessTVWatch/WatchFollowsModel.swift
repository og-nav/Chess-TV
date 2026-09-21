// Turning the phone's follow list into boards, ten seconds at a time.
//
// A follow says *who* or *what*, not *which board*, so every refresh resolves:
//
//   * `game(roundId, gameId)` → that round's JSON, that board. One request.
//   * `tournament(tourId)`    → the tour's rounds, the ongoing one (or the next one, which has no
//                               boards yet and is shown as a date), then that round's top boards.
//   * `player(fideId)`        → every live broadcast round, searched for a board with that FIDE
//                               id. This is the expensive one and it is capped; see `roundBudget`.
//
// Rounds fetched once per refresh are shared, so following both Carlsen and his tournament costs
// one request for the round, not two. Polling runs only while the app is on screen, with
// `BackoffPolicy` on errors so a Lichess hiccup does not turn into a hammering.
import Foundation
import Observation
import ChessCore
import FollowKit
import LichessKit

@MainActor
@Observable
final class WatchFollowsModel {

    /// How often a visible screen re-reads the round JSON. The plan's number.
    static let pollInterval: Duration = .seconds(10)

    /// At most this many round JSONs per refresh. A player follow would otherwise walk every live
    /// broadcast on Lichess, which on a busy Saturday is dozens of requests from a watch.
    static let roundBudget = 6

    /// At most this many boards from one tournament follow. The wrist is not a boards wall.
    static let boardsPerTournament = 3

    typealias Row = WatchBoardRow

    private(set) var rows: [Row] = []
    private(set) var isRefreshing = false
    private(set) var lastUpdated: Date?
    /// A short, human sentence, or nil. Shown as a footer, never as an alert.
    private(set) var lastError: String?

    private let client = BroadcastClient()
    private var follows: [WatchFollow] = []
    private var pinned: PinnedGameSnapshot?
    private var loop: Task<Void, Never>?

    /// Bumped whenever the thing being polled changes: a new follow list, a new pinned game, the
    /// screen going away and coming back.
    ///
    /// A pass takes up to six round requests and several seconds, and any of those awaits can be
    /// the moment the phone sends a different follow list. Without this, that pass finishes and
    /// writes rows built from the list the user no longer has — briefly, until the next tick, which
    /// on a wrist is exactly long enough to read.
    private var generation = 0

    /// The last row we actually resolved, by row id, so a pass that fails can show the position it
    /// had rather than an empty row. See `carryingForward`.
    private var lastResolved: [String: Row] = [:]

    // MARK: - Lifecycle

    /// Called when the app becomes active, and again whenever the phone sends a new follow list.
    ///
    /// Idempotent on purpose: the root view calls it from `.task`, from `onChange(of: payload)` and
    /// from the `.active` scene phase, which at launch all happen within a frame of each other. A
    /// call that changes nothing and finds the loop already running does nothing at all — three
    /// identical calls must cost one poll, not three.
    func start(with payload: WatchSyncPayload) {
        let changed = payload.follows != follows || payload.pinned != pinned
        follows = payload.follows
        pinned = payload.pinned
        seedFromPinned()

        if loop == nil {
            generation += 1
            let mine = generation
            loop = Task { [weak self] in await self?.run(generation: mine) }
        } else if changed {
            // A new follow list should not have to wait out the remaining nine seconds of the
            // current tick — but it must not start a second loop either. Restarting bumps the
            // generation, so the pass in flight discards its result instead of overwriting this one.
            restart()
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        // Anything still in flight belongs to a screen that is no longer on.
        generation += 1
        isRefreshing = false
    }

    private func restart() {
        loop?.cancel()
        generation += 1
        let mine = generation
        loop = Task { [weak self] in await self?.run(generation: mine) }
    }

    private func run(generation mine: Int) async {
        var backoff = BackoffPolicy()
        while !Task.isCancelled, generation == mine {
            let ok = await refresh(generation: mine)
            guard generation == mine else { return }
            if ok {
                backoff.reset()
                try? await Task.sleep(for: Self.pollInterval)
            } else {
                // Never faster than the backoff says, even though the screen is in front of someone.
                try? await Task.sleep(for: backoff.nextDelay())
            }
        }
    }

    /// The pinned game the phone last told us about, so the list has a board in it before the
    /// first request comes back.
    private func seedFromPinned() {
        rows.removeAll { $0.followId == "pinned" && $0.id != pinned.map { "pinned:\($0.gameId)" } }
        guard let pinned else { return }
        let row = Self.pinnedRow(pinned)
        if let index = rows.firstIndex(where: { $0.id == row.id }) {
            if rows[index].asOf <= row.asOf { rows[index] = row }
        } else {
            rows.insert(row, at: 0)
        }
        if lastResolved[row.id] == nil || lastResolved[row.id]!.asOf <= row.asOf {
            lastResolved[row.id] = row
        }
    }

    static func pinnedRow(_ pinned: PinnedGameSnapshot) -> Row {
        let board = BroadcastBoard(
            gameId: pinned.gameId, name: "\(pinned.whiteName) – \(pinned.blackName)",
            fen: pinned.state.fen, lastMove: pinned.state.lastMove, status: pinned.state.status,
            players: [
                BroadcastPlayer(name: pinned.whiteName, title: pinned.whiteTitle, rating: nil,
                    federation: nil, clockMs: pinned.state.whiteClock.map { $0 * 1000 }),
                BroadcastPlayer(name: pinned.blackName, title: pinned.blackTitle, rating: nil,
                    federation: nil, clockMs: pinned.state.blackClock.map { $0 * 1000 })
            ]
        )
        return Row(id: "pinned:\(pinned.gameId)", followId: "pinned", title: board.displayName,
            subtitle: String(localized: "Pinned on your iPhone"), roundId: pinned.roundId,
            roundName: pinned.roundName, tourName: pinned.tourName, board: board, asOf: pinned.state.asOf, san: pinned.state.san,
            clockRunningFor: pinned.state.clockRunningFor, isStale: Date().timeIntervalSince(pinned.state.asOf) > 30)
    }

    // MARK: - One pass

    /// - Returns: whether the pass finished without a network error.
    @discardableResult
    func refresh(generation mine: Int? = nil) async -> Bool {
        let mine = mine ?? generation
        guard !follows.isEmpty || pinned != nil else {
            guard generation == mine else { return true }
            rows = []
            lastResolved = [:]
            return true
        }
        isRefreshing = true
        defer { if generation == mine { isRefreshing = false } }

        let cache = RoundCache(client: client, budget: Self.roundBudget)
        var built: [Row] = []
        var failed = false

        if let pinned {
            let id = "pinned:\(pinned.gameId)"
            let subtitle = String(localized: "Pinned on your iPhone", comment: "Subtitle of the pinned row on the watch")
            switch await cache.pinnedBoard(roundId: pinned.roundId, gameId: pinned.gameId) {
            case .board(let board):
                built.append(Row(
                    id: id, followId: "pinned",
                    title: board.displayName, subtitle: subtitle,
                    roundId: pinned.roundId, roundName: pinned.roundName, tourName: pinned.tourName,
                    board: board, asOf: Date()
                ))
            case .absent:
                // The round answered and the game is not in it — finished and rolled off, usually.
                // Not an error, and not a reason to keep showing a board that is no longer there.
                built.append(Row(
                    id: id, followId: "pinned",
                    title: "\(pinned.whiteName) – \(pinned.blackName)", subtitle: subtitle,
                    roundId: pinned.roundId, roundName: pinned.roundName, tourName: pinned.tourName,
                    board: nil, asOf: pinned.state.asOf
                ))
            case .failed:
                // The pinned game is the one row that is always worth keeping: the phone told us
                // what it was, and a lost request is not news that it has gone. Show the last
                // position with its own timestamp, so the board screen does not wind clocks
                // forward from a time nothing was read at.
                failed = true
                built.append(carryingForward(Row(
                    id: id, followId: "pinned",
                    title: "\(pinned.whiteName) – \(pinned.blackName)", subtitle: subtitle,
                    roundId: pinned.roundId, roundName: pinned.roundName, tourName: pinned.tourName,
                    board: nil, asOf: pinned.state.asOf
                )))
            }
        }

        // Specific follows first, so that when a game and the tournament it belongs to both point
        // at the same board, the row that survives de-duplication is the one named after the
        // game. This is the list-shaped version of the coalescing the server does for pushes:
        // following both Carlsen and his event should show one board, not two identical ones.
        let ordered = follows.sorted { Self.specificity($0.target) < Self.specificity($1.target) }

        for follow in ordered {
            guard !Task.isCancelled, generation == mine else { return false }
            do {
                built.append(contentsOf: try await rows(for: follow, cache: cache))
            } catch is CancellationError {
                // The screen went away, or the follow list changed under us. Neither is a failure
                // to report, and the result of this pass is about to be discarded anyway.
                return false
            } catch {
                failed = true
                watchLog.notice("Could not resolve follow \(follow.id, privacy: .public): \(logLabel(for: error), privacy: .public)")
                // Keep the follow visible — with the board it had, if it had one — rather than
                // dropping a row and making the list jump.
                built.append(carryingForward(Row(
                    id: follow.id, followId: follow.id, title: follow.title,
                    subtitle: follow.subtitle, roundId: nil, roundName: nil, tourName: nil,
                    board: nil, asOf: Date()
                )))
            }
        }

        // Everything above may have taken several seconds and six requests. If the answer is no
        // longer the answer to the question that was asked, throw it away rather than show it.
        guard generation == mine else { return !failed }

        let resolved = Self.deduplicated(built)
        rows = resolved
        lastResolved = Dictionary(
            resolved.filter { $0.board != nil }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        lastUpdated = Date()
        lastError = failed
            ? String(localized: "Some games could not be refreshed.", comment: "Watch list footer after a failed poll")
            : nil
        return !failed
    }

    /// Fills a board-less row in with the board it had last time, keeping that board's own `asOf`
    /// so the clocks are wound from when they were actually read.
    private func carryingForward(_ row: Row) -> Row {
        guard row.board == nil, let previous = lastResolved[row.id], previous.board != nil else { return row }
        var carried = row
        carried.title = previous.title
        carried.subtitle = previous.subtitle ?? row.subtitle
        carried.roundId = previous.roundId
        carried.roundName = previous.roundName
        carried.tourName = previous.tourName
        carried.board = previous.board
        carried.asOf = previous.asOf
        carried.san = previous.san
        carried.clockRunningFor = nil
        carried.isStale = true
        return carried
    }

    private func rows(for follow: WatchFollow, cache: RoundCache) async throws -> [Row] {
        switch follow.target {
        case .game(let roundId, let gameId):
            // One lookup, not two: `round` is cached within the pass, but reading it twice invites
            // the second reader to be added outside the cache one day.
            let fetched = try await cache.round(roundId)
            guard let board = fetched?.boards.first(where: { $0.gameId == gameId }) else {
                return [placeholder(follow)]
            }
            let round = fetched?.round
            return [Row(
                id: follow.id, followId: follow.id, title: board.displayName,
                subtitle: round.map { "\($0.roundName) · \($0.name)" } ?? follow.subtitle,
                roundId: roundId, roundName: round?.roundName, tourName: round?.name,
                board: board, asOf: Date()
            )]

        case .tournament(let tourId):
            let tour = try await client.tournament(id: tourId)
            guard let round = Self.currentRound(of: tour) else { return [placeholder(follow)] }
            guard round.ongoing, let fetched = try await cache.round(round.id), !fetched.boards.isEmpty else {
                // Not started: say when, which is the one useful thing before the boards exist.
                return [Row(
                    id: follow.id, followId: follow.id, title: tour.name,
                    subtitle: Self.startsLabel(round),
                    roundId: round.id, roundName: round.name, tourName: tour.name,
                    board: nil, asOf: Date()
                )]
            }
            return Self.liveFirst(fetched.boards).prefix(Self.boardsPerTournament).map { board in
                Row(
                    id: "\(follow.id):\(board.gameId)", followId: follow.id,
                    title: board.displayName,
                    subtitle: "\(round.name) · \(tour.name)",
                    roundId: round.id, roundName: round.name, tourName: tour.name,
                    board: board, asOf: Date()
                )
            }

        case .player(let fideId):
            guard let found = try await cache.findPlayer(fideId: fideId) else {
                return [Row(
                    id: follow.id, followId: follow.id, title: follow.title,
                    subtitle: String(localized: "Not playing", comment: "Subtitle for a followed player with no live game"),
                    roundId: nil, roundName: nil, tourName: nil, board: nil, asOf: Date()
                )]
            }
            return [Row(
                id: follow.id, followId: follow.id, title: found.board.displayName,
                subtitle: "\(found.round.roundName) · \(found.round.name)",
                roundId: found.round.roundId, roundName: found.round.roundName, tourName: found.round.name,
                board: found.board, asOf: Date()
            )]
        }
    }

    /// A row for a follow that resolved to no board — the round budget was spent, the round has not
    /// started, the player is not playing. Carries the last board forward when there was one, for
    /// the budget case, which is temporary by definition.
    private func placeholder(_ follow: WatchFollow) -> Row {
        carryingForward(Row(
            id: follow.id, followId: follow.id, title: follow.title, subtitle: follow.subtitle,
            roundId: nil, roundName: nil, tourName: nil, board: nil, asOf: Date()
        ))
    }

    /// Lower is more specific. A game follow names one board; a player follow names one board once
    /// it is found; a tournament follow names several.
    static func specificity(_ target: FollowTarget) -> Int {
        switch target {
        case .game: 0
        case .player: 1
        case .tournament: 2
        }
    }

    /// Stable partition: live games first, preserving upstream board order within both groups.
    static func liveFirst(_ boards: [BroadcastBoard]) -> [BroadcastBoard] {
        boards.filter(\.isOngoing) + boards.filter { !$0.isOngoing }
    }

    /// One row per board. Rows without a board (a round that has not started, a follow that could
    /// not be resolved) are always kept — there is nothing to collide with.
    static func deduplicated(_ rows: [Row]) -> [Row] {
        var seen: Set<String> = []
        return rows.filter { row in
            guard let gameId = row.board?.gameId else { return true }
            return seen.insert(gameId).inserted
        }
    }

    /// The round a tournament follow should show: the one being played, else the next one to start,
    /// else the last one that finished.
    static func currentRound(of tour: BroadcastTour) -> BroadcastRound? {
        if let ongoing = tour.rounds.first(where: \.ongoing) { return ongoing }
        let upcoming = tour.rounds
            .filter { !$0.finished }
            .min { ($0.startsAt ?? .distantFuture) < ($1.startsAt ?? .distantFuture) }
        return upcoming ?? tour.rounds.last
    }

    static func startsLabel(_ round: BroadcastRound) -> String {
        guard let startsAt = round.startsAt else {
            return String(
                format: String(localized: "%@ · not started", comment: "Watch row subtitle for a round with no start time"),
                round.name
            )
        }
        return "\(round.name) · \(startsAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

/// Round JSONs fetched during one refresh, so overlapping follows share requests and the whole
/// pass stays inside a budget.
/// `@MainActor` because the model that owns it is: the cache is a reference passed between the
/// model's own async methods, and a non-isolated class would be "sent" across an await boundary
/// on every call. The work it waits on — `BroadcastClient` — is nonisolated and runs off the main
/// actor regardless.
@MainActor
private final class RoundCache {
    let client: BroadcastClient
    let budget: Int

    private var rounds: [String: (round: BroadcastTournament, boards: [BroadcastBoard])] = [:]
    private var fetched = 0
    /// The live-broadcast list, fetched at most once per refresh and only if a player follow needs it.
    private var active: [BroadcastTournament]?

    init(client: BroadcastClient, budget: Int) {
        self.client = client
        self.budget = budget
    }

    func round(_ id: String) async throws -> (round: BroadcastTournament, boards: [BroadcastBoard])? {
        if let hit = rounds[id] { return hit }
        guard fetched < budget else {
            watchLog.notice("Round budget spent; skipping \(id, privacy: .public) this pass")
            return nil
        }
        fetched += 1
        let result = try await client.round(id: id)
        rounds[id] = result
        return result
    }

    /// Why a pinned board is not here matters, so this says which of the three it is rather than
    /// collapsing all of them into nil. "The request failed" and "the game is not in this round"
    /// call for opposite behaviour on screen.
    enum PinnedBoardResult {
        case board(BroadcastBoard)
        /// The round was read and does not contain that game.
        case absent
        /// The round could not be read, or the budget was already spent.
        case failed
    }

    func pinnedBoard(roundId: String, gameId: String) async -> PinnedBoardResult {
        do {
            guard let fetched = try await round(roundId) else { return .failed }
            guard let board = fetched.boards.first(where: { $0.gameId == gameId }) else { return .absent }
            return .board(board)
        } catch {
            watchLog.notice("Could not read the pinned round: \(logLabel(for: error), privacy: .public)")
            return .failed
        }
    }

    /// Walks the live rounds looking for a board with this FIDE id. Stops at the first hit and at
    /// the budget, whichever comes first.
    func findPlayer(fideId: Int) async throws -> (round: BroadcastTournament, board: BroadcastBoard)? {
        if active == nil {
            active = try await client.top().active
        }
        for entry in active ?? [] where entry.roundOngoing {
            guard let fetched = try await round(entry.roundId) else { break }
            if let board = fetched.boards.first(where: { $0.players.contains { $0.fideId == fideId } }) {
                return (fetched.round, board)
            }
        }
        return nil
    }
}

extension BroadcastPlayer {
    /// The surname alone. Broadcast PGNs spell players `"Abdusattorov, Nodirbek"`, which on a
    /// 42 mm screen truncates to `"Abdusat…"` and tells you nothing. Everything before the comma
    /// is the family name; a name with no comma is left exactly as it came.
    var surname: String {
        guard let comma = name.firstIndex(of: ",") else { return name }
        let surname = name[..<comma].trimmingCharacters(in: .whitespaces)
        return surname.isEmpty ? name : surname
    }
}

extension BroadcastBoard {
    /// `"Abdusattorov – Erdogmus"`. Lichess's own `name` is `"White - Black"` with a hyphen and
    /// both given names; this is the version that fits a wrist.
    var displayName: String {
        guard let white, let black else { return name }
        return "\(white.surname) – \(black.surname)"
    }
}
