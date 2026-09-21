// Everything with a lifetime, built once and handed down the view tree.
//
// The TV app's AppModel is now GameSessionKit's `GameSession`, so this object is thinner than it
// looks: it owns the session, the home shelves, the follow list, the push identity and the
// server URL, and it is the one place those five are wired to each other, to the Live Activity
// controller and to the watch.
import Foundation
import SwiftUI
import FollowKit
import GameSessionKit
import LichessKit

@MainActor
@Observable
final class AppEnvironment {

    let settings: AppSettings
    let session: GameSession
    let home: HomeModel
    let follows: FollowStore
    let registrar: DeviceRegistrar
    let server: ServerConfiguration
    let alerts: AlertActivityLog

    @ObservationIgnored private let credentials: ScopedCredentialStore
    @ObservationIgnored private var thermalTask: Task<Void, Never>?
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private(set) var client: (any FollowServerClient)?
    @ObservationIgnored private var resolvedFollowText: [String: FollowRowText] = [:]

    /// The phone defaults to Light search: two threads on a battery in a pocket is a different
    /// machine from a mains-powered Apple TV, and the depth row in Settings says so.
    static let defaultEngineDepth: EngineDepth = .light

    /// Set by the test scheme. With it on, nothing reaches the network or the Keychain and no
    /// engine is started, so a unit-test run is not also a Lichess client.
    static var isUnderTest: Bool {
        ProcessInfo.processInfo.environment["CHESSTV_TESTING"] == "1"
            || ProcessInfo.processInfo.arguments.contains("-CHESSTV_TESTING")
    }

    init(
        settings: AppSettings = AppSettings(defaults: .standard, defaultEngineDepth: AppEnvironment.defaultEngineDepth),
        session: GameSession? = nil,
        home: HomeModel = HomeModel(),
        follows: FollowStore = FollowStore(),
        registrar: DeviceRegistrar? = nil,
        server: ServerConfiguration = ServerConfiguration(),
        alerts: AlertActivityLog = AlertActivityLog(),
        credentials: (any FollowCredentialStore)? = nil
    ) {
        // Scoped to the server it was minted by, so that pointing the app at a different host can
        // never hand that host this one's bearer token. See `ScopedCredentialStore`.
        let store = ScopedCredentialStore(
            wrapping: credentials ?? (Self.isUnderTest || FixtureMode.isActive ? InMemoryCredentialStore() : AppCredentialStore.make()),
            scope: ServerURL.identity(of: server.url)
        )
        self.credentials = store
        self.settings = settings
        self.session = session ?? GameSession(settings: settings)
        self.home = home
        self.follows = follows
        self.registrar = registrar ?? DeviceRegistrar(credentials: store)
        self.server = server
        self.alerts = alerts
        if !Self.isUnderTest { wire() }
    }

    /// The server URL and the install token together decide which client everything talks to.
    /// Either changing rebuilds it once, here.
    private func wire() {
        registrar.identityWillRegister = { [weak self] in self?.follows.serverIdentityChanged() }
        registrar.credentialDidChange = { [weak self] credential in
            guard let self else { return }
            if credential == nil { self.follows.serverIdentityChanged() }
            self.rebuildClient()
            if credential == nil { PhoneWatchBridge.shared.setCredential(nil) }
            self.syncWatch(credential: credential)
        }
        follows.didChange = { [weak self] in
            self?.publishToOtherTargets()
        }
        follows.unauthorized = { [weak self] in self?.registrar.credentialRejected() }
        rebuildClient()
    }

    private func rebuildClient() {
        let client = FollowClientFactory.make(baseURL: server.url, credentials: credentials.clientStore())
        self.client = client
        follows.setClient(client)
        registrar.setClient(client)
        LiveActivityController.shared.configure(client: client, serverBaseURL: server.url)
        SharedStore.setServerBaseURL(server.url)
    }

    // MARK: - Server URL

    /// Settings committed a new server URL (or cleared it).
    ///
    // MARK: - Push, from scratch

    /// Settings then Notifications then "Reset push notifications".
    ///
    /// The order is the whole of it: nothing may be registered against an identity that is
    /// about to be dropped.
    ///
    /// 1. Ask for permission if it has never been asked. A phone that was never allowed to show
    ///    an alert has no push token to fix, and iOS will not issue one.
    /// 2. `reset()` drops the device-token marker, the APNs environment it belonged to and the
    ///    install token, tells the old server row to go away, and — through `credentialDidChange`
    ///    — makes `FollowStore` forget its last-synced marker and re-queue every follow as a new
    ///    install. That last part is what actually gets the follows back onto the server: the
    ///    new device row starts empty, and without the re-queue the first sync would adopt that
    ///    emptiness.
    /// 3. Ask iOS for a token again, because `reset()` can only wait for one.
    /// 4. Report the first answer.
    ///
    /// - Returns: where registration got to, for the line the button shows.
    func resetPushRegistration() async -> DeviceRegistrar.Status {
        let status = await registrar.resetPushRegistration()
        server.probe(using: client)
        return status
    }

