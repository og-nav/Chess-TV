// EngineChannel — the only place that touches the Stockfish pipes.
//
// A dedicated POSIX thread owns the blocking read side. It parses every line it
// receives and, when a search is active, turns `info` lines into `Evaluation`
// values straight into that search's AsyncStream continuation. Nothing blocks
// inside `UCIEngine`: the actor only mutates small pieces of state behind this
// class' lock.

import Foundation
import os
#if canImport(Darwin)
import Darwin
#endif
import CStockfish

let engineLogger = Logger(subsystem: "com.navin.chesstv", category: "EngineKit")

/// Whether a Stockfish UCI loop is running in this process. Used by the tests
/// to prove that every shutdown really joined the engine thread.
var engineIsRunning: Bool { sf_is_running() != 0 }

/// Stops the engine the way process exit does: without a `quit` from the host.
/// The bridge runs the same routine from its `atexit` handler, so a test that
/// calls this exercises the path that keeps a process from aborting when it
/// exits with an engine still running. `true` if the UCI loop returned in time.
@discardableResult
func engineForceShutdown(timeout: Duration = .seconds(2)) -> Bool {
    sf_shutdown_now(Int32(timeout.milliseconds)) != 0
}

/// A search the reader thread is currently feeding.
private struct ActiveSearch {
    /// Distinguishes this search from the one that replaced it.
    let id: Int
    let fen: String
    let revision: Int
    /// `true` when Black is to move, so scores must be negated for White's perspective.
    let negate: Bool
    let continuation: AsyncStream<Evaluation>.Continuation
    /// Deepest iteration already delivered, so one search yields one Evaluation
    /// per depth however many `info` lines Stockfish prints for it.
    var deliveredDepth = 0
}

final class EngineChannel: @unchecked Sendable {

    private let lock = ConditionLock()

    // Descriptors the host keeps. The two ends handed to Stockfish are closed
    // immediately after `sf_start` duplicates them onto 0 and 1.
    private var writeFD: Int32 = -1
    private var readFD: Int32 = -1

    private var readerThread: Thread?
    private var active: ActiveSearch?
    private var nextSearchID = 1
    private var searchRunning = false
    /// The last few commands written to the engine, for tests and diagnostics.
    private var sentCommands: [String] = []
    private var bestmoveWaiters: [CheckedContinuation<Void, Never>] = []
    private var awaitedToken: String?
    private var awaitedTokenSeen = false
    private var closed = false

    // MARK: - Lifecycle

    /// Creates the pipes and starts the Stockfish UCI loop.
    /// - Throws: `EngineError.startupFailed` if a pipe or the engine thread could not be created.
    init() throws {
        var toEngine: [Int32] = [-1, -1]
        var fromEngine: [Int32] = [-1, -1]

        guard pipe(&toEngine) == 0 else {
            throw EngineError.startupFailed("pipe() failed: \(String(cString: strerror(errno)))")
        }
        guard pipe(&fromEngine) == 0 else {
            Darwin.close(toEngine[0]); Darwin.close(toEngine[1])
            throw EngineError.startupFailed("pipe() failed: \(String(cString: strerror(errno)))")
        }

        let rc = sf_start(toEngine[0], fromEngine[1])
        // `sf_start` dup2s both onto STDIN/STDOUT, so these copies are done.
        Darwin.close(toEngine[0])
        Darwin.close(fromEngine[1])
        guard rc == 0 else {
            Darwin.close(toEngine[1]); Darwin.close(fromEngine[0])
            throw EngineError.startupFailed("sf_start returned \(rc)")
        }

        writeFD = toEngine[1]
        readFD = fromEngine[0]

        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "com.navin.chesstv.engine-reader"
        thread.stackSize = 512 * 1024
        readerThread = thread
        thread.start()
    }

    /// Sends `quit`, joins the engine thread, and tears the pipes down.
    /// Safe to call more than once.
    func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        let fd = writeFD
        writeFD = -1
        let search = active
        active = nil
        searchRunning = false
        let waiters = bestmoveWaiters
        bestmoveWaiters = []
        lock.unlock()

        search?.continuation.finish()
        for waiter in waiters { waiter.resume() }

        if fd >= 0 {
            _ = sendBytes("quit\n", to: fd)
            // End of file is the loop's other exit, in case `quit` was missed.
            Darwin.close(fd)
        }

        // Joins the UCI thread and restores the process' real stdin/stdout,
        // which closes the pipe ends Stockfish held on descriptors 0 and 1.
        sf_stop()

        lock.lock()
        let rfd = readFD
        readFD = -1
        lock.unlock()
        if rfd >= 0 { Darwin.close(rfd) }

