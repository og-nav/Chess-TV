// Legal move generation.
//
// The Lichess feed sends a full FEN for every ply, so the app never needs a search — this exists
// so the move list can be written in SAN (see SAN.swift), which needs to know the *legal*
// alternatives to a move in order to disambiguate it, and whether the move gives check or mate.
//
// The representation is a plain 64-square mailbox built from `Position.pieces` on entry, and
// legality is checked the simple way: play the pseudo-legal move on a copy and ask whether the
// mover's king is attacked. That is far more than fast enough for one call per ply (well under a
// millisecond in release), and it keeps the code small enough to read. No bitboards.
//
// **Standard chess only.** Chess960 castling is not generated: castling is offered only when the
// king stands on its classical square (e1/e8) and the rook on a1/h1/a8/h8. In a shuffled start
// the generator simply returns no castling moves; everything else about such a position (ordinary
// moves, check, mate) is still handled correctly.

/// One move: the square a piece leaves, the square it lands on, and what a pawn promotes to.
///
/// Castling is spelled king-from → king-to in the plain UCI form ("e1g1", "e8c8"), never in the
/// king-to-rook form the Lichess TV feed uses; `SAN.notation(for:in:)` accepts either spelling
/// and resolves it to this one.
public struct Move: Hashable, Sendable {
    public let from: Square
    public let to: Square
    /// The piece a pawn becomes, for a move that reaches the last rank. Nil otherwise.
    public let promotion: PieceKind?

    public init(from: Square, to: Square, promotion: PieceKind? = nil) {
        self.from = from
        self.to = to
        self.promotion = promotion
    }

    /// "e2e4", "e7e8q", "e1g1".
    public var uci: String {
        var text = from.algebraic + to.algebraic
        if let promotion { text.append(promotion.fenLetter) }
        return text
    }
}

extension PieceKind {
    /// The lowercase FEN/UCI letter for this kind: "k", "q", "r", "b", "n", "p".
    var fenLetter: Character {
        switch self {
        case .king: "k"
        case .queen: "q"
        case .rook: "r"
        case .bishop: "b"
        case .knight: "n"
        case .pawn: "p"
        }
    }

    /// The SAN letter: "K", "Q", "R", "B", "N", and "" for a pawn.
    var sanLetter: String {
        self == .pawn ? "" : String(fenLetter).uppercased()
    }
}

// MARK: - Castling rights

/// The four classical castling rights, parsed out of the FEN's third field.
struct CastlingRights: OptionSet, Sendable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    static let whiteKingside = CastlingRights(rawValue: 1 << 0)
    static let whiteQueenside = CastlingRights(rawValue: 1 << 1)
    static let blackKingside = CastlingRights(rawValue: 1 << 2)
    static let blackQueenside = CastlingRights(rawValue: 1 << 3)

    /// Reads "KQkq". Shredder-FEN file letters are accepted only for the classical rook files
    /// (A/H, a/h); any other file means a Chess960 castling we do not generate, and is dropped.
    init(fenField: String) {
        var value: CastlingRights = []
        for character in fenField {
            switch character {
            case "K", "H": value.insert(.whiteKingside)
            case "Q", "A": value.insert(.whiteQueenside)
            case "k", "h": value.insert(.blackKingside)
            case "q", "a": value.insert(.blackQueenside)
            default: break
            }
        }
        self = value
    }

    /// "KQkq", or "-" when nothing is left.
    var fenField: String {
        var text = ""
        if contains(.whiteKingside) { text += "K" }
        if contains(.whiteQueenside) { text += "Q" }
        if contains(.blackKingside) { text += "k" }
        if contains(.blackQueenside) { text += "q" }
        return text.isEmpty ? "-" : text
    }

    static func kingside(_ color: PieceColor) -> CastlingRights {
        color == .white ? .whiteKingside : .blackKingside
    }

    static func queenside(_ color: PieceColor) -> CastlingRights {
        color == .white ? .whiteQueenside : .blackQueenside
    }

    static func both(_ color: PieceColor) -> CastlingRights {
        [kingside(color), queenside(color)]
    }
}

// MARK: - The mailbox

/// A 64-square board, built from a `Position` for the duration of one generation call.
struct Board {
    /// Index `rank * 8 + file`; nil is an empty square.
    var squares: [Piece?]
    var sideToMove: PieceColor
    var rights: CastlingRights
    var enPassant: Square?

