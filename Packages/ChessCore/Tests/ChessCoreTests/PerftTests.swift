import Testing
import Foundation
import ChessCore

/// Perft: the number of legal move sequences of a given length. These counts are the standard
/// way to prove a generator handles castling rights, en passant, promotion and pins correctly —
/// a single missing or extra move shows up as a wrong total.
@Suite("Perft validates the legal move generator")
struct PerftTests {

    private func position(_ fen: String) throws -> Position { try Position(fen: fen) }

    @Test("The starting position")
    func startPosition() throws {
        let start = Position.standard
        #expect(start.perft(1) == 20)
        #expect(start.perft(2) == 400)
        #expect(start.perft(3) == 8902)
    }

    @Test("Kiwipete, the castling and pin torture test")
    func kiwipete() throws {
        let p = try position("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1")
        #expect(p.perft(1) == 48)
        #expect(p.perft(2) == 2039)
        #expect(p.perft(3) == 97862)
    }

    /// Roughly four million nodes; a few seconds at -Onone, so it is opt-in:
    /// `CHESSCORE_SLOW_PERFT=1 swift test`.
    @Test(
        "Kiwipete to depth four",
        .enabled(if: ProcessInfo.processInfo.environment["CHESSCORE_SLOW_PERFT"] != nil)
    )
    func kiwipeteDeep() throws {
        let p = try position("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1")
        #expect(p.perft(4) == 4085603)
    }

    @Test("Position 3: en passant, promotions and a rook endgame")
    func positionThree() throws {
        let p = try position("8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1")
        #expect(p.perft(1) == 14)
        #expect(p.perft(2) == 191)
        #expect(p.perft(3) == 2812)
        #expect(p.perft(4) == 43238)
    }

    @Test("Position 4: underpromotions and a pinned queen")
    func positionFour() throws {
        let p = try position("r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1")
        #expect(p.perft(1) == 6)
        #expect(p.perft(2) == 264)
        #expect(p.perft(3) == 9467)
    }

    @Test("Castling is offered only when it is legal")
    func castlingLegality() throws {
        // Rights, empty squares, nothing attacked: both castlings are there.
        let open = try position("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
        let castles = open.legalMoves().filter { $0.from == Square(algebraic: "e1")! && abs($0.to.file - 4) == 2 }
        #expect(Set(castles.map(\.uci)) == ["e1g1", "e1c1"])

        // A rook covering f1 stops kingside castling but not queenside.
        let attacked = try position("r3k2r/5r2/8/8/8/8/8/R3K2R w KQkq - 0 1")
        #expect(attacked.legalMoves().map(\.uci).contains("e1c1"))
        #expect(!attacked.legalMoves().map(\.uci).contains("e1g1"))

        // No rights, no castling.
        let noRights = try position("r3k2r/8/8/8/8/8/8/R3K2R w - - 0 1")
        #expect(!noRights.legalMoves().contains { $0.from.file == 4 && abs($0.to.file - 4) == 2 })
    }

    @Test("Checkmate and stalemate are empty move lists")
    func terminalPositions() throws {
        let mate = try position("rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3")
        #expect(mate.legalMoves().isEmpty)
        #expect(mate.isInCheck(.white))
        #expect(mate.isCheckmate)

        let stalemate = try position("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1")
        #expect(stalemate.legalMoves().isEmpty)
        #expect(!stalemate.isInCheck(.black))
        #expect(!stalemate.isCheckmate)
    }

    @Test("making() keeps the clocks, the rights and the en passant square")
    func makingBookkeeping() throws {
        let start = Position.standard
        let afterE4 = start.making(Move(from: Square(algebraic: "e2")!, to: Square(algebraic: "e4")!))
        #expect(afterE4.fen == "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1")

        let afterNf6 = afterE4.making(Move(from: Square(algebraic: "g8")!, to: Square(algebraic: "f6")!))
        #expect(afterNf6.fen == "rnbqkb1r/pppppppp/5n2/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 1 2")

        // Castling moves the rook and drops both of that colour's rights.
        let castling = try position("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 4 9")
        let afterOO = castling.making(Move(from: Square(algebraic: "e1")!, to: Square(algebraic: "g1")!))
        #expect(afterOO.fen == "r3k2r/8/8/8/8/8/8/R4RK1 b kq - 5 9")
        let afterOOO = afterOO.making(Move(from: Square(algebraic: "e8")!, to: Square(algebraic: "c8")!))
        #expect(afterOOO.fen == "2kr3r/8/8/8/8/8/8/R4RK1 w - - 6 10")

        // En passant removes the pawn beside the mover, not the one on the target square.
        let enPassant = try position("rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3")
        let afterExd6 = enPassant.making(Move(from: Square(algebraic: "e5")!, to: Square(algebraic: "d6")!))
        #expect(afterExd6.placementFEN == "rnbqkbnr/ppp1pppp/3P4/8/8/8/PPPP1PPP/RNBQKBNR")

        // Promotion, and a rook capture that costs Black a castling right.
        let promotion = try position("rnbqkbnr/pP2pppp/8/8/8/8/PPPP1PPP/RNBQKBNR w KQkq - 0 5")
        let afterPromotion = promotion.making(
            Move(from: Square(algebraic: "b7")!, to: Square(algebraic: "a8")!, promotion: .queen)
        )
        #expect(afterPromotion.fen == "Qnbqkbnr/p3pppp/8/8/8/8/PPPP1PPP/RNBQKBNR b KQk - 0 5")
    }
}
