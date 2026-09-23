// One Stockfish child process, spoken to over UCI.
//
// The server shares its box with other people's services, so the process is started under the
// kernel's idle scheduling class (`chrt --idle 0`) when `chrt` exists: it then runs only on CPU
// time nothing else wants, and a busy neighbour costs this server analysis latency rather than
// costing the neighbour anything. The class is set before `exec`, so every thread Stockfish
// starts inherits it. One thread, a small hash, one search at a time.
//
// Foundation's `Process` and a blocking reader thread rather than anything newer: this has to
// build with swift-corelibs-foundation on Linux, where `FileHandle.bytes` does not exist.

import Foundation
import Logging

public struct UCISearchResult: Sendable, Equatable {
    /// White's point of view.
    public var score: EngineScore
    public var depth: Int
    public var bestMove: String?
}

public enum UCIError: Error, Sendable, Equatable {
    case notExecutable(String)
    case exited
    case timedOut
    case noScore
}

public struct UCIConfiguration: Sendable {
    public var executablePath: String
    public var hashMegabytes: Int = 32
    /// Prefixed to the command line when it exists. Nil or missing means start Stockfish directly,
    /// which is what a Mac running the tests gets.
    public var launcherPath: String? = "/usr/bin/chrt"
    public var launcherArguments: [String] = ["--idle", "0"]

    public init(executablePath: String, hashMegabytes: Int = 32) {
        self.executablePath = executablePath
        self.hashMegabytes = hashMegabytes
    }
}

public actor UCIProcess {

    private let configuration: UCIConfiguration
    private let logger: Logger
    private var process: Process?
    private var input: FileHandle?
    private var lines: LineChannel?

    public init(configuration: UCIConfiguration, logger: Logger = ServerLog.make("engine")) {
        self.configuration = configuration
        self.logger = logger
    }

    public var isRunning: Bool { process?.isRunning == true }

    /// Starts the engine if it is not running. Cheap to call before every search.
    public func start() async throws {
        if isRunning { return }
        await stop()

        guard FileManager.default.isExecutableFile(atPath: configuration.executablePath) else {
            throw UCIError.notExecutable(configuration.executablePath)
        }
        let process = Process()
        if let launcher = configuration.launcherPath, FileManager.default.isExecutableFile(atPath: launcher) {
            process.executableURL = URL(fileURLWithPath: launcher)
            process.arguments = configuration.launcherArguments + [configuration.executablePath]
        } else {
            process.executableURL = URL(fileURLWithPath: configuration.executablePath)
        }
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let channel = LineChannel()
        try process.run()
        self.process = process
        self.input = stdin.fileHandleForWriting
        self.lines = channel

        let reader = stdout.fileHandleForReading
        let thread = Thread {
            var pending = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...newline)
                    channel.push(line.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            channel.close()
        }
        thread.name = "stockfish-reader"
        thread.start()

        do {
            try send("uci")
            try await expect("uciok", within: 10)
            try send("setoption name Threads value 1")
            try send("setoption name Hash value \(configuration.hashMegabytes)")
            try send("isready")
            try await expect("readyok", within: 30)
        } catch {
            await stop()
            throw error
        }
        logger.info("engine started", metadata: [
            "pid": .stringConvertible(process.processIdentifier),
            "idle_class": .stringConvertible(process.arguments?.first == "--idle"),
        ])
    }

    /// Searches one position for a fixed time. The engine is started if needed; a search that
    /// does not come back is treated as a dead engine and the process is replaced next time.
    public func search(fen: String, movetimeMs: Int) async throws -> UCISearchResult {
        try await start()
        guard let lines else { throw UCIError.exited }
        let whiteToMove = fen.split(separator: " ").dropFirst().first != "b"

        try send("position fen \(fen)")
        try send("go movetime \(movetimeMs)")

        var score: EngineScore?
        var depth = 0
        let deadline = Date().addingTimeInterval(Double(movetimeMs) / 1000 + 10)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, let line = await lines.next(timeout: remaining) else {
                logger.warning("engine did not answer; restarting it next time")
                await stop()
                throw lines.isClosed ? UCIError.exited : UCIError.timedOut
            }
            if line.hasPrefix("bestmove") {
                guard let score else { throw UCIError.noScore }
                let move = line.split(separator: " ").dropFirst().first.map(String.init)
                return UCISearchResult(score: score, depth: depth, bestMove: move == "(none)" ? nil : move)
            }
            if let info = Self.parseInfo(line, whiteToMove: whiteToMove) {
                score = info.score
                depth = info.depth
            }
        }
    }

    /// Asks the engine to quit, then makes sure it has.
    public func stop() async {
        guard let process else { return }
        if process.isRunning {
            try? send("quit")
            for _ in 0..<20 where process.isRunning {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning { process.terminate() }
            logger.info("engine stopped")
        }
        try? input?.close()
        lines?.close()
        self.process = nil
        self.input = nil
        self.lines = nil
    }

    private func send(_ command: String) throws {
        guard let input, process?.isRunning == true else { throw UCIError.exited }
        try input.write(contentsOf: Data((command + "\n").utf8))
    }

    private func expect(_ token: String, within seconds: TimeInterval) async throws {
        guard let lines else { throw UCIError.exited }
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, let line = await lines.next(timeout: remaining) else {
                throw lines.isClosed ? UCIError.exited : UCIError.timedOut
            }
            if line == token { return }
        }
    }

    /// The score and depth of an `info` line, or nil for any other line and for a bound: a
    /// `lowerbound` or `upperbound` score is a search-window artefact, not an evaluation.
    static func parseInfo(_ line: String, whiteToMove: Bool) -> (score: EngineScore, depth: Int)? {
        guard line.hasPrefix("info ") else { return nil }
        let words = line.split(separator: " ")
        guard !words.contains("lowerbound"), !words.contains("upperbound") else { return nil }
        if let index = words.firstIndex(of: "multipv"), index + 1 < words.count, words[index + 1] != "1" { return nil }
        guard let scoreIndex = words.firstIndex(of: "score"), scoreIndex + 2 < words.count else { return nil }
        let value = Int(words[scoreIndex + 2])
        let unit = words[scoreIndex + 1]
        let score = EngineScore.fromUCI(
            centipawns: unit == "cp" ? value : nil,
            mate: unit == "mate" ? value : nil,
            whiteToMove: whiteToMove
        )
        guard let score else { return nil }
        let depth = words.firstIndex(of: "depth").flatMap { $0 + 1 < words.count ? Int(words[$0 + 1]) : nil } ?? 0
        return (score, depth)
    }
}

