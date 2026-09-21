import ChessCore

extension Position {
    /// FEN parsing accepts diagrams and variant boards. Stockfish's standard search requires
    /// two kings and a legal side-to-move relationship; never send a diagram to native code.
    public var supportsStandardAnalysis: Bool {
        for color in [PieceColor.white, .black] {
            guard pieces.values.filter({ $0.kind == .king && $0.color == color }).count == 1 else { return false }
        }
        guard !pieces.contains(where: { $0.value.kind == .pawn && ($0.key.rank == 0 || $0.key.rank == 7) }),
              !isInCheck(sideToMove.opposite) else { return false }
        guard castling == "-" || castling.allSatisfy({ "KQkq".contains($0) }) else { return false }
        for (right, color, rookFile) in [(Character("K"), PieceColor.white, 7), ("Q", .white, 0), ("k", .black, 7), ("q", .black, 0)] where castling.contains(right) {
            let rank = color == .white ? 0 : 7
            guard piece(at: Square(file: 4, rank: rank)) == Piece(kind: .king, color: color),
                  piece(at: Square(file: rookFile, rank: rank)) == Piece(kind: .rook, color: color) else { return false }
        }
        return true
    }
}
