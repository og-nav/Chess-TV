import Foundation
import Testing
@testable import FollowServer

/// Against a real Stockfish, when one is named: `FOLLOW_TEST_STOCKFISH=/path/to/stockfish swift test`.
/// Skipped otherwise, because CI and a fresh checkout have no engine binary.
@Suite("Engine process", .enabled(if: ProcessInfo.processInfo.environment["FOLLOW_TEST_STOCKFISH"] != nil))
struct EngineProcessTests {

    private var engine: UCIProcess {
        var configuration = UCIConfiguration(executablePath: ProcessInfo.processInfo.environment["FOLLOW_TEST_STOCKFISH"] ?? "")
        configuration.hashMegabytes = 16
        return UCIProcess(configuration: configuration)
    }

    @Test("Scores come back from White's side, mates included, and the engine restarts after a stop")
    func searches() async throws {
        let engine = self.engine
        // Black to move and mated in one by …Qh4# is still White's point of view: negative.
        let foolsMate = "rnbqkbnr/pppp1ppp/8/4p3/6P1/5P2/PPPPP2P/RNBQKBNR b KQkq - 0 2"
        let result = try await engine.search(fen: foolsMate, movetimeMs: 300)
        #expect(result.score == .mate(-1))
        #expect(result.bestMove == "d8h4")

        await engine.stop()
        #expect(await engine.isRunning == false)

        let start = try await engine.search(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", movetimeMs: 300)
        guard case .centipawns(let cp) = start.score else { Issue.record("no centipawn score"); return }
        #expect(abs(cp) < 100)
        #expect(start.depth > 8)

        // A position that is already mate searches to `mate 0` and no move.
        let mated = try await engine.search(fen: "rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3", movetimeMs: 100)
        #expect(mated.score == .mate(0))
        #expect(mated.bestMove == nil)
        await engine.stop()
    }

    @Test("A missing binary is an error, not a crash")
    func missingBinary() async {
        let engine = UCIProcess(configuration: UCIConfiguration(executablePath: "/nonexistent/stockfish"))
        await #expect(throws: UCIError.notExecutable("/nonexistent/stockfish")) {
            try await engine.search(fen: "8/8/8/8/8/8/8/K6k w - - 0 1", movetimeMs: 10)
        }
    }
}