    static let knightSteps: [(Int, Int)] = [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)]
    static let kingSteps: [(Int, Int)] = [(0, 1), (1, 1), (1, 0), (1, -1), (0, -1), (-1, -1), (-1, 0), (-1, 1)]
    static let rookRays: [(Int, Int)] = [(0, 1), (1, 0), (0, -1), (-1, 0)]
    static let bishopRays: [(Int, Int)] = [(1, 1), (1, -1), (-1, -1), (-1, 1)]
    static let promotionKinds: [PieceKind] = [.queen, .rook, .bishop, .knight]

    init(_ position: Position) {
        var squares = [Piece?](repeating: nil, count: Square.boardSize * Square.boardSize)
        for (square, piece) in position.pieces where square.isOnBoard {
            squares[square.index] = piece
        }
        self.squares = squares
        self.sideToMove = position.sideToMove
        self.rights = CastlingRights(fenField: position.castling)
        self.enPassant = position.enPassantSquare
    }

    subscript(square: Square) -> Piece? {
        get { square.isOnBoard ? squares[square.index] : nil }
        set { if square.isOnBoard { squares[square.index] = newValue } }
    }

    func kingSquare(for color: PieceColor) -> Square? {
        for index in squares.indices {
            if let piece = squares[index], piece.kind == .king, piece.color == color {
                return Square(index: index)
            }
        }
        return nil
    }

    // MARK: Attacks

    /// True when any piece of `color` attacks `square`.
    func isAttacked(_ square: Square, by color: PieceColor) -> Bool {
        guard square.isOnBoard else { return false }

        // Pawns. A white pawn attacks up the board, so it stands one rank *below* its target.
        let pawnRank = square.rank - (color == .white ? 1 : -1)
        for fileOffset in [-1, 1] {
            let from = Square(file: square.file + fileOffset, rank: pawnRank)
            if from.isOnBoard, self[from] == Piece(kind: .pawn, color: color) { return true }
        }

        for step in Board.knightSteps {
            let from = Square(file: square.file + step.0, rank: square.rank + step.1)
            if from.isOnBoard, self[from] == Piece(kind: .knight, color: color) { return true }
        }

        for step in Board.kingSteps {
            let from = Square(file: square.file + step.0, rank: square.rank + step.1)
            if from.isOnBoard, self[from] == Piece(kind: .king, color: color) { return true }
        }

        if slides(to: square, by: color, rays: Board.rookRays, first: .rook, second: .queen) { return true }
        if slides(to: square, by: color, rays: Board.bishopRays, first: .bishop, second: .queen) { return true }
        return false
    }

    private func slides(
        to square: Square,
        by color: PieceColor,
        rays: [(Int, Int)],
        first: PieceKind,
        second: PieceKind
    ) -> Bool {
        for ray in rays {
            var file = square.file + ray.0
            var rank = square.rank + ray.1
            while true {
                let step = Square(file: file, rank: rank)
                guard step.isOnBoard else { break }
                if let piece = self[step] {
                    if piece.color == color, piece.kind == first || piece.kind == second { return true }
                    break   // any other piece blocks the ray
                }
                file += ray.0
                rank += ray.1
            }
        }
        return false
    }

    func isInCheck(_ color: PieceColor) -> Bool {
        guard let king = kingSquare(for: color) else { return false }
        return isAttacked(king, by: color.opposite)
    }

    // MARK: Generation

    /// Every legal move for the side to move.
    func legalMoves() -> [Move] {
        let mover = sideToMove
        var legal: [Move] = []
        legal.reserveCapacity(40)
        for move in pseudoLegalMoves() {
            var next = self
            next.play(move)
            if !next.isInCheck(mover) { legal.append(move) }
        }
        return legal
    }

    /// Moves that respect each piece's movement rules but may leave the king en prise.
    /// Castling is the exception: its "may not castle out of, through or into check" rule is
    /// checked here, since the intermediate square is invisible to the king-safety filter.
    func pseudoLegalMoves() -> [Move] {
        var moves: [Move] = []
        moves.reserveCapacity(48)
        for index in squares.indices {
            guard let piece = squares[index], piece.color == sideToMove else { continue }
            let from = Square(index: index)
            switch piece.kind {
            case .pawn: appendPawnMoves(from: from, color: piece.color, into: &moves)
            case .knight: appendSteps(Board.knightSteps, from: from, color: piece.color, into: &moves)
            case .king: appendSteps(Board.kingSteps, from: from, color: piece.color, into: &moves)
            case .rook: appendRays(Board.rookRays, from: from, color: piece.color, into: &moves)
            case .bishop: appendRays(Board.bishopRays, from: from, color: piece.color, into: &moves)
            case .queen:
                appendRays(Board.rookRays, from: from, color: piece.color, into: &moves)
                appendRays(Board.bishopRays, from: from, color: piece.color, into: &moves)
            }
        }
        appendCastling(into: &moves)
        return moves
    }

    private func appendSteps(_ steps: [(Int, Int)], from: Square, color: PieceColor, into moves: inout [Move]) {
        for step in steps {
            let to = Square(file: from.file + step.0, rank: from.rank + step.1)
            guard to.isOnBoard else { continue }
            if let occupant = self[to], occupant.color == color { continue }
            moves.append(Move(from: from, to: to))
        }
    }

    private func appendRays(_ rays: [(Int, Int)], from: Square, color: PieceColor, into moves: inout [Move]) {
        for ray in rays {
            var file = from.file + ray.0
            var rank = from.rank + ray.1
            while true {
                let to = Square(file: file, rank: rank)
                guard to.isOnBoard else { break }
                if let occupant = self[to] {
                    if occupant.color != color { moves.append(Move(from: from, to: to)) }
                    break
                }
                moves.append(Move(from: from, to: to))
                file += ray.0
                rank += ray.1
            }
        }
    }

    private func appendPawnMoves(from: Square, color: PieceColor, into moves: inout [Move]) {
        let direction = color == .white ? 1 : -1
        let startRank = color == .white ? 1 : 6
        let lastRank = color == .white ? 7 : 0

        let ahead = Square(file: from.file, rank: from.rank + direction)
        if ahead.isOnBoard, self[ahead] == nil {
            append(pawnMove: Move(from: from, to: ahead), lastRank: lastRank, into: &moves)
            let twoAhead = Square(file: from.file, rank: from.rank + 2 * direction)
            if from.rank == startRank, twoAhead.isOnBoard, self[twoAhead] == nil {
                moves.append(Move(from: from, to: twoAhead))
            }
        }

        for fileOffset in [-1, 1] {
            let to = Square(file: from.file + fileOffset, rank: from.rank + direction)
            guard to.isOnBoard else { continue }
            if let occupant = self[to] {
                if occupant.color != color { append(pawnMove: Move(from: from, to: to), lastRank: lastRank, into: &moves) }
            } else if to == enPassant {
                // The captured pawn sits beside the mover, not on the target square.
                if self[Square(file: to.file, rank: from.rank)] == Piece(kind: .pawn, color: color.opposite) {
                    moves.append(Move(from: from, to: to))
                }
            }
        }
    }

    private func append(pawnMove move: Move, lastRank: Int, into moves: inout [Move]) {
        guard move.to.rank == lastRank else { return moves.append(move) }
        for kind in Board.promotionKinds {
            moves.append(Move(from: move.from, to: move.to, promotion: kind))
        }
    }

    /// Classical castling only; see the note at the top of the file.
    private func appendCastling(into moves: inout [Move]) {
        let color = sideToMove
        let rank = color.backRank
        let kingFrom = Square(file: 4, rank: rank)
        guard self[kingFrom] == Piece(kind: .king, color: color) else { return }
        // Castling out of check is illegal; the two other squares are checked per side below.
        guard !isAttacked(kingFrom, by: color.opposite) else { return }

        let rook = Piece(kind: .rook, color: color)
        if rights.contains(.kingside(color)),
           self[Square(file: 7, rank: rank)] == rook,
           self[Square(file: 5, rank: rank)] == nil,
           self[Square(file: 6, rank: rank)] == nil,
           !isAttacked(Square(file: 5, rank: rank), by: color.opposite),
           !isAttacked(Square(file: 6, rank: rank), by: color.opposite) {
            moves.append(Move(from: kingFrom, to: Square(file: 6, rank: rank)))
        }

        if rights.contains(.queenside(color)),
           self[Square(file: 0, rank: rank)] == rook,
           self[Square(file: 1, rank: rank)] == nil,
           self[Square(file: 2, rank: rank)] == nil,
           self[Square(file: 3, rank: rank)] == nil,
           !isAttacked(Square(file: 3, rank: rank), by: color.opposite),
           !isAttacked(Square(file: 2, rank: rank), by: color.opposite) {
            moves.append(Move(from: kingFrom, to: Square(file: 2, rank: rank)))
        }
    }

    // MARK: Playing a move

    /// Moves the pieces for `move` — capture, en passant, promotion and the castling rook — and
    /// flips the side to move. Does not maintain rights, the en passant square or the clocks:
    /// this is the board half of `Position.making(_:)` and the legality filter's inner loop.
    mutating func play(_ move: Move) {
        guard let piece = self[move.from] else { return }
        let captured = self[move.to]

        self[move.from] = nil
        if let promotion = move.promotion, piece.kind == .pawn {
            self[move.to] = Piece(kind: promotion, color: piece.color)
        } else if piece.kind == .pawn, move.to.rank == (piece.color == .white ? 7 : 0) {
            // A promotion whose piece the caller forgot to name: a queen, as every UI assumes.
            self[move.to] = Piece(kind: .queen, color: piece.color)
        } else {
            self[move.to] = piece
        }

        if piece.kind == .pawn, move.from.file != move.to.file, captured == nil {
            self[Square(file: move.to.file, rank: move.from.rank)] = nil   // en passant
        }

        if piece.kind == .king, abs(move.to.file - move.from.file) == 2 {
            let rank = move.from.rank
            let kingside = move.to.file > move.from.file
            let rookFrom = Square(file: kingside ? 7 : 0, rank: rank)
            let rookTo = Square(file: kingside ? 5 : 3, rank: rank)
            let rook = self[rookFrom]
            self[rookFrom] = nil
            self[rookTo] = rook
        }

        sideToMove = sideToMove.opposite
    }

    /// The board as a `[Square: Piece]` dictionary again.
    var pieceDictionary: [Square: Piece] {
        var pieces: [Square: Piece] = [:]
        pieces.reserveCapacity(32)
        for index in squares.indices {
            if let piece = squares[index] { pieces[Square(index: index)] = piece }
        }
        return pieces
    }
}

