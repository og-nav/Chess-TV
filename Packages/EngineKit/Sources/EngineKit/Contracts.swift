// EngineKit — frozen contracts (see TV_BUILD_PLAN.md).
import Foundation

public struct Evaluation: Sendable, Equatable {
    public enum Score: Sendable, Equatable {
        /// Always from White's perspective.
        case centipawns(Int)
        /// Positive = White mates in N, negative = Black mates in N.
        case mate(Int)
    }
    public let score: Score
    public let depth: Int
    public let principalVariation: [String]
    public let positionFEN: String
    public let revision: Int
    public init(score: Score, depth: Int, principalVariation: [String], positionFEN: String, revision: Int) {
        self.score = score; self.depth = depth; self.principalVariation = principalVariation; self.positionFEN = positionFEN; self.revision = revision
    }
}

public enum EngineError: Error, Sendable, Equatable {
    case networkFileMissing(String)
    case startupFailed(String)
    case notReady
    case unimplemented
}

/// How far a single search runs.
public enum EngineSearchLimit: Sendable, Equatable {
    /// Search for a fixed amount of time, then report `bestmove`.
    case movetime(Duration)
    /// Keep deepening until this depth is reached, however long that takes.
    case depth(Int)

    /// Stockfish counts plies up to 245; anything past that is rejected.
    static let maxSupportedDepth = 245

    /// The `go` command this limit maps to.
    var goCommand: String {
        switch self {
        case .movetime(let duration):
            return "go movetime \(max(1, duration.milliseconds))"
        case .depth(let depth):
            return "go depth \(min(max(1, depth), Self.maxSupportedDepth))"
        }
    }
}

/// A running Stockfish 19 instance, driven over a pipe pair.
///
/// One instance per process: Stockfish reads UCI commands from `stdin`, so the
/// bridge redirects the process' descriptors and only one engine can own them.
/// Call `shutdown()` before creating another.
public actor UCIEngine {

    /// How long `init` waits for `uciok` and for `readyok`.
    private static let handshakeTimeout: TimeInterval = 10

    let channel: EngineChannel
    private var searchTask: Task<Void, Never>?
    private(set) var isShutDown = false

    public init(networkURL: URL, threads: Int, hashMB: Int) throws {
        guard FileManager.default.fileExists(atPath: networkURL.path) else {
            throw EngineError.networkFileMissing(networkURL.path)
        }

        let channel = try EngineChannel()
        self.channel = channel

        channel.send("uci")
        guard channel.waitForToken("uciok", timeout: Self.handshakeTimeout) else {
            channel.close()
            throw EngineError.startupFailed("no uciok within \(Int(Self.handshakeTimeout))s")
        }

        channel.send("setoption name EvalFile value \(networkURL.path)")
        channel.send("setoption name Threads value \(max(1, threads))")
        channel.send("setoption name Hash value \(max(1, hashMB))")
        channel.send("setoption name MultiPV value 1")
        channel.send("isready")
        guard channel.waitForToken("readyok", timeout: Self.handshakeTimeout) else {
            channel.close()
            throw EngineError.startupFailed("no readyok within \(Int(Self.handshakeTimeout))s")
        }

        engineLogger.info("Stockfish ready (threads \(threads), hash \(hashMB) MB)")
    }

    /// Stops any running search, then evaluates `fen` for a fixed amount of time.
    /// Every emitted Evaluation carries `fen` and `revision`.
    /// The stream finishes after `bestmove` or when superseded by a newer call.
    public func evaluate(fen: String, movetime: Duration, revision: Int) -> AsyncStream<Evaluation> {
        evaluate(fen: fen, limit: .movetime(movetime), revision: revision)
    }

    /// Stops any running search, then evaluates `fen`, deepening until `maxDepth`.
    ///
    /// Used while watching a game: between two moves there may be minutes, so the
    /// search keeps iterating instead of stopping after a fixed slice of time. The
    /// stream finishes on `bestmove` (the depth cap was reached) or as soon as a
    /// newer call supersedes it, whichever comes first.
    public func evaluate(fen: String, maxDepth: Int, revision: Int) -> AsyncStream<Evaluation> {
        evaluate(fen: fen, limit: .depth(maxDepth), revision: revision)
    }

    /// Stops any running search, then evaluates `fen` under `limit`. Every emitted
    /// Evaluation carries `fen` and `revision`, one per depth the search completes.
    /// The stream finishes after `bestmove` or when superseded by a newer call.
    public func evaluate(fen: String, limit: EngineSearchLimit, revision: Int) -> AsyncStream<Evaluation> {
        let (stream, continuation) = AsyncStream<Evaluation>.makeStream(bufferingPolicy: .unbounded)

        guard !isShutDown else {
            continuation.finish()
            return stream
        }

        // Supersede whatever was running: detach its continuation from the
        // reader, finish it, and cancel the task that was driving it.
        let superseded = channel.takeActiveContinuation()
        searchTask?.cancel()
        superseded?.finish()

        let negate = UCIParser.blackToMove(fen: fen) ?? false
        let go = limit.goCommand
        let channel = self.channel

        searchTask = Task {
            // A task that was superseded before it ever ran must not send
            // `stop` at the search its successor has already started.
            guard !Task.isCancelled else {
                continuation.finish()
                return
            }
            // `stop` is only meaningful while a search is running, and the next
            // `position` must not race the outgoing `bestmove`.
            if channel.isSearchRunning {
                channel.send("stop")
                await channel.waitForBestmove(timeout: .seconds(5))
            }
            guard !Task.isCancelled else {
                continuation.finish()
                return
            }
            channel.beginSearch(fen: fen, revision: revision, negate: negate, continuation: continuation)
            channel.send("position fen \(fen)")
            channel.send(go)
        }

        return stream
    }

    public func stop() async {
        guard !isShutDown else { return }
        searchTask?.cancel()
        searchTask = nil
        // Detach this search before suspending. A new evaluate() may enter the actor
        // while we await bestmove; it owns a different continuation that must survive.
        channel.takeActiveContinuation()?.finish()
        if channel.isSearchRunning {
            channel.send("stop")
            await channel.waitForBestmove(timeout: .seconds(5))
        }
    }

    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        searchTask?.cancel()
        searchTask = nil
        channel.close()
        engineLogger.info("Stockfish shut down")
    }
}

extension Duration {
    /// Whole milliseconds, rounded down, clamped at zero.
    var milliseconds: Int {
        let (seconds, attoseconds) = components
        let millis = seconds * 1_000 + attoseconds / 1_000_000_000_000_000
        return millis > 0 ? Int(millis) : 0
    }
}
