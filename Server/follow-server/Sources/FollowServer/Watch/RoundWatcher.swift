// One round, one PGN stream.
//
// The stream re-sends a game's whole PGN every time it changes, so the watcher's job is small:
// turn each block into a snapshot and hand it to the pipeline, which decides whether anything
// actually moved. The two things it owns are the round context (board order, names, banner, FIDE
// ids — none of which is in the PGN) and the long-think tick, which needs the current position of
// every board and so belongs where those are already in memory.

import Foundation
import Logging

public actor RoundWatcher {

    public let roundId: String

    private let source: any BroadcastSource
    private let pipeline: FollowPipeline
    private let store: FollowStore
    private let configuration: ServerConfig
    private let logger: Logger
    private let now: @Sendable () -> Date

    private var context: RoundContext
    private var snapshots: [String: GameSnapshot] = [:]
    private var seenOnConnection: Set<String> = []

    /// How often a still board is checked for a long think. Short relative to any threshold a
    /// person would set (the minimum the UI offers is one minute), and cheap: no network.
    private let longThinkTick: Duration = .seconds(30)

    public init(
        roundId: String,
        source: any BroadcastSource,
        pipeline: FollowPipeline,
        store: FollowStore,
        configuration: ServerConfig,
        logger: Logger = ServerLog.make("watcher"),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.roundId = roundId
        self.source = source
        self.pipeline = pipeline
        self.store = store
        self.configuration = configuration
        self.logger = logger
        self.now = now
        self.context = RoundContext(roundId: roundId, roundName: "", tourId: "", tourName: "")
    }

    public func currentContext() -> RoundContext { context }

    /// Streams the round until the task is cancelled, reconnecting with backoff.
    ///
    /// Backoff matters here beyond politeness: this server holds several long-lived connections
    /// to Lichess from one IP, and the terms ask for at least a minute after a 429.
    public func run() async {
        var attempt = 0
        var quietEnds = 0
        while !Task.isCancelled {
            do {
                try await refreshContext()
                try await stream()
                attempt = 0
                // A stream that ends by itself means the round is over or the connection dropped.
                // A finished round is re-read at the coordinator's own pace — its next poll will
                // drop this watcher — and a round that keeps closing the stream without sending a
                // board backs off, so a dead round is not two Lichess requests every five seconds.
                if roundFinished {
                    try await Task.sleep(for: configuration.pollInterval)
                } else {
                    quietEnds = seenOnConnection.isEmpty ? quietEnds + 1 : 0
                    try await Task.sleep(for: .seconds(min(300, 5 << min(quietEnds, 6))))
                }
            } catch is CancellationError {
                return
            } catch BroadcastSourceError.rateLimited {
                logger.warning("rate limited by Lichess", metadata: ["round": .string(roundId)])
                try? await Task.sleep(for: configuration.rateLimitBackoff)
            } catch {
                attempt += 1
                let delay = min(300, Int(pow(2.0, Double(min(attempt, 8)))))
                logger.warning("round stream failed", metadata: [
                    "round": .string(roundId),
                    "attempt": .stringConvertible(attempt),
                    "error": .string(String(describing: type(of: error))),
                ])
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }

    /// The round JSON: board order, player federations and FIDE ids, the tour's name and banner.
    /// What the round JSON last said about the round being over. Read by `run()` to decide how
    /// soon a stream that ended is worth reopening.
    private var roundFinished = false

    public func refreshContext() async throws {
        let detail = try await source.round(id: roundId)
        context = RoundContext(detail)
        roundFinished = detail.round.finished
        try await store.save(
            RoundRecord(
                roundId: detail.round.id,
                tourId: detail.tour.id,
                name: detail.round.name,
                startsAt: detail.round.startsAt,
                ongoing: detail.round.ongoing,
                finished: detail.round.finished,
                updatedAt: now()
            )
        )
    }

    /// Called before every stream, and independently testable with a persisted baseline.
    public func beginConnection() {
        snapshots.removeAll()
        seenOnConnection.removeAll()
    }

    private func stream() async throws {
        beginConnection()
        let stream = source.pgnStream(roundId: roundId)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                for try await block in stream {
                    guard let self else { return }
                    await self.handle(block: block)
                }
            }
            group.addTask { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    try await Task.sleep(for: self.longThinkTick)
                    await self.tick()
                }
            }
            // Whichever finishes first ends the other: the ticker has nothing to do once the
            // stream is gone, and a failed ticker must not silently stop the stream.
            try await group.next()
            group.cancelAll()
        }
    }

    /// One re-sent game.
    public func handle(block: String) async {
        guard let snapshot = PGNSnapshot.snapshot(block: block, roundId: roundId, context: context) else { return }
        snapshots[snapshot.gameId] = snapshot
        do {
            let isContinuous = seenOnConnection.contains(snapshot.gameId)
            // `observed` is the instant the block came off the Lichess stream. It is also the
            // outbox row's `queued_at`, so the outbox's `since_observed_ms` measures stream
            // receipt to APNs acceptance, and `ingest_ms` here is the diff/policy/SQLite share.
            let observed = now()
            let started = ContinuousClock.now
            let events = try await pipeline.ingest(snapshot: snapshot, context: context, now: observed, continuouslyObserved: isContinuous)
            seenOnConnection.insert(snapshot.gameId)
            let ingestMs = (ContinuousClock.now - started).milliseconds
            for event in events {
                logger.info("event", metadata: [
                    "kind": .string(event.kind.rawValue),
                    "game": .string(snapshot.gameId),
                    "ply": .stringConvertible(snapshot.ply),
                    "ingest_ms": .stringConvertible(ingestMs),
                ])
            }
        } catch {
            logger.error("ingest failed", metadata: [
                "round": .string(roundId),
                "game": .string(snapshot.gameId),
                "error": .string(String(describing: type(of: error))),
            ])
        }
    }

    /// The long-think check over the boards that are still being played.
    public func tick() async {
        let live = snapshots.values.filter { !$0.isFinished }
        guard !live.isEmpty else { return }
        do {
            _ = try await pipeline.longThinkTick(snapshots: Array(live), context: context, now: now())
        } catch {
            logger.error("long-think tick failed", metadata: ["error": .string(String(describing: type(of: error)))])
        }
    }

    /// Every board's latest state, for the round summary.
    public func currentSnapshots() -> [GameSnapshot] {
        context.boards.compactMap { snapshots[$0] } + snapshots.values.filter { !context.boards.contains($0.gameId) }
    }
}
