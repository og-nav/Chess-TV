// Turning a push's `userInfo` into something typed, and the categories that give the expanded
// notification its buttons.
//
// FollowKit owns the wire format (`PushEnvelope`, `PushCategory`, `MovePush`, `TournamentPush`).
// This file owns the bit that is the *app's* choice rather than the protocol's: which of the two
// shapes we are looking at, and what the user can tap.
import Foundation
import UserNotifications
import FollowKit

/// The actions under our two categories.
///
/// Registered by the **app**, not by an extension: a content extension declares in its Info.plist
/// which categories it draws, but the buttons come from the app's `UNUserNotificationCenter`. If
/// the app never registers them the expanded view still appears, with no buttons under it.
public enum PushAction {
    /// Handled inside the content extension, which redraws and returns `.doNotDismiss`. It never
    /// reaches the app.
    public static let flipBoard = "FLIP_BOARD"
    /// Opens the app on the game.
    public static let openGame = "OPEN_GAME"
    /// Opens the app on the tournament.
    public static let openTournament = "OPEN_TOURNAMENT"

    // There is deliberately **no** "Mute this follow" action.
    //
    // An alert names a game and a round; it does not name a follow. `MovePush` and
    // `TournamentPush` carry no follow id, and the server coalesces — the same game reaches you
    // because you follow the player, or the event, or that game, or any two of the three. A button
    // that picked one of them and silenced it would silence something the user did not choose, and
    // the one thing a destructive action must never be is a guess.
    //
    // Muting stays where the choice can be made explicitly: Following → a follow → its switches,
    // on the phone or on the watch. If the server ever adds a follow id to the payload this
    // becomes a real action, and `PushCategories.all()` is the only place that has to change.
}

/// The decoded `d` key, told apart by `aps.category`.
///
/// The category is the only discriminator, because both shapes arrive under the same key and a
/// `TournamentPush` with every optional absent would happily decode as very little else.
public enum ChessPush: Sendable, Hashable {
    case game(MovePush)
    case tournament(TournamentPush)

    public var category: String {
        switch self {
        case .game: PushCategory.gameMove
        case .tournament: PushCategory.tournamentEvent
        }
    }

    /// The round this alert belongs to; the server mirrors it into `aps.thread-id` so iOS groups
    /// a round's alerts together.
    public var threadId: String {
        switch self {
        case .game(let push): push.roundId
        case .tournament(let push): push.roundId ?? push.tourId
        }
    }

    public var movePush: MovePush? {
        if case .game(let push) = self { return push }
        return nil
    }

    public var tournamentPush: TournamentPush? {
        if case .tournament(let push) = self { return push }
        return nil
    }

    /// Decodes the payload of a delivered notification.
    ///
    /// Returns nil for anything that is not one of our two shapes — a silent push, a test push, a
    /// category a future server invents. Every caller reads nil as "leave the notification exactly
    /// as the server wrote it", which is the safe outcome: the server always sends a usable
    /// `aps.alert`, and everything here only improves on it.
    public static func decode(userInfo: [AnyHashable: Any]) -> ChessPush? {
        guard let aps = userInfo["aps"] as? [AnyHashable: Any],
              let category = aps["category"] as? String
        else { return nil }

        switch category {
        case PushCategory.gameMove:
            guard let envelope = PushEnvelope<MovePush>.decode(userInfo) else {
                pushLog.error("A GAME_MOVE push did not decode")
                return nil
            }
            return .game(envelope.payload)
        case PushCategory.tournamentEvent:
            guard let envelope = PushEnvelope<TournamentPush>.decode(userInfo) else {
                pushLog.error("A TOURNAMENT_EVENT push did not decode")
                return nil
            }
            return .tournament(envelope.payload)
        default:
            return nil
        }
    }
}

public enum PushCategories {

    public static func all() -> Set<UNNotificationCategory> {
        let flip = UNNotificationAction(
            identifier: PushAction.flipBoard,
            title: String(localized: "Flip board", comment: "Notification action: turn the board around"),
            options: []                                    // no .foreground: the content extension redraws in place
        )
        let openGame = UNNotificationAction(
            identifier: PushAction.openGame,
            title: String(localized: "Open game", comment: "Notification action"),
            options: [.foreground]
        )
        let openTournament = UNNotificationAction(
            identifier: PushAction.openTournament,
            title: String(localized: "Open tournament", comment: "Notification action"),
            options: [.foreground]
        )
        // The hidden-previews placeholder is what iOS shows on a locked screen when the user has
        // previews off. watchOS has no such setting and no such initialiser, so the wrist gets the
        // plain form of the same two categories — the buttons, which is the part that matters
        // there, are identical.
        #if os(watchOS)
        // No "Flip board" here: the watch app has no notification delegate to receive the
        // background action, so the button would do nothing.
        let game = UNNotificationCategory(
            identifier: PushCategory.gameMove,
            actions: [openGame],
            intentIdentifiers: [],
            options: []
        )
        let tournament = UNNotificationCategory(
            identifier: PushCategory.tournamentEvent,
            actions: [openTournament],
            intentIdentifiers: [],
            options: []
        )
        #else
        let game = UNNotificationCategory(
            identifier: PushCategory.gameMove,
            actions: [flip, openGame],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: String(localized: "A move in a game you follow", comment: "Hidden notification preview"),
            options: []
        )
        let tournament = UNNotificationCategory(
            identifier: PushCategory.tournamentEvent,
            actions: [openTournament],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: String(localized: "News from an event you follow", comment: "Hidden notification preview"),
            options: []
        )
        #endif
        return [game, tournament]
    }

    /// Called once from the app's launch path, and from the watch app so a mirrored notification
    /// shows the same buttons on the wrist.
    public static func register(with center: UNUserNotificationCenter = .current()) {
        center.setNotificationCategories(all())
    }
}
