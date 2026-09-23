// Which positions get the engine, in what order, and what happens when one is a blunder.
//
// The whole cost model is here, and it is bounded by construction rather than by the number of
// installs or follows:
//
//   * **One engine, one search at a time.** Work arrives as a queue, never as a process per game.
//   * **Demand-gated.** The pipeline only offers a move that some active install has asked to
//     hear about (see `AlertEngine.wantsSwings`). No such install, no search.
//   * **One slot per game, `maximumBoards` slots.** A newer ply replaces an older one for the
//     same game, and when every slot is taken the lowest-priority game is dropped. Priority is the
//     event's Lichess tier and then the board number: never how many installs asked, so minting
//     installs cannot buy a place in the queue.
//   * **Classical only.** A game whose clocks say rapid or blitz is skipped: a ply every few
//     seconds would outrun the engine, and a swing in a blitz scramble is not news.
//   * **Idle means gone.** The engine process exits after `idleTimeout` without work.
//
// A candidate swing is searched again, both sides, at the longer confirmation time before it is
// pushed: a one-second search can be wrong by half a pawn, and a push cannot be taken back.

import Foundation
import Logging

public struct SwingConfiguration: Sendable {
    public var movetimeMs: Int = 1000
    public var confirmMovetimeMs: Int = 3000
    public var maximumBoards: Int = 20
    public var idleTimeout: TimeInterval = 300
    /// The least time between two swing pushes for one game. A time scramble can trade blunders
    /// every move; the second one a minute later is the same story.
    public var minimumGap: TimeInterval = 180
    /// A result this many plies behind the game is not news any more.
    public var maximumStaleness: Int = 2
    /// A clock under this early in the game means a faster time control than classical.
    public var classicalMinimumSeconds: Int = 30 * 60

    public init() {}
}

/// The engine behind `SwingWatcher`, as a protocol so the scheduling rules test without Stockfish.
public protocol PositionEvaluating: Sendable {
    func evaluate(fen: String, movetimeMs: Int) async throws -> EngineScore
    func shutDown() async
}

extension UCIProcess: PositionEvaluating {
    public func evaluate(fen: String, movetimeMs: Int) async throws -> EngineScore {
        try await search(fen: fen, movetimeMs: movetimeMs).score
    }
    public func shutDown() async { await stop() }
}

