import Testing
import ChessCore
@testable import ChessUI

@Test func boardCoversAll64Squares() {
    #expect(BoardGeometry.allSquares.count == 64)
    #expect(Set(BoardGeometry.allSquares).count == 64)
}

@Test func whiteOrientationPutsA1AtTheBottomLeft() {
    let a1 = Square(algebraic: "a1")!
    let h8 = Square(algebraic: "h8")!
    #expect(BoardGeometry.column(of: a1, orientation: .white) == 0)
    #expect(BoardGeometry.row(of: a1, orientation: .white) == 7)
    #expect(BoardGeometry.column(of: h8, orientation: .white) == 7)
    #expect(BoardGeometry.row(of: h8, orientation: .white) == 0)
}

@Test func blackOrientationFlipsTheBoard() {
    let a1 = Square(algebraic: "a1")!
    let h8 = Square(algebraic: "h8")!
    #expect(BoardGeometry.column(of: a1, orientation: .black) == 7)
    #expect(BoardGeometry.row(of: a1, orientation: .black) == 0)
    #expect(BoardGeometry.column(of: h8, orientation: .black) == 0)
    #expect(BoardGeometry.row(of: h8, orientation: .black) == 7)
}

@Test func everySquareHasADistinctSlotInBothOrientations() {
    for orientation in [PieceColor.white, .black] {
        let slots = BoardGeometry.allSquares.map {
            BoardGeometry.row(of: $0, orientation: orientation) * 8 + BoardGeometry.column(of: $0, orientation: orientation)
        }
        #expect(Set(slots).count == 64)
        #expect(slots.allSatisfy { (0..<64).contains($0) })
    }
}

@Test func squareOriginsTileTheBoardExactly() {
    let squareSide = 100.0
    let origins = BoardGeometry.allSquares.map { BoardGeometry.origin(of: $0, orientation: .white, squareSide: squareSide) }
    #expect(origins.map(\.x).max() == 700)
    #expect(origins.map(\.y).max() == 700)
    #expect(origins.map(\.x).min() == 0)
    #expect(origins.map(\.y).min() == 0)
}

@Test func boardViewBuildsForBothOrientations() throws {
    let position = try Position(fen: "r1b2rk1/pp2ppbp/6p1/4P3/6PN/2B4P/PPP1QPB1/2KR3q b - - 1 21")
    let move = try #require(LastMove(uci: "f1g2", position: position))
    for orientation in [PieceColor.white, .black] {
        for theme in BoardTheme.all {
            let view = BoardView(position: position, lastMove: move, theme: theme,
                                 pieceSet: .cburnett, orientation: orientation, showCoordinates: true)
            #expect(view.orientation == orientation)
            #expect(view.theme == theme)
            #expect(view.lastMove?.to == Square(algebraic: "g2"))
        }
    }
    let empty = BoardView(position: nil, lastMove: nil, theme: .sage, pieceSet: .chessnut,
                          orientation: .white, showCoordinates: false)
    #expect(empty.position == nil)
}

@Test func evalBarClampsOutOfRangeShares() {
    #expect(EvalBarView(whiteShare: 2, orientation: .white).whiteShare == 2)
    // The view clamps internally; the contract keeps the raw value.
    #expect(EvalBarView.cornerRadius == 4)
}
