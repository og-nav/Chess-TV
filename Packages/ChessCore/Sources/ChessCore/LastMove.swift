// Decoding the `lm` field of the Lichess TV feed.
//
// The feed gives the FEN *after* the move together with the move in UCI, and it encodes castling
// king-to-rook ("e1h1"). We therefore decide castling from the two squares plus the post-move
// position: see the doc comment on `LastMove.init(uci:position:)`.

enum LastMoveDecoder {
    struct Decoded {
        var from: Square
        var to: Square
        var promotion: PieceKind?
        var isCastling: Bool
    }

    static func decode(uci: String, position: Position) -> Decoded? {
        let text = uci.trimmingCharactersInSet(" \t\n\r")
        guard text.count == 4 || text.count == 5 else { return nil }

        let characters = Array(text)
        guard let from = Square(algebraic: String(characters[0...1])),
              let to = Square(algebraic: String(characters[2...3])),
              from != to
        else { return nil }

        var promotion: PieceKind?
        if characters.count == 5 {
            switch Character(characters[4].lowercased()) {
            case "q": promotion = .queen
            case "r": promotion = .rook
            case "b": promotion = .bishop
            case "n": promotion = .knight
            default: return nil
            }
        }

        switch castlingForm(from: from, to: to, position: position) {
        case .none:
            return Decoded(from: from, to: to, promotion: promotion, isCastling: false)
        case .plain:
            return Decoded(from: from, to: to, promotion: promotion, isCastling: true)
        case .kingToRook(let kingSquare):
            return Decoded(from: from, to: kingSquare, promotion: promotion, isCastling: true)
        }
    }

    private enum CastlingForm {
        case none
        /// "e1g1": the UCI destination is already the king's square.
        case plain
        /// "e1h1": the UCI destination is the rook's square; the associated value is the king's.
        case kingToRook(Square)
    }

    private static func castlingForm(from: Square, to: Square, position: Position) -> CastlingForm {
        guard from.rank == to.rank, from.rank == 0 || from.rank == 7 else { return .none }
        let color: PieceColor = from.rank == 0 ? .white : .black
        let rank = from.rank

        // Castling is the only move that leaves the king on g/c with the rook next to it on f/d.
        let kingside = to.file > from.file
        let kingSquare = Square(file: kingside ? 6 : 2, rank: rank)
        let rookSquare = Square(file: kingside ? 5 : 3, rank: rank)
        guard position.piece(at: kingSquare) == Piece(kind: .king, color: color),
              position.piece(at: rookSquare) == Piece(kind: .rook, color: color)
        else { return .none }

        if to == kingSquare { return .plain }

        // Every ordinary move leaves the moving piece standing on its UCI destination, so an empty
        // destination in the resulting position means the destination was not the mover's real
        // square: the king-to-rook castling encoding, where `to` is the rook's *origin*.
        // (After "e1h1" the fixture reads R4RK1 — h1 is empty, the rook is on f1.)
        if position.piece(at: to) == nil { return .kingToRook(kingSquare) }

        return .none
    }
}

extension LastMove {
    /// True when the UCI string describes castling in the position that results from it, in either
    /// the Lichess king-to-rook encoding or the plain form.
    public static func isCastling(uci: String, position: Position) -> Bool {
        LastMoveDecoder.decode(uci: uci, position: position)?.isCastling ?? false
    }

    /// The piece a pawn promoted to, from the fifth character of a UCI string ("e7e8q" → queen).
    public static func promotion(uci: String, position: Position) -> PieceKind? {
        LastMoveDecoder.decode(uci: uci, position: position)?.promotion
    }

    /// The two squares this move highlights.
    public var squares: [Square] { [from, to] }

    /// True when this move touches the given square.
    public func highlights(_ square: Square) -> Bool { square == from || square == to }
}

extension String {
    fileprivate func trimmingCharactersInSet(_ characters: String) -> String {
        let set = Set(characters)
        var slice = Substring(self)
        while let first = slice.first, set.contains(first) { slice.removeFirst() }
        while let last = slice.last, set.contains(last) { slice.removeLast() }
        return String(slice)
    }
}