extension Square {
    /// `rank * 8 + file`, the mailbox index. Only meaningful for an on-board square.
    var index: Int { rank * Square.boardSize + file }

    init(index: Int) {
        self.init(file: index % Square.boardSize, rank: index / Square.boardSize)
    }
}

// MARK: - The public surface

extension Position {

    /// True when any piece of `color` attacks `square` — pins and legality are not considered,
    /// which is exactly what "attacked" means for check, castling and king moves.
    public func isAttacked(_ square: Square, by color: PieceColor) -> Bool {
        Board(self).isAttacked(square, by: color)
    }

    /// True when `color`'s king stands on a square the other side attacks.
    /// False when that king is missing from the position (fixtures, puzzles).
    public func isInCheck(_ color: PieceColor) -> Bool {
        Board(self).isInCheck(color)
    }

    /// Every legal move for the side to move, in no particular order.
    ///
    /// Empty means the game is over: checkmate when `isInCheck(sideToMove)` is true, stalemate
    /// otherwise. Chess960 castling is not generated (see the note at the top of this file).
    public func legalMoves() -> [Move] {
        Board(self).legalMoves()
    }

    /// True when the side to move has no legal move and stands in check.
    public var isCheckmate: Bool {
        isInCheck(sideToMove) && legalMoves().isEmpty
    }

