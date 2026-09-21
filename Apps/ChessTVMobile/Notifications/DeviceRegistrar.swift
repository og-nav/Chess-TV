// Permission, the APNs token, and telling the server about this install exactly once.
//
// The rule that matters: **a token refresh is a PUT, not a second install.** iOS hands out a new
// device token after a restore, an OS upgrade and sometimes for no reason at all, and an app that
// POSTs every time ends up with a row per refresh on the server and one push per row on the
// phone. `RegistrationPlan` is the whole decision, and it is pure so a test can hold it still.
import Foundation
import FollowKit
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// What should happen given what we hold and what iOS just handed us.
enum RegistrationDecision: Equatable, Sendable {
    /// No token from iOS yet; nothing to do but wait for the delegate callback.
    case waitingForToken
    /// No credential: mint one with `POST /v1/devices`.
    case register
    /// Same install, new token: `PUT /v1/devices/me/token`.
    case updateToken
    /// The server already knows this exact token.
    case upToDate
}

enum RegistrationPlan {

    /// - Parameters:
    ///   - credential: what the Keychain holds, or nil on a fresh install.
    ///   - registeredToken: the token the server was last told, as recorded locally.
    ///   - registeredEnvironment: the APNs environment that token belonged to.
    ///   - apnsToken: what iOS handed us this launch.
    ///   - environment: this build's APNs environment.
    static func decide(
        credential: DeviceCredential?,
        registeredToken: String?,
        registeredEnvironment: String?,
        apnsToken: String?,
        environment: String
    ) -> RegistrationDecision {
        guard let apnsToken, !apnsToken.isEmpty else { return .waitingForToken }
        guard credential != nil else { return .register }
        // A Debug build's token is a sandbox token and a Release build's is not; the same row on
        // the server cannot be both, and `PUT /token` carries no environment to change it with.
        // So a build that crossed the line registers afresh and lets the old row die on its
        // first 410. This only happens on the owner's own devices, between builds.
        guard registeredEnvironment == environment else { return .register }
        return registeredToken == apnsToken ? .upToDate : .updateToken
    }

    /// How long to wait before trying a failed registration again: 5 s, doubling, capped at five
    /// minutes. Registration is not urgent — every screen works without it — so the retry is
    /// gentle rather than eager.
    static func retryDelay(afterFailures failures: Int) -> Duration {
        guard failures > 0 else { return .seconds(5) }
        let seconds = min(5.0 * pow(2, Double(failures - 1)), 300)
        return .seconds(seconds)
    }

    /// APNs device tokens are raw bytes; the server wants the usual lowercase hex.
    static func hexToken(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

/// What the Settings screen says about permission.
enum PushPermission: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    /// The simulator and previews, where there is no APNs at all.
    case unavailable

    var allowsPush: Bool { self == .authorized || self == .provisional }

    var title: String {
        switch self {
        case .notDetermined: "Not asked yet"
        case .denied: "Turned off"
        case .authorized: "On"
        case .provisional: "Quiet delivery"
        case .unavailable: "Unavailable"
        }
    }

    var detail: String {
        switch self {
        case .notDetermined: "Chess TV hasn\u{2019}t asked for permission to send alerts yet."
        case .denied: "Notifications are off for Chess TV in iOS Settings, so nothing will arrive."
        case .authorized: "Alerts for the things you follow will arrive on this device."
        case .provisional: "Alerts arrive quietly in Notification Center until you allow them properly."
        case .unavailable: "This device can\u{2019}t receive push notifications."
        }
    }
}

/// Thin seam over `UNUserNotificationCenter` and `UIApplication`, so the registrar is testable.
@MainActor
protocol PushEnvironment: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func registerForRemoteNotifications()
    func openSettings()
}

@MainActor
final class SystemPushEnvironment: PushEnvironment {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    func registerForRemoteNotifications() {
        #if canImport(UIKit)
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }

    func openSettings() {
        #if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }
}

/// Owns the install's identity and keeps the server's copy of the APNs token current.
@MainActor
@Observable
final class DeviceRegistrar {

