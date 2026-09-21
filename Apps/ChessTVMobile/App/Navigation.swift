// What the phone can push, and which tab it belongs to.
//
// The TV app's `Route` is a two-case enum because a TV has one stack. The phone has three, and a
// row in Following has to be able to open a board in the Home stack, so the routes carry enough
// to rebuild a screen from nothing.
import Foundation
import FollowKit
import GameSessionKit
import LichessKit

enum MobileRoute: Hashable, Sendable {
    /// The rounds of one broadcast, with dates and an ongoing marker.
    case tournament(tourId: String, name: String?)
    /// Every board of one round.
    case boards(roundId: String, tournamentName: String?)
    case game(GameDestination)
    /// Route by the stable target: registration replaces a temporary local follow ID.
    case followDetail(target: FollowTarget)
    /// The Settings → Notifications section and the screens under it.
    case notifications
    case followDefaults(kind: FollowKind)
    /// Settings then Credits, and one bundled licence text under it.
    case credits
    case licence(Credits.Licence)
}

/// The three places the phone can be. On iPad these are the sidebar's rows instead of tabs.
enum MobileTab: String, Hashable, CaseIterable, Identifiable, Sendable {
    case home, following, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Watch"
        case .following: "Following"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "play.tv"
        case .following: "bell"
        case .settings: "gearshape"
        }
    }
}

/// One navigation stack per tab, so switching tabs keeps where you were.
@MainActor
@Observable
final class Navigator {
    var tab: MobileTab = .home
    var homePath: [MobileRoute] = []
    var followingPath: [MobileRoute] = []
    var settingsPath: [MobileRoute] = []

    /// Called with the tap that pushes a game, before the route lands in a path. The app points
    /// this at `GameSession.noteNavigationTap`, so the opening is timed from the tap.
    @ObservationIgnored var gameTapped: (() -> Void)?

    /// The path for whichever tab is showing.
    var activePath: [MobileRoute] {
        get {
            switch tab {
            case .home: homePath
            case .following: followingPath
            case .settings: settingsPath
            }
        }
        set {
            switch tab {
            case .home: homePath = newValue
            case .following: followingPath = newValue
            case .settings: settingsPath = newValue
            }
        }
    }

    func push(_ route: MobileRoute, in tab: MobileTab? = nil) {
        if case .game = route { gameTapped?() }
        let target = tab ?? self.tab
        self.tab = target
        switch target {
        case .home: homePath.append(route)
        case .following: followingPath.append(route)
        case .settings: settingsPath.append(route)
        }
    }

    /// Opening a board from Following: the Home stack is where a game lives, so the board list
    /// goes under it and Back lands somewhere sensible rather than on a bell icon.
    func openBoard(roundId: String, gameId: String, tournamentName: String?, destination: GameDestination) {
        gameTapped?()
        tab = .home
        homePath = [
            .boards(roundId: roundId, tournamentName: tournamentName),
            .game(destination),
        ]
    }

    func openTournament(tourId: String, name: String?) {
        tab = .home
        homePath = [.tournament(tourId: tourId, name: name)]
    }

    func popToRoot() { activePath = [] }
}

// MARK: - Launch arguments

/// `-open board:<roundId>:<gameId>`, `-open boards:<roundId>`, `-open tv:blitz`, `-open following`.
/// The same spelling the TV app uses, so one habit covers both.
enum LaunchArguments {
    static func initialTab(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> MobileTab? {
        guard let index = arguments.firstIndex(of: "-open"), index + 1 < arguments.count else { return nil }
        switch arguments[index + 1] {
        case "following": return .following
        case "settings": return .settings
        default: return nil
        }
    }

    static func routes(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> [MobileRoute] {
        guard let index = arguments.firstIndex(of: "-open"), index + 1 < arguments.count else { return [] }
        let value = arguments[index + 1]
        if value.hasPrefix("boards:") {
            let roundId = String(value.dropFirst("boards:".count))
            guard !roundId.isEmpty else { return [] }
            return [.boards(roundId: roundId, tournamentName: nil)]
        }
        if value.hasPrefix("tour:") {
            let tourId = String(value.dropFirst("tour:".count))
            guard !tourId.isEmpty else { return [] }
            return [.tournament(tourId: tourId, name: nil)]
        }
        guard let source = GameSource(storageKey: value) else { return [] }
        switch source {
        case .broadcastBoard(let roundId, _):
            return [.boards(roundId: roundId, tournamentName: nil), .game(GameDestination(source: source))]
        default:
            return [.game(GameDestination(source: source))]
        }
    }
}
