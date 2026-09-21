import Foundation
import ChessCore

/// Follows one board of a broadcast round through `GET /api/stream/broadcast/round/{roundId}.pgn`,
/// **with the moves that were already played**.
///
/// `BroadcastBoardStream` polls the round JSON, which carries only the current FEN: a viewer who
/// joins at move 30 sees a board and no history. This endpoint instead pushes every game of the
/// round as complete PGN — first all of them, then a game's whole PGN again on each new move —
/// so the history is there for the taking. The PGN is replayed with `ChessCore` and turned into
/// the same `.featured` + `.fen` events every other source produces.
///
/// ## What it emits
///
/// * On the first PGN block for `gameId`: `.featured` (players, titles and ratings from the
///   tags, orientation white, the game's *setup* position and no clocks), then **one `.fen` per
///   ply** from move one, each with its UCI as `lastMove` and the `[%clk]` clocks in seconds. All
///   of these are flagged historical; the consumer reduces them privately and shows the result.
/// * On every later block for the same game: only the plies beyond the ones already emitted.
///   A re-sent identical PGN therefore emits nothing, which is what makes a reconnect — the
///   server resends every game — idempotent.
/// * If a later block diverges from what was emitted (a correction, a takeback, or a result that
///   changed with no new ply), a fresh `.featured` at the setup position is emitted and the whole
///   corrected line is re-sent as history.
///
/// ## Ending
///
/// Like `GameStream`, the stream **finishes normally** when the game's `Result` tag stops being
/// `*`, and the reason is left on the client as `lastResult`.
///
/// ```swift
/// for try await event in stream.events(roundId: r, gameId: g) { … }
/// if let result = stream.lastResult { … }        // "1-0", "1/2-1/2", …
/// ```
public final class BroadcastPGNStream: @unchecked Sendable {   // @unchecked: URLSession is not Sendable; mutable state is lock-guarded

    /// Why the stream for one board finished normally.
    public struct Termination: Sendable, Equatable {
        public let gameId: String
        /// The PGN result token: `"1-0"`, `"0-1"`, `"1/2-1/2"`.
        public let result: String

        public init(gameId: String, result: String) {
            self.gameId = gameId
            self.result = result
        }
    }

    /// Thrown when the PGN for the board could not be read `failures` times in a row.
    ///
    /// The caller's cue to fall back to polling; `GameSourceStreamer` does exactly that.
    public struct UnparseablePGN: Error, CustomStringConvertible, Sendable {
        public let roundId: String
        public let gameId: String
        public let failures: Int
        /// The last underlying failure, as text.
        public let reason: String

        public var description: String {
            "Broadcast PGN for \(gameId) in round \(roundId) failed to parse \(failures)× in a row: \(reason)"
        }
    }

    private let session: URLSession
    private let baseURL: URL
    private let configuration: TVFeedStream.Configuration
    /// Consecutive unreadable PGN blocks before the stream gives up.
    private let parseFailureLimit: Int
    private let broadcaster = ConnectionStateBroadcaster()
    private let replayCache: BroadcastPGNReplayCache

    private let lock = NSLock()
    private var terminations: [String: Termination] = [:]
    private var mostRecent: Termination?

    public convenience init(
        session: URLSession = LichessURLSession.streaming,
        baseURL: URL = LichessConfig.baseURL,
        configuration: TVFeedStream.Configuration = TVFeedStream.Configuration(),
        parseFailureLimit: Int = 3
    ) {
        self.init(session: session, baseURL: baseURL, configuration: configuration,
                  parseFailureLimit: parseFailureLimit, replayCache: .shared)
    }

    init(session: URLSession, baseURL: URL, configuration: TVFeedStream.Configuration,
         parseFailureLimit: Int = 3, replayCache: BroadcastPGNReplayCache) {
        self.replayCache = replayCache
        self.session = session
        self.baseURL = baseURL
        self.configuration = configuration
        self.parseFailureLimit = max(1, parseFailureLimit)
    }

    /// Every connection transition, with the current state replayed first.
    public var connectionStates: AsyncStream<ConnectionState> { broadcaster.subscribe() }
    public var currentConnectionState: ConnectionState? { broadcaster.current }

    /// Ends all `connectionStates` subscriptions. Only for retiring the client.
    public func finish() { broadcaster.finish() }

    /// The most recent finished board seen by this client.
    public var lastResult: Termination? {
        lock.lock(); defer { lock.unlock() }
        return mostRecent
    }

    /// The result for one board, if this client has seen it finish.
    public func result(forGameId gameId: String) -> Termination? {
        lock.lock(); defer { lock.unlock() }
        return terminations[gameId]
    }

