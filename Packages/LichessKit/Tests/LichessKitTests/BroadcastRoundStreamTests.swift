import Foundation
import Testing
import ChessCore
@testable import LichessKit

@Suite("One live stream for every broadcast round board")
struct BroadcastRoundStreamTests {
    private func block(_ id: String, _ moves: String, result: String = "*", white: String = "Alice") -> Data {
        BroadcastPGNStreamTests.block(gameId: id, moves: moves, result: result, white: white)
    }
    private func stream(_ server: LoopbackHTTPServer) -> BroadcastRoundStream {
        BroadcastRoundStream(session: LichessURLSession.make(streaming: true), baseURL: server.baseURL,
                             configuration: BroadcastPGNStreamTests.fastConfiguration())
    }
    private func collect(_ source: BroadcastRoundStream, count: Int) async throws -> [BroadcastRoundUpdate] {
        try await withTimeout(.seconds(8), "round snapshots") {
            var result: [BroadcastRoundUpdate] = []
            for try await update in source.updates(roundId: "R1") {
                result.append(update)
                if result.count == count { break }
            }
            return result
        }
    }

    @Test("Fragmented UTF-8 PGNs update multiple boards through one request without intermediate history")
    func fragmentedMultipleBoards() async throws {
        var payload = block("A", "1. e4 { [%clk 0:05:00] } e5 { [%clk 0:04:59] }", white: "José")
        payload.append(block("B", "1. d4 { [%clk 1:30:00] } d5 { [%clk 1:29:58] } 2. c4 { [%clk 1:29:50] }"))
        payload.append(block("A", "1. e4 { [%clk 0:05:00] } e5 { [%clk 0:04:59] } 2. Nf3 { [%clk 0:04:55] }", white: "José"))
        let chunks = stride(from: 0, to: payload.count, by: 7).map { payload.subdata(in: $0..<min($0 + 7, payload.count)) }
        let server = try LoopbackHTTPServer(steps: [.init(chunks: chunks, chunkDelay: 0.0001, ending: .hold)])
        defer { server.stop() }
        let source = stream(server)
        defer { source.finish() }
        let updates = try await collect(source, count: 3)
        #expect(updates.map { $0.board.gameId } == ["A", "B", "A"])
        #expect(updates.map(\.san) == ["e5", "c4", "Nf3"])
        #expect(updates.map(\.isInitial) == [true, true, false])
        #expect(updates[0].board.white?.name == "José")
        #expect(updates[0].board.white?.clockSeconds == 300)
        #expect(updates[1].board.black?.clockSeconds == 5398)
        #expect(updates[2].board.white?.clockSeconds == 295)
        #expect(updates[2].board.lastMove == "g1f3")
        #expect(server.requests.count == 1)
        #expect(server.requests[0].contains("/api/stream/broadcast/round/R1.pgn"))
    }

    @Test("Repeated positions do not restart clocks, while clock corrections, takebacks and result-only changes emit")
    func correctionsAndResults() async throws {
        let first = block("A", "1. e4 { [%clk 0:05:00] } e5 { [%clk 0:04:59] }")
        let correctedClock = block("A", "1. e4 { [%clk 0:04:50] } e5 { [%clk 0:04:59] }")
        let takeback = block("A", "1. d4 { [%clk 0:04:48] }")
        let server = try LoopbackHTTPServer(steps: [.init(chunks: [first, first, correctedClock, takeback,
            block("A", "1. d4 { [%clk 0:04:48] }", result: "1-0"), block("B", "1. c4")], ending: .hold)])
        defer { server.stop() }
        let source = stream(server)
        defer { source.finish() }
        let updates = try await collect(source, count: 5)
        #expect(updates.map { $0.board.gameId } == ["A", "A", "A", "A", "B"])
        #expect(updates[0].board.fen == updates[1].board.fen)
        #expect(updates[1].board.white?.clockSeconds == 290)
        #expect(updates[2].san == "d4")
        #expect(updates[2].board.lastMove == "d2d4")
        #expect(updates[3].board.status == "1-0")
        #expect(updates[3].board.fen == updates[2].board.fen)
        #expect(!updates[3].board.isOngoing)
        #expect(updates[4].board.isOngoing) // One finished board does not close the round stream.
    }

    @Test("Reconnect suppresses duplicate boards and distinguishes missed moves from newly arriving moves")
    func reconnectCatchup() async throws {
        let a = block("A", "1. e4 { [%clk 0:05:00] }")
        let b = block("B", "1. d4 { [%clk 0:05:00] }")
        let aLater = block("A", "1. e4 { [%clk 0:05:00] } e5 { [%clk 0:04:30] }")
        let bLater = block("B", "1. d4 { [%clk 0:05:00] } d5 { [%clk 0:04:40] }")
        let server = try LoopbackHTTPServer(steps: [
            .init(chunks: [a, b], ending: .abrupt),
            .init(chunks: [aLater, b, aLater, bLater], ending: .hold)
        ])
        defer { server.stop() }
        let source = stream(server)
        defer { source.finish() }
        let updates = try await collect(source, count: 4)
        #expect(updates.map { $0.board.gameId } == ["A", "B", "A", "B"])
        #expect(updates.map(\.isInitial) == [true, true, true, false])
        #expect(updates.map(\.san) == ["e4", "d4", "e5", "d5"])
        #expect(server.requests.count == 2)
    }

    @Test("An invalid board cannot block valid boards or make its first valid clock look live")
    func malformedBoardIsolation() async throws {
        let server = try LoopbackHTTPServer(steps: [.init(chunks: [block("A", "1. Qh5"), block("B", "1. d4"), block("A", "1. e4")], ending: .hold)])
        defer { server.stop() }
        let source = stream(server)
        defer { source.finish() }
        let updates = try await collect(source, count: 2)
        #expect(updates.map { $0.board.gameId } == ["B", "A"])
        #expect(updates.allSatisfy { $0.isInitial })
    }

    @Test("HTTP 429 respects Retry-After and retirement cancels the pending retry")
    func rateLimitAndCancellation() async throws {
        let server = try LoopbackHTTPServer(steps: [.init(statusCode: 429, headers: ["Retry-After": "120"])])
        defer { server.stop() }
        let source = stream(server)
        let consumer = Task { for try await _ in source.updates(roundId: "R1") {} }
        let state = try await withTimeout(.seconds(3), "rate limit response") {
            for await state in source.connectionStates {
                if case .reconnecting = state { return state }
            }
            throw URLError(.badServerResponse)
        }
        guard case .reconnecting(_, let delay) = state else { Issue.record("Expected retry"); return }
        #expect(delay >= .seconds(120))
        source.finish()
        try await withTimeout(.seconds(1), "cancelled retry") { try await consumer.value }
        #expect(server.requests.count == 1)
    }
}