    /// The position after `move`, with a regenerated FEN.
    ///
    /// Handles captures, the en passant capture, promotion (an unnamed one becomes a queen), the
    /// castling rook, and updates the castling rights, the en passant square, the halfmove clock,
    /// the fullmove number and the side to move. Castling is given in the plain form ("e1g1").
    ///
    /// The move is trusted: an illegal one is played anyway, and a move from an empty square
    /// returns the position unchanged.
    public func making(_ move: Move) -> Position {
        guard let piece = pieces[move.from] else { return self }
        let captured = pieces[move.to]
        let isEnPassant = piece.kind == .pawn && move.from.file != move.to.file && captured == nil

        var board = Board(self)
        board.play(move)

        // Castling rights: the mover's own when the king moves, and one side's when the rook
        // leaves — or is captured on — its corner.
        var rights = CastlingRights(fenField: castling)
        if piece.kind == .king { rights.subtract(.both(piece.color)) }
        for square in [move.from, move.to] {
            switch (square.file, square.rank) {
            case (0, 0): rights.subtract(.whiteQueenside)
            case (7, 0): rights.subtract(.whiteKingside)
            case (0, 7): rights.subtract(.blackQueenside)
            case (7, 7): rights.subtract(.blackKingside)
            default: break
            }
        }

        // A double pawn push leaves an en passant target behind it.
        var enPassant: Square?
        if piece.kind == .pawn, abs(move.to.rank - move.from.rank) == 2 {
            enPassant = Square(file: move.from.file, rank: (move.from.rank + move.to.rank) / 2)
        }

        let resetsClock = piece.kind == .pawn || captured != nil || isEnPassant
        return Position(
            pieces: board.pieceDictionary,
            sideToMove: sideToMove.opposite,
            castling: rights.fenField,
            enPassantSquare: enPassant,
            halfmoveClock: resetsClock ? 0 : halfmoveClock + 1,
            fullmoveNumber: sideToMove == .black ? fullmoveNumber + 1 : fullmoveNumber
        )
    }

