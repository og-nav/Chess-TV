// The client contract. The app, the watch app and the tests all talk to the server through this;
// `HTTPFollowServerClient` is the one that uses the network.

import Foundation

public protocol FollowServerClient: Sendable {
    /// Registers this install and stores the credential.
    ///
    /// Every call mints a **new** install with no follows. An APNs token is a routing address, not
    /// proof of identity, so the server will not hand an existing device's follows to whoever
    /// presents its token; the previous install keeps its data and delivery settings. Register
    /// once, keep the credential, and use
    /// `updateToken(_:)` for the rest of the install's life.
    func register(_ device: DeviceRegistration) async throws -> DeviceCredential
    /// Rotates the APNs token for the already-registered device. iOS hands out a new one after a
    /// restore or an app reinstall; the install token, and so the follows, survive.
    func updateToken(_ apnsToken: String) async throws

    func follows() async throws -> [Follow]
    func add(_ follow: Follow) async throws -> Follow
    func update(_ follow: Follow) async throws -> Follow
    func remove(id: String) async throws

    func preferences() async throws -> NotificationPreferences
    func setPreferences(_ preferences: NotificationPreferences) async throws

    func registerActivity(_ activity: ActivityRegistration) async throws
    func endActivity(gameId: String) async throws
    func health() async throws -> ServerHealth
    func alertCount() async throws -> AlertCount?
    /// Deletes the install `credential` names, with its follows. The credential is passed rather
    /// than read from the store because the caller is in the middle of throwing it away.
    func unregister(_ credential: DeviceCredential) async throws
}

extension FollowServerClient {
    /// Stubs and the watch never unregister; the phone's HTTP client does.
    public func unregister(_ credential: DeviceCredential) async throws {}

    /// Convenience for the Settings → About row: the server's own view of itself, or nil when it
    /// cannot be reached. Overridden by `HTTPFollowServerClient`; the default is for stubs.
    public func health() async throws -> ServerHealth { ServerHealth() }

    /// How many alerts the server actually delivered to this install in the last 24 hours, for
    /// Settings → Notifications.
    ///
    /// The server's number is the honest one: a phone that was asleep, or whose notifications the
    /// user cleared, has no local log to count. A caller that prefers its own delivered-notification
    /// log can ignore this. The default returns nil so a stub does not have to implement it and a
    /// caller can tell "no answer" from "none delivered".
    public func alertCount() async throws -> AlertCount? { nil }
}

/// `GET /v1/alerts/count`.
public struct AlertCount: Codable, Sendable, Equatable {
    /// Alerts delivered to this install in the last 24 hours. Live Activity updates are not
    /// alerts and are not counted.
    public var last24h: Int

    public init(last24h: Int = 0) { self.last24h = last24h }
}

/// Everything that can go wrong between the app and the server, in the terms the UI needs.
///
/// The cases are deliberately coarse: the Following screen shows "Not synced" and retries, and no
/// screen ever shows an HTTP status.
public enum FollowServerError: Error, Sendable, Equatable {
    /// The base URL is not https and is not a loopback address. Refused before any request goes
    /// out — a bearer token must never travel in the clear.
    case insecureBaseURL(String)
    /// A call that needs a device was made before `register(_:)` succeeded.
    case notRegistered
    /// The server rejected our install token. The app should register again; the old follows are
    /// gone with the old device.
    case unauthorized
    /// 404 on a follow or an activity.
    case notFound
    /// The server understood the request and refused it (400, 422): a malformed follow, usually.
    case rejected(String)
    /// 5xx, a timeout, or no network. The caller retries with backoff.
    case unavailable(String)
    /// The body was not what the contract says.
    case malformedResponse(String)
}

/// Where the install token lives between launches.
///
/// It is a bearer credential: anything holding it can read and change this device's follows, so
/// the Apple implementation is the Keychain and there is no file-backed one.
public protocol FollowCredentialStore: Sendable {
    func load() async throws -> DeviceCredential?
    func save(_ credential: DeviceCredential) async throws
    func clear() async throws
}

/// For tests, previews, and the server's own tooling. Not for a shipping app: it forgets the
/// credential when the process exits, so every launch registers a new device.
public actor InMemoryCredentialStore: FollowCredentialStore {
    private var credential: DeviceCredential?

    public init(_ credential: DeviceCredential? = nil) { self.credential = credential }

    public func load() throws -> DeviceCredential? { credential }
    public func save(_ credential: DeviceCredential) throws { self.credential = credential }
    public func clear() throws { credential = nil }
}
