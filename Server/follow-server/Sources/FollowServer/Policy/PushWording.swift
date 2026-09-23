// The words on the lock screen.
//
// The notification service extension rewrites the title and body from the payload once it has
// rendered the board, so what is written here is the fallback: what the user sees when the
// extension did not get to run (low memory, an older build, the watch). It therefore has to be
// complete on its own, and it has to be short.

import Foundation
import FollowKit

public enum PushWording {

    // MARK: Board alerts

    public static func title(for push: MovePush, thinkSeconds: Int?) -> String {
        switch push.pushKind {
        case .gameStart:
            return "\(push.white.name) – \(push.black.name)"
        case .move:
            guard let mover = mover(of: push), let move = push.numberedSAN else {
                return "\(push.white.name) – \(push.black.name)"
            }
            return "\(mover) played \(move)"
        case .longThink:
            let waiting = sideToMoveName(of: push) ?? push.white.name
            return "\(waiting) has been thinking for \(minutes(thinkSeconds ?? 0))"
        case .gameEnd:
            return "Game over: \(result(push.status))"
        case .gameResult:
            return "\(push.white.name) \(result(push.status)) \(push.black.name)"
        case .evalSwing:
            let mover = mover(of: push) ?? push.white.name
            let move = push.numberedSAN.map { ": \($0)" } ?? ""
            switch push.swing?.kind {
            case "throwsWin": return "\(mover) lets the win slip\(move)"
            case "allowsMate": return "\(mover) walks into mate\(move)"
            case "missesMate": return "\(mover) misses a forced mate\(move)"
            default: return "Blunder by \(mover)\(move)"
            }
        case nil:
            return "\(push.white.name) – \(push.black.name)"
        }
    }

    public static func body(for push: MovePush) -> String {
        var parts: [String] = []
        if !push.tourName.isEmpty { parts.append(push.tourName) }
        if !push.roundName.isEmpty { parts.append(push.roundName) }
        switch push.pushKind {
        case .gameEnd, .gameResult:
            parts.insert("\(push.white.name) – \(push.black.name)", at: 0)
        case .evalSwing:
            // The evaluation is the news; the clocks can wait for the app.
            if let swing = push.swing { parts.insert("Stockfish \(swing.before) → \(swing.after)", at: 0) }
            parts.insert("\(push.white.name) – \(push.black.name)", at: 0)
        default:
            if let clocks = clocks(of: push) { parts.append(clocks) }
        }
        return parts.joined(separator: " · ")
    }

    /// Higher for the things a person would be annoyed to miss. iOS sorts a stack of our
    /// notifications by this.
    public static func relevance(for kind: MovePushKind) -> Double {
        switch kind {
        case .gameEnd, .gameResult: 1.0
        case .evalSwing: 0.8
        case .gameStart: 0.6
        case .longThink: 0.5
        case .move: 0.4
        }
    }

    // MARK: Event alerts

    public static func title(for push: TournamentPush) -> String {
        let round = push.roundName ?? "The next round"
        switch push.pushKind {
        case .startingSoon:
            guard let startsAt = push.startsAt else { return "\(round) starts soon" }
            let minutes = max(1, Int(startsAt.timeIntervalSince(push.sentAt) / 60 + 0.5))
            return "\(round) starts in \(self.minutes(minutes * 60))"
        case .roundLive:
            return "\(round) is live"
        case .roundFinished:
            return "\(round) finished"
        case .tournamentFinished, nil:
            return "\(push.tourName) has finished"
        }
    }

    public static func body(for push: TournamentPush) -> String {
        switch push.pushKind {
        case .startingSoon:
            return push.tourName
        case .roundLive:
            guard let boards = push.boardCount else { return push.tourName }
            return "\(boards) \(boards == 1 ? "board" : "boards") · \(push.tourName)"
        case .roundFinished:
            let results = push.results ?? []
            return results.isEmpty ? push.tourName : results.joined(separator: " · ")
        case .tournamentFinished, nil:
            let leaders = push.leaders ?? []
            return leaders.isEmpty ? "Every round is done." : leaders.joined(separator: " · ")
        }
    }

    public static func relevance(for kind: TournamentPushKind) -> Double {
        switch kind {
        case .roundLive: 0.9
        case .tournamentFinished: 0.8
        case .startingSoon: 0.7
        case .roundFinished: 0.6
        }
    }

    // MARK: Pieces

    /// `1-0` → `1–0`, `1/2-1/2` → `½–½`. En dashes and a real vulgar fraction, because this is a
    /// chess app and the lock screen has room for exactly one line.
    public static func result(_ status: String) -> String {
        switch status {
        case "1-0": "1–0"
        case "0-1": "0–1"
        case "1/2-1/2", "½-½": "½–½"
        default: status
        }
    }

    /// `"12 minutes"`, `"1 hour 5 minutes"`.
    public static func minutes(_ seconds: Int) -> String {
        let total = max(1, seconds / 60)
        guard total >= 60 else { return "\(total) \(total == 1 ? "minute" : "minutes")" }
        let hours = total / 60
        let rest = total % 60
        let hoursText = "\(hours) \(hours == 1 ? "hour" : "hours")"
        guard rest > 0 else { return hoursText }
        return "\(hoursText) \(rest) \(rest == 1 ? "minute" : "minutes")"
    }

    /// `"1:04:12 – 58:31"`, white first.
    public static func clocks(of push: MovePush) -> String? {
        guard let white = push.whiteClock, let black = push.blackClock else { return nil }
        return "\(clock(white)) – \(clock(black))"
    }

    public static func clock(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let rest = seconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, rest) }
        return String(format: "%d:%02d", minutes, rest)
    }

    /// `"Carlsen 1–0 Nepomniachtchi"`, for the round summary's `results`.
    public static func resultLine(white: String, black: String, status: String) -> String {
        "\(white) \(result(status)) \(black)"
    }

    /// Who played the move that produced this position — the side that is *not* to move.
    ///
    /// From the FEN, not from the ply's parity: a game broadcast from a setup position with Black
    /// to move would otherwise have every move attributed to the wrong player.
    static func mover(of push: MovePush) -> String? {
        guard push.ply > 0 else { return nil }
        switch push.sideToMove {
        case "white": return push.black.name
        case "black": return push.white.name
        default: return push.ply % 2 == 1 ? push.white.name : push.black.name
        }
    }

    /// Who is to move, which for a long think is the person doing the thinking.
    static func sideToMoveName(of push: MovePush) -> String? {
        switch push.sideToMove {
        case "white": push.white.name
        case "black": push.black.name
        default: nil
        }
    }
}