    /// Builds a position from its parts and derives the FEN from them. Internal: the public way
    /// in is `init(fen:)` or `making(_:)`.
    init(
        pieces: [Square: Piece],
        sideToMove: PieceColor,
        castling: String,
        enPassantSquare: Square?,
        halfmoveClock: Int,
        fullmoveNumber: Int
    ) {
        self.pieces = pieces
        self.sideToMove = sideToMove
        self.castling = castling
        self.enPassantSquare = enPassantSquare
        self.halfmoveClock = halfmoveClock
        self.fullmoveNumber = fullmoveNumber
        self.fen = [
            Position.placement(of: pieces),
            sideToMove == .white ? "w" : "b",
            castling,
            enPassantSquare?.algebraic ?? "-",
            String(halfmoveClock),
            String(fullmoveNumber),
        ].joined(separator: " ")
    }

    /// The FEN board placement field for a piece dictionary.
    static func placement(of pieces: [Square: Piece]) -> String {
        var ranks: [String] = []
        ranks.reserveCapacity(Square.boardSize)
        for rank in stride(from: Square.boardSize - 1, through: 0, by: -1) {
            var text = ""
            var empties = 0
            for file in 0..<Square.boardSize {
                if let piece = pieces[Square(file: file, rank: rank)] {
                    if empties > 0 { text += String(empties); empties = 0 }
                    text.append(piece.fenCharacter)
                } else {
                    empties += 1
                }
            }
            if empties > 0 { text += String(empties) }
            ranks.append(text)
        }
        return ranks.joined(separator: "/")
    }

    /// The number of legal move sequences of length `depth` from this position — the standard
    /// perft count used to validate a move generator.
    public func perft(_ depth: Int) -> Int {
        guard depth > 0 else { return 1 }
        let board = Board(self)
        if depth == 1 { return board.legalMoves().count }
        return Position.perft(board, depth: depth)
    }

    private static func perft(_ board: Board, depth: Int) -> Int {
        let moves = board.legalMoves()
        if depth == 1 { return moves.count }
        var total = 0
        for move in moves {
            var next = board
            next.play(move)
            next.enPassant = enPassantTarget(for: move, on: board)
            next.rights = rights(after: move, on: board)
            total += perft(next, depth: depth - 1)
        }
        return total
    }

    private static func enPassantTarget(for move: Move, on board: Board) -> Square? {
        guard board[move.from]?.kind == .pawn, abs(move.to.rank - move.from.rank) == 2 else { return nil }
        return Square(file: move.from.file, rank: (move.from.rank + move.to.rank) / 2)
    }

    private static func rights(after move: Move, on board: Board) -> CastlingRights {
        var rights = board.rights
        if let piece = board[move.from], piece.kind == .king { rights.subtract(.both(piece.color)) }
        for square in [move.from, move.to] {
            switch (square.file, square.rank) {
            case (0, 0): rights.subtract(.whiteQueenside)
            case (7, 0): rights.subtract(.whiteKingside)
            case (0, 7): rights.subtract(.blackQueenside)
            case (7, 7): rights.subtract(.blackKingside)
            default: break
            }
        }
        return rights
    }
}
