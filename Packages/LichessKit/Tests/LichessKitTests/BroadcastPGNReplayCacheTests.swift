import Foundation
import Testing
import ChessCore
@testable import LichessKit

private final class ReplayCacheClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    func now() -> ContinuousClock.Instant { lock.withLock { instant } }
    func advance(_ duration: Duration) { lock.withLock { instant += duration } }
}

@Suite("Bounded broadcast history warmup")
struct BroadcastPGNReplayCacheTests {
    private func block(_ moves: String = "1. e4 e5", result: String = "*") -> Data {
        BroadcastPGNStreamTests.block(gameId: "G1", moves: moves, result: result)
    }
    private func replay(_ moves: String = "1. e4 e5", result: String = "*") throws -> BroadcastPGNReplay {
        let game = try #require(PGN.parseGame(String(decoding: block(moves, result: result), as: UTF8.self)))
        return BroadcastPGNReplay(game: game, steps: try game.replay(from: game.initialPosition))
    }
    private func stream(_ server: LoopbackHTTPServer, cache: BroadcastPGNReplayCache) -> BroadcastPGNStream {
        BroadcastPGNStream(session: LichessURLSession.make(streaming: true), baseURL: server.baseURL,
                           configuration: BroadcastPGNStreamTests.fastConfiguration(), replayCache: cache)
    }

    @Test("Round wall replay appears in detail before the detail HTTP body provides any PGN")
    func immediateWallToDetailWarmup() async throws {
        let cache = BroadcastPGNReplayCache()
        let server = try LoopbackHTTPServer(steps: [.init(chunks: [block()], ending: .hold), .init(chunks: [], ending: .hold)])
        defer { server.stop() }
        let wall = BroadcastRoundStream(session: LichessURLSession.make(streaming: true), baseURL: server.baseURL,
                                        configuration: BroadcastPGNStreamTests.fastConfiguration(), replayCache: cache)
        try await withTimeout(.seconds(2), "round wall snapshot") {
            for try await _ in wall.updates(roundId: "R1") { break }
        }
        wall.finish()
        let detail = stream(server, cache: cache)
        defer { detail.finish() }
        let started = ContinuousClock.now
        let events = try await withTimeout(.seconds(1), "cached complete history without HTTP PGN") {
            var events: [SourcedEvent] = []
            for try await event in detail.sourcedEvents(roundId: "R1", gameId: "G1") {
                events.append(event)
                if event.historyComplete == true { break }
            }
            return events
        }
        let elapsed = started.duration(to: .now)
        print("Round-to-detail cached history: \(elapsed)")
        #expect(elapsed < .seconds(5))   // a model benchmark, not a screen measurement; loose enough for a loaded box
        #expect(events.count == 3)
        #expect(events.allSatisfy { $0.isHistorical && $0.isCached })
        #expect(events.map(\.historyComplete) == [false, false, true])
    }

    @Test("Fresh PGN adds only the new move after cached complete history")
    func deduplicatesCachedPrefix() async throws {
        let cache = BroadcastPGNReplayCache()
        let server = try LoopbackHTTPServer(steps: [.init(chunks: [block(), block("1. e4 e5 2. Nf3"), block("1. e4 e5 2. Nf3", result: "1-0")])])
        defer { server.stop() }
        cache.store(try replay(), roundId: "R1", gameId: "G1", origin: server.baseURL)
        let source = stream(server, cache: cache)
        defer { source.finish() }
        let events = try await withTimeout(.seconds(2), "fresh result") {
            var result: [SourcedEvent] = []
            for try await event in source.sourcedEvents(roundId: "R1", gameId: "G1") { result.append(event) }
            return result
        }
        #expect(events.count == 8)
        #expect(events.prefix(3).allSatisfy { $0.isCached && $0.isHistorical })
        #expect(!events[3].isCached && !events[3].isHistorical)
        #expect(events.suffix(4).allSatisfy { !$0.isCached && $0.isHistorical })
        #expect(events.last?.historyComplete == true)
        #expect(source.lastResult?.result == "1-0")
    }

    @Test("A divergent fresh line is a new atomic history batch, including after a cached terminal result")
    func correctionAndTerminalConfirmation() async throws {
        let cache = BroadcastPGNReplayCache()
        let server = try LoopbackHTTPServer(steps: [.init(chunks: [block("1. d4 d5", result: "0-1")])])
        defer { server.stop() }
        cache.store(try replay(result: "1-0"), roundId: "R1", gameId: "G1", origin: server.baseURL)
        let source = stream(server, cache: cache)
        defer { source.finish() }
        let events = try await withTimeout(.seconds(2), "corrected result") {
            var result: [SourcedEvent] = []
            for try await event in source.sourcedEvents(roundId: "R1", gameId: "G1") { result.append(event) }
            return result
        }
        #expect(events.count == 6)
        #expect(events.allSatisfy { $0.isHistorical })
        #expect(events.map(\.isCached) == [true, true, true, false, false, false])
        #expect(events.map(\.historyComplete) == [false, false, true, false, false, true])
        #expect(source.lastResult?.result == "0-1")
        #expect(server.requests.count == 1)
    }

