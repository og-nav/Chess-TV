// Reading Standard Algebraic Notation.
//
// The writing direction lives in SAN.swift. This is the inverse: a PGN token such as `Nbd2`,
// `exd8=Q+`, `O-O` or `0-0-0` resolved against the legal moves of the position before it.
//
// The resolution is deliberately done by *writing* the SAN for every legal move and comparing —
// that way there is exactly one definition of what SAN means in this package, and a move can
// never be resolved to something `SAN.notation(for:in:)` would spell differently. A second,
// structural pass then rescues the spellings real PGNs contain but the writer never emits:
// over-disambiguation (`Nb1d2` where `Nd2` is unique), long algebraic (`e2e4`, `e2-e4`), a
// lowercase promotion piece, or a missing promotion piece altogether.

extension SAN {

    /// Resolves one SAN token against the legal moves of `position` — the position **before**
    /// the move.
    ///
    /// Accepted decoration, all of it stripped before matching: the check and mate marks `+`
    /// and `#`, the annotation glyphs `!` and `?` in any combination (`!?`, `??`), a trailing
    /// numeric NAG (`$1`), an `e.p.` suffix, surrounding whitespace, and the `0-0` / `0-0-0`
    /// spelling of castling. A promotion is accepted with or without the `=` (`e8=Q`, `e8Q`,
    /// `e8q`) and, as a last resort, without the piece at all (`e8`, read as a queen).
    ///
    /// - Returns: nil when the token is malformed, names no legal move in `position`, or is
    ///   ambiguous — two legal moves that the token describes equally well.
    public static func move(forSAN san: String, in position: Position) -> Move? {
        let token = canonicalSAN(san)
        guard !token.isEmpty else { return nil }

        let legal = position.legalMoves()

        // The definitive pass: whatever this package would *write* for the move.
        var written: [Move] = []
        for candidate in legal where notation(for: candidate, in: position).map(canonicalSAN) == token {
            written.append(candidate)
        }
        if written.count == 1 { return written[0] }
        if written.count > 1 { return nil }

        return structuralMatch(token, among: legal, in: position)
    }

    /// A SAN token with every decoration removed, so two spellings of the same move compare equal.
    ///
    /// `Nbxd2+!?` → `Nbxd2`, `e8=Q#` → `e8Q`, `0-0` → `O-O`, `exd6e.p.` → `exd6`.
    static func canonicalSAN(_ raw: String) -> String {
        var text = raw.sanTrimmed()
        // A numeric NAG (`$17`) is an annotation, never part of the move.
        if let dollar = text.firstIndex(of: "$") { text = String(text[text.startIndex..<dollar]).sanTrimmed() }
        if text.hasSuffix("e.p.") { text.removeLast(4) }
        else if text.hasSuffix("e.p") { text.removeLast(3) }

        var stripped = ""
        for character in text where !"+#!?=".contains(character) {
            stripped.append(character)
        }

        // Castling in any of its spellings, including the digit zero and lowercase o.
        let castling = stripped.lowercased()
        if castling == "o-o" || castling == "0-0" || castling == "oo" || castling == "00" { return "O-O" }
        if castling == "o-o-o" || castling == "0-0-0" || castling == "ooo" || castling == "000" { return "O-O-O" }

        // Outside castling a hyphen only ever appears in the long algebraic form `e2-e4`.
        return stripped.filter { $0 != "-" }
    }

    /// Takes the token apart — piece, disambiguation, capture, destination, promotion — and
    /// filters the legal moves by each part. Used only when the exact-spelling pass found nothing.
    private static func structuralMatch(_ token: String, among legal: [Move], in position: Position) -> Move? {
        if token == "O-O" || token == "O-O-O" {
            let kingside = token == "O-O"
            let matches = legal.filter { move in
                guard let piece = position.piece(at: move.from), piece.kind == .king else { return false }
                guard abs(move.to.file - move.from.file) == 2 else { return false }
                return kingside ? move.to.file > move.from.file : move.to.file < move.from.file
            }
            return matches.count == 1 ? matches[0] : nil
        }

        var characters = Array(token)

        // Promotion: the trailing piece letter, `e8Q` or `e8q`, after a rank digit.
        var promotion: PieceKind?
        if characters.count >= 3, let kind = promotionKind(characters[characters.count - 1]),
           characters[characters.count - 2].isNumber {
            promotion = kind
            characters.removeLast()
        }

        // Destination: the last two characters.
        guard characters.count >= 2, let destination = Square(algebraic: String(characters.suffix(2))) else { return nil }
        characters.removeLast(2)

        // Mover: a leading piece letter, or a pawn.
        var kind = PieceKind.pawn
        if let first = characters.first, let named = pieceKind(first) {
            kind = named
            characters.removeFirst()
        }
        if characters.last == "x" { characters.removeLast() }

        // Whatever is left disambiguates: a file letter, a rank digit, or both.
        var fileHint: Int?
        var rankHint: Int?
        for character in characters {
            if let scalar = character.unicodeScalars.first, ("a"..."h").contains(character) {
                fileHint = Int(scalar.value) - Int(UnicodeScalar("a").value)
            } else if let digit = character.wholeNumberValue, (1...8).contains(digit) {
                rankHint = digit - 1
            } else {
                return nil   // not a SAN token at all
            }
        }

        var candidates = legal.filter { move in
            guard move.to == destination else { return false }
            guard let piece = position.piece(at: move.from), piece.kind == kind, piece.color == position.sideToMove else { return false }
            if let fileHint, move.from.file != fileHint { return false }
            if let rankHint, move.from.rank != rankHint { return false }
            return true
        }

        if let promotion {
            candidates = candidates.filter { $0.promotion == promotion }
        } else {
            let plain = candidates.filter { $0.promotion == nil }
            // A promotion whose piece the writer left out: everyone means a queen.
            candidates = plain.isEmpty ? candidates.filter { $0.promotion == .queen } : plain
        }

        let unique = Set(candidates)
        return unique.count == 1 ? unique.first : nil
    }

    private static func pieceKind(_ letter: Character) -> PieceKind? {
        switch letter {
        case "K": .king
        case "Q": .queen
        case "R": .rook
        case "B": .bishop
        case "N": .knight
        default: nil
        }
    }

    private static func promotionKind(_ letter: Character) -> PieceKind? {
        switch letter {
        case "Q", "q": .queen
        case "R", "r": .rook
        case "B", "b": .bishop
        case "N", "n": .knight
        default: nil
        }
    }
}

extension String {
    /// Whitespace-trimmed, without pulling in Foundation.
    func sanTrimmed() -> String {
        var slice = Substring(self)
        while let first = slice.first, first.isWhitespace { slice.removeFirst() }
        while let last = slice.last, last.isWhitespace { slice.removeLast() }
        return String(slice)
    }
}
