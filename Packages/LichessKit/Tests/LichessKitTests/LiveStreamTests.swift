import Foundation
import Testing
import ChessCore
@testable import LichessKit

/// Behaviour of the three new streams, driven by the loopback HTTP server so that real
/// `URLSession` streaming, polling and cancellation are exercised. No test touches the network.
@Suite("Arena and broadcast streaming")
struct LiveStreamTests {

    private static func fastConfiguration() -> TVFeedStream.Configuration {
        var configuration = TVFeedStream.Configuration()
        configuration.jitterFraction = { 0 }
        configuration.baseDelay = .milliseconds(20)
        configuration.maxDelay = .milliseconds(80)
        configuration.healthyConnectionThreshold = .milliseconds(200)
        return configuration
    }

    // MARK: - GameStream

    @Test("A recorded game stream replays as one featured event plus a fen per move, then finishes")
    func gameStreamReplaysFixture() async throws {
        let server = try LoopbackHTTPServer(steps: [
            .init(chunks: [try Fixture.gameStreamData], chunkDelay: 0, ending: .graceful)
        ])
        defer { server.stop() }
        let stream = GameStream(
            session: LichessURLSession.make(streaming: true),
            baseURL: server.baseURL,
            configuration: Self.fastConfiguration()
        )

        let events = try await withTimeout(.seconds(20), "the whole game") { [stream] in
            var collected: [TVEvent] = []
            for try await event in stream.events(gameId: "1bkVTDgw") { collected.append(event) }
            return collected
        }

        // 1 featured + 25 move lines; the closing metadata line ends the stream instead of emitting.
        #expect(events.count == 26)
        guard case .featured(let gameId, let orientation, let players, let fen) = events[0] else {
            Issue.record("expected a featured event first"); return
        }
        #expect(gameId == "1bkVTDgw")
        #expect(orientation == .white)
        #expect(players.map(\.name) == ["joserivas", "CRUYFFORD_ChesYT"])
        #expect(players.allSatisfy { $0.secondsRemaining == nil })
        // The opening metadata line has no position, so the standard start position stands in.
        #expect(fen == Position.standard.fen)
        #expect(events.dropFirst().allSatisfy { if case .fen = $0 { true } else { false } })

        // The stream finished normally: the reason is on the client.
        let termination = try #require(stream.lastTermination)
        #expect(termination.gameId == "1bkVTDgw")
        #expect(termination.status.name == "mate")
        #expect(termination.status.winner == .black)
        #expect(stream.lastStatus == termination.status)
        #expect(stream.termination(forGameId: "1bkVTDgw") == termination)
        #expect(stream.termination(forGameId: "nosuchid") == nil)

        let head = try #require(server.requests.first)
        #expect(head.hasPrefix("GET /api/stream/game/1bkVTDgw HTTP/1.1"))
        #expect(head.contains("User-Agent: ChessTV/"))   // the exact value is UserAgentTests' business
        #expect(server.connectionCount == 1)   // finished, so it did not reconnect
    }

    // MARK: - BroadcastBoardStream

    private static func roundPayload(fen: String, status: String, whiteClock: Int, blackClock: Int) -> Data {
        Data("""
        {"round":{"id":"R1","name":"Round 1","ongoing":true,"startsAt":1789683722400},
         "tour":{"id":"T1","name":"Test Open","tier":4,"info":{"format":"9-round swiss","location":"Nowhere"}},
         "games":[{"id":"other","name":"A - B","fen":"8/8/8/8/8/8/8/8 w - - 0 1","status":"*","players":[]},
                  {"id":"G1","name":"Alice - Bob","fen":"\(fen)","lastMove":"e2e4","status":"\(status)",
                   "players":[{"name":"Alice","title":"GM","rating":2700,"fed":"USA","clock":\(whiteClock)},
                              {"name":"Bob","title":"IM","rating":2500,"fed":"FRA","clock":\(blackClock)}]}]}
        """.utf8)
    }

