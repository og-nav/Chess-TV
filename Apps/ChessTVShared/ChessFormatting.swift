// Small pure formatters shared by the extensions, the activity views, the widgets and the watch.
import Foundation
import ChessCore
import FollowKit

public enum ChessFormat {

    /// `"1:23:45"` over an hour, `"12:34"` under one, `"0:09"` in the last seconds. Negative
    /// clocks (a flag that fell while the push was in flight) read as zero rather than "-0:01".
    public static func clock(seconds: Int?) -> String? {
        guard let seconds else { return nil }
        let total = max(0, seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// The clock at `asOf`, run forward to now for the side that is actually on move.
    ///
    /// The push says how much time a player had when the server sent it; by the time a person
    /// looks at the notification that is already wrong for one of them. Everything that shows a
    /// running clock goes through here or through `deadline(...)` below.
    public static func remaining(seconds: Int?, asOf: Date, running: Bool, now: Date = Date()) -> Int? {
        guard let seconds else { return nil }
        guard running else { return seconds }
        let elapsed = Int(now.timeIntervalSince(asOf).rounded())
        return max(0, seconds - max(0, elapsed))
    }

    /// When this clock reaches zero, for `Text(timerInterval:)`. Nil when the clock is not running
    /// or there is no clock at all — a frozen clock is drawn as text, never as a timer.
    public static func deadline(seconds: Int?, asOf: Date) -> Date? {
        guard let seconds else { return nil }
        return asOf.addingTimeInterval(TimeInterval(max(0, seconds)))
    }

    /// `45` → `23` (white's 23rd move). Ply 1 is White's first move.
    public static func moveNumber(ply: Int) -> Int {
        max(1, (ply + 1) / 2)
    }

    /// Whose move the given ply was. Ply 1 is White's.
    public static func mover(ply: Int) -> PieceColor {
        ply % 2 == 1 ? .white : .black
    }

    /// Whose clock is running after `push`: read from the FEN, which is right for a game
    /// broadcast from a setup position where ply parity is not. Parity is the fallback for a FEN
    /// too short to say.
    public static func sideToMove(_ push: MovePush) -> PieceColor {
        switch push.sideToMove {
        case "white": .white
        case "black": .black
        default: mover(ply: push.ply + 1)
        }
    }

    /// The move as a person writes it, numbered from the FEN (`MovePush.numberedSAN`), or the
    /// parity-numbered UCI when the server sent no SAN.
    public static func moveLabel(_ push: MovePush) -> String? {
        push.numberedSAN ?? moveLabel(ply: push.ply, san: nil, uci: push.lastMove)
    }

    /// `"23. Nf5"` or `"23... Nf5"`. Falls back to the raw UCI when the server sent no SAN, which
    /// is honest rather than pretty: `"23... e7e5"`.
    public static func moveLabel(ply: Int, san: String?, uci: String?) -> String? {
        let text = san ?? uci.map(coordinateNotation)
        guard let text, !text.isEmpty else { return nil }
        let number = moveNumber(ply: ply)
        return mover(ply: ply) == .white ? "\(number). \(text)" : "\(number)… \(text)"
    }

    /// `"e2e4"` → `"e2–e4"`. Used where there is no SAN to be had — the broadcast round JSON the
    /// watch polls carries only UCI, and inventing SAN from the post-move FEN alone is not possible.
    public static func coordinateNotation(uci: String) -> String {
        guard uci.count >= 4 else { return uci }
        let characters = Array(uci)
        let from = String(characters[0...1])
        let to = String(characters[2...3])
        let promotion = characters.count > 4 ? "=" + String(characters[4]).uppercased() : ""
        return "\(from)–\(to)\(promotion)"
    }

    /// `"1-0"` → `"1–0"`, `"1/2-1/2"` → `"½–½"`. `"*"` and an empty status mean the game is live.
    public static func result(status: String) -> String? {
        switch status {
        case "*", "": return nil
        case "1-0", "1–0": return "1–0"
        case "0-1", "0–1": return "0–1"
        case "1/2-1/2", "½-½", "½–½": return "½–½"
        default: return status
        }
    }

    public static func isFinished(status: String) -> Bool {
        result(status: status) != nil
    }

    /// `"GM Magnus Carlsen"`, or just the name when there is no title.
    public static func titled(_ name: String, title: String?) -> String {
        guard let title, !title.isEmpty else { return name }
        return "\(title) \(name)"
    }

    /// `"in 15 minutes"`, `"in 2 hours"`, `"now"`. Deliberately coarse: a starting-soon alert that
    /// says "in 14 minutes" because of push latency reads as a bug.
    public static func relative(to date: Date, from now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 60 { return String(localized: "now", comment: "A round starting immediately") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

// MARK: - The same question asked of FollowKit's payloads

extension LiveActivityState {
    /// `"23… Nf5"`. Here rather than in FollowKit because the typography is this app's choice, not
    /// the protocol's — the server and the watch would both be entitled to render `ply` differently.
    public var moveLabel: String? {
        ChessFormat.moveLabel(ply: ply, san: san, uci: lastMove)
    }
}

extension MovePush {
    public var moveLabel: String? {
        ChessFormat.moveLabel(ply: ply, san: san, uci: lastMove)
    }
}
