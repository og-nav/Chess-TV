import Foundation
import Testing
import ChessCore
@testable import LichessKit

/// `BroadcastPGNStream` and the history marking, driven by the loopback HTTP server so that the
/// real streaming path — chunked bodies, partial lines, reconnects — is exercised.
@Suite("Broadcast PGN streaming carries the move history")
struct BroadcastPGNStreamTests {

    // MARK: - Fixtures

    static func fastConfiguration() -> TVFeedStream.Configuration {
        var configuration = TVFeedStream.Configuration()
        configuration.jitterFraction = { 0 }
        configuration.baseDelay = .milliseconds(20)
        configuration.maxDelay = .milliseconds(80)
        configuration.healthyConnectionThreshold = .milliseconds(200)
        return configuration
    }

    /// One game block exactly as the round stream sends it: tags, a blank line, one movetext
    /// line ending in the result token, then the blank line that closes the block.
    static func block(
        gameId: String,
        moves: String,
        result: String = "*",
        white: String = "Alice",
        black: String = "Bob"
    ) -> Data {
        Data("""
        [Event "Test Open"]
        [Site "lichess.org"]
        [White "\(white)"]
        [Black "\(black)"]
        [Result "\(result)"]
        [WhiteElo "2700"]
        [BlackElo "2500"]
        [WhiteTitle "GM"]
        [BlackTitle "IM"]
        [GameURL "https://lichess.org/broadcast/test-open/round-1/R1/\(gameId)"]

        \(moves) \(result)


        """.utf8)
    }

    private static let opening = "1. e4 { [%clk 0:03:00] } 1... e5 { [%clk 0:02:58] } 2. Nf3 { [%clk 0:02:55] }"
    private static let plusOne = opening + " 2... Nc6 { [%clk 0:02:50] }"
    private static let mate = plusOne + " 3. Bc4 { [%clk 0:02:49] } 3... Nd4 { [%clk 0:02:44] } 4. Nxe5 { [%clk 0:02:40] }"
        + " 4... Qg5 { [%clk 0:02:30] } 5. Nxf7 { [%clk 0:02:20] } 5... Qxg2 { [%clk 0:02:10] }"
        + " 6. Rf1 { [%clk 0:02:00] } 6... Qxe4+ { [%clk 0:01:55] } 7. Be2 { [%clk 0:01:50] } 7... Nf3#"

    private func stream(_ server: LoopbackHTTPServer) -> BroadcastPGNStream {
        BroadcastPGNStream(
            session: LichessURLSession.make(streaming: true),
            baseURL: server.baseURL,
            configuration: Self.fastConfiguration()
        )
    }

    // MARK: - History, then only what is new