public actor SwingWatcher {

    struct Job: Sendable {
        var snapshot: GameSnapshot
        var context: RoundContext
        var previousFen: String
        var priority: Priority
        var sequence: Int
    }

    /// Larger sorts first.
    struct Priority: Comparable, Sendable {
        var tier: Int
        var board: Int
        static func < (lhs: Priority, rhs: Priority) -> Bool {
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            return lhs.board > rhs.board
        }
    }

    public typealias SwingHandler = @Sendable (MoveEvent, RoundContext) async -> Void

    private let engine: any PositionEvaluating
    private let configuration: SwingConfiguration
    private let classifier: SwingClassifier
    private let logger: Logger
    private let now: @Sendable () -> Date
    private var onSwing: SwingHandler?

    private var queue: [String: Job] = [:]
    private var sequence = 0
    /// The newest ply seen per game, whether or not it was searched, for the staleness rule.
    private var latestPly: [String: Int] = [:]
    private var lastSwingAt: [String: Date] = [:]
    private var fastGames: Set<String> = []
    /// Recent evaluations by FEN. The position after one move is the position before the next,
    /// so in the ordinary case each ply costs one search, not two.
    private var cache: [String: EngineScore] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 256

    private var wake: CheckedContinuation<Void, Never>?
    private var lastWorkAt: Date?

    private(set) var searches = 0
    private(set) var swings = 0
    private(set) var dropped = 0

    public init(
        engine: any PositionEvaluating,
        configuration: SwingConfiguration = SwingConfiguration(),
        classifier: SwingClassifier = SwingClassifier(),
        logger: Logger = ServerLog.make("swings"),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.engine = engine
        self.configuration = configuration
        self.classifier = classifier
        self.logger = logger
        self.now = now
    }

    public func setHandler(_ handler: @escaping SwingHandler) {
        onSwing = handler
    }

    // MARK: - Intake

    /// Offers a move for analysis. Returns at once; the search happens on `run()`.
    public func consider(snapshot: GameSnapshot, context: RoundContext) {
        let gameId = snapshot.gameId
        latestPly[gameId] = max(latestPly[gameId] ?? 0, snapshot.ply)
        guard !snapshot.isFinished, snapshot.ply > 0, let previousFen = snapshot.previousFen else { return }
        guard !isFast(snapshot) else { return }

        let priority = Priority(tier: context.tier ?? 0, board: context.board(of: gameId) ?? 999)
        sequence += 1
        let job = Job(snapshot: snapshot, context: context, previousFen: previousFen, priority: priority, sequence: sequence)

        if queue[gameId] == nil, queue.count >= configuration.maximumBoards {
            // The job that would run last is the one to give up, and only for a better one.
            guard let weakest = queue.values.max(by: { Self.runsLater($1, than: $0) }),
                  weakest.priority < priority else {
                dropped += 1
                return
            }
            queue[weakest.snapshot.gameId] = nil
            dropped += 1
        } else if queue[gameId] != nil {
            // The older ply of this game never got searched: the newer one is what matters.
            dropped += 1
        }
        queue[gameId] = job
        wake?.resume()
        wake = nil
    }

    /// Whether `a` should run after `b`.
    private static func runsLater(_ a: Job, than b: Job) -> Bool {
        if a.priority != b.priority { return a.priority < b.priority }
        return a.sequence > b.sequence
    }

    /// Clocks decide it, and only early: after twenty plies a clock is as likely to be low from
    /// a long think as from a fast control, so a game first seen late is given the benefit.
    private func isFast(_ snapshot: GameSnapshot) -> Bool {
        if fastGames.contains(snapshot.gameId) { return true }
        guard snapshot.ply <= 20 else { return false }
        let clocks = [snapshot.whiteClock, snapshot.blackClock].compactMap { $0 }
        guard let highest = clocks.max(), highest < configuration.classicalMinimumSeconds else { return false }
        fastGames.insert(snapshot.gameId)
        return true
    }

    // MARK: - Work

    /// Runs until cancelled. One job at a time; the engine goes when the queue has been empty for
    /// `idleTimeout`.
    public func run() async {
        var statsAt = now()
        while !Task.isCancelled {
            if now().timeIntervalSince(statsAt) >= 3600 {
                statsAt = now()
                let stats = takeStats()
                if stats.searches > 0 || stats.dropped > 0 {
                    logger.info("swing summary", metadata: [
                        "searches": .stringConvertible(stats.searches),
                        "swings": .stringConvertible(stats.swings),
                        "dropped": .stringConvertible(stats.dropped),
                    ])
                }
            }
            if let job = dequeue() {
                await process(job)
                lastWorkAt = now()
                continue
            }
            if let last = lastWorkAt, now().timeIntervalSince(last) >= configuration.idleTimeout {
                await engine.shutDown()
                lastWorkAt = nil
                // Nothing has moved anywhere for a while; nothing here is worth keeping, and
                // clearing it is what stops these maps growing for as long as the process lives.
                cache.removeAll()
                cacheOrder.removeAll()
                latestPly.removeAll()
                lastSwingAt.removeAll()
                fastGames.removeAll()
            }
            await sleepUntilWoken(atMost: .seconds(30))
        }
        await engine.shutDown()
    }

    /// Works through whatever is queued and returns. `run()` without the waiting, for tests.
    func drain() async {
        while let job = dequeue() { await process(job) }
    }

    var queuedGameIds: Set<String> { Set(queue.keys) }

    private func dequeue() -> Job? {
        guard let next = queue.values.min(by: { Self.runsLater($1, than: $0) }) else { return nil }
        queue[next.snapshot.gameId] = nil
        return next
    }

    private func sleepUntilWoken(atMost duration: Duration) async {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: duration)
            await self?.wakeUp()
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if !queue.isEmpty || Task.isCancelled {
                    continuation.resume()
                } else {
                    wake = continuation
                }
            }
        } onCancel: {
            Task { await self.interrupt() }
        }
        timer.cancel()
    }

    private func wakeUp() {
        wake?.resume()
        wake = nil
    }

    /// For shutdown: resolves a pending sleep so `run()` can see the cancellation.
    public func interrupt() { wakeUp() }

    func process(_ job: Job) async {
        let gameId = job.snapshot.gameId
        do {
            let before = try await score(job.previousFen, movetimeMs: configuration.movetimeMs)
            let after = try await score(job.snapshot.fen, movetimeMs: configuration.movetimeMs)
            let whiteMoved = job.snapshot.fen.split(separator: " ").dropFirst().first == "b"
            guard classifier.classify(before: before, after: after, whiteMoved: whiteMoved) != nil else { return }

            // A candidate. Search both again, longer, and believe only that.
            let confirmedBefore = try await engine.evaluate(fen: job.previousFen, movetimeMs: configuration.confirmMovetimeMs)
            let confirmedAfter = try await engine.evaluate(fen: job.snapshot.fen, movetimeMs: configuration.confirmMovetimeMs)
            searches += 2
            remember(job.previousFen, confirmedBefore)
            remember(job.snapshot.fen, confirmedAfter)
            guard let swing = classifier.classify(before: confirmedBefore, after: confirmedAfter, whiteMoved: whiteMoved) else {
                logger.info("swing not confirmed", metadata: ["game": .string(gameId), "ply": .stringConvertible(job.snapshot.ply)])
                return
            }

            if let latest = latestPly[gameId], latest - job.snapshot.ply > configuration.maximumStaleness {
                logger.info("swing too late to push", metadata: ["game": .string(gameId), "ply": .stringConvertible(job.snapshot.ply)])
                return
            }
            let at = now()
            if let last = lastSwingAt[gameId], at.timeIntervalSince(last) < configuration.minimumGap {
                logger.info("swing inside the gap", metadata: ["game": .string(gameId), "ply": .stringConvertible(job.snapshot.ply)])
                return
            }
            lastSwingAt[gameId] = at
            swings += 1
            logger.info("swing", metadata: [
                "game": .string(gameId),
                "ply": .stringConvertible(job.snapshot.ply),
                "kind": .string(swing.kind.rawValue),
                "before": .string(swing.before.display),
                "after": .string(swing.after.display),
            ])
            let event = MoveEvent(kind: .evalSwing, snapshot: job.snapshot, at: at, swing: swing)
            await onSwing?(event, job.context)
        } catch {
            logger.warning("search failed", metadata: [
                "game": .string(gameId),
                "error": .string(String(describing: error)),
            ])
        }
    }

    private func score(_ fen: String, movetimeMs: Int) async throws -> EngineScore {
        if let cached = cache[fen] { return cached }
        let score = try await engine.evaluate(fen: fen, movetimeMs: movetimeMs)
        searches += 1
        remember(fen, score)
        return score
    }

    private func remember(_ fen: String, _ score: EngineScore) {
        if cache[fen] == nil {
            cacheOrder.append(fen)
            if cacheOrder.count > cacheLimit { cache[cacheOrder.removeFirst()] = nil }
        }
        cache[fen] = score
    }

    /// For the hourly log line.
    public func takeStats() -> (searches: Int, swings: Int, dropped: Int) {
        defer { searches = 0; swings = 0; dropped = 0 }
        return (searches, swings, dropped)
    }
}
