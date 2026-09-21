import Testing
import Foundation
import ChessCore

/// Reading SAN back: every move this package can *write* must resolve to the move it came from,
/// and the spellings real PGNs use must resolve too.
@Suite("SAN reads back everything it writes")
struct SANParsingTests {

    /// The four perft positions: between them they cover castling, en passant, promotion,
    /// under-promotion, pins and every flavour of disambiguation.
    private static let positions = [
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
    ]

    @Test("Every legal move of the perft positions survives notation → move", arguments: positions)
    func roundTripOnePly(fen: String) throws {
        let position = try Position(fen: fen)
        try roundTrip(position)
    }

    /// One ply deeper as well, so Black's moves and the positions after castling are covered too.
    /// A sample of the children keeps the suite quick; the first ply already covers every move.
    @Test("…and a sample of the positions one ply later", arguments: positions)
    func roundTripTwoPly(fen: String) throws {
        let position = try Position(fen: fen)
        for move in position.legalMoves().sorted(by: { $0.uci < $1.uci }).prefix(8) {
            try roundTrip(position.making(move), decorated: false)
        }
    }

    private func roundTrip(_ position: Position, decorated: Bool = true) throws {
        for move in position.legalMoves() {
            let san = try #require(SAN.notation(for: move, in: position), "no SAN for \(move.uci)")
            let resolved = SAN.move(forSAN: san, in: position)
            #expect(resolved == move, "\(san) resolved to \(resolved?.uci ?? "nil"), expected \(move.uci)")
            guard decorated else { continue }
            // The decoration a PGN hangs off a move must not change the answer.
            #expect(SAN.move(forSAN: san + "!?", in: position) == move)
            #expect(SAN.move(forSAN: san + " $1", in: position) == move)
        }
    }

    @Test("Castling in every spelling")
    func castlingSpellings() throws {
        let position = try Position(fen: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
        for token in ["O-O", "0-0", "o-o", "O-O+"] {
            #expect(SAN.move(forSAN: token, in: position)?.uci == "e1g1", "\(token)")
        }
        for token in ["O-O-O", "0-0-0", "O-O-O!"] {
            #expect(SAN.move(forSAN: token, in: position)?.uci == "e1c1", "\(token)")
        }
    }

    @Test("Promotions with, without and missing the piece")
    func promotions() throws {
        let position = try Position(fen: "1n6/P7/8/8/8/8/8/K6k w - - 0 1")
        #expect(SAN.move(forSAN: "a8=Q", in: position)?.uci == "a7a8q")
        #expect(SAN.move(forSAN: "a8Q", in: position)?.uci == "a7a8q")
        #expect(SAN.move(forSAN: "a8q", in: position)?.uci == "a7a8q")
        #expect(SAN.move(forSAN: "a8=N+", in: position)?.uci == "a7a8n")
        #expect(SAN.move(forSAN: "axb8=R", in: position)?.uci == "a7b8r")
        // No piece at all: a queen, by universal convention.
        #expect(SAN.move(forSAN: "a8", in: position)?.uci == "a7a8q")
    }

    @Test("Over-disambiguation and the long algebraic form still resolve")
    func lenientSpellings() throws {
        let position = try Position(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
        #expect(SAN.move(forSAN: "Ng1f3", in: position)?.uci == "g1f3")
        #expect(SAN.move(forSAN: "e2e4", in: position)?.uci == "e2e4")
        #expect(SAN.move(forSAN: "e2-e4", in: position)?.uci == "e2e4")
        #expect(SAN.move(forSAN: "Nf3", in: position)?.uci == "g1f3")
    }

    @Test("Illegal, ambiguous and malformed tokens return nil")
    func rejections() throws {
        let start = Position.standard
        #expect(SAN.move(forSAN: "e5", in: start) == nil)           // illegal
        #expect(SAN.move(forSAN: "Kd2", in: start) == nil)          // illegal
        #expect(SAN.move(forSAN: "", in: start) == nil)
        #expect(SAN.move(forSAN: "hello", in: start) == nil)
        #expect(SAN.move(forSAN: "Z9", in: start) == nil)

        // Two knights both reach d2 from b1 and f3-less start; use a made-up position instead.
        let twoKnights = try Position(fen: "8/8/8/8/8/8/8/KN1N3k w - - 0 1")
        #expect(SAN.move(forSAN: "Nc3", in: twoKnights) == nil)     // b1 and d1 both reach c3
        #expect(SAN.move(forSAN: "Nbc3", in: twoKnights)?.uci == "b1c3")
        #expect(SAN.move(forSAN: "Ndc3", in: twoKnights)?.uci == "d1c3")
    }

    @Test("En passant, with and without the e.p. suffix")
    func enPassant() throws {
        let position = try Position(fen: "rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3")
        #expect(SAN.move(forSAN: "exd6", in: position)?.uci == "e5d6")
        #expect(SAN.move(forSAN: "exd6e.p.", in: position)?.uci == "e5d6")
    }
}