        // The reader sees end of file once both write ends are gone.
        while let thread = readerThread, !thread.isFinished {
            usleep(1_000)
        }
        readerThread = nil
    }

    // MARK: - Writing

    func send(_ command: String) {
        lock.lock()
        let fd = writeFD
        lock.unlock()
        guard fd >= 0 else { return }
        recordSent(command)
        engineLogger.debug("→ \(command, privacy: .public)")
        _ = sendBytes(command + "\n", to: fd)
    }

    private func recordSent(_ command: String) {
        lock.lock()
        sentCommands.append(command)
        if sentCommands.count > 32 { sentCommands.removeFirst(sentCommands.count - 32) }
        lock.unlock()
    }

    /// The last 32 commands sent, oldest first.
    func recentCommands() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return sentCommands
    }

    private func sendBytes(_ string: String, to fd: Int32) -> Bool {
        let bytes = Array(string.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer -> Int in
                write(fd, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written <= 0 {
                if errno == EINTR { continue }
                engineLogger.error("write to engine failed: \(String(cString: strerror(errno)), privacy: .public)")
                return false
            }
            offset += written
        }
        return true
    }

    // MARK: - Handshake support

    /// Blocks the calling thread until a line starting with `token` arrives.
    /// Used only by `UCIEngine.init`, which the frozen contract makes synchronous.
    func waitForToken(_ token: String, timeout: TimeInterval) -> Bool {
        lock.lock()
        awaitedToken = token
        awaitedTokenSeen = false
        let deadline = Date().addingTimeInterval(timeout)
        while !awaitedTokenSeen && !closed {
            if !lock.wait(until: deadline) { break }
        }
        let seen = awaitedTokenSeen
        awaitedToken = nil
        awaitedTokenSeen = false
        lock.unlock()
        return seen
    }

    // MARK: - Searches

    /// Installs `search` as the destination for `info` lines. Returns the search
    /// it replaced, if any, so the caller can finish that stream.
    func beginSearch(fen: String,
                     revision: Int,
                     negate: Bool,
                     continuation: AsyncStream<Evaluation>.Continuation) {
        lock.lock()
        active = ActiveSearch(id: nextSearchID,
                              fen: fen,
                              revision: revision,
                              negate: negate,
                              continuation: continuation)
        nextSearchID += 1
        searchRunning = true
        lock.unlock()
    }

    /// Detaches the current search without finishing its stream; the caller owns it.
    func takeActiveContinuation() -> AsyncStream<Evaluation>.Continuation? {
        lock.lock()
        let continuation = active?.continuation
        active = nil
        lock.unlock()
        return continuation
    }

    var isSearchRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return searchRunning
    }

    /// Suspends until the running search reports `bestmove`, or `timeout` elapses.
    func waitForBestmove(timeout: Duration) async {
        lock.lock()
        guard searchRunning, !closed else {
            lock.unlock()
            return
        }
        lock.unlock()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    if !searchRunning || closed {
                        lock.unlock()
                        continuation.resume()
                    } else {
                        bestmoveWaiters.append(continuation)
                        lock.unlock()
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            await group.next()
            group.cancelAll()
            // The waiter task cannot be cancelled out of `withCheckedContinuation`,
            // so release every waiter once one of the two arms won.
            self.releaseBestmoveWaiters()
            await group.waitForAll()
        }
    }

    private func releaseBestmoveWaiters() {
        lock.lock()
        let waiters = bestmoveWaiters
        bestmoveWaiters = []
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    // MARK: - Reader thread

    private func readLoop() {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)

        while true {
            lock.lock()
            let fd = readFD
            lock.unlock()
            guard fd >= 0 else { break }

            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            if count == 0 { break }  // end of file: the engine is gone

            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
                let lineData = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                handle(line: line.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        // The engine died or was shut down: release everyone still waiting.
        lock.lock()
        let search = active
        active = nil
        searchRunning = false
        let waiters = bestmoveWaiters
        bestmoveWaiters = []
        lock.broadcast()
        lock.unlock()
        search?.continuation.finish()
        for waiter in waiters { waiter.resume() }
    }

    private func handle(line: String) {
        guard !line.isEmpty else { return }
        engineLogger.debug("← \(line, privacy: .public)")

        lock.lock()
        if let token = awaitedToken, line.hasPrefix(token) {
            awaitedTokenSeen = true
            lock.broadcast()
        }
        let search = active
        lock.unlock()

        if line.hasPrefix("bestmove") {
            lock.lock()
            active = nil
            searchRunning = false
            let waiters = bestmoveWaiters
            bestmoveWaiters = []
            lock.unlock()
            search?.continuation.finish()
            for waiter in waiters { waiter.resume() }
            return
        }

        guard let search, line.hasPrefix("info ") else { return }
        guard let evaluation = UCIParser.evaluation(from: line,
                                                    fen: search.fen,
                                                    revision: search.revision,
                                                    negate: search.negate) else { return }

        // Shallow iterations complete in microseconds, and a long `go depth`
        // search can print several scored lines for one iteration, so only the
        // first line of each new depth reaches the stream. Nothing useful is
        // lost: the later lines of an iteration are re-searches of the same
        // depth, and the UI only ever shows the deepest score.
        lock.lock()
        guard var current = active, current.id == search.id, evaluation.depth > current.deliveredDepth else {
            lock.unlock()
            return
        }
        current.deliveredDepth = evaluation.depth
        active = current
        lock.unlock()

        search.continuation.yield(evaluation)
    }
}
