// The board, square by square, for VoiceOver.
//
// `BoardView` is one accessibility element with a summary label, which is right on a TV where
// nothing on the board takes focus. On a phone VoiceOver is how a blind player reads a position,
// and "Chess board, 32 pieces, White to move" is not a position. So the board is drawn as before
// and an invisible 8×8 grid of elements is laid over it, in the reading order the sighted board
// has: top-left to bottom-right for whichever side is at the bottom.
import SwiftUI
import ChessCore
import ChessUI

struct AccessibleBoard: View {
    let position: Position?
    let lastMove: LastMove?
    let theme: BoardTheme
    let pieceSet: PieceSet
    let orientation: PieceColor
    let showCoordinates: Bool

    var body: some View {
        BoardView(
            position: position,
            lastMove: lastMove,
            theme: theme,
            pieceSet: pieceSet,
            orientation: orientation,
            showCoordinates: showCoordinates
        )
        .accessibilityHidden(true)
        .overlay {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(0..<8, id: \.self) { row in
                    GridRow {
                        ForEach(0..<8, id: \.self) { column in
                            let square = BoardSpeech.square(row: row, column: column, orientation: orientation)
                            Color.clear
                                .contentShape(Rectangle())
                                .accessibilityElement()
                                .accessibilityLabel(BoardSpeech.label(for: square, in: position))
                                .accessibilityValue(BoardSpeech.value(for: square, lastMove: lastMove))
                        }
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Board"))
        .accessibilityIdentifier(UIID.Game.board)
    }
}

/// How a square is spoken. Pure, so the wording is checked in tests rather than by ear.
enum BoardSpeech {

    /// Row 0 is the top of the screen and column 0 is the left, matching `BoardView`'s own
    /// geometry, so the grid over the board lines up with the squares under it.
    static func square(row: Int, column: Int, orientation: PieceColor) -> Square {
        orientation == .white
            ? Square(file: column, rank: 7 - row)
            : Square(file: 7 - column, rank: row)
    }

    static func label(for square: Square, in position: Position?) -> String {
        guard let piece = position?.piece(at: square) else { return "\(square.algebraic), empty" }
        return "\(square.algebraic), \(name(of: piece))"
    }

    /// The last move is announced as a value rather than baked into the label, so VoiceOver's
    /// "empty" and "white pawn" stay short while the two interesting squares still say why.
    static func value(for square: Square, lastMove: LastMove?) -> String {
        guard let lastMove else { return "" }
        if lastMove.from == square { return "last move from here" }
        if lastMove.to == square { return "last move to here" }
        return ""
    }

    static func name(of piece: Piece) -> String {
        "\(piece.color == .white ? "white" : "black") \(kind(piece.kind))"
    }

    static func kind(_ kind: PieceKind) -> String {
        switch kind {
        case .king: "king"
        case .queen: "queen"
        case .rook: "rook"
        case .bishop: "bishop"
        case .knight: "knight"
        case .pawn: "pawn"
        }
    }

    /// The move list's spoken form: "23. Nf5" rather than the bare SAN, and pieces by name so
    /// "Nbd7" is not read as a word.
    static func move(number: Int, color: PieceColor, san: String) -> String {
        let side = color == .white ? "White" : "Black"
        return "\(side), move \(number), \(spell(san))"
    }

    /// Spells SAN for a screen reader: "Nf5" → "knight f5", "O-O" → "castles kingside".
    static func spell(_ san: String) -> String {
        if san == "O-O" || san == "0-0" { return "castles kingside" }
        if san == "O-O-O" || san == "0-0-0" { return "castles queenside" }
        var text = san
        var suffix = ""
        if text.hasSuffix("#") { suffix = ", checkmate"; text.removeLast() }
        else if text.hasSuffix("+") { suffix = ", check"; text.removeLast() }
        var lead = ""
        if let first = text.first, let kind = pieceKind(forSANLetter: first) {
            lead = kind + " "
            text.removeFirst()
        }
        var promotion = ""
        if let equals = text.firstIndex(of: "=") {
            let letter = text[text.index(after: equals)...].first
            promotion = " promotes to " + (letter.flatMap(pieceKind(forSANLetter:)) ?? "queen")
            text = String(text[text.startIndex..<equals])
        }
        let body = text.replacingOccurrences(of: "x", with: " takes ")
        return (lead + body + promotion).replacingOccurrences(of: "  ", with: " ") + suffix
    }

    private static func pieceKind(forSANLetter letter: Character) -> String? {
        switch letter {
        case "K": "king"
        case "Q": "queen"
        case "R": "rook"
        case "B": "bishop"
        case "N": "knight"
        default: nil
        }
    }
}
