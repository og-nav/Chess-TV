// Toasts for the other boards of a broadcast round: a result landing, or both clocks dropping
// under five minutes. The detector is pure so the tests can drive it with hand-made boards.
import Foundation
import LichessKit

/// One line for the header: "Board 3 · GM Carlsen beat GM Nakamura".
public struct TournamentAlert: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case result
        case timeScramble
        /// Several results arrived in one poll; the rest are folded into one line.
        case more
    }

    public let id: UUID
    public let kind: Kind
    /// "Board 3", or "Results" for a folded line.
    public let headline: String
    public let detail: String

    public init(kind: Kind, headline: String, detail: String) {
        self.id = UUID()
        self.kind = kind
        self.headline = headline
        self.detail = detail
    }

    /// The two parts on one line, for accessibility and logs.
    public var text: String { "\(headline) \u{00B7} \(detail)" }
}

/// Diffs one poll of a round against the previous one. The first poll only takes a baseline:
/// whatever has already happened when you sit down is not news.
public struct RoundAlertDetector {

    /// Both clocks at or under this is a time scramble.
    public static let scrambleThresholdMs = 5 * 60 * 1000
    /// More alerts than this in one poll are folded into one "N more" line.
    public static let maxPerPoll = 3

    private var lastStatus: [String: String] = [:]
    private var scrambled: Set<String> = []
    private var primed = false

    public init() {}

    /// The alerts this poll produced, watched board excluded: its result and its clocks are
    /// already on the screen.
    public mutating func alerts(for boards: [BroadcastBoard], watching gameId: String?) -> [TournamentAlert] {
        var found: [TournamentAlert] = []
        for (index, board) in boards.enumerated() {
            let number = index + 1
            let previous = lastStatus[board.gameId]
            lastStatus[board.gameId] = board.status
            let inScramble = board.isOngoing && Self.isScramble(board)
            guard primed, board.gameId != gameId else {
                if inScramble { scrambled.insert(board.gameId) }
                continue
            }
            if let previous, Self.isOngoing(previous), !board.isOngoing {
                found.append(TournamentAlert(kind: .result, headline: "Board \(number)", detail: Self.resultText(board)))
            }
            if inScramble, !scrambled.contains(board.gameId) {
                scrambled.insert(board.gameId)
                found.append(TournamentAlert(
                    kind: .timeScramble,
                    headline: "Board \(number)",
                    detail: "Time scramble: \(Self.shortName(board.white)) \u{2013} \(Self.shortName(board.black)), both under 5:00"
                ))
            }
        }
        primed = true
        return Self.condensed(found)
    }

    /// Forgets everything, so the next poll takes a fresh baseline.
    public mutating func reset() {
        lastStatus = [:]
        scrambled = []
        primed = false
    }

    // MARK: - Text

    public static func isOngoing(_ status: String) -> Bool { status == "*" || status.isEmpty }

    public static func isScramble(_ board: BroadcastBoard) -> Bool {
        guard let white = board.white?.clockMs, let black = board.black?.clockMs else { return false }
        return white <= scrambleThresholdMs && black <= scrambleThresholdMs
    }

    public static func resultText(_ board: BroadcastBoard) -> String {
        let white = shortName(board.white)
        let black = shortName(board.black)
        switch board.status {
        case "1-0": return "\(white) beat \(black)"
        case "0-1": return "\(black) beat \(white)"
        case "\u{00BD}-\u{00BD}", "1/2-1/2": return "\(white) and \(black) drew"
        default: return "\(white) \u{2013} \(black) \u{00B7} \(board.status)"
        }
    }

    /// "GM Carlsen": the title and the surname, which Lichess puts before the comma.
    public static func shortName(_ player: BroadcastPlayer?) -> String {
        guard let player else { return "?" }
        let name = player.name.split(separator: ",", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? player.name
        guard let title = player.title, !title.isEmpty else { return name }
        return "\(title) \(name)"
    }

    /// Keeps the first few alerts and folds the rest into one line, so a round ending all at
    /// once does not queue twenty toasts.
    public static func condensed(_ alerts: [TournamentAlert]) -> [TournamentAlert] {
        guard alerts.count > maxPerPoll else { return alerts }
        let kept = Array(alerts.prefix(maxPerPoll - 1))
        let rest = alerts.count - kept.count
        return kept + [TournamentAlert(kind: .more, headline: "Results", detail: "\(rest) more boards finished")]
    }
}
