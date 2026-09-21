import Foundation
import LichessKit
import GameSessionKit

/// One screen pushed on top of the home screen.
enum Route: Hashable, Sendable {
    /// The board list of one broadcast round. The name is what the shelf card showed, if known.
    case boards(roundId: String, tournamentName: String?)
    case game(GameDestination)
}

// MARK: - Launch arguments

/// `-open tv:blitz`, `-open arena:<id>`, `-open board:<roundId>:<gameId>`, `-open boards:<roundId>`.
/// Anything else is ignored, so a bad argument only means "start at home".
enum LaunchArguments {

    static func routes(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> [Route] {
        guard let index = arguments.firstIndex(of: "-open"), index + 1 < arguments.count else { return [] }
        let value = arguments[index + 1]
        if value.hasPrefix("boards:") {
            let roundId = String(value.dropFirst("boards:".count))
            guard !roundId.isEmpty else { return [] }
            appLog.notice("Launch argument -open boards:\(roundId, privacy: .public)")
            return [.boards(roundId: roundId, tournamentName: nil)]
        }
        guard let source = GameSource(storageKey: value) else {
            appLog.error("Ignoring unparseable -open \(value, privacy: .public)")
            return []
        }
        appLog.notice("Launch argument -open \(value, privacy: .public)")
        switch source {
        case .broadcastBoard(let roundId, _):
            // Keep the natural stack, so Back from the game lands on the board list.
            return [.boards(roundId: roundId, tournamentName: nil), .game(GameDestination(source: source))]
        default:
            return [.game(GameDestination(source: source))]
        }
    }
}
