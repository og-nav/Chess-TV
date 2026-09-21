// What the notification says.
//
// The server always sends a usable `aps.alert`; this rewrites it into something that reads like a
// chess app rather than a webhook. Pure functions with no I/O, so the same wording is used by the
// service extension, the content extension's header, and the tests.
import Foundation
import ChessCore

import FollowKit

public struct PushWording: Sendable, Hashable {
    public var title: String
    public var subtitle: String?
    public var body: String

    public init(title: String, subtitle: String?, body: String) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }
}

public enum PushWordingBuilder {

    public static func wording(for push: ChessPush, now: Date = Date()) -> PushWording {
        switch push {
        case .game(let move): game(move, now: now)
        case .tournament(let event): tournament(event, now: now)
        }
    }

    // MARK: - Board-shaped alerts

    static func game(_ push: MovePush, now: Date = Date()) -> PushWording {
        let event = "\(push.tourName) · \(push.roundName)"
        let pairing = "\(ChessFormat.titled(push.white.name, title: push.white.title)) – \(ChessFormat.titled(push.black.name, title: push.black.title))"

        switch push.kind {
        case "gameStart":
            return PushWording(title: pairing, subtitle: event, body: startBody(push))

        case "longThink":
            // The player on the clock is the one who has *not* moved: one ply past the last one.
            let thinking = ChessFormat.sideToMove(push) == .white ? push.white : push.black
            let title = String(
                format: String(localized: "%@ is thinking", comment: "Notification title for a long think"),
                thinking.name
            )
            var parts: [String] = []
            if let move = ChessFormat.moveLabel(push) {
                parts.append(String(
                    format: String(localized: "After %@", comment: "Notification body: the move preceding a long think"),
                    move
                ))
            }
            if let clocks = clockLine(push) { parts.append(clocks) }
            return PushWording(title: title, subtitle: event, body: parts.joined(separator: " · "))

        case "gameEnd", "gameResult":
            let result = ChessFormat.result(status: push.status) ?? String(localized: "finished", comment: "A game with no scoreline")
            let title = String(
                format: String(localized: "Game over: %@", comment: "Notification title at the end of a game"),
                result
            )
            var parts = [pairing]
            if let move = ChessFormat.moveLabel(push) { parts.append(move) }
            return PushWording(title: title, subtitle: event, body: parts.joined(separator: " · "))

        default:
            // "move", and anything a newer server invents: a move is the safe reading, because the
            // payload always carries one and the board is drawn either way.
            let mover = ChessFormat.sideToMove(push) == .white ? push.black : push.white
            guard let move = ChessFormat.moveLabel(push) else {
                return PushWording(title: pairing, subtitle: event, body: clockLine(push) ?? event)
            }
            let title = String(
                format: String(localized: "%1$@ played %2$@", comment: "Notification title: a player and their move"),
                mover.name, move
            )
            return PushWording(title: title, subtitle: event, body: clockLine(push) ?? pairing)
        }
    }

    private static func startBody(_ push: MovePush) -> String {
        var parts = [String(localized: "The game has started", comment: "Notification body when a followed game begins")]
        if let ratings = ratingLine(push) { parts.append(ratings) }
        return parts.joined(separator: " · ")
    }

    private static func ratingLine(_ push: MovePush) -> String? {
        guard let white = push.white.rating, let black = push.black.rating else { return nil }
        return "\(white) – \(black)"
    }

    /// `"White 1:23:45 · Black 0:58:12"`, wound forward from `sentAt` for the side on move so the
    /// body is not already stale on the Lock Screen.
    static func clockLine(_ push: MovePush, now: Date = Date()) -> String? {
        let toMove = ChessFormat.sideToMove(push)
        let finished = ChessFormat.isFinished(status: push.status)
        let white = ChessFormat.clock(seconds: ChessFormat.remaining(
            seconds: push.whiteClock, asOf: push.sentAt, running: !finished && toMove == .white, now: now
        ))
        let black = ChessFormat.clock(seconds: ChessFormat.remaining(
            seconds: push.blackClock, asOf: push.sentAt, running: !finished && toMove == .black, now: now
        ))
        switch (white, black) {
        case let (white?, black?):
            return String(
                format: String(localized: "White %1$@ · Black %2$@", comment: "Both clocks in a notification body"),
                white, black
            )
        default:
            return nil
        }
    }

    // MARK: - Event-shaped alerts

    static func tournament(_ push: TournamentPush, now: Date = Date()) -> PushWording {
        let round = push.roundName ?? String(localized: "The next round", comment: "Fallback round name")

        switch push.kind {
        case "startingSoon":
            let when = push.startsAt.map { ChessFormat.relative(to: $0, from: now) }
                ?? String(localized: "soon", comment: "A round starting at an unknown time")
            let title = String(
                format: String(localized: "%1$@ %2$@ starts %3$@", comment: "Notification title: event, round, when"),
                push.tourName, round, when
            )
            let body = push.startsAt.map {
                "\(push.tourName) · \($0.formatted(date: .omitted, time: .shortened))"
            } ?? push.tourName
            return PushWording(title: title, subtitle: push.tourName, body: body)

        case "roundLive":
            let title = String(
                format: String(localized: "%@ is live", comment: "Notification title when a round starts"),
                round
            )
            let body = push.boardCount.map { "\(push.tourName) · \(boardCount($0))" } ?? push.tourName
            return PushWording(title: title, subtitle: push.tourName, body: body)

        case "roundFinished":
            let title = String(
                format: String(localized: "%@ finished", comment: "Notification title when a round ends"),
                round
            )
            return PushWording(title: title, subtitle: push.tourName, body: listBody(push) ?? push.tourName)

        case "tournamentFinished":
            let title = String(
                format: String(localized: "%@ has finished", comment: "Notification title when an event ends"),
                push.tourName
            )
            return PushWording(title: title, subtitle: nil, body: listBody(push) ?? round)

        default:
            return PushWording(title: push.tourName, subtitle: round, body: listBody(push) ?? round)
        }
    }

    /// `"14 boards"`, and `"1 board"` — a round with one board is exactly what a World
    /// Championship round is, so the singular is not a hypothetical.
    private static func boardCount(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 board", comment: "Board count in a notification body, singular")
            : String(
                format: String(localized: "%lld boards", comment: "Board count in a notification body, plural"),
                count
            )
    }

    /// Results first, leaders if there are no results. At most five lines either way — the server
    /// already caps them, and this is the second line of defence against a hundred-board open.
    private static func listBody(_ push: TournamentPush) -> String? {
        if let results = push.results, !results.isEmpty {
            return results.prefix(5).joined(separator: "\n")
        }
        if let leaders = push.leaders, !leaders.isEmpty {
            return String(
                format: String(localized: "Leading: %@", comment: "Notification body listing the leaders"),
                leaders.prefix(5).joined(separator: ", ")
            )
        }
        return nil
    }
}
