// The check sound asks ChessCore whether the side to move stands in check; these are the cases
// the app cares about. (This file used to test an attack scan the app carried itself, before
// ChessCore grew a move generator.)
import Testing
import ChessCore
@testable import GameSessionKit

@Suite("The check detection the check sound relies on")
struct CheckDetectionTests {

    private func position(_ fen: String) throws -> Position { try Position(fen: fen) }

    @Test("A knight check is detected")
    func knightCheck() throws {
        // White knight on e6 forks nothing but checks the black king on g8... via f6/d8; use c7.
        let p = try position("4k3/2N5/8/8/8/8/8/4K3 b - - 0 1")
        #expect(p.isAttacked(Square(algebraic: "e8")!, by: .white))
        #expect(p.isInCheck(.black))
    }

    @Test("A bishop checks along a diagonal and a blocker stops it")
    func bishopRay() throws {
        // Bishop a4, king e8: a4-b5-c6-d7-e8.
        let open = try position("4k3/8/8/8/B7/8/8/4K3 b - - 0 1")
        #expect(open.isInCheck(.black))

        let blocked = try position("4k3/8/2P5/8/B7/8/8/4K3 b - - 0 1")
        #expect(!blocked.isInCheck(.black))
    }

    @Test("A rook checks along a file and a blocker stops it")
    func rookRay() throws {
        let open = try position("4k3/8/8/8/8/8/8/4R1K1 b - - 0 1")
        #expect(open.isInCheck(.black))

        let blocked = try position("4k3/4p3/8/8/8/8/8/4R1K1 b - - 0 1")
        #expect(!blocked.isInCheck(.black))
    }

    @Test("A queen checks on both the rank and the diagonal")
    func queenRays() throws {
        let diagonal = try position("4k3/8/8/8/Q7/8/8/4K3 b - - 0 1")
        #expect(diagonal.isInCheck(.black))
        let rank = try position("4k2Q/8/8/8/8/8/8/4K3 b - - 0 1")
        #expect(rank.isInCheck(.black))
    }

    @Test("A pawn checks forward-diagonally, in the right direction only")
    func pawnAttacks() throws {
        let checking = try position("4k3/3P4/8/8/8/8/8/4K3 b - - 0 1")
        #expect(checking.isInCheck(.black))
        // A white pawn *above* the black king does not attack it.
        let harmless = try position("3P4/4k3/8/8/8/8/8/4K3 b - - 0 1")
        #expect(!harmless.isInCheck(.black))
        // Black pawns attack downward.
        let blackPawn = try position("4k3/8/8/8/8/8/4p3/3K4 w - - 0 1")
        #expect(blackPawn.isInCheck(.white))
    }

    @Test("The enemy king attacks its neighbours")
    func kingAttacks() throws {
        let p = try position("8/8/8/3kK3/8/8/8/8 w - - 0 1")
        #expect(p.isAttacked(Square(algebraic: "e5")!, by: .black))
        #expect(p.isAttacked(Square(algebraic: "d5")!, by: .white))
    }

    @Test("A quiet middlegame position is not a check")
    func quietPosition() throws {
        let p = try position("r1b2rk1/pp2ppbp/6p1/4P3/6PN/2B4P/PPP1QPB1/2KR3q b - - 1 21")
        #expect(!p.isInCheck(.black))
    }

    @Test("A real check from the live fixture")
    func liveCheck() throws {
        // Scholar's mate: the white queen on f7 sits next to the black king on e8.
        let p = try position("r1bqkbnr/pppp1Qpp/2n5/4p3/2B1P3/8/PPPP1PPP/RNB1K1NR b KQkq - 0 4")
        #expect(p.isInCheck(.black))
        #expect(!p.isInCheck(.white))
    }

    @Test("A missing king is never in check")
    func missingKing() throws {
        let p = try position("8/8/8/8/8/8/8/4K3 b - - 0 1")
        #expect(!p.isInCheck(.black))
    }
}
