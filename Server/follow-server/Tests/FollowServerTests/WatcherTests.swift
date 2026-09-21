import Foundation
import FollowKit
import Testing
@testable import FollowServer

@Suite("PGN stream splitting")
struct SplitterTests {

    @Test("The recorded round splits into the four blocks it was recorded as")
    func blocks() throws {
        let document = try Fixture.text("stream-round-22.pgn")
        let blocks = PGNStreamSplitter.blocks(in: document)
        #expect(blocks.count == 4)
        #expect(blocks.allSatisfy { $0.hasPrefix("[Event ") })
        #expect(blocks.allSatisfy { $0.contains("kbp34ERp") })
    }

    @Test("Feeding the same bytes a few at a time produces the same blocks")
    func chunked() throws {
        let document = try Fixture.text("stream-round-22.pgn")
        var splitter = PGNStreamSplitter()
        var blocks: [String] = []
        // 64 bytes at a time lands inside tags, inside movetext and across the boundary itself,
        // which is the whole point of the test.
        var remaining = Substring(document)
        while !remaining.isEmpty {
            let chunk = remaining.prefix(64)
            remaining = remaining.dropFirst(64)
            blocks.append(contentsOf: splitter.append(String(chunk)))
        }
        if let last = splitter.flush() { blocks.append(last) }
        #expect(blocks == PGNStreamSplitter.blocks(in: document))
    }
}

@Suite("PGN snapshots")
struct SnapshotTests {

    @Test("A recorded block becomes the position, the move and both clocks")
    func snapshot() throws {
        let blocks = PGNStreamSplitter.blocks(in: try Fixture.text("stream-round-22.pgn"))
        let context = RoundContext(try Fixture.round("replay-round.json"))
        let first = try #require(PGNSnapshot.snapshot(block: blocks[0], roundId: "JUiFwhFj", context: context))

        #expect(first.gameId == "kbp34ERp")
        #expect(first.ply == 37)                       // 19 white moves, 18 black
        #expect(first.san == "Re1")
        // The rook that reaches e1 is the castled one on f1; a1's is still behind its bishop.
        #expect(first.lastMove == "f1e1")
        #expect(first.status == "*")
        #expect(first.white.name == "Avalanche 4.0.0")
        #expect(first.black.name == "Wasp 7.16")
        #expect(first.white.rating == 3506)
        // `[%clk 0:19:53]` on white's 19th, `[%clk 0:19:31]` on black's 18th.
        #expect(first.whiteClock == 19 * 60 + 53)
        #expect(first.blackClock == 19 * 60 + 31)
        // Black to move: white has just played their nineteenth.
        #expect(first.fen.contains(" b "))
    }

    @Test("The stream's four blocks are four plies, in order")
    func progression() throws {
        let blocks = PGNStreamSplitter.blocks(in: try Fixture.text("stream-round-22.pgn"))
        let plies = blocks.compactMap { PGNSnapshot.snapshot(block: $0, roundId: "JUiFwhFj")?.ply }
        #expect(plies == [37, 38, 39, 40])
    }

    @Test("The round JSON supplies the federation and FIDE id the PGN does not carry")
    func contextEnrichment() throws {
        let round = try Fixture.round("wch-round.json")
        let context = RoundContext(round)
        let pgn = """
        [Event "World Championship 2026"]
        [White "Carlsen, Magnus"]
        [Black "Nepomniachtchi, Ian"]
        [Result "*"]
        [GameURL "https://lichess.org/broadcast/x/round-2/WCHr0002/wchGam01"]

        1. e4 { [%clk 1:59:55] } 1... e5 { [%clk 1:59:50] } *
        """
        let snapshot = try #require(PGNSnapshot.snapshot(block: pgn, roundId: "WCHr0002", context: context))
        #expect(snapshot.whiteFideId == 1_503_014)
        #expect(snapshot.blackFideId == 4_168_119)
        #expect(snapshot.white.fed == "NOR")
        #expect(snapshot.ply == 2)
        #expect(context.board(of: "wchGam01") == 1)
        #expect(context.board(of: "wchGam02") == 2)
    }

    @Test("A movetext with an illegal move keeps the prefix that replayed")
    func illegalMove() {
        let pgn = """
        [Event "Broken"]
        [White "A"]
        [Black "B"]
        [GameURL "https://lichess.org/broadcast/x/round-1/r/gameid01"]

        1. e4 e5 2. Qh9 *
        """
        let snapshot = PGNSnapshot.snapshot(block: pgn, roundId: "r")
        #expect(snapshot?.ply == 2)
        #expect(snapshot?.san == "e5")
    }
}

@Suite("The baseline rule")
struct GameDifferTests {

    private let now = Fixture.now