    enum Status: Equatable, Sendable {
        case idle
        case waitingForToken
        case registering
        case registered
        case failed(String)
        /// A server URL has not been configured, so there is nobody to register with.
        case noServer
    }

    enum Key {
        static let registeredToken = "registeredAPNSToken"
        static let registeredEnvironment = "registeredAPNSEnvironment"
    }

    private(set) var permission: PushPermission = .notDetermined
    private(set) var status: Status = .idle
    /// True once the server has answered; the Settings screen shows the id's prefix only.
    var deviceID: String? { credential?.deviceId }

    @ObservationIgnored private let credentials: any FollowCredentialStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let environment: any PushEnvironment
    @ObservationIgnored private var credential: DeviceCredential?
    @ObservationIgnored private var apnsToken: String?
    @ObservationIgnored private var client: (any FollowServerClient)?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var hasLoadedCredential = false
    @ObservationIgnored private var work: Task<Void, Never>?
    /// Bumped by `reset()`. A registration that was already on the wire when the identity was
    /// dropped must not be adopted afterwards: cancelling the task does not stop a request that
    /// is past its last suspension point, and the credential it returns was minted by a host the
    /// app no longer talks to.
    @ObservationIgnored private var identityGeneration = 0
    /// The generation `identityWillRegister` last fired for. A registration that fails and
    /// retries is still the same new identity, and the follow store must not re-queue its list
    /// on every retry.
    @ObservationIgnored private var announcedGeneration: Int?
    /// When a rejected credential last caused a reset, so a server that answers 401 to every
    /// token cannot drive a register → 401 → register loop.
    @ObservationIgnored private var lastRejectionReset: Date?
    /// Keychain writes, chained. `reset()`'s clear and a registration landing at the same instant
    /// must not interleave, or the token the reset removed is written straight back behind it.
    @ObservationIgnored private var keychainWrites: Task<Void, Never>?

    /// Called with the credential whenever it changes, so the app can build a client that
    /// carries it. The token itself never leaves this object by any other route.
    @ObservationIgnored var identityWillRegister: (() -> Void)?
    @ObservationIgnored var credentialDidChange: ((DeviceCredential?) -> Void)?

    init(
        credentials: any FollowCredentialStore = AppCredentialStore.make(),
        defaults: UserDefaults = .standard,
        environment: any PushEnvironment = SystemPushEnvironment()
    ) {
        self.credentials = credentials
        self.defaults = defaults
        self.environment = environment
    }

    var isRegistered: Bool { credential != nil }

    /// Reads the Keychain once at launch. Separate from `init` because `FollowCredentialStore`
    /// is async — the Keychain implementation is not, but the in-memory one used by the tests
    /// and the server tooling is an actor.
    func loadCredential() async {
        let generation = identityGeneration
        await keychainWrites?.value
        let loaded = try? await credentials.load()
        guard generation == identityGeneration else { return }
        credential = loaded
        hasLoadedCredential = true
        credentialDidChange?(credential)
        advance()
    }

    func setClient(_ client: (any FollowServerClient)?) {
        self.client = client
        if client == nil, status != .registered { status = .noServer }
        advance()
    }

    // MARK: - Permission

    /// Reads the current permission without asking for anything. Run on every activation, so a
    /// trip to iOS Settings is reflected when the user comes back.
    func refreshPermission() async {
        let status = await environment.authorizationStatus()
        permission = Self.permission(for: status)
        if permission.allowsPush { environment.registerForRemoteNotifications() }
    }

    /// The button in Settings → Notifications, and the first-run prompt.
    func requestPermission() async {
        do {
            let granted = try await environment.requestAuthorization()
            mobileLog.notice("Notification permission \(granted ? "granted" : "refused")")
        } catch {
            mobileLog.error("Notification permission request failed: \(FollowStore.message(for: error), privacy: .public)")
        }
        await refreshPermission()
    }

    func openSystemSettings() { environment.openSettings() }

