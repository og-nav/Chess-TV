// The words for every alert switch, the order they are listed in, and which of them a given
// follow is allowed to offer.
//
// Pure, so ChessTVMobileTests can check the rules without a view.
import Foundation
import FollowKit
import LichessKit

enum AlertCatalogue {

    /// The order the switch list shows for a player or game follow.
    static let gameAlerts: [GameAlert] = [.start, .move, .longThink, .end]
    /// The order the switch list shows for a tournament follow.
    static let tournamentAlerts: [TourAlert] = [
        .startingSoon, .roundLive, .gameResults, .roundSummary, .finished, .topBoardMoves,
    ]

    static func title(for alert: GameAlert) -> String {
        switch alert {
        case .start: "Game starts"
        case .move: "Every move"
        case .longThink: "Long think"
        case .end: "Game ends"
        }
    }

    static func detail(for alert: GameAlert) -> String {
        switch alert {
        case .start: "When the board goes live."
        case .move: "A push for each move played. Use the interval below to thin it out."
        case .longThink: "When a player has been on the same move for longer than the threshold."
        case .end: "The result, with the final position."
        }
    }

    static func title(for alert: TourAlert) -> String {
        switch alert {
        case .startingSoon: "Round starting soon"
        case .roundLive: "Round goes live"
        case .gameResults: "Results"
        case .roundSummary: "Round summary"
        case .finished: "Event finishes"
        case .topBoardMoves: "Moves on the top boards"
        }
    }

    static func detail(for alert: TourAlert) -> String {
        switch alert {
        case .startingSoon: "A heads-up before the round is scheduled to start."
        case .roundLive: "One push when the round is actually being played, not when it was planned."
        case .gameResults: "As the top boards finish, and any board with a player you follow."
        case .roundSummary: "One push when the whole round is over, with the top results."
        case .finished: "When the last round of the event has finished."
        case .topBoardMoves: "A push per move on the top boards. Off by default; this is the noisy one."
        }
    }

    /// `minMinutesBetweenMoveAlerts` only means anything while a move switch is on.
    static func movePacingApplies(to alerts: FollowAlerts, kind: FollowKind) -> Bool {
        alerts.sendsMoveAlerts(for: kind)
    }

    /// `longThinkMinutes` only means anything while the long-think switch is on.
    static func longThinkApplies(to alerts: FollowAlerts) -> Bool { alerts.game.contains(.longThink) }

    /// The choices the move-interval picker offers, in minutes. Zero is "every move".
    static let moveIntervalChoices = [0, 1, 2, 5, 10, 15, 30]
    /// The choices the long-think picker offers, in minutes.
    static let longThinkChoices = [5, 10, 15, 20, 30, 45]
    /// The choices the starting-soon picker offers, in minutes.
    static let startingSoonChoices = [5, 10, 15, 30, 60]
    /// Top boards a tournament follow watches for results and moves. The plan caps this at 5.
    static let topBoardsRange = 1...5

    static func moveIntervalText(_ minutes: Int) -> String {
        minutes == 0 ? "Every move" : "At most every \(minutes) min"
    }

    static func longThinkText(_ minutes: Int) -> String { "\(minutes) min" }

    static func startingSoonText(_ minutes: Int) -> String {
        minutes >= 60 ? "1 hour before" : "\(minutes) min before"
    }

    static func topBoardsText(_ boards: Int) -> String {
        boards == 1 ? "Top board" : "Top \(boards) boards"
    }
}

// MARK: - What can be followed

/// Whether the thing on screen can be followed at all, and why not when it cannot.
enum Followability: Equatable, Sendable {
    case followable(FollowTarget)
    case unsupported(reason: String)

    var target: FollowTarget? {
        if case .followable(let target) = self { return target }
        return nil
    }

    var reason: String? {
        if case .unsupported(let reason) = self { return reason }
        return nil
    }
}

enum FollowCapability {

    /// Only broadcast boards are followable.
    ///
    /// A Lichess TV channel does not name a lasting game — the channel promotes a new one every
    /// few minutes — and an arena's featured board changes just as fast, so there is nothing
    /// stable for the server to watch and nothing sensible to alert on. The plan puts
    /// arena and TV-channel follows in the backlog, with start and end only, for the same reason.
    static func followability(of source: GameSource) -> Followability {
        switch source {
        case .broadcastBoard(let roundId, let gameId):
            .followable(.game(roundId: roundId, gameId: gameId))
        case .tvChannel:
            .unsupported(reason: "Lichess TV plays a different game every few minutes, so there is no one board to follow.")
        case .arena:
            .unsupported(reason: "An arena moves to a new featured board constantly. Follow a broadcast board instead.")
        }
    }

    /// A player is followable whenever the board told us their FIDE id; that id is what survives
    /// from one round, and one event, to the next.
    static func followability(ofPlayerWithFideID fideId: Int?) -> Followability {
        guard let fideId, fideId > 0 else {
            return .unsupported(reason: "This player has no FIDE id in the broadcast, so there is nothing to follow them by.")
        }
        return .followable(.player(fideId: fideId))
    }

    /// The switches a follow of this target may show. Board-shaped follows offer the four game
    /// alerts; a tournament offers the six event ones. Nothing else is offered, so a UI that
    /// iterates this can never present a switch the server would ignore.
    static func availableGameAlerts(for target: FollowTarget) -> [GameAlert] {
        target.followKind.isBoardShaped ? AlertCatalogue.gameAlerts : []
    }

    static func availableTournamentAlerts(for target: FollowTarget) -> [TourAlert] {
        target.followKind.isBoardShaped ? [] : AlertCatalogue.tournamentAlerts
    }
}