    @Test("A cached finished game reopened at the same FEN emits a fresh atomic history batch")
    func cachedTerminalBecomesOngoingAtSamePosition() async throws {
        let cache = BroadcastPGNReplayCache()
        let server = try LoopbackHTTPServer(steps: [.init(chunks: [block()], ending: .hold)])
        defer { server.stop() }
        cache.store(try replay(result: "1-0"), roundId: "R1", gameId: "G1", origin: server.baseURL)
        let source = stream(server, cache: cache)
        defer { source.finish() }
        let events = try await withTimeout(.seconds(2), "fresh ongoing history") {
            var result: [SourcedEvent] = []
            for try await event in source.sourcedEvents(roundId: "R1", gameId: "G1") {
                result.append(event)
                if !event.isCached && event.historyComplete == true { break }
            }
            return result
        }
        #expect(events.count == 6)
        #expect(events.allSatisfy { $0.isHistorical })
        #expect(events.map(\.isCached) == [true, true, true, false, false, false])
        #expect(events.map(\.historyComplete) == [false, false, true, false, false, true])
        #expect(events[2].event == events[5].event)
        #expect(source.lastResult == nil)
    }

    @Test("Reads do not extend TTL; rounds and provider origins cannot share a replay")
    func expiryAndIsolation() throws {
        let clock = ReplayCacheClock()
        let cache = BroadcastPGNReplayCache(ttl: .seconds(60), now: { clock.now() })
        let origin = URL(string: "https://example.invalid")!
        cache.store(try replay(), roundId: "R1", gameId: "G1", origin: origin)
        clock.advance(.seconds(59))
        #expect(cache.replay(roundId: "R1", gameId: "G1", origin: origin) != nil)
        #expect(cache.replay(roundId: "R2", gameId: "G1", origin: origin) == nil)
        #expect(cache.replay(roundId: "R1", gameId: "G1", origin: URL(string: "https://other.invalid")!) == nil)
        clock.advance(.seconds(1))
        #expect(cache.replay(roundId: "R1", gameId: "G1", origin: origin) == nil)
    }

    @Test("LRU count and byte budgets evict bounded entries; preview mismatch invalidates stale history")
    func capacityAndPreviewAuthority() throws {
        let origin = URL(string: "https://\(UUID().uuidString).invalid")!
        let value = try replay()
        let cache = BroadcastPGNReplayCache(capacity: 2, costLimit: value.cost * 2)
        cache.store(value, roundId: "R1", gameId: "A", origin: origin)
        cache.store(value, roundId: "R1", gameId: "B", origin: origin)
        #expect(cache.replay(roundId: "R1", gameId: "A", origin: origin) != nil)
        cache.store(value, roundId: "R1", gameId: "C", origin: origin)
        #expect(cache.replay(roundId: "R1", gameId: "B", origin: origin) == nil)
        let short = try replay("1. e4")
        let limited = BroadcastPGNReplayCache(costLimit: short.cost)
        limited.store(short, roundId: "R1", gameId: "A", origin: origin)
        #expect(limited.replay(roundId: "R1", gameId: "A", origin: origin) != nil)
        limited.store(value, roundId: "R1", gameId: "A", origin: origin)
        #expect(limited.replay(roundId: "R1", gameId: "A", origin: origin) == nil)
        let tooSmall = BroadcastPGNReplayCache(costLimit: value.cost - 1)
        tooSmall.store(value, roundId: "R1", gameId: "A", origin: origin)
        #expect(tooSmall.replay(roundId: "R1", gameId: "A", origin: origin) == nil)
        let own = BroadcastPGNReplayCache()
        own.store(value, roundId: "R1", gameId: "G1", origin: origin)
        #expect(BroadcastReplayWarmup.retainMatching(roundId: "R1", gameId: "G1", fen: value.steps.last!.fen, baseURL: origin, in: own))
        // Lichess leaves the en passant field empty unless a capture is legal; the same position
        // spelled its way still matches.
        var lichessSpelling = value.steps.last!.fen.split(separator: " ").map(String.init)
        lichessSpelling[3] = "-"
        #expect(BroadcastReplayWarmup.retainMatching(roundId: "R1", gameId: "G1", fen: lichessSpelling.joined(separator: " "), baseURL: origin, in: own))
        #expect(!BroadcastReplayWarmup.retainMatching(roundId: "R1", gameId: "G1", fen: Position.standard.fen, baseURL: origin, in: own))
        #expect(own.replay(roundId: "R1", gameId: "G1", origin: origin) == nil)
    }

    @Test("Cancelling a warmed game waiting for fresh HTTP does not fabricate a cached result")
    func warmedCancellation() async throws {
        let cache = BroadcastPGNReplayCache()
        let server = try LoopbackHTTPServer(steps: [.init(chunks: [Data("\n".utf8)], ending: .hold)])
        defer { server.stop() }
        cache.store(try replay(result: "1-0"), roundId: "R1", gameId: "G1", origin: server.baseURL)
        let source = stream(server, cache: cache)
        defer { source.finish() }
        let consumer = Task { for try await _ in source.sourcedEvents(roundId: "R1", gameId: "G1") {} }
        try await withTimeout(.seconds(2), "fresh connection") {
            for await state in source.connectionStates { if state == .live { return } }
        }
        #expect(source.lastResult == nil)
        consumer.cancel()
        try await withTimeout(.seconds(1), "cancel warmed stream") { try await consumer.value }
        #expect(source.lastResult == nil)
    }
}
