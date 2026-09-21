// The board's look, resolved from the App Group's strings into ChessUI's types.
import Foundation
import ChessCore
import ChessUI

/// Theme, piece set, coordinates and orientation: everything `BoardImageRenderer` and the widget
/// board need in order to look like the app the notification came from.
public struct BoardAppearance: Sendable, Equatable {
    public var theme: BoardTheme
    public var pieceSet: PieceSet
    public var showsCoordinates: Bool
    /// The colour at the bottom of the board.
    public var orientation: PieceColor

    public init(theme: BoardTheme, pieceSet: PieceSet, showsCoordinates: Bool, orientation: PieceColor) {
        self.theme = theme
        self.pieceSet = pieceSet
        self.showsCoordinates = showsCoordinates
        self.orientation = orientation
    }

    public static let fallback = BoardAppearance(
        theme: .sage, pieceSet: .cburnett, showsCoordinates: false, orientation: .white
    )

    /// Reads the App Group. An unknown theme name or piece set falls back rather than failing:
    /// a notification with the wrong shade of green still tells the user about the move.
    public static func fromAppGroup(defaults: UserDefaults = ChessTVAppGroup.defaults) -> BoardAppearance {
        BoardAppearance(
            theme: theme(named: SharedStore.boardThemeName(defaults: defaults)),
            pieceSet: PieceSet(rawValue: SharedStore.pieceSetName(defaults: defaults)) ?? .cburnett,
            showsCoordinates: SharedStore.showsCoordinates(defaults: defaults),
            orientation: SharedStore.flipBoard(defaults: defaults) ? .black : .white
        )
    }

    public static func theme(named name: String) -> BoardTheme {
        BoardTheme.all.first { $0.name == name } ?? .sage
    }

    public func flipped() -> BoardAppearance {
        var copy = self
        copy.orientation = orientation == .white ? .black : .white
        return copy
    }
}
