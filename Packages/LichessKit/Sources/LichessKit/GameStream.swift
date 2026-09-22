import Foundation
import ChessCore

/// How a game ended, as reported by the last line of `/api/stream/game/{id}`.
public struct GameStatus: Sendable, Equatable {
    /// Lichess' numeric status (`20` started, `30` mate, `31` resign, …). Absent on some lines.
    public let id: Int?
    /// `"started"`, `"mate"`, `"resign"`, `"outoftime"`, `"draw"`, `"stalemate"`, `"aborted"`, …
    public let name: String
    public let winner: PieceColor?

    public init(id: Int?, name: String, winner: PieceColor?) {
        self.id = id
        self.name = name
        self.winner = winner
    }

    /// `true` for anything that is not still in progress.
    ///
    /// The conservative reading of the spec: any status whose `name` is not `"started"`
    /// (or `"created"`) means the game is over.
    public var isOver: Bool { name != "started" && name != "created" }
}

/// Streams one game from `GET /api/stream/game/{gameId}` as `TVEvent`s.
///
/// The wire format differs from the TV feed — there is no `t` discriminator — so this has its
/// own line decoder, but it reuses `NDJSONLineDecoder`, `LichessURLSession`, `BackoffPolicy`
/// and `ConnectionStateBroadcaster` exactly as `TVFeedStream` does.
///
/// ## Knowing the game ended
///
/// `TVEvent` is frozen, so there is no `.gameOver` event. Instead **the stream finishes
/// normally** when Lichess reports a terminal status, and the reason is left on the client:
///
/// ```swift
/// for try await event in stream.events(gameId: id) { … }
/// if let termination = stream.lastTermination { … }        // why it ended
/// ```
///
/// A property read *after* the `for await` loop is the cleanest of the options: it needs no
/// second task, no second concurrency surface, and there is no ordering question — the loop
/// cannot exit before the terminal line has been seen. A second `AsyncStream<GameStatus>`
/// would have to be consumed concurrently to avoid dropping the one value it ever carries.
/// `termination(forGameId:)` keys the same information when one client streams several games.
/// A stream that ends because the consumer cancelled leaves `lastTermination` untouched.
public final class GameStream: @unchecked Sendable {   // @unchecked: URLSession is not Sendable; mutable state is lock-guarded

    /// Why a game stream finished normally.
    public struct Termination: Sendable, Equatable {
        public let gameId: String
        public let status: GameStatus

        public init(gameId: String, status: GameStatus) {
            self.gameId = gameId
            self.status = status
        }
    }

    private let session: URLSession
    private let baseURL: URL
    private let configuration: TVFeedStream.Configuration
    private let broadcaster = ConnectionStateBroadcaster()

    private let lock = NSLock()
    private var terminations: [String: Termination] = [:]
    private var mostRecent: Termination?

    public init(
        session: URLSession = LichessURLSession.streaming,
        baseURL: URL = LichessConfig.baseURL,
        configuration: TVFeedStream.Configuration = TVFeedStream.Configuration()
    ) {
        self.session = session
        self.baseURL = baseURL
        self.configuration = configuration
    }

    /// Every connection transition, with the current state replayed first.
    public var connectionStates: AsyncStream<ConnectionState> { broadcaster.subscribe() }

    public var currentConnectionState: ConnectionState? { broadcaster.current }

    /// Ends all `connectionStates` subscriptions. Only for retiring the client.
    public func finish() { broadcaster.finish() }

    /// The most recent game-over report seen by this client.
    public var lastTermination: Termination? {
        lock.lock(); defer { lock.unlock() }
        return mostRecent
    }

    /// The final status of the most recently finished game, for callers that only want the status.
    public var lastStatus: GameStatus? { lastTermination?.status }

    /// The game-over report for a specific game, if this client has seen one.
    public func termination(forGameId gameId: String) -> Termination? {
        lock.lock(); defer { lock.unlock() }
        return terminations[gameId]
    }

