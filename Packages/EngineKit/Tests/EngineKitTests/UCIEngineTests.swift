import Foundation
import Synchronization
import Testing
@testable import EngineKit

/// Stockfish owns the process' stdin and stdout, so only one engine can exist
/// at a time: the whole suite is serialised.
@Suite("UCIEngine", .serialized)
struct UCIEngineTests {

    static let startFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    static let mateForWhite = "6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1"
    static let mateForBlack = "r5k1/5ppp/8/8/8/8/5PPP/6K1 b - - 0 1"

    // MARK: - Lifecycle

    @Test func missingNetworkThrows() async throws {
        let bogus = URL(fileURLWithPath: "/tmp/definitely-not-a-network-\(UUID().uuidString).nnue")
        #expect(throws: EngineError.networkFileMissing(bogus.path)) {
            _ = try UCIEngine(networkURL: bogus, threads: 1, hashMB: 16)
        }
    }

    @Test(.timeLimit(.minutes(5)))
    func startAndShutdownTwentyTimesWithoutLeakingDescriptors() async throws {
        let network = try #require(TestSupport.networkURL, TestSupport.missingNetworkMessage)

        // One warm-up cycle: the first start allocates process-wide state
        // (the saved stdin/stdout duplicates) that later cycles reuse.
        let warmup = try UCIEngine(networkURL: network, threads: 1, hashMB: 16)
        await warmup.shutdown()

        let before = TestSupport.openFileDescriptorCount()
        var startupMilliseconds: [Double] = []

        for iteration in 0..<20 {
            let clock = ContinuousClock()
            let start = clock.now
            let engine = try UCIEngine(networkURL: network, threads: 1, hashMB: 16)
            startupMilliseconds.append(Double((clock.now - start).milliseconds))
            await engine.shutdown()
            #expect(!engineIsRunning, "engine still running after cycle \(iteration)")
        }

        let after = TestSupport.openFileDescriptorCount()
        let average = startupMilliseconds.reduce(0, +) / Double(startupMilliseconds.count)
        TestSupport.note("startup: avg \(Int(average)) ms, min \(Int(startupMilliseconds.min() ?? 0)) ms, max \(Int(startupMilliseconds.max() ?? 0)) ms")
        TestSupport.note("file descriptors: before \(before), after \(after)")
        #expect(after <= before + 2, "leaked \(after - before) file descriptors over 20 cycles")
    }

    /// The path process exit takes: nobody sent `quit`, nobody called
    /// `shutdown()`, and the bridge has to get the UCI loop to return anyway.
    /// Before the bridge was hardened this state ended in std::terminate() when
    /// the process exited, which is what the crash reports showed.
    @Test(.timeLimit(.minutes(1)))
    func forcedShutdownStopsAnEngineNobodyQuit() async throws {
        let network = try #require(TestSupport.networkURL, TestSupport.missingNetworkMessage)

        let abandoned = try UCIEngine(networkURL: network, threads: 1, hashMB: 16)
        #expect(engineIsRunning)

        let clock = ContinuousClock()
        let start = clock.now
        #expect(engineForceShutdown(timeout: .seconds(5)), "the UCI loop did not return")
        TestSupport.note("forced shutdown took \((clock.now - start).milliseconds) ms")
        #expect(!engineIsRunning)

        // Tidying up the abandoned host side must still be safe, and the next
        // engine must still start on the restored descriptors.
        await abandoned.shutdown()
        #expect(!engineIsRunning)

        let next = try UCIEngine(networkURL: network, threads: 1, hashMB: 16)
        #expect(engineIsRunning)
        await next.shutdown()
        #expect(!engineIsRunning)
    }

    // MARK: - Evaluation

    @Test(.timeLimit(.minutes(1)))
    func startPositionIsRoughlyBalanced() async throws {
        let network = try #require(TestSupport.networkURL, TestSupport.missingNetworkMessage)
        let engine = try UCIEngine(networkURL: network, threads: 2, hashMB: 32)

        let evaluations = await TestSupport.collect(
            await engine.evaluate(fen: Self.startFEN, movetime: .milliseconds(500), revision: 1))

        #expect(!evaluations.isEmpty)
        #expect(evaluations.allSatisfy { $0.positionFEN == Self.startFEN })
        #expect(evaluations.allSatisfy { $0.revision == 1 })

        let deep = evaluations.filter { $0.depth >= 8 }
        #expect(!deep.isEmpty, "deepest reached was \(evaluations.map(\.depth).max() ?? 0)")
        let balanced = deep.contains {
            if case .centipawns(let cp) = $0.score { return (-100...100).contains(cp) }
            return false
        }
        #expect(balanced, "scores at depth >= 8: \(deep.map(\.score))")
        TestSupport.note("start position: deepest \(evaluations.map(\.depth).max() ?? 0) in 500 ms, final \(evaluations.last?.score as Any)")

        await engine.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func mateInOneIsReportedFromWhitesPerspective() async throws {
        let network = try #require(TestSupport.networkURL, TestSupport.missingNetworkMessage)
        let engine = try UCIEngine(networkURL: network, threads: 2, hashMB: 32)

        let white = await TestSupport.collect(
            await engine.evaluate(fen: Self.mateForWhite, movetime: .milliseconds(400), revision: 1))
        #expect(white.contains { $0.score == .mate(1) },
                "white-to-move mate scores: \(white.map(\.score))")

        let black = await TestSupport.collect(
            await engine.evaluate(fen: Self.mateForBlack, movetime: .milliseconds(400), revision: 2))
        #expect(black.contains { $0.score == .mate(-1) },
                "black-to-move mate scores: \(black.map(\.score))")
        #expect(black.allSatisfy { $0.positionFEN == Self.mateForBlack && $0.revision == 2 })

        await engine.shutdown()
    }

    @Test(.timeLimit(.minutes(2)))
    func rapidSwitchingNeverDeliversAStaleFEN() async throws {
        let network = try #require(TestSupport.networkURL, TestSupport.missingNetworkMessage)
        let engine = try UCIEngine(networkURL: network, threads: 2, hashMB: 32)

        // A short opening line, one FEN per ply.
        let fens = [
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
            "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1",
            "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2",
            "rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2",
            "r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3",
            "r1bqkbnr/pppp1ppp/2n5/1B2p3/4P3/5N2/PPPP1PPP/RNBQK2R b KQkq - 3 3",
            "r1bqkbnr/1ppp1ppp/p1n5/1B2p3/4P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 0 4",
            "r1bqkbnr/1ppp1ppp/p1n5/4p3/B3P3/5N2/PPPP1PPP/RNBQK2R b KQkq - 1 4",
            "r1bqkbnr/1ppp1ppp/p1n5/4p3/B3P3/5N2/PPPP1PPP/RNBQ1RK1 b kq - 3 5",
            "r1bqk1nr/1ppp1ppp/p1n5/2b1p3/B3P3/5N2/PPPP1PPP/RNBQ1RK1 w kq - 4 6",
        ]

        var lastStream: AsyncStream<Evaluation>?
        var seen: [(String, Evaluation)] = []
        let collected = Mutex<[(String, Evaluation)]>([])

        for (index, fen) in fens.enumerated() {
            let stream = await engine.evaluate(fen: fen, movetime: .milliseconds(600), revision: index)
            if index == fens.count - 1 {
                lastStream = stream
            } else {
                // Drain superseded streams in the background and record what
                // FEN each of their evaluations claimed.
                Task {
                    for await evaluation in stream {
                        collected.withLock { $0.append((fen, evaluation)) }
                    }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        let last = await TestSupport.collect(try #require(lastStream))
        seen = collected.withLock { $0 }

        for (requested, evaluation) in seen {
            #expect(evaluation.positionFEN == requested,
                    "an evaluation for \(evaluation.positionFEN) arrived on the stream for \(requested)")
        }
        #expect(!last.isEmpty, "the final stream produced nothing")
        #expect(last.allSatisfy { $0.positionFEN == fens[fens.count - 1] })
        #expect(last.allSatisfy { $0.revision == fens.count - 1 })
        TestSupport.note("rapid switching: \(seen.count) superseded evaluations, \(last.count) on the final stream")

        await engine.shutdown()
    }

    // MARK: - Depth-limited search

    @Test func depthLimitMapsToAGoCommand() {
        #expect(EngineSearchLimit.depth(40).goCommand == "go depth 40")
        #expect(EngineSearchLimit.depth(0).goCommand == "go depth 1")
        #expect(EngineSearchLimit.depth(10_000).goCommand == "go depth 245")
        #expect(EngineSearchLimit.movetime(.milliseconds(1500)).goCommand == "go movetime 1500")
        #expect(EngineSearchLimit.movetime(.zero).goCommand == "go movetime 1")
    }

    @Test(.timeLimit(.minutes(2)))
    func depthSearchDeepensToTheCapOneEvaluationPerDepth() async throws {
        let network = try #require(TestSupport.networkURL, TestSupport.missingNetworkMessage)
        let engine = try UCIEngine(networkURL: network, threads: 2, hashMB: 32)

        // A small cap so the test is quick; the app uses 40.
        let cap = 14
        let evaluations = await TestSupport.collect(
            await engine.evaluate(fen: Self.startFEN, maxDepth: cap, revision: 7))

        let commands = await engine.channel.recentCommands()
        #expect(commands.contains("go depth \(cap)"), "commands sent: \(commands)")
        #expect(!commands.contains { $0.hasPrefix("go movetime") }, "commands sent: \(commands)")

        #expect(!evaluations.isEmpty)
        #expect(evaluations.allSatisfy { $0.positionFEN == Self.startFEN })
        #expect(evaluations.allSatisfy { $0.revision == 7 })

        let depths = evaluations.map(\.depth)
        #expect(depths == depths.sorted(), "depths were not increasing: \(depths)")
        #expect(Set(depths).count == depths.count, "a depth was reported twice: \(depths)")
        #expect((depths.max() ?? 0) >= cap, "deepest reached was \(depths.max() ?? 0), cap was \(cap)")
        TestSupport.note("depth search: \(evaluations.count) evaluations, depths \(depths)")

        await engine.shutdown()
    }

    @Test(.timeLimit(.minutes(2)))
    func supersedingADepthSearchStopsItAndFinishesItsStream() async throws {
        let network = try #require(TestSupport.networkURL, TestSupport.missingNetworkMessage)
        let engine = try UCIEngine(networkURL: network, threads: 2, hashMB: 32)

        // A cap high enough that this search would run for many minutes on its own.
        let first = await engine.evaluate(fen: Self.startFEN, maxDepth: 99, revision: 1)
        let firstDrained = Task { await TestSupport.collect(first) }
        try await Task.sleep(for: .milliseconds(500))

        let nextFEN = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"
        let second = await engine.evaluate(fen: nextFEN, maxDepth: 12, revision: 2)

        // The old stream must end on its own, without the depth cap being reached.
        let superseded = await firstDrained.value
        let latest = await TestSupport.collect(second)

        let commands = await engine.channel.recentCommands()
        #expect(commands.contains("stop"), "commands sent: \(commands)")
        #expect(commands.contains("go depth 12"), "commands sent: \(commands)")

        #expect(superseded.allSatisfy { $0.positionFEN == Self.startFEN && $0.revision == 1 })
        #expect((superseded.map(\.depth).max() ?? 0) < 99, "the superseded search ran to its cap")
        #expect(!latest.isEmpty, "the replacing search produced nothing")
        #expect(latest.allSatisfy { $0.positionFEN == nextFEN && $0.revision == 2 })
        TestSupport.note("superseded after \(superseded.count) evaluations (deepest \(superseded.map(\.depth).max() ?? 0)), replacement produced \(latest.count)")

        await engine.shutdown()
    }

    @Test(.timeLimit(.minutes(5)))
    func memoryStaysFlatAcrossOneHundredEvaluations() async throws {
        let network = try #require(TestSupport.networkURL, TestSupport.missingNetworkMessage)
        let engine = try UCIEngine(networkURL: network, threads: 2, hashMB: 32)

        // Warm up so the NNUE net, the hash table and the thread stacks are
        // already resident before the baseline is taken.
        _ = await TestSupport.collect(
            await engine.evaluate(fen: Self.startFEN, movetime: .milliseconds(200), revision: 0))

        let before = TestSupport.residentBytes()
        for iteration in 1...100 {
            _ = await TestSupport.collect(
                await engine.evaluate(fen: Self.startFEN, movetime: .milliseconds(200), revision: iteration))
        }
        let after = TestSupport.residentBytes()

        let growth = Int64(after) - Int64(before)
        TestSupport.note("resident size: before \(before / 1_048_576) MB, after \(after / 1_048_576) MB, growth \(growth / 1_048_576) MB")
        #expect(growth < 50 * 1_048_576, "grew by \(growth / 1_048_576) MB over 100 evaluations")

        await engine.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func chess960OptionIsAccepted() async throws {
        let network = try #require(TestSupport.networkURL, TestSupport.missingNetworkMessage)
        let engine = try UCIEngine(networkURL: network, threads: 1, hashMB: 16)

        await engine.setChess960(true)
        let chess960 = "bqnbrkrn/pppppppp/8/8/8/8/PPPPPPPP/BQNBRKRN w KQkq - 0 1"
        let evaluations = await TestSupport.collect(
            await engine.evaluate(fen: chess960, movetime: .milliseconds(300), revision: 1))
        #expect(!evaluations.isEmpty)
        #expect(evaluations.allSatisfy { $0.positionFEN == chess960 })

        await engine.setChess960(false)
        await engine.shutdown()
    }
}
