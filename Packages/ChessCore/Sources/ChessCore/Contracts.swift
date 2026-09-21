// ChessCore — frozen contracts (see TV_BUILD_PLAN.md).
// Public signatures below must not change without telling the orchestrator.
// Parsing lives in FEN.swift; move decoding in LastMove.swift; helpers in Square.swift.

public struct Square: Hashable, Sendable {
    /// 0-based; a1 = (file 0, rank 0), h8 = (7, 7).
    public let file: Int
    public let rank: Int
    public init(file: Int, rank: Int) { self.file = file; self.rank = rank }
}

public enum PieceKind: Sendable, Hashable { case king, queen, rook, bishop, knight, pawn }
public enum PieceColor: Sendable, Hashable { case white, black }

public struct Piece: Hashable, Sendable {
    public let kind: PieceKind
    public let color: PieceColor
    public init(kind: PieceKind, color: PieceColor) { self.kind = kind; self.color = color }
}

public enum ChessCoreError: Error, Equatable, Sendable {
    case malformedFEN(String)
    case unimplemented
}

public struct Position: Sendable, Equatable {
    public let fen: String
    public let pieces: [Square: Piece]
    public let sideToMove: PieceColor
    /// Raw FEN castling field, e.g. "KQkq" or "-".
    public let castling: String
    public let fullmoveNumber: Int
    /// The en passant target square from the FEN's fourth field, or nil when the field is "-"
    /// (or absent, as in a two-field FEN).
    public let enPassantSquare: Square?
    /// The FEN's fifth field: plies since the last capture or pawn move. Defaults to 0 when absent.
    public let halfmoveClock: Int

    /// Parses a full FEN (6 fields) or a bare placement string with side to move (2 fields).
    ///
    /// Three, four and five field FENs are also accepted; the missing trailing fields take their
    /// usual defaults ("-" castling, no en passant square, halfmove clock 0, fullmove number 1).
    ///
    /// - Throws: `ChessCoreError.malformedFEN` for a wrong number of fields, a rank that does not
    ///   describe exactly eight squares, an unknown piece letter, an unknown side to move, a
    ///   malformed en passant square, or non-numeric counters.
    public init(fen: String) throws {
        let parsed = try FENParser.parse(fen)
        self.fen = parsed.normalizedFEN
        self.pieces = parsed.pieces
        self.sideToMove = parsed.sideToMove
        self.castling = parsed.castling
        self.fullmoveNumber = parsed.fullmoveNumber
        self.enPassantSquare = parsed.enPassantSquare
        self.halfmoveClock = parsed.halfmoveClock
    }
}

public struct LastMove: Sendable, Equatable {
    public let from: Square
    public let to: Square

    /// Parses a UCI move string against the position that results from it.
    ///
    /// Accepts plain moves ("e2e4"), promotions ("e7e8q", the promotion letter is ignored for
    /// highlighting purposes), and the **king-to-rook castling encoding the Lichess TV feed uses**
    /// (`"e1h1"`, `"e8a8"`, and the Chess960 forms where the rook's square is the target).
    ///
    /// **The castling rule**, decided from the two squares plus the *post-move* position alone.
    /// A move whose `from` and `to` share the first or the eighth rank is castling when, in the
    /// resulting position, that rank's color has
    ///   * its king on the g-file (kingside, `to.file > from.file`) or the c-file (queenside), and
    ///   * a rook of the same color beside it on the f-file or the d-file respectively.
    /// Only castling puts that pair there. `to` is then read as follows:
    ///   * `to` is already the king's square → the plain UCI form ("e1g1"), nothing to rewrite;
    ///   * `to` is **empty** → the Lichess king-to-rook form. Every ordinary move leaves the moving
    ///     piece standing on its UCI destination, so an empty destination means `to` names the
    ///     rook's *origin*, not the mover's square. `to` is rewritten to the king's real square:
    ///     e1h1 → g1, e1a1 → c1, e8h8 → g8, e8a8 → c8 (and the Chess960 forms, e.g. b1a1 → c1).
    ///
    /// Note that after "e1h1" the h1 square is empty — the rook has hopped to f1 (the castling
    /// fixture's FEN reads `R4RK1`), which is why emptiness, not a rook on `to`, is the signal.
    ///
    /// Anything else, including a rook sliding along the back rank to h1 while the king sits
    /// elsewhere, passes through with its squares unchanged.
    ///
    /// - Returns: nil for malformed input (wrong length, off-board squares, bad promotion letter).
    public init?(uci: String, position: Position) {
        guard let decoded = LastMoveDecoder.decode(uci: uci, position: position) else { return nil }
        self.from = decoded.from
        self.to = decoded.to
    }

    /// Memberwise initializer, for callers that already have both squares (tests, previews).
    public init(from: Square, to: Square) { self.from = from; self.to = to }
}