    @Test("The first block replays the whole game; later blocks add only the new plies")
    func historyThenIncrements() async throws {
        let server = try LoopbackHTTPServer(steps: [
            .init(chunks: [
                Self.block(gameId: "OTHER", moves: "1. d4 { [%clk 0:05:00] }"),
                Self.block(gameId: "G1", moves: Self.opening),
                Self.block(gameId: "G1", moves: Self.plusOne),
                Self.block(gameId: "OTHER", moves: "1. d4 { [%clk 0:05:00] } 1... d5 { [%clk 0:05:00] }"),
                Self.block(gameId: "G1", moves: Self.mate, result: "1-0"),
            ], chunkDelay: 0.03, ending: .graceful),
        ])
        defer { server.stop() }
        let stream = stream(server)

        let events = try await withTimeout(.seconds(20), "the board to finish") { [stream] in
            var collected: [SourcedEvent] = []
            for try await event in stream.sourcedEvents(roundId: "R1", gameId: "G1") { collected.append(event) }
            return collected
        }

        // Initial history, one live ply, then the closing block's new plies live: a result that
        // arrives with the mating move is the end of the game, not a correction to replay.
        #expect(events.count == 15)

        guard case .featured(let gameId, let orientation, let players, let fen) = events[0].event else {
            Issue.record("expected featured first"); return
        }
        #expect(gameId == "G1")
        #expect(orientation == .white)
        #expect(fen == Position.standard.fen)
        #expect(players.map(\.name) == ["Alice", "Bob"])
        #expect(players.map(\.title) == ["GM", "IM"])
        #expect(players.map(\.rating) == [2700, 2500])
        #expect(players.map(\.secondsRemaining) == [nil, nil])
        #expect(events[0].isHistorical)
        #expect(events[0].historyComplete == false)
        #expect(events[3].historyComplete == true)
        #expect(events[4].historyComplete == nil)                       // setup and replay form one batch

        // The three replayed plies, with their UCI and the clock of whoever moved.
        #expect(events[1].event == .fen(
            fen: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1",
            lastMove: "e2e4", whiteClock: 180, blackClock: nil))
        #expect(events[2].event == .fen(
            fen: "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2",
            lastMove: "e7e5", whiteClock: 180, blackClock: 178))
        #expect(events[3].event == .fen(
            fen: "rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2",
            lastMove: "g1f3", whiteClock: 175, blackClock: 178))
        #expect(events[1...3].allSatisfy { $0.isHistorical })       // the whole first block is history

        // The second block repeated all three and added one: only the new ply came out, live.
        #expect(events[4].event == .fen(
            fen: "r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3",
            lastMove: "b8c6", whiteClock: 175, blackClock: 170))
        #expect(!events[4].isHistorical)
        // The final block added ten plies and the result. The plies are live — the mating move
        // gets its sound and its clock — and nothing restates the history.
        #expect(events[5...].allSatisfy { !$0.isHistorical })
        #expect(events[5...].allSatisfy { if case .fen = $0.event { true } else { false } })

        // It stopped because the game did, and said so the way GameStream does.
        let result = try #require(stream.lastResult)
        #expect(result == BroadcastPGNStream.Termination(gameId: "G1", result: "1-0"))
        #expect(stream.result(forGameId: "G1") == result)
        #expect(stream.result(forGameId: "OTHER") == nil)

        let head = try #require(server.requests.first)
        #expect(head.hasPrefix("GET /api/stream/broadcast/round/R1.pgn HTTP/1.1"))
        #expect(head.contains("User-Agent: ChessTV/"))   // the exact value is UserAgentTests' business
        #expect(server.connectionCount == 1)                   // finished, so it did not reconnect
    }

    @Test("A diverging re-send restates the setup and replays the complete corrected history")
    func divergenceReEmits() async throws {
        let server = try LoopbackHTTPServer(steps: [
            .init(chunks: [
                Self.block(gameId: "G1", moves: "1. e4 1... e5 2. Nf3 2... Nc6"),
                // Ply 3 is different: the operator corrected the board.
                Self.block(gameId: "G1", moves: "1. e4 1... e5 2. d4 2... exd4", result: "0-1"),
            ], chunkDelay: 0.05, ending: .graceful),
        ])
        defer { server.stop() }
        let stream = stream(server)

        let events = try await withTimeout(.seconds(20), "the correction") { [stream] in
            var collected: [SourcedEvent] = []
            for try await event in stream.sourcedEvents(roundId: "R1", gameId: "G1") { collected.append(event) }
            return collected
        }

        // featured + 4 history plies, then a fresh featured + all 4 corrected plies.
        #expect(events.count == 10)
        #expect(events[1...4].allSatisfy { $0.isHistorical })
        guard case .featured(_, _, _, let restated) = events[5].event else {
            Issue.record("expected a fresh featured event at the divergence"); return
        }
        #expect(restated == Position.standard.fen)
        #expect(events[5...].allSatisfy { $0.isHistorical })
        #expect(events[8].event == .fen(
            fen: "rnbqkbnr/pppp1ppp/8/4p3/3PP3/8/PPP2PPP/RNBQKBNR b KQkq d3 0 2",
            lastMove: "d2d4", whiteClock: nil, blackClock: nil))
        #expect(events[9].event == .fen(
            fen: "rnbqkbnr/pppp1ppp/8/8/3pP3/8/PPP2PPP/RNBQKBNR w KQkq - 0 3",
            lastMove: "e5d4", whiteClock: nil, blackClock: nil))
        #expect(stream.lastResult?.result == "0-1")
    }

    @Test("A reconnect resends every game, and the ply bookkeeping makes that a no-op")
    func reconnectIsIdempotent() async throws {
        // The recorded stream: four re-sends of one live TCEC game, each two plies longer.
        let recording = try Fixture.broadcastStreamData
        var assembler = PGNBlockAssembler()
        var latest = ""
        for line in String(decoding: recording, as: UTF8.self).components(separatedBy: "\n") {
            if let block = assembler.append(line: line) { latest = block }
        }
        if let tail = assembler.finish() { latest = tail }
        // A reconnect supplies the current snapshot, not a recording of old snapshots.
        let server = try LoopbackHTTPServer(steps: [
            .init(chunks: [recording], chunkDelay: 0, ending: .graceful),
            .init(chunks: [Data((latest + "\n\n").utf8)], chunkDelay: 0, ending: .graceful),
        ])
        defer { server.stop() }
        let stream = stream(server)

        let events = await collect(stream.sourcedEvents(roundId: "JUiFwhFj", gameId: "kbp34ERp"), for: .seconds(2))

        let featured = events.filter { if case .featured = $0.event { true } else { false } }
        let fens = events.filter { if case .fen = $0.event { true } else { false } }
        #expect(featured.count == 1)                           // one header, however often it reconnects
        #expect(server.connectionCount >= 2)                   // it did reconnect

        // The recording's blocks are 37, 38, 39 and 40 plies long; nothing was emitted twice.
        #expect(fens.count == 40)
        #expect(fens.prefix(37).allSatisfy { $0.isHistorical })     // the first block is the history
        #expect(fens.dropFirst(37).allSatisfy { !$0.isHistorical })
        guard case .fen(let last, let lastMove, _, _) = try #require(fens.last).event else { return }
        #expect(lastMove == "g5g4")
        let finalPosition = try Position(fen: last)
        #expect(finalPosition.fullmoveNumber == 21)
    }

    @Test("A shorter authoritative PGN restores the complete taken-back history")
    func takebackReplays() async throws {
        let server = try LoopbackHTTPServer(steps: [
            .init(chunks: [
                Self.block(gameId: "G1", moves: "1. e4 e5 2. Nf3 Nc6"),
                Self.block(gameId: "G1", moves: "1. e4 e5", result: "1/2-1/2"),
            ], chunkDelay: 0.03, ending: .graceful),
        ])
        defer { server.stop() }
        let stream = stream(server)
        let events = try await withTimeout(.seconds(20), "the takeback") { [stream] in
            var collected: [SourcedEvent] = []
            for try await event in stream.sourcedEvents(roundId: "R1", gameId: "G1") { collected.append(event) }
            return collected
        }
        #expect(events.count == 8)
        guard case .featured(_, _, _, let fen) = events[5].event else {
            Issue.record("takeback must reset the previous history"); return
        }
        #expect(fen == Position.standard.fen)
        #expect(events[5...].allSatisfy { $0.isHistorical })
        guard case .fen(_, let move, _, _) = events.last?.event else { return }
        #expect(move == "e7e5")
    }

    @Test("Setup PGNs starting with Black assign the first clock to Black")
    func blackSetupClock() async throws {
        let setup = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1"
        let raw = String(decoding: Self.block(gameId: "G1", moves: "1... e5 { [%clk 0:02:50] }", result: "1/2-1/2"), as: UTF8.self)
            .replacingOccurrences(of: "[Event", with: "[SetUp \"1\"]\n[FEN \"\(setup)\"]\n[Event")
        let server = try LoopbackHTTPServer(steps: [.init(chunks: [Data(raw.utf8)], ending: .graceful)])
        defer { server.stop() }
        let stream = stream(server)
        let events = try await withTimeout(.seconds(20), "the setup game") { [stream] in
            var collected: [SourcedEvent] = []
            for try await event in stream.sourcedEvents(roundId: "R1", gameId: "G1") { collected.append(event) }
            return collected
        }
        guard case .fen(_, _, let white, let black) = events.last?.event else {
            Issue.record("missing move"); return
        }
        #expect(white == nil)
        #expect(black == 170)
    }

    @Test("Three unreadable blocks in a row give up, so the caller can fall back")
    func unparseableGivesUp() async throws {
        let broken = Self.block(gameId: "G1", moves: "1. Ke5 1... Qh9")
        let server = try LoopbackHTTPServer(steps: [
            .init(chunks: [broken, broken, broken, broken], chunkDelay: 0.02, ending: .hold),
        ])
        defer { server.stop() }
        let stream = stream(server)

        await #expect(throws: BroadcastPGNStream.UnparseablePGN.self) {
            try await withTimeout(.seconds(20), "the stream to give up") { [stream] in
                for try await _ in stream.sourcedEvents(roundId: "R1", gameId: "G1") {}
            }
        }
        #expect(stream.currentConnectionState.map { if case .failed = $0 { true } else { false } } == true)
    }

    // MARK: - The block assembler

    @Test("The assembler splits a recorded round into its games")
    func assemblerSplitsRound() throws {
        var assembler = PGNBlockAssembler()
        var blocks: [String] = []
        let text = try Fixture.broadcastRoundText
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let block = assembler.append(line: String(line)) { blocks.append(block) }
        }
        if let tail = assembler.finish() { blocks.append(tail) }

        #expect(blocks.count == 5)
        #expect(blocks.allSatisfy { PGN.parseGame($0) != nil })
        #expect(blocks.compactMap { PGN.parseGame($0)?.gameId }.count == 5)
    }

    @Test("A game is complete at the blank line after its result token, not only at the next game")
    func assemblerClosesOnResult() throws {
        var assembler = PGNBlockAssembler()
        let lines = [
            "[Event \"Test\"]",
            "[GameURL \"https://lichess.org/broadcast/t/round-1/R1/G1\"]",
            "",                                                // between tags and movetext: no split
            "1. e4 e5 *",
            "",                                                // here: the game is complete
        ]
        var blocks: [String] = []
        for line in lines {
            if let block = assembler.append(line: line) { blocks.append(block) }
        }
        #expect(blocks.count == 1)
        let game = try #require(PGN.parseGame(blocks[0]))
        #expect(game.moves.count == 2)
        #expect(assembler.finish() == nil)                     // nothing left over
    }

    @Test("Bytes split across chunk boundaries still make whole lines, blank ones included")
    func lineDecoderKeepsBlankLines() {
        var decoder = PGNLineDecoder()
        var lines = decoder.append(Data("[Event \"A\"]\r\n\r\n1. e4 *\r\n".utf8))
        if let tail = decoder.flush() { lines.append(tail) }
        #expect(lines == ["[Event \"A\"]", "", "1. e4 *"])
    }
}

