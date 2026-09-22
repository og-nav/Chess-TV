import Foundation

/// Stable identifiers shared by saved preferences and the bundled sound filenames.
public enum SoundSet: String, CaseIterable, Sendable, Codable {
    case recordedWood = "wood"
    case mutedWood = "muted"
    case softFelt = "felt"
    case lichessPiano = "piano"
    case lichessNES = "nes"
    case lichessSFX = "sfx"

    public var displayName: String {
        switch self {
        case .recordedWood: "Recorded Wood"
        case .mutedWood: "Muted Wood"
        case .softFelt: "Soft Felt"
        case .lichessPiano: "Lichess Piano"
        case .lichessNES: "Lichess NES"
        case .lichessSFX: "Lichess SFX"
        }
    }

    public func resourceName(for outcome: MoveOutcome) -> String {
        let event: String
        switch outcome {
        case .move: event = "move"
        case .capture: event = "capture"
        case .check: event = "check"
        }
        return "sound-\(rawValue)-\(event)"
    }
}
