// Square helpers: algebraic conversion and square color.

extension Square {
    /// The number of squares on a board edge.
    public static let boardSize = 8

    /// Parses "a1" ... "h8" (lowercase file letter, digit rank). Returns nil for anything else.
    public init?(algebraic: String) {
        guard algebraic.count == 2 else { return nil }
        var iterator = algebraic.unicodeScalars.makeIterator()
        guard let fileScalar = iterator.next(), let rankScalar = iterator.next() else { return nil }
        let file = Int(fileScalar.value) - Int(UnicodeScalar("a").value)
        let rank = Int(rankScalar.value) - Int(UnicodeScalar("1").value)
        guard (0..<Square.boardSize).contains(file), (0..<Square.boardSize).contains(rank) else { return nil }
        self.init(file: file, rank: rank)
    }

    /// "a1" ... "h8". Empty string if the square is somehow off-board.
    public var algebraic: String {
        guard isOnBoard else { return "" }
        let fileScalar = UnicodeScalar(UInt8(UnicodeScalar("a").value) + UInt8(file))
        let rankScalar = UnicodeScalar(UInt8(UnicodeScalar("1").value) + UInt8(rank))
        return String(Character(fileScalar)) + String(Character(rankScalar))
    }

    /// True when the square is one of the dark squares. a1 is dark.
    public var isDark: Bool { (file + rank) % 2 == 0 }

    /// True when both coordinates lie in 0..<8.
    public var isOnBoard: Bool {
        (0..<Square.boardSize).contains(file) && (0..<Square.boardSize).contains(rank)
    }
}

extension Square: CustomStringConvertible {
    public var description: String { algebraic }
}

extension Piece {
    /// The FEN letter for this piece: uppercase for White, lowercase for Black.
    public var fenCharacter: Character {
        let letter: Character
        switch kind {
        case .king: letter = "k"
        case .queen: letter = "q"
        case .rook: letter = "r"
        case .bishop: letter = "b"
        case .knight: letter = "n"
        case .pawn: letter = "p"
        }
        return color == .white ? Character(letter.uppercased()) : letter
    }

    /// Parses a FEN piece letter. Returns nil for anything that is not one of KQRBNPkqrbnp.
    public init?(fenCharacter: Character) {
        let kind: PieceKind
        switch Character(fenCharacter.lowercased()) {
        case "k": kind = .king
        case "q": kind = .queen
        case "r": kind = .rook
        case "b": kind = .bishop
        case "n": kind = .knight
        case "p": kind = .pawn
        default: return nil
        }
        guard fenCharacter.isLetter else { return nil }
        self.init(kind: kind, color: fenCharacter.isUppercase ? .white : .black)
    }
}

extension PieceColor {
    /// The opposite color.
    public var opposite: PieceColor { self == .white ? .black : .white }

    /// The back rank for this color: 0 for White, 7 for Black.
    public var backRank: Int { self == .white ? 0 : 7 }
}
