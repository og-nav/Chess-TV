// ChessUI — frozen contracts (see TV_BUILD_PLAN.md).
//
// The public signatures below and in BoardView.swift, EvalBarView.swift and EvalMapping.swift are
// exactly as the orchestrator froze them; only the bodies are filled in. Piece image loading lives
// in PieceAssets.swift, the artwork in Resources/Pieces.xcassets (see LICENSES.md).
import SwiftUI
import ChessCore

public struct BoardTheme: Sendable, Equatable {
    public let name: String
    public let light: Color
    public let dark: Color
    public let lastMoveLight: Color
    public let lastMoveDark: Color
    public init(name: String, light: Color, dark: Color, lastMoveLight: Color, lastMoveDark: Color) {
        self.name = name; self.light = light; self.dark = dark; self.lastMoveLight = lastMoveLight; self.lastMoveDark = lastMoveDark
    }
    public static let sage  = BoardTheme(name: "Sage",  light: Color(hex: 0xDED7C5), dark: Color(hex: 0x78816B), lastMoveLight: Color(hex: 0xD6D68E), lastMoveDark: Color(hex: 0x8D9860))
    public static let brown = BoardTheme(name: "Brown", light: Color(hex: 0xF0D9B5), dark: Color(hex: 0xB58863), lastMoveLight: Color(hex: 0xCDD26B), lastMoveDark: Color(hex: 0xAAA23A))
    public static let green = BoardTheme(name: "Green", light: Color(hex: 0xEEEED1), dark: Color(hex: 0x759655), lastMoveLight: Color(hex: 0xCCDE7B), lastMoveDark: Color(hex: 0x85AA32))
    public static let slate = BoardTheme(name: "Slate", light: Color(hex: 0xDCE2E2), dark: Color(hex: 0x788D99), lastMoveLight: Color(hex: 0xC1D785), lastMoveDark: Color(hex: 0x86A55A))
    public static let all: [BoardTheme] = [.sage, .brown, .green, .slate]
}

public enum PieceSet: String, CaseIterable, Sendable {
    case cburnett, merida, chessnut
    public var displayName: String {
        switch self { case .cburnett: "Classic"; case .merida: "Merida"; case .chessnut: "Chessnut" }
    }
}

extension Color {
    public init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
