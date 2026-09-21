// The app's view of FollowKit's types.
//
// Two jobs. First, a name: `FollowTarget.kind` is already taken by FollowKit, where it is the
// wire string ("player", "game", "tournament"), so the app's own three-way distinction is
// `followKind` and never shadows it. Second, a single place where follows are made, so the shape
// of `Follow`'s initialiser is written once.
//
// It also resolves a collision: GameSessionKit's `TournamentAlert` is the TV toast shown in the
// game header, while FollowKit's is a push switch. Both are spelled out in full below and the
// rest of the app uses the alias.
import Foundation
import FollowKit
import LichessKit

/// FollowKit's push switch for an event-shaped alert.
typealias TourAlert = FollowKit.TournamentAlert

/// What kind of thing a follow points at. `FollowTarget` carries the ids; this carries the
/// distinction the UI groups and defaults by.
enum FollowKind: String, CaseIterable, Sendable, Hashable {
    case player, game, tournament

    var title: String {
        switch self {
        case .player: "Players"
        case .game: "Games"
        case .tournament: "Tournaments"
        }
    }

    /// The singular, for a sentence about one follow.
    var singular: String {
        switch self {
        case .player: "player"
        case .game: "game"
        case .tournament: "tournament"
        }
    }

    /// Player and game follows share one switch list; tournaments have their own.
    var isBoardShaped: Bool { self != .tournament }
}

extension FollowTarget {
    /// The app's three-way kind. Named to stay clear of FollowKit's own `kind`, which is the
    /// string that goes over the wire.
    var followKind: FollowKind {
        switch self {
        case .player: .player
        case .game: .game
        case .tournament: .tournament
        }
    }

    /// The round a board follow belongs to, for opening it from the Following list.
    var roundId: String? {
        if case .game(let roundId, _) = self { return roundId }
        return nil
    }

    var gameId: String? {
        if case .game(_, let gameId) = self { return gameId }
        return nil
    }

    var tourId: String? {
        if case .tournament(let tourId) = self { return tourId }
        return nil
    }

    var fideId: Int? {
        if case .player(let fideId) = self { return fideId }
        return nil
    }

    /// The `GameSource` this follow opens, when it names one board.
    var gameSource: GameSource? {
        guard case .game(let roundId, let gameId) = self else { return nil }
        return .broadcastBoard(roundId: roundId, gameId: gameId)
    }
}

extension Follow {
    var followKind: FollowKind { target.followKind }
}

// MARK: - Defaults

extension FollowAlerts {
    /// The switches a brand new follow of this kind starts with, before the device's own
    /// Settings defaults are applied.
    static func fallbackDefaults(for kind: FollowKind) -> FollowAlerts {
        switch kind {
        case .player: .playerDefaults
        case .game: .gameDefaults
        case .tournament: .tournamentDefaults
        }
    }

    /// True when this follow will produce a push per move — the thing worth warning about.
    func sendsMoveAlerts(for kind: FollowKind) -> Bool {
        kind.isBoardShaped ? game.contains(.move) : tournament.contains(.topBoardMoves)
    }

    /// The switches that are on, in the order the UI lists them, for a one-line summary.
    func summary(for kind: FollowKind) -> String {
        let names: [String] = kind.isBoardShaped
            ? AlertCatalogue.gameAlerts.filter { game.contains($0) }.map(AlertCatalogue.title(for:))
            : AlertCatalogue.tournamentAlerts.filter { tournament.contains($0) }.map(AlertCatalogue.title(for:))
        guard !names.isEmpty else { return "No alerts" }
        return names.joined(separator: " \u{00B7} ")
    }
}

extension NotificationPreferences {

    /// What a fresh install sends, in this device's time zone. FollowKit's memberwise defaults
    /// are already this; naming it here keeps the app from repeating an empty initialiser.
    static func mobileDefault(timeZone: TimeZone = .current) -> NotificationPreferences {
        NotificationPreferences(timeZoneIdentifier: timeZone.identifier)
    }

    /// The Settings defaults for one kind of follow.
    func defaults(for kind: FollowKind) -> FollowAlerts {
        switch kind {
        case .player: newPlayerFollowDefaults
        case .game: newGameFollowDefaults
        case .tournament: newTournamentFollowDefaults
        }
    }

    mutating func setDefaults(_ alerts: FollowAlerts, for kind: FollowKind) {
        switch kind {
        case .player: newPlayerFollowDefaults = alerts
        case .game: newGameFollowDefaults = alerts
        case .tournament: newTournamentFollowDefaults = alerts
        }
    }

    /// True when quiet hours are configured at all.
    var hasQuietHours: Bool { quietHoursStart != nil && quietHoursEnd != nil }
}

// MARK: - Making a follow

enum FollowFactory {

    /// A new follow of `target`, inheriting the device's Settings defaults for its kind.
    ///
    /// The id is generated here and is a **local** id until the server answers with its own —
    /// `POST /v1/follows` ignores whatever id it is sent. `FollowStore` rewrites it when the
    /// queued call lands.
    static func make(
        target: FollowTarget,
        preferences: NotificationPreferences,
        now: Date = .now,
        id: String = FollowFactory.localID()
    ) -> Follow {
        Follow(
            id: id,
            target: target,
            alerts: preferences.defaults(for: target.followKind).clamped(),
            createdAt: now
        )
    }

    /// Locally minted ids are prefixed so a glance at a log, or at the pending queue, says which
    /// ids the server has never seen.
    static let localPrefix = "local-"

    static func localID() -> String { localPrefix + UUID().uuidString }

    static func isLocal(_ id: String) -> Bool { id.hasPrefix(localPrefix) }

    /// A copy of `follow` with different switches, clamped to the ranges the server enforces so
    /// a value the UI could never produce can never be queued either.
    static func replacingAlerts(_ follow: Follow, with alerts: FollowAlerts) -> Follow {
        var copy = follow
        copy.alerts = alerts.clamped()
        return copy
    }

    static func replacingID(_ follow: Follow, with id: String) -> Follow {
        var copy = follow
        copy.id = id
        return copy
    }
}

// MARK: - Registration

enum DeviceRegistrationFactory {
    static func make(apnsToken: String) -> DeviceRegistration {
        DeviceRegistration(
            platform: MobileIdentity.platform,
            environment: MobileIdentity.apnsEnvironment,
            apnsToken: apnsToken,
            appVersion: MobileIdentity.appVersion
        )
    }
}

// MARK: - Row text

/// The two lines a follow shows on the watch.
struct FollowRowText: Equatable, Sendable {
    var title: String
    var subtitle: String?
}