    @Test("The first sight of a game is stored and says nothing")
    func firstSightIsSilent() {
        let snapshot = GameSnapshot.make(ply: 37)
        let outcome = GameDiffer.advance(baseline: nil, snapshot: snapshot, now: now)
        #expect(outcome.events.isEmpty)
        #expect(outcome.baseline.ply == 37)
        // Nothing can be claimed about how long the player has been on this ply.
        #expect(outcome.baseline.longThinkEligible == false)
    }

    @Test("A ply that advances is one move event, whatever the size of the gap")
    func advance() {
        let baseline = GameSnapshot.make(ply: 37).baseline(observedAt: now, longThinkEligible: true)
        let outcome = GameDiffer.advance(baseline: baseline, snapshot: GameSnapshot.make(ply: 41), now: now.addingTimeInterval(120))
        #expect(outcome.events.map(\.kind) == [.move])
        #expect(outcome.events[0].snapshot.ply == 41)
        #expect(outcome.baseline.longThinkEligible)
        #expect(outcome.baseline.observedAt == now.addingTimeInterval(120))
    }

    @Test("A game that was at ply zero announces its start rather than a move")
    func start() {
        let baseline = GameSnapshot.make(ply: 0, san: nil).baseline(observedAt: now, longThinkEligible: false)
        let outcome = GameDiffer.advance(baseline: baseline, snapshot: GameSnapshot.make(ply: 1), now: now)
        #expect(outcome.events.map(\.kind) == [.gameStart])
    }

    @Test("A result on the same ply is a game end")
    func resultWithoutAMove() {
        let baseline = GameSnapshot.make(ply: 60).baseline(observedAt: now, longThinkEligible: true)
        let resigned = GameSnapshot.make(ply: 60, status: "1-0")
        let outcome = GameDiffer.advance(baseline: baseline, snapshot: resigned, now: now.addingTimeInterval(30))
        #expect(outcome.events.map(\.kind) == [.gameEnd])
        // The ply did not move, so the long think it was on keeps its start time.
        #expect(outcome.baseline.observedAt == now)
    }

    @Test("A result that arrives with the move is one game end, not a move and an end")
    func resultWithAMove() {
        let baseline = GameSnapshot.make(ply: 60).baseline(observedAt: now, longThinkEligible: true)
        let outcome = GameDiffer.advance(baseline: baseline, snapshot: GameSnapshot.make(ply: 61, status: "0-1"), now: now)
        #expect(outcome.events.map(\.kind) == [.gameEnd])
    }

    @Test("A PGN correction that takes a move back says nothing and re-baselines")
    func correction() {
        let baseline = GameSnapshot.make(ply: 41).baseline(observedAt: now, longThinkEligible: true)
        let outcome = GameDiffer.advance(baseline: baseline, snapshot: GameSnapshot.make(ply: 40), now: now.addingTimeInterval(10))
        #expect(outcome.events.isEmpty)
        #expect(outcome.baseline.ply == 40)
        #expect(outcome.baseline.longThinkEligible == false)
    }

    @Test("The same PGN sent again is not an event")
    func resend() {
        let snapshot = GameSnapshot.make(ply: 41)
        let baseline = snapshot.baseline(observedAt: now, longThinkEligible: true)
        let outcome = GameDiffer.advance(baseline: baseline, snapshot: snapshot, now: now.addingTimeInterval(45))
        #expect(outcome.events.isEmpty)
    }

    @Test("A long think is measured from when the position was first seen, not from the clocks")
    func longThink() {
        let snapshot = GameSnapshot.make(ply: 41, whiteClock: 1800, blackClock: 1800)
        let baseline = snapshot.baseline(observedAt: now, longThinkEligible: true)

        #expect(GameDiffer.longThink(baseline: baseline, snapshot: snapshot, now: now.addingTimeInterval(540), minimumSeconds: 600) == nil)
        let event = GameDiffer.longThink(baseline: baseline, snapshot: snapshot, now: now.addingTimeInterval(660), minimumSeconds: 600)
        #expect(event?.kind == .longThink)
        #expect(event?.thinkSeconds == 660)

        // The clocks are identical in both snapshots — an increment would even have raised them —
        // so nothing here could have come from clock subtraction.
        #expect(snapshot.whiteClock == 1800)
    }

    @Test("A ply the server did not watch arrive cannot be a long think")
    func longThinkNeedsEligibility() {
        let snapshot = GameSnapshot.make(ply: 41)
        let baseline = snapshot.baseline(observedAt: now, longThinkEligible: false)
        #expect(GameDiffer.longThink(baseline: baseline, snapshot: snapshot, now: now.addingTimeInterval(3600), minimumSeconds: 600) == nil)
    }

    @Test("A finished game is never thinking")
    func longThinkNeedsALiveGame() {
        let snapshot = GameSnapshot.make(ply: 41, status: "1-0")
        let baseline = snapshot.baseline(observedAt: now, longThinkEligible: true)
        #expect(GameDiffer.longThink(baseline: baseline, snapshot: snapshot, now: now.addingTimeInterval(3600), minimumSeconds: 600) == nil)
    }
}
