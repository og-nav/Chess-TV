// The adaptive root: a tab bar on iPhone, a sidebar and a detail pane on iPad.
//
// Both shapes push the same routes through the same builder, so a screen is written once. The
// system's iOS 26 chrome does the work — the tab bar and the toolbars are stock, and the custom
// drawing is kept to the board, the eval bar and the cards.
import SwiftUI
import GameSessionKit

struct RootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                PhoneTabs()
            } else {
                PadSplitView()
            }
        }
        .background(Palette.ground)
    }
}

// MARK: - iPhone

private struct PhoneTabs: View {
    @Environment(Navigator.self) private var navigator

    var body: some View {
        @Bindable var navigator = navigator
        TabView(selection: $navigator.tab.withSelectionFeedback()) {
            Tab(MobileTab.home.title, systemImage: MobileTab.home.systemImage, value: MobileTab.home) {
                NavigationStack(path: $navigator.homePath.withSelectionFeedback()) {
                    HomeScreen()
                        .navigationDestination(for: MobileRoute.self) { RouteView(route: $0) }
                }
            }
            Tab(MobileTab.following.title, systemImage: MobileTab.following.systemImage, value: MobileTab.following) {
                NavigationStack(path: $navigator.followingPath.withSelectionFeedback()) {
                    FollowingScreen()
                        .navigationDestination(for: MobileRoute.self) { RouteView(route: $0) }
                }
            }
            Tab(MobileTab.settings.title, systemImage: MobileTab.settings.systemImage, value: MobileTab.settings) {
                NavigationStack(path: $navigator.settingsPath.withSelectionFeedback()) {
                    SettingsScreen()
                        .navigationDestination(for: MobileRoute.self) { RouteView(route: $0) }
                }
            }
        }
    }
}

// MARK: - iPad

private struct PadSplitView: View {
    @Environment(Navigator.self) private var navigator
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        @Bindable var navigator = navigator
        NavigationSplitView {
            // The sidebar's selection is optional on iOS — a split view can legitimately have
            // nothing selected while it is collapsed — so a nil selection means "stay where we
            // are" rather than "show nothing".
            List(selection: Binding(get: { navigator.tab }, set: { navigator.tab = $0 ?? navigator.tab }).withSelectionFeedback()) {
                // Identified by the tab itself, not by `Identifiable`'s `id`. `MobileTab.id` is a
                // String, and a `ForEach` over an Identifiable collection tags each row with that
                // id; the row's own `.tag(tab)` did not win, so every tap wrote a String into a
                // `MobileTab?` selection, which SwiftUI dropped — the sidebar rows did nothing at
                // all on iPad. Identifying by self makes the implicit tag the tab.
                ForEach(MobileTab.allCases, id: \.self) { tab in
                    Label(tab.title, systemImage: tab.systemImage)
                        .tag(tab)
                        .badge(tab == .following ? app.follows.follows.count : 0)
                }
            }
            .navigationTitle("Chess TV")
            .listStyle(.sidebar)
        } detail: {
            switch navigator.tab {
            case .home:
                NavigationStack(path: $navigator.homePath.withSelectionFeedback()) {
                    HomeScreen()
                        .navigationDestination(for: MobileRoute.self) { RouteView(route: $0) }
                }
            case .following:
                NavigationStack(path: $navigator.followingPath.withSelectionFeedback()) {
                    FollowingScreen()
                        .navigationDestination(for: MobileRoute.self) { RouteView(route: $0) }
                }
            case .settings:
                NavigationStack(path: $navigator.settingsPath.withSelectionFeedback()) {
                    SettingsScreen()
                        .navigationDestination(for: MobileRoute.self) { RouteView(route: $0) }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

// MARK: - Routes

/// The single place a route becomes a screen.
struct RouteView: View {
    let route: MobileRoute

    var body: some View {
        switch route {
        case .tournament(let tourId, let name):
            TournamentScreen(tourId: tourId, name: name)
        case .boards(let roundId, let tournamentName):
            BoardsWallScreen(roundId: roundId, tournamentName: tournamentName)
        case .game(let destination):
            GameScreen(destination: destination)
        case .followDetail(let target):
            FollowDetailScreen(target: target)
        case .notifications:
            NotificationSettingsScreen()
        case .followDefaults(let kind):
            FollowDefaultsScreen(kind: kind)
        case .credits:
            CreditsScreen()
        case .licence(let licence):
            LicenceScreen(licence: licence)
        }
    }
}