    /// Repairs registration only when alerts are allowed, and waits for a fresh APNs callback
    /// before registering. The callback may contain the same token; it still confirms that iOS
    /// has registered this launch. Keep the existing identity when permission is denied.
    func resetPushRegistration() async -> Status {
        permission = Self.permission(for: await environment.authorizationStatus())
        if permission == .notDetermined {
            do { _ = try await environment.requestAuthorization() }
            catch { return .failed("Could not request notification permission") }
            permission = Self.permission(for: await environment.authorizationStatus())
        }
        guard permission.allowsPush else { return .idle }
        reset(waitForFreshToken: true)
        environment.registerForRemoteNotifications()
        return await awaitRegistration()
    }

    static func permission(for status: UNAuthorizationStatus) -> PushPermission {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .provisional
        @unknown default: .unavailable
        }
    }

    // MARK: - The token

    /// The app delegate's `didRegisterForRemoteNotificationsWithDeviceToken`.
    func tokenArrived(_ data: Data) {
        let hex = RegistrationPlan.hexToken(from: data)
        guard hex != apnsToken else { return }
        apnsToken = hex
        // The token identifies this device for APNs routing: log its length, never its value.
        mobileLog.notice("APNs token received (\(hex.count) hex characters)")
        advance()
    }

    /// The app delegate's `didFailToRegisterForRemoteNotificationsWithError`.
    func tokenFailed(_ error: Error) {
        mobileLog.error("APNs registration failed: \(FollowStore.message(for: error), privacy: .public)")
        if permission.allowsPush { status = .failed("iOS could not issue a push token") }
    }

    // MARK: - Talking to the server

    /// Does whatever the plan says, once. Safe to call repeatedly.
    func advance() {
        guard hasLoadedCredential else { return }
        guard work == nil else { return }
        guard let client else {
            status = credential == nil ? .noServer : .registered
            return
        }
        let decision = RegistrationPlan.decide(
            credential: credential,
            registeredToken: defaults.string(forKey: Key.registeredToken),
            registeredEnvironment: defaults.string(forKey: Key.registeredEnvironment),
            apnsToken: apnsToken,
            environment: MobileIdentity.apnsEnvironment
        )
        switch decision {
        case .waitingForToken:
            status = permission.allowsPush ? .waitingForToken : .idle
        case .upToDate:
            status = .registered
            failures = 0
        case .register, .updateToken:
            status = .registering
            let generation = identityGeneration
            if decision == .register, announcedGeneration != generation {
                announcedGeneration = generation
                identityWillRegister?()
            }
            work = Task { @MainActor [weak self] in
                guard let self, generation == self.identityGeneration, !Task.isCancelled else { return }
                await self.perform(decision, with: client)
                guard generation == self.identityGeneration else { return }
                self.work = nil
                if case .registered = self.status { self.advance() }
                else { self.scheduleRetry() }
            }
        }
    }

