import Testing
@testable import ChessCore

// FENs taken from Fixtures/feed-blitz.ndjson and Fixtures/feed-castling.ndjson.
enum Fixtures {
    static let start = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

    static let blitz = [
        "r1b2rk1/pp2ppbp/6p1/4P3/6PN/2B4P/PPP1QP2/2KR1B1q w - - 0 21",
        "r1b2rk1/pp2ppbp/6p1/4P3/6PN/2B4P/PPP1QPB1/2KR3q b - - 1 21",
        "r1b2rk1/pp2ppbp/6p1/4P3/6PN/2B4P/PPP1QPBq/2KR4 w - - 2 22",
        "r1b2rk1/pp2ppbp/6p1/4P3/6PN/2B1Q2P/PPP2PBq/2KR4 b - - 3 22",
    ]

    static let castling = [
        "r3k2r/pppq1ppp/2npbn2/4p3/4P3/2NPBN2/PPPQ1PPP/R3K2R w KQkq - 4 8",
        "r3k2r/pppq1ppp/2npbn2/4p3/4P3/2NPBN2/PPPQ1PPP/R4RK1 b kq - 5 8",
        "2kr3r/pppq1ppp/2npbn2/4p3/4P3/2NPBN2/PPPQ1PPP/R4RK1 w - - 6 9",
    ]
}

@Test func startPositionRoundTrips() throws {
    let position = try Position(fen: Fixtures.start)
    #expect(position.fen == Fixtures.start)
    #expect(position.makeFEN() == Fixtures.start)
    #expect(position.pieceCount == 32)
    #expect(position.sideToMove == .white)
    #expect(position.castling == "KQkq")
    #expect(position.enPassantSquare == nil)
    #expect(position.halfmoveClock == 0)
    #expect(position.fullmoveNumber == 1)
    #expect(position == Position.standard)
}

@Test(arguments: Fixtures.blitz + Fixtures.castling)
func fixtureFENsRoundTrip(fen: String) throws {
    let position = try Position(fen: fen)
    #expect(position.fen == fen)
    #expect(position.makeFEN() == fen)
}

@Test func piecesAreOnTheRightSquares() throws {
    let position = try Position(fen: Fixtures.start)
    #expect(position.piece(at: Square(algebraic: "e1")!) == Piece(kind: .king, color: .white))
    #expect(position.piece(at: Square(algebraic: "d8")!) == Piece(kind: .queen, color: .black))
    #expect(position.piece(at: Square(algebraic: "b1")!) == Piece(kind: .knight, color: .white))
    #expect(position.piece(at: Square(algebraic: "e4")!) == nil)
    #expect(position.kingSquare(for: .black) == Square(algebraic: "e8"))
    #expect(position.pieceCount(for: .white) == 16)
}

@Test func twoFieldFENParses() throws {
    let position = try Position(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w")
    #expect(position.sideToMove == .white)
    #expect(position.castling == "-")
    #expect(position.enPassantSquare == nil)
    #expect(position.halfmoveClock == 0)
    #expect(position.fullmoveNumber == 1)
    #expect(position.pieces == Position.standard.pieces)
    #expect(position.makeFEN() == "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w - - 0 1")
}

@Test func enPassantSquareIsParsed() throws {
    let position = try Position(fen: "rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 2")
    #expect(position.enPassantSquare == Square(algebraic: "c6"))
    #expect(position.enPassantSquare?.file == 2)
    #expect(position.enPassantSquare?.rank == 5)
    #expect(position.halfmoveClock == 0)
    #expect(position.fullmoveNumber == 2)
    #expect(position.makeFEN() == position.fen)

    let none = try Position(fen: Fixtures.start)
    #expect(none.enPassantSquare == nil)

    let halfmoves = try Position(fen: "8/8/4k3/8/8/4K3/8/8 b - - 37 90")
    #expect(halfmoves.halfmoveClock == 37)
    #expect(halfmoves.fullmoveNumber == 90)
    #expect(halfmoves.sideToMove == .black)
}

@Test(arguments: [
    "",
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR",                          // one field
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP w KQkq - 0 1",                      // seven ranks
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR/8 w KQkq - 0 1",           // nine ranks
    "rnbqkbnr/ppppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",            // rank too long
    "rnbqkbnr/ppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",              // rank too short
    "rnbqkbnr/pppxpppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",             // unknown letter
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR x KQkq - 0 1",             // unknown side
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq e9 0 1",            // bad ep square
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq e4 0 1",            // ep on wrong rank
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w ZZ - 0 1",               // bad castling
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - x 1",             // bad halfmove clock
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 0",             // bad fullmove number
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 extra",       // too many fields
])
func malformedFENThrows(fen: String) {
    #expect(throws: ChessCoreError.self) {
        _ = try Position(fen: fen)
    }
}

@Test func squareHelpers() {
    #expect(Square(algebraic: "a1") == Square(file: 0, rank: 0))
    #expect(Square(algebraic: "h8") == Square(file: 7, rank: 7))
    #expect(Square(algebraic: "e4")?.algebraic == "e4")
    #expect(Square(algebraic: "i1") == nil)
    #expect(Square(algebraic: "a0") == nil)
    #expect(Square(algebraic: "a9") == nil)
    #expect(Square(algebraic: "A1") == nil)
    #expect(Square(algebraic: "e44") == nil)
    #expect(Square(algebraic: "") == nil)

    #expect(Square(algebraic: "a1")!.isDark)
    #expect(Square(algebraic: "h8")!.isDark)
    #expect(!Square(algebraic: "h1")!.isDark)
    #expect(!Square(algebraic: "a8")!.isDark)
    #expect(!Square(algebraic: "e4")!.isDark)
}

@Test func positionEquality() throws {
    let a = try Position(fen: Fixtures.blitz[0])
    let b = try Position(fen: Fixtures.blitz[0])
    let c = try Position(fen: Fixtures.blitz[1])
    #expect(a == b)
    #expect(a != c)
}

@Test func pieceCountDropsOnCapture() throws {
    let before = try Position(fen: "r1bqkbnr/pppp1ppp/2n5/4p3/3PP3/5N2/PPP2PPP/RNBQKB1R b KQkq - 0 3")
    let after = try Position(fen: "r1bqkbnr/pppp1ppp/2n5/8/3pP3/5N2/PPP2PPP/RNBQKB1R w KQkq - 0 4")
    #expect(before.pieceCount - after.pieceCount == 1)
}
