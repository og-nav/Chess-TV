// Standard Algebraic Notation.
//
// The Lichess feed carries no SAN — only UCI and a FEN per ply — so the move list writes its own.
// Everything here needs the position *before* the move: SAN is relative to what else was possible,
// which is why the disambiguation below asks the generator for the legal alternatives rather than
// guessing from the piece placement.

public enum SAN {

    /// The SAN for a move given in UCI, played in `position`.
    ///
    /// `position` is the position **before** the move. Both castling spellings are accepted: the
    /// plain UCI form ("e1g1") and the king-to-rook form the Lichess TV feed sends ("e1h1",
    /// "e8a8"), which is recognised by the mover's own rook standing on the destination.
    ///
    /// - Returns: nil when the string is malformed or does not name a legal move in `position`
    ///   (a mid-stream broadcast, a variant, or a Chess960 castling, which is not generated).
    public static func notation(for uci: String, in position: Position) -> String? {
        guard let move = move(forUCI: uci, in: position) else { return nil }
        return notation(for: move, in: position)
    }

    /// The SAN for a move, played in `position` — the position before the move.
    ///
    /// - Returns: nil when the move is not legal in `position`, since SAN for an illegal move is
    ///   not defined (its disambiguation and its check suffix would both be guesses).
    public static func notation(for move: Move, in position: Position) -> String? {
        let legal = position.legalMoves()
        guard legal.contains(move) || legal.contains(where: { $0.from == move.from && $0.to == move.to && $0.promotion == move.promotion }),
              let piece = position.piece(at: move.from), piece.color == position.sideToMove
        else { return nil }

        var text: String
        if piece.kind == .king, abs(move.to.file - move.from.file) == 2 {
            text = move.to.file > move.from.file ? "O-O" : "O-O-O"
        } else {
            let isEnPassant = piece.kind == .pawn
                && move.from.file != move.to.file
                && position.piece(at: move.to) == nil
            let isCapture = position.piece(at: move.to) != nil || isEnPassant

            if piece.kind == .pawn {
                text = isCapture ? "\(fileLetter(move.from.file))x\(move.to.algebraic)" : move.to.algebraic
                if let promotion = move.promotion { text += "=\(promotion.sanLetter)" }
            } else {
                text = piece.kind.sanLetter
                    + disambiguation(for: move, piece: piece, among: legal, in: position)
                    + (isCapture ? "x" : "")
                    + move.to.algebraic
            }
        }

        let after = position.making(move)
        if after.isInCheck(after.sideToMove) {
            text += after.legalMoves().isEmpty ? "#" : "+"
        }
        return text
    }

    /// The file, the rank, or both — whichever the SAN rules call for.
    ///
    /// Only *legal* alternatives count. A same-kind piece that could reach the square but is
    /// pinned to its king is not an alternative, and so needs no disambiguating.
    private static func disambiguation(
        for move: Move,
        piece: Piece,
        among legal: [Move],
        in position: Position
    ) -> String {
        let rivals = legal.filter { candidate in
            candidate.to == move.to
                && candidate.from != move.from
                && position.piece(at: candidate.from) == piece
        }
        guard !rivals.isEmpty else { return "" }
        if rivals.allSatisfy({ $0.from.file != move.from.file }) { return String(fileLetter(move.from.file)) }
        if rivals.allSatisfy({ $0.from.rank != move.from.rank }) { return String(move.from.rank + 1) }
        return move.from.algebraic
    }

    private static func fileLetter(_ file: Int) -> Character {
        Character(UnicodeScalar(UInt8(UnicodeScalar("a").value) + UInt8(file)))
    }

    /// Resolves a UCI string against the legal moves of `position` (the position before the move),
    /// rewriting the Lichess king-to-rook castling form to the king's real destination.
    ///
    /// - Returns: nil when the string is malformed or names no legal move.
    public static func move(forUCI uci: String, in position: Position) -> Move? {
        let characters = Array(uci.trimmed())
        guard characters.count == 4 || characters.count == 5 else { return nil }
        guard var from = Square(algebraic: String(characters[0...1])),
              var to = Square(algebraic: String(characters[2...3])),
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

        // King to its own rook: castling, as the feed spells it. No legal ordinary move ever lands
        // a king on a square its own rook occupies, so this is unambiguous.
        if let mover = position.piece(at: from), mover.kind == .king,
           position.piece(at: to) == Piece(kind: .rook, color: mover.color) {
            to = Square(file: to.file > from.file ? 6 : 2, rank: from.rank)
            from = Square(file: 4, rank: from.rank)
        }

        let candidate = Move(from: from, to: to, promotion: promotion)
        let legal = position.legalMoves()
        if legal.contains(candidate) { return candidate }
        // A promotion whose letter the feed left out: everyone means a queen.
        if promotion == nil {
            let queening = Move(from: from, to: to, promotion: .queen)
            if legal.contains(queening) { return queening }
        }
        return nil
    }
}

extension String {
    fileprivate func trimmed() -> String {
        let set: Set<Character> = [" ", "\t", "\n", "\r"]
        var slice = Substring(self)
        while let first = slice.first, set.contains(first) { slice.removeFirst() }
        while let last = slice.last, set.contains(last) { slice.removeLast() }
        return String(slice)
    }
}