    /// A failed attempt waits and tries again. Scheduling it here rather than inside `perform`
    /// keeps `work` honest: the retry is the task, so a `reset()` or a new token cancels it.
    private func scheduleRetry() {
        guard case .failed = status, failures > 0 else { return }
        let delay = RegistrationPlan.retryDelay(afterFailures: failures)
        work = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.work = nil
            self.advance()
        }
    }

    private func perform(_ decision: RegistrationDecision, with client: any FollowServerClient) async {
        guard let apnsToken else { return }
        let generation = identityGeneration
        do {
            switch decision {
            case .register:
                let credential = try await client.register(DeviceRegistrationFactory.make(apnsToken: apnsToken))
                guard generation == identityGeneration else {
                    mobileLog.notice("Discarding a registration that landed after the identity was reset")
                    return
                }
                self.credential = credential
                writeCredential(credential)
                await keychainWrites?.value
                guard generation == identityGeneration, !Task.isCancelled else { return }
                credentialDidChange?(credential)
                mobileLog.notice("Registered this install with the push server")
            case .updateToken:
                try await client.updateToken(apnsToken)
                guard generation == identityGeneration else { return }
                mobileLog.notice("Push token updated on the server")
            case .upToDate, .waitingForToken:
                return
            }
            defaults.set(apnsToken, forKey: Key.registeredToken)
            defaults.set(MobileIdentity.apnsEnvironment, forKey: Key.registeredEnvironment)
            failures = 0
            status = .registered
        } catch {
            guard !(error is CancellationError), generation == identityGeneration else { return }
            failures += 1
            status = .failed(FollowStore.message(for: error))
            mobileLog.error("Registration attempt \(self.failures) failed: \(FollowStore.message(for: error), privacy: .public)")
        }
    }

    /// Keychain writes happen in the order they were asked for. Without the chain, a `clear()`
    /// issued by `reset()` and a `save()` from a registration that landed a moment earlier are
    /// two unordered tasks, and the losing order leaves the old host's token in the Keychain.
    private func writeCredential(_ credential: DeviceCredential?) {
        let store = credentials
        let previous = keychainWrites
        let generation = identityGeneration
        keychainWrites = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, generation == self.identityGeneration else { return }
            if let credential {
                try? await store.save(credential)
            } else {
                try? await store.clear()
            }
        }
    }

    /// The server answered 401 to this install's token: the device row is gone or was rotated
    /// away. The credential is worthless, so drop it and register again — once. A second
    /// rejection inside ten minutes is left alone and stays visible as a sync failure, because
    /// a server that rejects every token would otherwise be hammered with registrations.
    func credentialRejected() {
        guard credential != nil else { return }
        if let last = lastRejectionReset, Date.now.timeIntervalSince(last) < 600 {
            mobileLog.error("Credential rejected again within ten minutes; not re-registering")
            return
        }
        lastRejectionReset = .now
        mobileLog.notice("Credential rejected by the server; registering this install again")
        reset()
    }

    /// Asks the server to delete the install this phone is about to abandon, so its follows do
    /// not go on producing a second copy of every alert to the new identity. Best effort and
    /// detached: the credential travels by value, because `reset()` clears the store a moment
    /// later. Safe to call twice — the second time there is no credential left to send.
    func unregisterCurrentIdentity() {
        guard let client, let credential else { return }
        Task.detached {
            do {
                try await client.unregister(credential)
                mobileLog.notice("Unregistered the previous install from the server")
            } catch {
                mobileLog.notice("Could not unregister the previous install: \(FollowStore.message(for: error), privacy: .public)")
            }
        }
    }

    /// Waits for the registration that a `reset()` kicked off to land, so the button that asked
    /// for it can say what happened rather than leaving a spinner and a shrug.
    ///
    /// Polling rather than a continuation: `status` is the observable the whole screen already
    /// reads, and a second notification path for the same fact is a second thing to keep in
    /// step. A registration that fails retries on its own schedule; this reports the first
    /// answer and does not wait out the backoff.
    func awaitRegistration(timeout: Duration = .seconds(20)) async -> Status {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            switch status {
            case .registered, .failed, .noServer: return status
            case .idle, .registering, .waitingForToken: break
            }
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { break }
        }
        return status
    }

    /// Forgets this install entirely.
    ///
    /// Two callers: the "Reset push identity" button, for a device registered against a server
    /// that no longer knows it, and `AppEnvironment` when the server URL is pointed somewhere
    /// else — an install token minted by one host means nothing to another and must never be
    /// sent to it.
    func reset(waitForFreshToken: Bool = false) {
        unregisterCurrentIdentity()
        identityGeneration &+= 1
        (credentials as? ScopedCredentialStore)?.invalidateIdentity()
        work?.cancel()
        work = nil
        credential = nil
        if waitForFreshToken { apnsToken = nil }
        hasLoadedCredential = true
        writeCredential(nil)
        defaults.removeObject(forKey: Key.registeredToken)
        defaults.removeObject(forKey: Key.registeredEnvironment)
        failures = 0
        status = .idle
        credentialDidChange?(nil)
        mobileLog.notice("Push identity reset")
        advance()
    }
}