    /// Events for one game. Finishes normally once the game is over (see the type documentation);
    /// reconnects with backoff if the connection drops before then.
    public func events(gameId: String) -> AsyncThrowingStream<TVEvent, Error> {
        let sourced = sourcedEvents(gameId: gameId)
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do {
                    for try await event in sourced { continuation.yield(event.event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The same events, each marked as replayed history or live play.
    ///
    /// The endpoint replays the whole game from move one before it goes live, with nothing on
    /// the wire to mark the join; `HistoryBoundaryDetector` finds it from the timing of the
    /// lines, or from `liveFen` when the caller already knows where the game stands (the TV
    /// channel feed announces that with the featured game).
    public func sourcedEvents(gameId: String, liveFen: String? = nil) -> AsyncThrowingStream<SourcedEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                await self.run(gameId: gameId, liveFen: liveFen, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Reconnect loop

    private func run(
        gameId: String,
        liveFen: String?,
        continuation: AsyncThrowingStream<SourcedEvent, Error>.Continuation
    ) async {
        var backoff = BackoffPolicy(
            base: configuration.baseDelay,
            cap: configuration.maxDelay,
            jitterFraction: configuration.jitterFraction
        )
        // Survives reconnects so a replayed move history is not emitted twice.
        var seen = SeenState()

        while !Task.isCancelled {
            broadcaster.send(.connecting)
            let startedAt = ContinuousClock.now
            do {
                let status = try await connectOnce(gameId: gameId, liveFen: liveFen, seen: &seen, continuation: continuation)
                if let status, status.isOver {
                    record(Termination(gameId: gameId, status: status))
                    log.info("Game \(gameId, privacy: .public) ended: \(status.name, privacy: .public)")
                    return
                }
                // The body closed without a terminal status: treat it as a dropped connection.
                throw LichessError.streamEndedUnexpectedly
            } catch {
                if Task.isCancelled || error.isCancellation {
                    log.debug("Game stream \(gameId, privacy: .public) cancelled")
                    return
                }
                if let lichess = error as? LichessError, lichess.isUnrecoverable {
                    log.error("Game stream \(gameId, privacy: .public) failed: \(lichess.description, privacy: .public)")
                    broadcaster.send(.failed(lichess.description))
                    continuation.finish(throwing: lichess)
                    return
                }
                let lasted = startedAt.duration(to: .now)
                if lasted >= configuration.healthyConnectionThreshold { backoff.reset() }
                var delay = backoff.nextDelay()
                if case .rateLimited(let retryAfter)? = error as? LichessError {
                    delay = max(delay, configuration.minimumRateLimitDelay)
                    if let retryAfter { delay = max(delay, retryAfter) }
                }
                log.error("Game stream \(gameId, privacy: .public) dropped after \(lasted.seconds, format: .fixed(precision: 1))s: \(String(describing: error), privacy: .public); retrying in \(delay.seconds, format: .fixed(precision: 1))s")
                broadcaster.send(.reconnecting(attempt: backoff.attempt, nextRetryIn: delay))
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
    }

    /// What has already been emitted, so a reconnect replaying the game does not duplicate it.
    private struct SeenState {
        var emittedFeatured = false
        var lastFen: String?
    }

    /// Runs one connection. Returns the terminal status if the game ended, `nil` if the
    /// server merely closed the body.
    private func connectOnce(
        gameId: String,
        liveFen: String?,
        seen: inout SeenState,
        continuation: AsyncThrowingStream<SourcedEvent, Error>.Continuation
    ) async throws -> GameStatus? {
        let url = baseURL.appendingPathComponent("api/stream/game").appendingPathComponent(gameId)
        let (bytes, response) = try await session.bytes(for: LichessURLSession.request(url))
        _ = try LichessHTTP.check(response)

        var lineDecoder = NDJSONLineDecoder()
        var terminal: GameStatus?
        var live = false
        // Fresh per connection: a reconnect replays the game again, and that replay is history
        // for a consumer that is fast-forwarding through it.
        var history = HistoryBoundaryDetector(liveFen: liveFen, startedAt: .now)

        for try await byte in bytes {
            try Task.checkCancellation()
            guard let line = lineDecoder.append(byte: byte) else { continue }
            guard let decoded = decodeOrSkip(line, gameId: gameId) else { continue }
            if !live {
                live = true
                broadcaster.send(.live)
            }
            switch decoded {
            case .metadata(let metadata):
                if !seen.emittedFeatured {
                    seen.emittedFeatured = true
                    let fen = metadata.fen ?? Position.standard.fen
                    seen.lastFen = metadata.fen
                    let featured = TVEvent.featured(
                        gameId: metadata.id ?? gameId,
                        orientation: .white,
                        players: metadata.players,
                        fen: fen
                    )
                    continuation.yield(SourcedEvent(event: featured, isHistorical: history.classify(featured)))
                } else if let fen = metadata.fen, fen != seen.lastFen {
                    // The closing summary can carry a position the move lines never delivered.
                    // Preserve it before reporting the result, without inventing a last move.
                    seen.lastFen = fen
                    continuation.yield(SourcedEvent(event: .fen(fen: fen, lastMove: nil,
                        whiteClock: nil, blackClock: nil), isHistorical: false))
                }
                if let status = metadata.status, status.isOver { terminal = status }
            case .move(let fen, let lastMove, let whiteClock, let blackClock):
                guard fen != seen.lastFen else { continue }
                seen.lastFen = fen
                let move = TVEvent.fen(fen: fen, lastMove: lastMove, whiteClock: whiteClock, blackClock: blackClock)
                let isHistorical = history.classify(move)
                continuation.yield(SourcedEvent(event: move, isHistorical: isHistorical,
                    historyComplete: isHistorical && liveFen != nil ? history.isLive : nil))
            }
            if terminal != nil { break }
        }
        if lineDecoder.flush() != nil {
            log.notice("Game stream ended mid-line; discarding the partial event")
        }
        log.debug("Game \(gameId, privacy: .public): \(history.historicalCount) replayed plies before the stream went live")
        return terminal
    }

    private func decodeOrSkip(_ line: String, gameId: String) -> GameStreamLine? {
        do {
            return try GameStreamLineDecoder.decode(line: line)
        } catch {
            log.error("Skipping malformed game-stream line for \(gameId, privacy: .public) (\(line.count) chars): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func record(_ termination: Termination) {
        lock.lock()
        terminations[termination.gameId] = termination
        mostRecent = termination
        lock.unlock()
    }
}

// MARK: - Line decoding

/// One decoded line of `/api/stream/game/{id}`.
enum GameStreamLine: Equatable {
    /// The first line, and the final line when the game ends.
    case metadata(GameStreamMetadata)
    /// One move: `{"fen":…,"lm":…,"wc":…,"bc":…}`.
    case move(fen: String, lastMove: String?, whiteClock: Int?, blackClock: Int?)
}

struct GameStreamMetadata: Equatable {
    let id: String?
    let players: [TVPlayer]
    /// Only present on the closing line.
    let fen: String?
    let status: GameStatus?
}

/// Splits a game-stream line into metadata or a move.
///
/// The endpoint has no `t` discriminator: a line carrying `players` is metadata, anything
/// else carrying `fen` is a move.
enum GameStreamLineDecoder {
    static func decode(line: String) throws -> GameStreamLine? {
        guard let data = line.data(using: .utf8) else { throw LichessError.malformedBody }
        return try decode(data: data)
    }

    static func decode(data: Data) throws -> GameStreamLine? {
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        if let players = wire.players {
            return .metadata(GameStreamMetadata(
                id: wire.id,
                players: [players.white.player(color: .white), players.black.player(color: .black)],
                fen: wire.fen,
                status: wire.status.map { GameStatus(id: $0.id, name: $0.name ?? "unknown", winner: wire.winner.flatMap(PieceColor.init(wire:))) }
            ))
        }
        guard let fen = wire.fen else { return nil }
        return .move(fen: fen, lastMove: wire.lm, whiteClock: wire.wc, blackClock: wire.bc)
    }

    private struct Wire: Decodable {
        struct Players: Decodable {
            let white: Side
            let black: Side
        }
        struct Side: Decodable {
            struct User: Decodable {
                let name: String?
                let title: String?
            }
            let user: User?
            let rating: Int?
            /// Present instead of `user` for engine opponents.
            let aiLevel: Int?

            func player(color: PieceColor) -> TVPlayer {
                TVPlayer(
                    name: user?.name ?? aiLevel.map { "Stockfish level \($0)" } ?? "Anonymous",
                    title: user?.title,
                    rating: rating,
                    color: color,
                    // The game stream carries clocks on the move lines, never on the metadata line.
                    secondsRemaining: nil
                )
            }
        }
        struct Status: Decodable {
            let id: Int?
            let name: String?
        }
        let id: String?
        let players: Players?
        let fen: String?
        let lm: String?
        let wc: Int?
        let bc: Int?
        let status: Status?
        let winner: String?
    }
}
