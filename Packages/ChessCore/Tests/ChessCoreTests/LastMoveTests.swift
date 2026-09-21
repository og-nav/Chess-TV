import Testing
@testable import ChessCore

@Test func plainMoveParses() throws {
    // From Fixtures/feed-castling.ndjson: 1. e4.
    let after = try Position(fen: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1")
    let move = try #require(LastMove(uci: "e2e4", position: after))
    #expect(move.from == Square(algebraic: "e2"))
    #expect(move.to == Square(algebraic: "e4"))
    #expect(!LastMove.isCastling(uci: "e2e4", position: after))
    #expect(move.highlights(Square(algebraic: "e4")!))
    #expect(!move.highlights(Square(algebraic: "d4")!))
}

@Test func promotionParses() throws {
    let after = try Position(fen: "4Q3/8/8/8/8/8/4k3/4K3 b - - 0 40")
    let move = try #require(LastMove(uci: "e7e8q", position: after))
    #expect(move.from == Square(algebraic: "e7"))
    #expect(move.to == Square(algebraic: "e8"))
    #expect(LastMove.promotion(uci: "e7e8q", position: after) == .queen)
    #expect(LastMove.promotion(uci: "e7e8n", position: after) == .knight)
    #expect(LastMove.promotion(uci: "e7e8", position: after) == nil)
}

// Every castling case in Fixtures/feed-castling.ndjson, plus the two black-side mirrors.
struct CastlingCase: Sendable {
    let uci: String
    let fenAfter: String
    let expectedTo: String
}

let castlingCases: [CastlingCase] = [
    // White kingside, straight from the fixture.
    CastlingCase(uci: "e1h1",
                 fenAfter: "r3k2r/pppq1ppp/2npbn2/4p3/4P3/2NPBN2/PPPQ1PPP/R4RK1 b kq - 5 8",
                 expectedTo: "g1"),
    // Black queenside, straight from the fixture.
    CastlingCase(uci: "e8a8",
                 fenAfter: "2kr3r/pppq1ppp/2npbn2/4p3/4P3/2NPBN2/PPPQ1PPP/R4RK1 w - - 6 9",
                 expectedTo: "c8"),
    // White queenside.
    CastlingCase(uci: "e1a1",
                 fenAfter: "r3k2r/pppq1ppp/2npbn2/4p3/4P3/2NPBN2/PPPQ1PPP/2KR3R b kq - 5 8",
                 expectedTo: "c1"),
    // Black kingside.
    CastlingCase(uci: "e8h8",
                 fenAfter: "r4rk1/pppq1ppp/2npbn2/4p3/4P3/2NPBN2/PPPQ1PPP/R3K2R w KQ - 5 9",
                 expectedTo: "g8"),
]

@Test(arguments: castlingCases)
func kingToRookCastlingMapsToTheKingSquare(testCase: CastlingCase) throws {
    let after = try Position(fen: testCase.fenAfter)
    let move = try #require(LastMove(uci: testCase.uci, position: after))
    #expect(move.from == Square(algebraic: String(testCase.uci.prefix(2))))
    #expect(move.to == Square(algebraic: testCase.expectedTo))
    #expect(after.piece(at: move.to) == Piece(kind: .king, color: move.to.rank == 0 ? .white : .black))
    #expect(LastMove.isCastling(uci: testCase.uci, position: after))
}

@Test func plainUCICastlingPassesThroughUnchanged() throws {
    let whiteKingside = try Position(fen: "r3k2r/pppq1ppp/2npbn2/4p3/4P3/2NPBN2/PPPQ1PPP/R4RK1 b kq - 5 8")
    let move = try #require(LastMove(uci: "e1g1", position: whiteKingside))
    #expect(move.from == Square(algebraic: "e1"))
    #expect(move.to == Square(algebraic: "g1"))
    #expect(LastMove.isCastling(uci: "e1g1", position: whiteKingside))

    let blackQueenside = try Position(fen: "2kr3r/pppq1ppp/2npbn2/4p3/4P3/2NPBN2/PPPQ1PPP/R4RK1 w - - 6 9")
    let black = try #require(LastMove(uci: "e8c8", position: blackQueenside))
    #expect(black.to == Square(algebraic: "c8"))
    #expect(LastMove.isCastling(uci: "e8c8", position: blackQueenside))
}

@Test func chess960StyleRookTargetMapsToTheKingSquare() throws {
    // Chess960: king on b1, rook on a1, castling queenside is sent as "b1a1"; after the move the
    // king stands on c1 and the rook on d1.
    let after = try Position(fen: "1rkr4/pppppppp/8/8/8/8/PPPPPPPP/2KR4 b kq - 1 1")
    let move = try #require(LastMove(uci: "b1a1", position: after))
    #expect(move.to == Square(algebraic: "c1"))
    #expect(LastMove.isCastling(uci: "b1a1", position: after))
}

@Test func aRookMoveToTheRookSquareIsNotMistakenForCastling() throws {
    // Rook a1-h1 with the white king still on e1: not castling, `to` must stay h1.
    let after = try Position(fen: "4k3/8/8/8/8/8/8/4K2R b - - 1 30")
    let move = try #require(LastMove(uci: "a1h1", position: after))
    #expect(move.to == Square(algebraic: "h1"))
    #expect(!LastMove.isCastling(uci: "a1h1", position: after))
}

@Test(arguments: ["", "e2", "e2e", "e2e4e4", "z2e4", "e9e4", "e2e9", "e2e4x", "e4e4", "  "])
func malformedUCIReturnsNil(uci: String) throws {
    let position = try Position(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
    #expect(LastMove(uci: uci, position: position) == nil)
}

@Test func everyCastlingLineInTheFixtureIsHandled() throws {
    // Mirrors Fixtures/feed-castling.ndjson without reading the file (no I/O in tests).
    let lines: [(fen: String, lm: String, expected: String)] = [
        ("r3k2r/pppq1ppp/2npbn2/4p3/4P3/2NPBN2/PPPQ1PPP/R4RK1 b kq - 5 8", "e1h1", "g1"),
        ("2kr3r/pppq1ppp/2npbn2/4p3/4P3/2NPBN2/PPPQ1PPP/R4RK1 w - - 6 9", "e8a8", "c8"),
        ("rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1", "e2e4", "e4"),
    ]
    for line in lines {
        let position = try Position(fen: line.fen)
        let move = try #require(LastMove(uci: line.lm, position: position))
        #expect(move.to == Square(algebraic: line.expected), "\(line.lm) should land on \(line.expected)")
    }
}