    @Test("A broadcast board emits only on change and stops on a result")
    func broadcastBoardEmitsOnChange() async throws {
        let a = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"
        let b = "rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"
        let c = "rnbqkbnr/pp1ppppp/8/2p5/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2"
        let server = try LoopbackHTTPServer(steps: [
            .init(chunks: [Self.roundPayload(fen: a, status: "*", whiteClock: 600_000, blackClock: 600_000)], chunkDelay: 0),
            .init(chunks: [Self.roundPayload(fen: a, status: "*", whiteClock: 600_000, blackClock: 600_000)], chunkDelay: 0),
            .init(chunks: [Self.roundPayload(fen: b, status: "*", whiteClock: 598_000, blackClock: 599_000)], chunkDelay: 0),
            .init(chunks: [Self.roundPayload(fen: c, status: "1-0", whiteClock: 597_000, blackClock: 599_000)], chunkDelay: 0),
        ])
        defer { server.stop() }
        let stream = BroadcastBoardStream(baseURL: server.baseURL, pollInterval: .milliseconds(20))

        let events = try await withTimeout(.seconds(20), "the board to finish") { [stream] in
            var collected: [TVEvent] = []
            for try await event in stream.events(roundId: "R1", gameId: "G1") { collected.append(event) }
            return collected
        }

        // featured + fen(a) + fen(b) + fen(c). The identical second poll emitted nothing.
        #expect(events.count == 4)
        guard case .featured(let gameId, let orientation, let players, let fen) = events[0] else {
            Issue.record("expected featured first"); return
        }
        #expect(gameId == "G1")
        #expect(orientation == .white)
        #expect(fen == a)
        #expect(players.map(\.name) == ["Alice", "Bob"])
        #expect(players.map(\.title) == ["GM", "IM"])
        #expect(players.map(\.rating) == [2700, 2500])
        #expect(players.map(\.secondsRemaining) == [6000, 6000])   // clock ms → seconds

        #expect(events[1] == .fen(fen: a, lastMove: "e2e4", whiteClock: 6000, blackClock: 6000))
        #expect(events[2] == .fen(fen: b, lastMove: "e2e4", whiteClock: 5980, blackClock: 5990))
        #expect(events[3] == .fen(fen: c, lastMove: "e2e4", whiteClock: 5970, blackClock: 5990))
        #expect(server.connectionCount == 4)   // the unchanged poll still happened

        let head = try #require(server.requests.first)
        #expect(head.hasPrefix("GET /api/broadcast/-/-/R1 HTTP/1.1"))
    }