// MARK: - Helpers

/// Consumes a stream for a fixed time, then cancels it — for streams that never end on their own.
func collect(_ stream: AsyncThrowingStream<SourcedEvent, Error>, for duration: Duration) async -> [SourcedEvent] {
    let collector = EventCollector()
    let task = Task {
        do {
            for try await event in stream { await collector.append(event) }
        } catch {
            await collector.record(error)
        }
    }
    try? await Task.sleep(for: duration)
    task.cancel()
    _ = await task.result
    return await collector.events
}

actor EventCollector {
    private(set) var events: [SourcedEvent] = []
    private(set) var failure: (any Error)?
    func append(_ event: SourcedEvent) { events.append(event) }
    func record(_ error: any Error) { failure = error }
}

/// The same, for the combined feed — events plus the game-over item — with the arrival time of
/// each one, which is what the game-over hold has to be measured against.
func collect(_ stream: AsyncThrowingStream<FeedItem, Error>, for duration: Duration) async -> [(item: FeedItem, at: ContinuousClock.Instant)] {
    let collector = ItemCollector()
    let task = Task {
        do {
            for try await item in stream { await collector.append(item) }
        } catch {
            await collector.record(error)
        }
    }
    try? await Task.sleep(for: duration)
    task.cancel()
    _ = await task.result
    return await collector.items
}

actor ItemCollector {
    private(set) var items: [(item: FeedItem, at: ContinuousClock.Instant)] = []
    private(set) var failure: (any Error)?
    func append(_ item: FeedItem) { items.append((item, .now)) }
    func record(_ error: any Error) { failure = error }
}
