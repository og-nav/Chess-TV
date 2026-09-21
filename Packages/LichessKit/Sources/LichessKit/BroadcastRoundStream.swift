import Foundation
import ChessCore

/// One complete board snapshot from a shared round stream. Clocks are PGN clocks after the last
/// recorded moves, in the BroadcastBoard model's milliseconds. A snapshot received on joining
/// or reconnecting is not a newly played move: retain a matching, fresher round-JSON clock anchor.
public struct BroadcastRoundUpdate: Sendable, Equatable {
    public let board: BroadcastBoard
    public let san: String?
    /// First snapshot for this board on this connection, including reconnect catch-up.
    public let isInitial: Bool
    public init(board: BroadcastBoard, san: String?, isInitial: Bool) {
        self.board = board; self.san = san; self.isInitial = isInitial
    }
}

/// One streaming HTTP request serves every board of a visible round. Full PGNs reduce privately
/// to final snapshots; duplicate retransmissions do not restart client countdowns. Corrections,
/// clock edits, takebacks and result-only changes remain observable. Cancel consumption or call
/// finish() when the round leaves the foreground.
public final class BroadcastRoundStream: @unchecked Sendable {
    private let session: URLSession
    private let baseURL: URL
    private let configuration: TVFeedStream.Configuration
    private let broadcaster = ConnectionStateBroadcaster()
    private let replayCache: BroadcastPGNReplayCache
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var retired = false

    public convenience init(session: URLSession = LichessURLSession.streaming,
                baseURL: URL = LichessConfig.baseURL,
                configuration: TVFeedStream.Configuration = .init()) {
        self.init(session: session, baseURL: baseURL, configuration: configuration, replayCache: .shared)
    }
    init(session: URLSession, baseURL: URL, configuration: TVFeedStream.Configuration,
         replayCache: BroadcastPGNReplayCache) {
        self.session = session; self.baseURL = baseURL; self.configuration = configuration
        self.replayCache = replayCache
    }
    public var connectionStates: AsyncStream<ConnectionState> { broadcaster.subscribe() }
    public var currentConnectionState: ConnectionState? { broadcaster.current }

    public func updates(roundId: String) -> AsyncThrowingStream<BroadcastRoundUpdate, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            let task = Task {
                await self.run(roundId: roundId, continuation: continuation)
                continuation.finish()
            }
            let cancel = lock.withLock { () -> Bool in
                guard !retired else { return true }
                tasks[id] = task
                return false
            }
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                _ = self?.lock.withLock { self?.tasks.removeValue(forKey: id) }
            }
            if cancel { task.cancel(); continuation.finish() }
        }
    }
    public func finish() {
        let active = lock.withLock { retired = true; let active = Array(tasks.values); tasks.removeAll(); return active }
        for task in active { task.cancel() }
        broadcaster.finish()
    }

    private func run(roundId: String, continuation: AsyncThrowingStream<BroadcastRoundUpdate, Error>.Continuation) async {
        var backoff = BackoffPolicy(base: configuration.baseDelay, cap: configuration.maxDelay,
                                    jitterFraction: configuration.jitterFraction)
        var snapshots: [String: BroadcastBoard] = [:]
        while !Task.isCancelled {
            broadcaster.send(.connecting)
            let started = ContinuousClock.now
            do {
                try await connectOnce(roundId: roundId, snapshots: &snapshots, continuation: continuation)
                throw LichessError.streamEndedUnexpectedly
            } catch {
                if Task.isCancelled || error.isCancellation { return }
                if let error = error as? LichessError, error.isUnrecoverable {
                    broadcaster.send(.failed(error.description))
                    continuation.finish(throwing: error)
                    return
                }
                if started.duration(to: .now) >= configuration.healthyConnectionThreshold { backoff.reset() }
                var delay = backoff.nextDelay()
                if case .rateLimited(let retryAfter)? = error as? LichessError {
                    delay = max(delay, configuration.minimumRateLimitDelay)
                    if let retryAfter { delay = max(delay, retryAfter) }
                }
                broadcaster.send(.reconnecting(attempt: backoff.attempt, nextRetryIn: delay))
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
    }

    private func connectOnce(roundId: String, snapshots: inout [String: BroadcastBoard],
                             continuation: AsyncThrowingStream<BroadcastRoundUpdate, Error>.Continuation) async throws {
        let url = baseURL.appendingPathComponent("api/stream/broadcast/round").appendingPathComponent("\(roundId).pgn")
        let (bytes, response) = try await session.bytes(for: LichessURLSession.request(url))
        _ = try LichessHTTP.check(response)
        var decoder = PGNLineDecoder()
        var assembler = PGNBlockAssembler()
        var seen: Set<String> = []
        var live = false
        func handle(_ block: String) {
            do {
                guard let game = PGN.parseGame(block), let id = game.gameId else { return }
                let steps = try game.replay(from: game.initialPosition)
                replayCache.store(BroadcastPGNReplay(game: game, steps: steps), roundId: roundId, gameId: id, origin: baseURL)
                let update = Self.snapshot(game, steps: steps, isInitial: !seen.contains(id))
                seen.insert(id)
                guard snapshots[id] != update.board else { return }
                snapshots[id] = update.board
                continuation.yield(update)
            } catch {
                // One malformed board must not interrupt updates for every other board.
                log.error("Round \(roundId, privacy: .public) PGN snapshot skipped: \(String(describing: error), privacy: .public)")
            }
        }
        for try await byte in bytes {
            try Task.checkCancellation()
            guard let line = decoder.append(byte: byte) else { continue }
            if !live { live = true; broadcaster.send(.live) }
            if let block = assembler.append(line: line) { handle(block) }
        }
        if let tail = decoder.flush(), let block = assembler.append(line: tail) { handle(block) }
        if let block = assembler.finish() { handle(block) }
    }

    static func snapshot(_ game: PGNGame, isInitial: Bool) throws -> BroadcastRoundUpdate {
        snapshot(game, steps: try game.replay(from: game.initialPosition), isInitial: isInitial)
    }
    private static func snapshot(_ game: PGNGame, steps: [(san: String, uci: String, fen: String)],
                                 isInitial: Bool) -> BroadcastRoundUpdate {
        var white: Int?, black: Int?
        for (index, move) in game.moves.enumerated() {
            guard let seconds = move.clockSeconds else { continue }
            let milliseconds = min(max(0, seconds), Int.max / 1000) * 1000
            let side = index % 2 == 0 ? game.initialPosition.sideToMove : game.initialPosition.sideToMove.opposite
            if side == .white { white = milliseconds } else { black = milliseconds }
        }
        let whiteName = game.white ?? "Unknown", blackName = game.black ?? "Unknown"
        let players = [
            BroadcastPlayer(name: whiteName, title: game.whiteTitle, rating: game.whiteElo,
                            federation: game["WhiteFed"], clockMs: white, fideId: game["WhiteFideId"].flatMap(Int.init)),
            BroadcastPlayer(name: blackName, title: game.blackTitle, rating: game.blackElo,
                            federation: game["BlackFed"], clockMs: black, fideId: game["BlackFideId"].flatMap(Int.init))
        ]
        let board = BroadcastBoard(gameId: game.gameId ?? "", name: "\(whiteName) - \(blackName)",
                                   fen: steps.last?.fen ?? game.initialPosition.fen, lastMove: steps.last?.uci,
                                   status: game.outcome ?? "*", players: players)
        return BroadcastRoundUpdate(board: board, san: steps.last?.san, isInitial: isInitial)
    }
}
