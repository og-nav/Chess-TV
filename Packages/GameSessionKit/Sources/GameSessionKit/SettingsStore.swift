import Foundation
import ChessUI

/// Preferences are UI state and therefore MainActor-isolated, not freely mutable Sendable state.
@MainActor public protocol SettingsStore: AnyObject {
    var boardThemeName: String { get set }
    var pieceSet: PieceSet { get set }
    var coordinates: Bool { get set }
    var sounds: Bool { get set }
    var engineEnabled: Bool { get set }
    var engineDepth: EngineDepth { get set }
    var flipBoard: Bool { get set }
    var followFeaturedPlayer: Bool { get set }
}

extension AppSettings: SettingsStore {}