/// Lines from the reader thread to the actor, one waiter at a time.
final class LineChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [String] = []
    private var waiter: (id: Int, continuation: CheckedContinuation<String?, Never>)?
    private var nextWaiter = 0
    private var closed = false

    var isClosed: Bool { lock.withLock { closed } }

    func push(_ line: String) {
        let resume: CheckedContinuation<String?, Never>? = lock.withLock {
            guard !closed else { return nil }
            if let waiter {
                self.waiter = nil
                return waiter.continuation
            }
            buffer.append(line)
            return nil
        }
        resume?.resume(returning: line)
    }

    func close() {
        let resume: CheckedContinuation<String?, Never>? = lock.withLock {
            closed = true
            defer { waiter = nil }
            return waiter?.continuation
        }
        resume?.resume(returning: nil)
    }

    /// The next line, or nil when the process is gone or nothing arrived in time.
    func next(timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { continuation in
            let id: Int? = lock.withLock {
                if !buffer.isEmpty {
                    continuation.resume(returning: buffer.removeFirst())
                    return nil
                }
                if closed {
                    continuation.resume(returning: nil)
                    return nil
                }
                nextWaiter += 1
                waiter = (nextWaiter, continuation)
                return nextWaiter
            }
            guard let id else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                let expired: CheckedContinuation<String?, Never>? = self.lock.withLock {
                    guard let waiter = self.waiter, waiter.id == id else { return nil }
                    self.waiter = nil
                    return waiter.continuation
                }
                expired?.resume(returning: nil)
            }
        }
    }
}