    @Test("A board that is not in the round yet is polled until it appears")
    func broadcastBoardWaitsForTheBoard() async throws {
        let empty = Data(#"{"round":{"id":"R1","name":"Round 1","startsAt":1},"tour":{"id":"T1","name":"T","tier":4},"games":[]}"#.utf8)
        let fen = "8/8/8/8/8/8/8/K6k w - - 0 1"
        let server = try LoopbackHTTPServer(steps: [
            .init(chunks: [empty], chunkDelay: 0),
            .init(chunks: [empty], chunkDelay: 0),
            .init(chunks: [Self.roundPayload(fen: fen, status: "½-½", whiteClock: 1_000, blackClock: 2_000)], chunkDelay: 0),
        ])
        defer { server.stop() }
        let stream = BroadcastBoardStream(baseURL: server.baseURL, pollInterval: .milliseconds(20))

        let events = try await withTimeout(.seconds(20), "the board to appear and finish") { [stream] in
            var collected: [TVEvent] = []
            for try await event in stream.events(roundId: "R1", gameId: "G1") { collected.append(event) }
            return collected
        }
        #expect(events.count == 2)
        #expect(events[1] == .fen(fen: fen, lastMove: "e2e4", whiteClock: 10, blackClock: 20))
        #expect(server.connectionCount >= 3)
    }

    // MARK: - ArenaFeaturedStream

    private static func arenaDetail(featuredId: String?, finished: Bool = false) -> Data {
        let featured = featuredId.map {
            """
            ,"featured":{"id":"\($0)","fen":"8/8/8/8/8/8/8/K6k w","orientation":"white","color":"white",
             "white":{"name":"Alice","id":"alice","rank":1,"rating":2400},
             "black":{"name":"Bob","id":"bob","rank":2,"rating":2300},"c":{"white":60,"black":60}}
            """
        } ?? ""
        return Data("""
        {"id":"A1","fullName":"Test Arena","nbPlayers":42,"minutes":60,"startsAt":1789696800000,
         "variant":{"key":"standard"},"perf":{"key":"bullet"},"secondsToFinish":900,
         "isStarted":true\(finished ? ",\"isFinished\":true" : "")\(featured),
         "standing":{"page":1,"players":[{"name":"Alice","rank":1,"rating":2400,"score":10}]}}
        """.utf8)
    }

    private static func gameLines(_ gameId: String, moves: [String], terminal: Bool) -> Data {
        var text = #"{"id":"\#(gameId)","variant":{"key":"standard"},"speed":"bullet","perf":"bullet","rated":true,"source":"arena","createdAt":1,"tournamentId":"A1","players":{"white":{"user":{"name":"Alice","id":"alice"},"rating":2400},"black":{"user":{"name":"Bob","id":"bob"},"rating":2300}}}"# + "\n"
        for (index, fen) in moves.enumerated() {
            text += #"{"fen":"\#(fen)","lm":"e2e4","wc":\#(60 - index),"bc":60}"# + "\n"
        }
        if terminal {
            text += #"{"id":"\#(gameId)","players":{"white":{"user":{"name":"Alice","id":"alice"},"rating":2400},"black":{"user":{"name":"Bob","id":"bob"},"rating":2300}},"fen":"\#(moves.last ?? "8/8/8/8/8/8/8/K6k w - - 0 1")","status":{"id":31,"name":"resign"},"winner":"white"}"# + "\n"
        }
        return Data(text.utf8)
    }

    @Test("The arena featured stream rotates to the next game when the first one ends")
    func arenaFeaturedRotates() async throws {
        let g1 = ["8/8/8/8/8/8/8/K6k b - - 0 1", "8/8/8/8/8/8/8/K5k1 w - - 1 2"]
        let g2 = ["8/8/8/8/8/8/8/K4k2 b - - 0 1"]
        let server = try LoopbackHTTPServer(router: { path, index in
            switch path {
            case "/api/tournament/A1":
                // First look: game 1. Every later look: game 2.
                return .init(chunks: [Self.arenaDetail(featuredId: index == 0 ? "G1" : "G2")], chunkDelay: 0)
            case "/api/stream/game/G1":
                return .init(chunks: [Self.gameLines("G1", moves: g1, terminal: true)], chunkDelay: 0)
            case "/api/stream/game/G2":
                return .init(chunks: [Self.gameLines("G2", moves: g2, terminal: false)], chunkDelay: 0, ending: .hold)
            default:
                return .init(statusCode: 404, chunks: [], chunkDelay: 0)
            }
        })
        defer { server.stop() }

        let stream = ArenaFeaturedStream(baseURL: server.baseURL, pollInterval: .milliseconds(20))
        let events = try await withTimeout(.seconds(25), "a rotation to the second game") { [stream] in
            var collected: [TVEvent] = []
            for try await event in stream.events(tournamentId: "A1") {
                collected.append(event)
                // featured G1, two fens, featured G2, one fen.
                if collected.count == 5 { break }
            }
            return collected
        }

        #expect(events.count == 5)
        guard case .featured(let first, _, let players, _) = events[0] else { Issue.record("featured first"); return }
        #expect(first == "G1")
        #expect(players.map(\.name) == ["Alice", "Bob"])
        #expect(events[1] == .fen(fen: g1[0], lastMove: "e2e4", whiteClock: 60, blackClock: 60))
        #expect(events[2] == .fen(fen: g1[1], lastMove: "e2e4", whiteClock: 59, blackClock: 60))
        guard case .featured(let second, _, _, _) = events[3] else { Issue.record("featured again"); return }
        #expect(second == "G2")
        #expect(events[4] == .fen(fen: g2[0], lastMove: "e2e4", whiteClock: 60, blackClock: 60))
    }

    @Test("The arena featured stream finishes once the arena is over")
    func arenaFeaturedStopsWhenFinished() async throws {
        let server = try LoopbackHTTPServer(router: { path, _ in
            path == "/api/tournament/A1"
                ? .init(chunks: [Self.arenaDetail(featuredId: nil, finished: true)], chunkDelay: 0)
                : .init(statusCode: 404, chunks: [], chunkDelay: 0)
        })
        defer { server.stop() }

        let stream = ArenaFeaturedStream(baseURL: server.baseURL, pollInterval: .milliseconds(20))
        let events = try await withTimeout(.seconds(15), "the arena stream to finish") { [stream] in
            var collected: [TVEvent] = []
            for try await event in stream.events(tournamentId: "A1") { collected.append(event) }
            return collected
        }
        #expect(events.isEmpty)
    }

    // MARK: - GameSourceStreamer

    @Test("GameSourceStreamer picks the right stream and forwards its connection states")
    func sourceStreamerRoutes() async throws {
        let fen = "8/8/8/8/8/8/8/K6k w - - 0 1"
        let server = try LoopbackHTTPServer(router: { path, _ in
            path == "/api/broadcast/-/-/R1"
                ? .init(chunks: [Self.roundPayload(fen: fen, status: "1-0", whiteClock: 3_000, blackClock: 4_000)], chunkDelay: 0)
                : .init(statusCode: 404, chunks: [], chunkDelay: 0)
        })
        defer { server.stop() }

        let streamer = GameSourceStreamer(baseURL: server.baseURL)
        let states = streamer.connectionStates
        let source = GameSource.broadcastBoard(roundId: "R1", gameId: "G1")

        let events = try await withTimeout(.seconds(15), "board events through the streamer") { [streamer] in
            var collected: [TVEvent] = []
            for try await event in streamer.events(for: source) { collected.append(event) }
            return collected
        }
        #expect(events.count == 2)
        #expect(events[1] == .fen(fen: fen, lastMove: "e2e4", whiteClock: 30, blackClock: 40))

        let live = try await withTimeout(.seconds(10), "a forwarded .live state") {
            for await state in states where state == .live { return true }
            return false
        }
        #expect(live)
        streamer.finish()
    }
}
