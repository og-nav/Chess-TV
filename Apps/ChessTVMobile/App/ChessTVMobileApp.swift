// The app: one scene, one environment, one adaptive root.
import SwiftUI
import UserNotifications
import FollowKit
import GameSessionKit
#if canImport(UIKit)
import UIKit
#endif

@main
struct ChessTVMobileApp: App {

    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #endif

    @State private var environment: AppEnvironment
    @State private var navigator = Navigator()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Fixture mode first: it has to be in place before any client builds a URLSession.
        FixtureMode.activateIfRequested()
        MobileIdentity.configurePackages()
        let environment = AppEnvironment()
        _environment = State(initialValue: environment)
        MobileIntegration.install(MobileIntegration(environment: environment))
        AppDelegate.environment = environment
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .environment(navigator)
                .preferredColorScheme(.dark)
                .tint(Palette.accent)
                .task {
                    environment.start()
                    let session = environment.session
                    navigator.gameTapped = { session.noteNavigationTap() }
                    navigator.tab = LaunchArguments.initialTab() ?? navigator.tab
                    let routes = LaunchArguments.routes()
                    if !routes.isEmpty { navigator.homePath = routes }
                    AppDelegate.attach(navigator: navigator)
                }
                .onOpenURL { AppDelegate.receive(PushRouting.target(from: $0)) }
                .onChange(of: scenePhase) { _, phase in
                    environment.scenePhaseChanged(to: phase)
                }
        }
    }
}

#if canImport(UIKit)

/// The APNs token, and what a tapped notification opens.
///
/// SwiftUI has no hook for either, so this is the whole reason there is a delegate at all. It
/// holds nothing: both properties are set once at launch by the app above.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    static var environment: AppEnvironment?
    static var navigator: Navigator?
    private static var pendingTarget: PushRouting.Target?

    static func attach(navigator: Navigator) {
        Self.navigator = navigator
        if let pendingTarget {
            Self.pendingTarget = nil
            route(pendingTarget, using: navigator)
        }
    }

    /// Notification responses can precede SwiftUI's first task on a cold launch.
    static func receive(_ target: PushRouting.Target?) {
        guard let target else { return }
        guard let navigator else { pendingTarget = target; return }
        route(target, using: navigator)
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        if !AppEnvironment.isUnderTest { PushCategories.register() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Self.environment?.registrar.tokenArrived(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Self.environment?.registrar.tokenFailed(error)
    }

    /// A silent or alert push arrived while the app was running. Nothing is fetched here: the
    /// board on screen has its own live feed, and the count is what this is for.
    nonisolated func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping @Sendable (UIBackgroundFetchResult) -> Void
    ) {
        let identifier = PushRouting.identifier(from: userInfo)
        Task { @MainActor in
            Self.environment?.alerts.record(id: identifier)
            Self.environment?.follows.reconcile()
            completionHandler(.noData)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Keep the Objective-C completion handlers explicit. The async delegate bridge can invoke
    /// UIKit's completion on a cooperative worker after our MainActor.run has returned. On a
    /// notification tap UIKit saves restoration state there, which asserts off the main thread.
    /// Both routing and completion therefore happen in the same main-actor task.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        let identifier = notification.request.identifier
        let date = notification.date
        let target = PushRouting.target(from: notification.request.content.userInfo)
        Task { @MainActor in
            Self.environment?.alerts.record(id: identifier, at: date)
            if case .board(let roundId, let gameId, _) = target,
               Self.environment?.session.openDestination?.source == .broadcastBoard(roundId: roundId, gameId: gameId) {
                completionHandler([])
            } else {
                completionHandler([.banner, .sound, .list])
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        Self.handleNotificationResponse(
            actionIdentifier: response.actionIdentifier,
            identifier: response.notification.request.identifier,
            date: response.notification.date,
            target: PushRouting.target(from: response.notification.request.content.userInfo),
            completionHandler: completionHandler
        )
    }

    /// Only immutable values cross the actor boundary; UNNotificationResponse stays on the
    /// system callback's executor. Also used by the regression test to exercise an off-main
    /// callback and verify UIKit receives its completion on the main thread, even for no-op taps.
    nonisolated static func handleNotificationResponse(
        actionIdentifier: String,
        identifier: String,
        date: Date,
        target: PushRouting.Target?,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        Task { @MainActor in
            defer { completionHandler() }
            guard actionIdentifier == UNNotificationDefaultActionIdentifier
                || actionIdentifier == PushAction.openGame
                || actionIdentifier == PushAction.openTournament else { return }
            Self.open(target, identifier: identifier, at: date)
        }
    }

    private static func open(_ target: PushRouting.Target?, identifier: String, at date: Date) {
        Self.environment?.alerts.record(id: identifier, at: date)
        receive(target)
    }

    private static func route(_ target: PushRouting.Target, using navigator: Navigator) {
        switch target {
        case .board(let roundId, let gameId, let tourName):
            navigator.openBoard(
                roundId: roundId,
                gameId: gameId,
                tournamentName: tourName,
                destination: GameDestination(source: .broadcastBoard(roundId: roundId, gameId: gameId), title: tourName)
            )
        case .tournament(let tourId, let name):
            navigator.openTournament(tourId: tourId, name: name)
        }
    }
}

#endif