    /// Events for one board of a round, history first. See the type documentation.
    public func events(roundId: String, gameId: String) -> AsyncThrowingStream<TVEvent, Error> {
        let sourced = sourcedEvents(roundId: roundId, gameId: gameId)
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do {
                    for try await sourcedEvent in sourced { continuation.yield(sourcedEvent.event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The same events, each marked as history or live. Every ply of the first PGN block that
    /// matches the board is history; everything after it is live.
    public func sourcedEvents(roundId: String, gameId: String) -> AsyncThrowingStream<SourcedEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                await self.run(roundId: roundId, gameId: gameId, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Reconnect loop

    private func run(
        roundId: String,
        gameId: String,
        continuation: AsyncThrowingStream<SourcedEvent, Error>.Continuation
    ) async {
        var backoff = BackoffPolicy(
            base: configuration.baseDelay,
            cap: configuration.maxDelay,
            jitterFraction: configuration.jitterFraction
        )
        // Survives reconnects: a reconnect resends every game from move one, and the ply
        // bookkeeping is what makes that a no-op instead of a duplicate history.
        var emitted = EmittedBoard()
        // Publish the complete cached replay before any network await. It remains historical:
        // only a fresh server response can confirm live clocks or a terminal result.
        guard !Task.isCancelled else { return }
        if let cached = replayCache.replay(roundId: roundId, gameId: gameId, origin: baseURL) {
            emit(game: cached.game, steps: cached.steps, gameId: gameId, emitted: &emitted, continuation: continuation, isCached: true)
        }

        while !Task.isCancelled {
            broadcaster.send(.connecting)
            let startedAt = ContinuousClock.now
            do {
                if let result = try await connectOnce(
                    roundId: roundId,
                    gameId: gameId,
                    emitted: &emitted,
                    continuation: continuation
                ) {
                    let termination = Termination(gameId: gameId, result: result)
                    record(termination)
                    log.info("Broadcast board \(gameId, privacy: .public) finished: \(result, privacy: .public)")
                    return
                }
                throw LichessError.streamEndedUnexpectedly
            } catch {
                if Task.isCancelled || error.isCancellation {
                    log.debug("Broadcast PGN stream \(gameId, privacy: .public) cancelled")
                    return
                }
                if let unparseable = error as? UnparseablePGN {
                    log.error("\(unparseable.description, privacy: .public)")
                    broadcaster.send(.failed(unparseable.description))
                    continuation.finish(throwing: unparseable)
                    return
                }
                if let lichess = error as? LichessError, lichess.isUnrecoverable {
                    log.error("Broadcast PGN stream \(gameId, privacy: .public) failed: \(lichess.description, privacy: .public)")
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
                log.error("Broadcast PGN stream \(gameId, privacy: .public) dropped after \(lasted.seconds, format: .fixed(precision: 1))s: \(String(describing: error), privacy: .public); retrying in \(delay.seconds, format: .fixed(precision: 1))s")
                broadcaster.send(.reconnecting(attempt: backoff.attempt, nextRetryIn: delay))
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
    }

    /// One connection. Returns the result token when the board finished, `nil` when the server
    /// merely closed the body.
    private func connectOnce(
        roundId: String,
        gameId: String,
        emitted: inout EmittedBoard,
        continuation: AsyncThrowingStream<SourcedEvent, Error>.Continuation
    ) async throws -> String? {
        let url = baseURL
            .appendingPathComponent("api/stream/broadcast/round")
            .appendingPathComponent("\(roundId).pgn")
        let (bytes, response) = try await session.bytes(for: LichessURLSession.request(url))
        _ = try LichessHTTP.check(response)

        var lineDecoder = PGNLineDecoder()
        var assembler = PGNBlockAssembler()
        var live = false
        var consecutiveFailures = 0

        func handle(block: String) throws -> String? {
            guard let game = PGN.parseGame(block), Self.block(game, matches: gameId) else { return nil }
            do {
                let steps = try game.replay(from: game.initialPosition)
                consecutiveFailures = 0
                replayCache.store(BroadcastPGNReplay(game: game, steps: steps), roundId: roundId, gameId: gameId, origin: baseURL)
                emit(game: game, steps: steps, gameId: gameId, emitted: &emitted, continuation: continuation)
                return game.isFinished ? game.outcome : nil
            } catch {
                consecutiveFailures += 1
                log.error("Broadcast PGN for \(gameId, privacy: .public) did not replay (\(consecutiveFailures)/\(self.parseFailureLimit)): \(String(describing: error), privacy: .public)")
                if consecutiveFailures >= parseFailureLimit {
                    throw UnparseablePGN(
                        roundId: roundId,
                        gameId: gameId,
                        failures: consecutiveFailures,
                        reason: String(describing: error)
                    )
                }
                return nil
            }
        }

        for try await byte in bytes {
            try Task.checkCancellation()
            guard let line = lineDecoder.append(byte: byte) else { continue }
            if !live {
                live = true
                broadcaster.send(.live)
            }
            guard let block = assembler.append(line: line) else { continue }
            if let result = try handle(block: block) { return result }
        }
        if let tail = lineDecoder.flush() { _ = assembler.append(line: tail) }
        if let block = assembler.finish(), let result = try handle(block: block) { return result }
        return nil
    }

    /// `[GameURL "…/{roundId}/{gameId}"]`, or a `Site` tag ending the same way.
    private static func block(_ game: PGNGame, matches gameId: String) -> Bool {
        if let id = game.gameId { return id == gameId }
        return game.gameURL?.hasSuffix("/\(gameId)") ?? false
    }

    // MARK: - Emitting

    /// What has already gone out for the board, so a re-sent PGN only adds what is new.
    private struct EmittedBoard {
        var emittedFeatured = false
        var initialFEN: String?
        var result: String?
        /// The FEN after each ply already emitted.
        var fens: [String] = []
    }

    private func emit(
        game: PGNGame,
        steps: [(san: String, uci: String, fen: String)],
        gameId: String,
        emitted: inout EmittedBoard,
        continuation: AsyncThrowingStream<SourcedEvent, Error>.Continuation,
        isCached: Bool = false
    ) {
        let clocks = Self.clocks(for: game)
        let newFens = steps.map(\.fen)
        let shared = Self.commonPrefix(emitted.fens, newFens)
        // A result that arrives *with* new plies (the mating move and "1-0" in one block, which is
        // how PGN-file sources always publish and DGT boards often do) is the normal end of a
        // game, not a correction: the plies go out live and the termination carries the result.
        // Only a result that changes with no new ply — a resignation, or a corrected result on
        // the same position — needs the featured/replay path.
        let needsReplay = !emitted.emittedFeatured
            || emitted.initialFEN != game.initialPosition.fen
            || (emitted.emittedFeatured && emitted.result != game.outcome && shared == newFens.count)
            || shared < emitted.fens.count
        let first = needsReplay ? 0 : shared

        if needsReplay {
            // Each PGN is authoritative, including takebacks. A featured event resets the
            // reducer, so start at the setup position and replay the entire corrected line.
            // Reconnecting with the same complete PGN remains a no-op.
            continuation.yield(SourcedEvent(
                event: .featured(
                    gameId: gameId,
                    orientation: .white,
                    players: Self.players(game, clocks: nil),
                    fen: game.initialPosition.fen
                ),
                isHistorical: true,
                historyComplete: newFens.isEmpty,
                isCached: isCached
            ))
            emitted.emittedFeatured = true
            emitted.initialFEN = game.initialPosition.fen
        }

        for index in first..<newFens.count {
            let clock = index < clocks.count ? clocks[index] : (white: nil, black: nil)
            continuation.yield(SourcedEvent(
                event: .fen(
                    fen: newFens[index],
                    lastMove: steps[index].uci,
                    whiteClock: clock.white,
                    blackClock: clock.black
                ),
                isHistorical: needsReplay,
                historyComplete: needsReplay ? index == newFens.count - 1 : nil,
                isCached: isCached
            ))
        }
        emitted.fens = newFens
        emitted.result = game.outcome
    }

    /// Both clocks after each ply. A `[%clk]` belongs to the player who just moved, so the other
    /// side's clock is carried forward from its own last move.
    private static func clocks(for game: PGNGame) -> [(white: Int?, black: Int?)] {
        var white: Int?
        var black: Int?
        var result: [(white: Int?, black: Int?)] = []
        result.reserveCapacity(game.moves.count)
        for (index, move) in game.moves.enumerated() {
            if let seconds = move.clockSeconds {
                let mover = index % 2 == 0 ? game.initialPosition.sideToMove : game.initialPosition.sideToMove.opposite
                if mover == .white { white = seconds } else { black = seconds }
            }
            result.append((white: white, black: black))
        }
        return result
    }

    private static func players(_ game: PGNGame, clocks: (white: Int?, black: Int?)?) -> [TVPlayer] {
        [
            TVPlayer(
                name: game.white ?? "Unknown",
                title: game.whiteTitle,
                rating: game.whiteElo,
                color: .white,
                secondsRemaining: clocks?.white
            ),
            TVPlayer(
                name: game.black ?? "Unknown",
                title: game.blackTitle,
                rating: game.blackElo,
                color: .black,
                secondsRemaining: clocks?.black
            ),
        ]
    }

    private static func commonPrefix(_ lhs: [String], _ rhs: [String]) -> Int {
        var index = 0
        while index < lhs.count, index < rhs.count, lhs[index] == rhs[index] { index += 1 }
        return index
    }

    private func record(_ termination: Termination) {
        lock.lock()
        terminations[termination.gameId] = termination
        mostRecent = termination
        lock.unlock()
    }
}

// MARK: - Splitting the stream into games

/// Turns the PGN stream's bytes into lines, **keeping the blank ones**.
///
/// `NDJSONLineDecoder` swallows blank lines as keep-alives; in PGN a blank line is structure —
/// it separates a game's tags from its movetext, and one game from the next.
struct PGNLineDecoder: Sendable {
    /// A PGN line longer than this is not something we can use.
    static let maxLineBytes = 1 << 20

    private var buffer: [UInt8] = []
    private var overflowing = false

    /// Feeds one byte. Returns the completed line — possibly the empty string — on a newline.
    mutating func append(byte: UInt8) -> String? {
        guard byte != UInt8(ascii: "\n") else { return takeLine() }
        guard !overflowing else { return nil }
        buffer.append(byte)
        if buffer.count > Self.maxLineBytes {
            log.error("PGN line exceeded \(Self.maxLineBytes) bytes; dropping until the next newline")
            buffer.removeAll(keepingCapacity: false)
            overflowing = true
        }
        return nil
    }

    mutating func append(_ chunk: some Sequence<UInt8>) -> [String] {
        var lines: [String] = []
        for byte in chunk {
            if let line = append(byte: byte) { lines.append(line) }
        }
        return lines
    }

    /// Whatever is left at end of body, if anything.
    mutating func flush() -> String? {
        buffer.isEmpty ? nil : takeLine()
    }

    private mutating func takeLine() -> String? {
        defer {
            buffer.removeAll(keepingCapacity: true)
            overflowing = false
        }
        guard !overflowing else { return nil }
        var bytes = buffer[...]
        if bytes.last == UInt8(ascii: "\r") { bytes = bytes.dropLast() }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Collects PGN lines until one game is complete.
///
/// A game ends at whichever of these comes first:
/// * a **tag line after movetext** — the next game's `[Event …]`; or
/// * a **blank line after movetext that ends in a result token** (`*`, `1-0`, `0-1`, `1/2-1/2`),
///   which is how the streaming endpoint closes a game it is about to re-send.
///
/// The second rule is what makes the stream usable live: waiting for the next `[Event` would
/// hold a game back until some *other* game moved. The blank line between a game's own tags and
/// its movetext never splits anything, because no movetext has been seen at that point.
struct PGNBlockAssembler {
    private var lines: [String] = []
    private var sawMovetext = false
    private var movetextEndsWithResult = false

    /// Feeds one line. Returns a complete game block when the line completed one.
    mutating func append(line raw: String) -> String? {
        let line = raw.trimmingWhitespace()

        if line.isEmpty {
            guard sawMovetext, movetextEndsWithResult else { return nil }
            return take()
        }

        if Self.isTagLine(line) {
            guard sawMovetext else {
                lines.append(line)
                return nil
            }
            let block = take()
            lines.append(line)
            return block
        }

        sawMovetext = true
        lines.append(line)
        movetextEndsWithResult = Self.endsWithResult(line)
        return nil
    }

    /// The block still being collected, at end of body.
    mutating func finish() -> String? {
        guard sawMovetext else { return nil }
        return take()
    }

    private mutating func take() -> String? {
        defer {
            lines.removeAll(keepingCapacity: true)
            sawMovetext = false
            movetextEndsWithResult = false
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func isTagLine(_ line: String) -> Bool {
        line.hasPrefix("[") && line.hasSuffix("]") && line.contains("\"")
    }

    private static func endsWithResult(_ line: String) -> Bool {
        guard let last = line.split(separator: " ").last else { return false }
        return PGN.isResultToken(String(last))
    }
}

extension String {
    /// Foundation's trimming without the `CharacterSet` dance.
    func trimmingWhitespace() -> String {
        var slice = Substring(self)
        while let first = slice.first, first.isWhitespace { slice = slice.dropFirst() }
        while let last = slice.last, last.isWhitespace { slice = slice.dropLast() }
        return String(slice)
    }
}
