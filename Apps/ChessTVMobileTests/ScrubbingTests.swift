import Testing
import Foundation
import ChessCore
import GameSessionKit
@testable import ChessTVMobile

@Suite("Scrubbing back through a game")
struct ScrubbingTests {

    /// The Immortal Game's opening, enough plies to cover both colours and a capture.
    private static let pgn = """
    [Event "London"]
    [White "Anderssen"]
    [Black "Kieseritzky"]
    [Result "1-0"]

    1. e4 e5 2. f4 exf4 3. Bc4 Qh4+ 4. Kf1 b5 5. Bxb5 Nf6 6. Nf3 Qh6 1-0
    """

    /// The move list the app would hold after replaying that PGN, in `MoveEntry` form.
    private func history() throws -> (entries: [MoveEntry], replayed: [(san: String, uci: String, fen: String)]) {
        let game = try #require(PGN.parseGame(Self.pgn))
        let replayed = try game.replay()
        var entries: [MoveEntry] = []
        var position = game.initialPosition
        for step in replayed {
            // The move number is the one in force *before* the move, which is the same number
            // for both colours of a pair.
            entries.append(
                MoveEntry(
                    uci: step.uci,
                    san: step.san,
                    fen: step.fen,
                    moveNumber: position.fullmoveNumber,
                    color: position.sideToMove
                )
            )
            position = try Position(fen: step.fen)
        }
        return (entries, replayed)
    }

    @Test("Every ply shows exactly the position ChessCore's replay produces")
    func positionsMatchReplay() throws {
        let (entries, replayed) = try history()
        let initial = Position.standard.fen

        // Ply 0 is the position before the first move.
        #expect(ScrubTimeline.fen(atPly: 0, history: entries, initialFEN: initial) == initial)

        for (index, step) in replayed.enumerated() {
            let ply = ScrubTimeline.ply(forHistoryIndex: index)
            #expect(ScrubTimeline.fen(atPly: ply, history: entries, initialFEN: initial) == step.fen)
        }

        // One past the end is nothing, not the last move.
        #expect(ScrubTimeline.fen(atPly: entries.count + 1, history: entries, initialFEN: initial) == nil)
        #expect(ScrubTimeline.fen(atPly: -1, history: entries, initialFEN: initial) == nil)
    }

    @Test("Stepping back from live lands on the move before the last one, and forward returns to live")
    func steppingWalksTheWholeGame() throws {
        let (entries, _) = try history()
        let total = entries.count

        let back = ScrubTimeline.previous(nil, total: total)
        #expect(back == total - 1)

        var ply = back
        for _ in 0..<(total * 2) where ply != nil {
            ply = ScrubTimeline.previous(ply, total: total)
        }
        #expect(ply == 0, "stepping back repeatedly stops at the initial position")

        var forward: Int? = total - 1
        forward = ScrubTimeline.next(forward, total: total)
        #expect(forward == nil, "stepping past the last ply is live again")
    }

    @Test("An empty game has nothing to scrub through")
    func emptyGame() {
        #expect(ScrubTimeline.previous(nil, total: 0) == nil)
        #expect(ScrubTimeline.next(nil, total: 0) == nil)
        #expect(ScrubTimeline.isLive(nil, total: 0))
    }

    @Test("The scrub label names the move, with the ellipsis form for Black")
    func labels() throws {
        let (entries, _) = try history()
        #expect(ScrubTimeline.label(viewed: nil, history: entries) == "Live")
        #expect(ScrubTimeline.label(viewed: 0, history: entries) == "Start")
        #expect(ScrubTimeline.label(viewed: 1, history: entries) == "1. e4")
        #expect(ScrubTimeline.label(viewed: 2, history: entries) == "1\u{2026} e5")
    }

    @Test("Move rows keep each half's ply, so tapping a move scrubs to that move")
    func numberedRowsCarryPlies() throws {
        let (entries, _) = try history()
        let rows = NumberedMoveRow.rows(from: entries)

        #expect(rows.first?.number == 1)
        #expect(rows.first?.white?.ply == 1)
        #expect(rows.first?.black?.ply == 2)
        #expect(rows.count == (entries.count + 1) / 2)
        // Every ply appears exactly once, in order.
        let plies = rows.flatMap { [$0.white?.ply, $0.black?.ply].compactMap { $0 } }
        #expect(plies == Array(1...entries.count))
    }

    @Test("A stream joined at Black's move starts with a row whose White half is empty")
    func joinedMidGame() {
        let entries = [
            MoveEntry(uci: "e7e5", san: "e5", fen: "x", moveNumber: 12, color: .black),
            MoveEntry(uci: "g1f3", san: "Nf3", fen: "y", moveNumber: 13, color: .white),
        ]
        let rows = NumberedMoveRow.rows(from: entries)
        #expect(rows.count == 2)
        #expect(rows[0].white == nil)
        #expect(rows[0].black?.ply == 1, "the first entry is ply 1 even though it is move 12")
        #expect(rows[1].white?.ply == 2)
    }
}
