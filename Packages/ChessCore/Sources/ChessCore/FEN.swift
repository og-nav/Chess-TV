// FEN parsing and serialization.
//
// The Lichess TV feed always sends a full six-field FEN, but the parser also accepts the
// two-field form (placement + side to move) that appears in puzzles and hand-written fixtures.

enum FENParser {
    struct Parsed {
        var normalizedFEN: String
        var pieces: [Square: Piece]
        var sideToMove: PieceColor
        var castling: String
        var enPassantSquare: Square?
        var halfmoveClock: Int
        var fullmoveNumber: Int
    }

    static func parse(_ raw: String) throws -> Parsed {
        let fields = raw.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .map(String.init)
        guard fields.count >= 2, fields.count <= 6 else {
            throw ChessCoreError.malformedFEN("expected 2 to 6 fields, found \(fields.count): \"\(raw)\"")
        }

        let pieces = try parsePlacement(fields[0])

        let sideToMove: PieceColor
        switch fields[1] {
        case "w": sideToMove = .white
        case "b": sideToMove = .black
        default: throw ChessCoreError.malformedFEN("unknown side to move \"\(fields[1])\"")
        }

        let castling = fields.count > 2 ? try validatedCastling(fields[2]) : "-"

        var enPassantSquare: Square?
        if fields.count > 3, fields[3] != "-" {
            guard let square = Square(algebraic: fields[3]) else {
                throw ChessCoreError.malformedFEN("bad en passant square \"\(fields[3])\"")
            }
            guard square.rank == 2 || square.rank == 5 else {
                throw ChessCoreError.malformedFEN("en passant square \"\(fields[3])\" is not on the third or sixth rank")
            }
            enPassantSquare = square
        }

        var halfmoveClock = 0
        if fields.count > 4 {
            guard let value = Int(fields[4]), value >= 0 else {
                throw ChessCoreError.malformedFEN("bad halfmove clock \"\(fields[4])\"")
            }
            halfmoveClock = value
        }

        var fullmoveNumber = 1
        if fields.count > 5 {
            guard let value = Int(fields[5]), value >= 1 else {
                throw ChessCoreError.malformedFEN("bad fullmove number \"\(fields[5])\"")
            }
            fullmoveNumber = value
        }

        return Parsed(
            normalizedFEN: fields.joined(separator: " "),
            pieces: pieces,
            sideToMove: sideToMove,
            castling: castling,
            enPassantSquare: enPassantSquare,
            halfmoveClock: halfmoveClock,
            fullmoveNumber: fullmoveNumber
        )
    }

    private static func parsePlacement(_ placement: String) throws -> [Square: Piece] {
        let ranks = placement.split(separator: "/", omittingEmptySubsequences: false)
        guard ranks.count == Square.boardSize else {
            throw ChessCoreError.malformedFEN("expected 8 ranks, found \(ranks.count) in \"\(placement)\"")
        }

        var pieces: [Square: Piece] = [:]
        pieces.reserveCapacity(32)

        // FEN lists ranks from 8 down to 1.
        for (index, rankText) in ranks.enumerated() {
            let rank = Square.boardSize - 1 - index
            var file = 0
            for character in rankText {
                if let empties = character.wholeNumberValue, character.isNumber {
                    guard empties >= 1, empties <= Square.boardSize else {
                        throw ChessCoreError.malformedFEN("bad skip count \"\(character)\" on rank \(rank + 1)")
                    }
                    file += empties
                } else if let piece = Piece(fenCharacter: character) {
                    guard file < Square.boardSize else {
                        throw ChessCoreError.malformedFEN("rank \(rank + 1) is longer than 8 squares in \"\(placement)\"")
                    }
                    pieces[Square(file: file, rank: rank)] = piece
                    file += 1
                } else {
                    throw ChessCoreError.malformedFEN("unknown piece character \"\(character)\" in \"\(placement)\"")
                }
            }
            guard file == Square.boardSize else {
                throw ChessCoreError.malformedFEN("rank \(rank + 1) describes \(file) squares, expected 8, in \"\(placement)\"")
            }
        }
        return pieces
    }

    private static func validatedCastling(_ field: String) throws -> String {
        if field == "-" { return field }
        guard !field.isEmpty, field.count <= 4 else {
            throw ChessCoreError.malformedFEN("bad castling field \"\(field)\"")
        }
        // Standard KQkq plus the Shredder-FEN file letters that Chess960 games can use.
        let allowed = Set("KQkqABCDEFGHabcdefgh")
        guard field.allSatisfy({ allowed.contains($0) }) else {
            throw ChessCoreError.malformedFEN("bad castling field \"\(field)\"")
        }
        return field
    }
}

extension Position {
    /// The piece on a square, or nil when it is empty.
    public func piece(at square: Square) -> Piece? { pieces[square] }

    /// The number of pieces on the board. The app compares this across positions to detect
    /// captures for the capture sound.
    public var pieceCount: Int { pieces.count }

    /// The number of pieces of one color.
    public func pieceCount(for color: PieceColor) -> Int {
        pieces.values.reduce(into: 0) { $0 += ($1.color == color ? 1 : 0) }
    }

    /// The square the given color's king stands on, or nil if it is missing (fixtures, puzzles).
    public func kingSquare(for color: PieceColor) -> Square? {
        for (square, piece) in pieces where piece.kind == .king && piece.color == color {
            return square
        }
        return nil
    }

    /// The board placement field, rebuilt from `pieces`.
    public var placementFEN: String { Position.placement(of: pieces) }

    /// A full six-field FEN rebuilt from the parsed state. For a well-formed six-field input this
    /// is identical to `fen`; for a shorter input it fills in the defaults.
    public func makeFEN() -> String {
        [
            placementFEN,
            sideToMove == .white ? "w" : "b",
            castling,
            enPassantSquare?.algebraic ?? "-",
            String(halfmoveClock),
            String(fullmoveNumber),
        ].joined(separator: " ")
    }

    /// The standard chess starting position.
    public static let standard: Position = {
        // Safe to force-try: the literal is a known-good FEN, covered by a test.
        try! Position(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
    }()
}