    // MARK: - Lifecycle

    func start() {
        guard !didStart else { return }
        didStart = true
        publishAppearance()
        guard !Self.isUnderTest else {
            mobileLog.notice("CHESSTV_TESTING: skipping the engine, the network and the push identity")
            return
        }
        session.start()
        session.setThermalState(ProcessInfo.processInfo.thermalState)
        observeThermalState()
        PhoneWatchBridge.shared.activate()
        Task { [registrar] in
            await registrar.loadCredential()
            await registrar.refreshPermission()
        }
        follows.reconcile()
        server.probe(using: client)
        Task {
            await LiveActivityController.shared.reconcileOnForeground()
            syncWatch()
        }
        publishToOtherTargets()
    }

    func scenePhaseChanged(to phase: ScenePhase) {
        guard !Self.isUnderTest else { return }
        session.scenePhaseChanged(to: phase)
        switch phase {
        case .active:
            // Coming back is the moment everything that could have drifted is re-read: the
            // permission may have been changed in iOS Settings, the queue may hold edits made on
            // a flight, the watch may have flipped a switch, and the alert count wants the
            // delivered list again.
            Task { [registrar] in await registrar.refreshPermission() }
            registrar.advance()
            follows.refreshTimeZone()
            follows.reconcile()
            Task { [alerts, client] in await alerts.refresh(client: client) }
            server.probe(using: client)
            session.setThermalState(ProcessInfo.processInfo.thermalState)
            Task {
                await LiveActivityController.shared.reconcileOnForeground()
                syncWatch()
            }
            publishAppearance()
        case .background:
            LiveActivityController.shared.suspendRetries()
            publishToOtherTargets()
        default:
            break
        }
    }

    func teardown() async {
        thermalTask?.cancel()
        await session.shutdownEngine()
        session.teardown()
    }

    /// The engine stops itself at `.serious`; watching the notification is what makes that happen
    /// while a game is on screen rather than only when one opens.
    private func observeThermalState() {
        thermalTask = Task { @MainActor [weak self] in
            let notifications = NotificationCenter.default.notifications(named: ProcessInfo.thermalStateDidChangeNotification)
            for await _ in notifications {
                guard let self else { return }
                let state = ProcessInfo.processInfo.thermalState
                mobileLog.notice("Thermal state \(String(describing: state), privacy: .public)")
                self.session.setThermalState(state)
            }
        }
    }

    // MARK: - The rest of the suite

    /// The board colours and the piece set the notification extensions and the widget draw with.
    func publishAppearance() {
        SharedStore.writeAppearance(
            boardThemeName: settings.boardThemeName,
            pieceSetName: settings.pieceSet.rawValue,
            coordinates: settings.coordinates,
            flipBoard: settings.flipBoard
        )
    }

    /// The Following tab hands over the names it resolved from Lichess, keyed by follow id, so
    /// the watch shows "Magnus Carlsen" rather than a FIDE id. Nothing depends on them arriving.
    func cacheFollowText(_ text: [String: FollowRowText]) {
        guard text != resolvedFollowText else { return }
        resolvedFollowText = text
        syncWatch()
    }

    /// Follows and preferences changed: the app group's copy and the watch both want to know.
    private func publishToOtherTargets() {
        syncWatch()
    }

    func syncWatch(credential: DeviceCredential? = nil) {
        guard !Self.isUnderTest else { return }
        PhoneWatchBridge.shared.sync(
            follows: watchFollows,
            preferences: follows.preferences,
            serverBaseURL: server.url,
            pinned: LiveActivityController.shared.pinned,
            credential: credential
        )
    }

    /// The follow list as the watch shows it: a title and a status line, because the watch has no
    /// Lichess client of its own for the names behind the ids.
    private var watchFollows: [WatchFollow] {
        follows.follows.map { follow in
            let text = resolvedFollowText[follow.id] ?? WatchFollowText.fallback(for: follow)
            return WatchFollow(follow: follow, title: text.title, subtitle: text.subtitle)
        }
    }
}

/// Wording for the watch rows before the phone has resolved a name from Lichess, so the watch
/// always has something better than a bare id.
enum WatchFollowText {
    static func fallback(for follow: Follow) -> FollowRowText {
        let title: String
        switch follow.target {
        case .player(let fideId): title = "FIDE \(fideId)"
        case .game(_, let gameId): title = "Board \(gameId.prefix(6))"
        case .tournament(let tourId): title = tourId.replacingOccurrences(of: "-", with: " ").capitalized
        }
        return FollowRowText(title: title, subtitle: follow.alerts.summary(for: follow.followKind))
    }
}
