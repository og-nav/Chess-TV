// Small SwiftUI pieces shared by the expanded notification, the Live Activity and the watch.
//
// Three surfaces drawing the same game three times is how two of them end up subtly wrong, so the
// board, the clock and the player row live here once.
import SwiftUI
import ChessCore
import ChessUI

/// A board from a FEN, with the last move highlighted.
///
/// Falls back to an empty board rather than to nothing: a notification that has already promised a
/// picture should not collapse to a grey rectangle because one FEN was malformed.
public struct PositionBoard: View {
    public let fen: String
    public let lastMoveUCI: String?
    public let appearance: BoardAppearance

    public init(fen: String, lastMoveUCI: String?, appearance: BoardAppearance) {
        self.fen = fen
        self.lastMoveUCI = lastMoveUCI
        self.appearance = appearance
    }

    private var position: Position? { try? Position(fen: fen) }

    public var body: some View {
        let position = position
        BoardView(
            position: position,
            lastMove: position.flatMap { board in lastMoveUCI.flatMap { LastMove(uci: $0, position: board) } },
            theme: appearance.theme,
            pieceSet: appearance.pieceSet,
            orientation: appearance.orientation,
            showCoordinates: appearance.showsCoordinates
        )
    }
}

/// A board built out of plain `Rectangle`s and `Image`s, for WidgetKit.
///
/// `ChessUI.BoardView` draws its squares with `Canvas`, which is the right call in an app and a
/// gamble in a widget or a Live Activity: WidgetKit renders its views in a separate process under
/// its own rules, and the list of what it will not draw is not exhaustive anywhere. Sixty-four
/// rectangles and at most thirty-two images are ordinary SwiftUI that no renderer can refuse, and
/// at Smart Stack size the difference is invisible.
///
/// Used by the Live Activity and both widget extensions. Everything that runs in a real app
/// process — the expanded notification, the watch app — uses `PositionBoard` instead.
public struct MiniBoard: View {
    public let fen: String
    public let lastMoveUCI: String?
    public let appearance: BoardAppearance

    public init(fen: String, lastMoveUCI: String?, appearance: BoardAppearance) {
        self.fen = fen
        self.lastMoveUCI = lastMoveUCI
        self.appearance = appearance
    }

    public var body: some View {
        let position = try? Position(fen: fen)
        let lastMove = position.flatMap { board in lastMoveUCI.flatMap { LastMove(uci: $0, position: board) } }
        // Row 0 is the top of the screen: rank 8 with White at the bottom, rank 1 with Black.
        VStack(spacing: 0) {
            ForEach(0..<8, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { column in
                        square(row: row, column: column, position: position, lastMove: lastMove)
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label(position)))
    }

    private func square(row: Int, column: Int, position: Position?, lastMove: LastMove?) -> some View {
        let file = appearance.orientation == .white ? column : 7 - column
        let rank = appearance.orientation == .white ? 7 - row : row
        let square = Square(file: file, rank: rank)
        let highlighted = lastMove?.highlights(square) ?? false
        let color: Color = highlighted
            ? (square.isDark ? appearance.theme.lastMoveDark : appearance.theme.lastMoveLight)
            : (square.isDark ? appearance.theme.dark : appearance.theme.light)
        return Rectangle()
            .fill(color)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let piece = position?.piece(at: square) {
                    PieceAssets.image(set: appearance.pieceSet, piece: piece)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                }
            }
    }

    private func label(_ position: Position?) -> String {
        guard let position else {
            return String(localized: "Chess board", comment: "Accessibility label for a board with no readable position")
        }
        let side = position.sideToMove == .white
            ? String(localized: "White to move", comment: "Accessibility label")
            : String(localized: "Black to move", comment: "Accessibility label")
        return String(
            format: String(localized: "Chess board, %@", comment: "Accessibility label for a board"),
            side
        )
    }
}

/// One clock. Counts down by itself when it is the running one, and is plain text when it is not —
/// which is also what a finished game gets, so a result never shows a clock ticking towards zero.
public struct ClockChip: View {
    public let seconds: Int?
    /// Non-nil only for the side actually on the move in a live game.
    public let deadline: Date?
    public let compact: Bool

    public init(seconds: Int?, deadline: Date?, compact: Bool = false) {
        self.seconds = seconds
        self.deadline = deadline
        self.compact = compact
    }

    public var body: some View {
        // Timer Text accepts all proposed width; ordinary Text does not. Give both the same
        // intrinsic monospaced column, then align the ticking digits inside that column.
        Text("00:00:00")
            .hidden()
            .accessibilityHidden(true)
            .overlay(alignment: .trailing) {
                clockText
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
            }
            .font(compact ? .caption2 : .callout)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder private var clockText: some View {
        if let deadline, deadline > Date() {
            // The system redraws this without the process running.
            Text(timerInterval: Date()...deadline, countsDown: true)
                .foregroundStyle(ChessTVPalette.accent)
        } else if deadline != nil {
            Text("0:00").foregroundStyle(ChessTVPalette.accent)
        } else if let text = ChessFormat.clock(seconds: seconds) {
            Text(text).foregroundStyle(ChessTVPalette.muted)
        } else {
            Text("—").foregroundStyle(ChessTVPalette.muted)
        }
    }

    private var accessibilityLabel: Text {
        let remaining = deadline.map { max(0, Int($0.timeIntervalSinceNow.rounded(.up))) } ?? seconds
        guard let text = ChessFormat.clock(seconds: remaining) else {
            return Text("No clock", comment: "Accessibility label for a game with no clock")
        }
        return Text(text)
    }
}

/// A name, an optional title and a clock, on one line.
public struct PlayerLine: View {
    public let name: String
    public let title: String?
    public let rating: Int?
    public let seconds: Int?
    public let deadline: Date?
    public let isToMove: Bool
    public let compact: Bool

    public init(
        name: String, title: String? = nil, rating: Int? = nil,
        seconds: Int? = nil, deadline: Date? = nil, isToMove: Bool = false, compact: Bool = false
    ) {
        self.name = name
        self.title = title
        self.rating = rating
        self.seconds = seconds
        self.deadline = deadline
        self.isToMove = isToMove
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: 6) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(compact ? .caption2 : .caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(ChessTVPalette.accent)
            }
            Text(name)
                .font(compact ? .caption : .callout)
                .fontWeight(isToMove ? .semibold : .regular)
                .foregroundStyle(ChessTVPalette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            if let rating, !compact {
                Text(verbatim: "\(rating)")
                    .font(.caption)
                    .foregroundStyle(ChessTVPalette.muted)
            }
            Spacer(minLength: 4)
            ClockChip(seconds: seconds, deadline: deadline, compact: compact)
        }
        .accessibilityElement(children: .combine)
    }
}

/// `1–0`, `½–½`, or "Live" while the game runs.
public struct ResultChip: View {
    public let status: String
    public let compact: Bool

    public init(status: String, compact: Bool = false) {
        self.status = status
        self.compact = compact
    }

    public var body: some View {
        let result = ChessFormat.result(status: status)
        Text(result ?? String(localized: "Live", comment: "Chip on a game that is in progress"))
            .font(compact ? .caption2 : .caption)
            .fontWeight(.semibold)
            .monospacedDigit()
            .foregroundStyle(result == nil ? ChessTVPalette.ground : ChessTVPalette.ink)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(result == nil ? ChessTVPalette.accent : ChessTVPalette.line, in: Capsule())
    }
}
