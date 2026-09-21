// The watch's half of the link.
//
// Two jobs:
//   * receive the application context the phone sends, split the credential off into the watch's
//     own Keychain and keep the rest;
//   * hand the rest to `WatchSnapshot`, so the watch app opens with the follow list it had last
//     time rather than an empty screen waiting on a phone that may be in another room.
//
// The phone and the watch share nothing at rest — not an App Group, not a Keychain — so this is
// the only way anything gets here. `FollowKit.KeychainCredentialStore` is used with its default
// access group: the shared-access-group form in that type's documentation shares a credential
// between an app and *its extensions on the same device*, which the watch is not.
#if os(watchOS)
import Foundation
import Observation
import WatchConnectivity
import FollowKit
import WidgetKit

@MainActor
@Observable
public final class WatchSyncStore: NSObject {

    public static let shared = WatchSyncStore()

    /// Everything the phone has told us, last-write-wins.
    public private(set) var payload: WatchSyncPayload

    /// True once a context has arrived in this install. False means "we have never heard from the
    /// phone", which the UI says out loud rather than showing an empty list.
    public private(set) var hasSynced: Bool

    /// Whether the watch holds a credential. The value itself never reaches the UI layer.
    public private(set) var hasCredential = false

    private static let credentialHostKey = "watchCredentialHost"

    @ObservationIgnored private let credentials = KeychainCredentialStore()

    private override init() {
        let stored = WatchSnapshot.read()
        payload = stored ?? WatchSyncPayload()
        hasSynced = stored != nil
        super.init()
    }

    public func activate() {
        refreshCredentialFlag()
        guard WCSession.isSupported() else {
            watchLinkLog.notice("WatchConnectivity is not supported here")
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        // A context that arrived while this app was not running is waiting in
        // `receivedApplicationContext`; the delegate callback does not fire for it.
        adopt(Self.extract(session.receivedApplicationContext))
    }

    /// A client for the follow server, or nil when there is no server yet or no credential yet.
    /// The watch's Notifications screen uses this and nothing else.
    public func makeClient(userAgent: String) -> HTTPFollowServerClient? {
        guard hasCredential, let baseURL = payload.serverBaseURL else { return nil }
        // One client per server. Each `URLSession` owns threads and queues for the life of the
        // process, and the Notifications screen asks for a client on every switch toggle.
        if let cached = cachedClient, cached.baseURL == baseURL, cached.userAgent == userAgent { return cached.client }
        do {
            let client = try HTTPFollowServerClient(
                baseURL: baseURL,
                credentials: credentials,
                transport: URLSessionTransport(session: URLSessionTransport.session(userAgent: userAgent)),
                userAgent: userAgent
            )
            cachedClient = (baseURL, userAgent, client)
            return client
        } catch {
            // The only throwing case is an insecure base URL, which is a configuration mistake on
            // the phone, not something the wrist can fix.
            watchLinkLog.error("Cannot build a server client: \(logLabel(for: error), privacy: .public)")
            return nil
        }
    }

    private var cachedClient: (baseURL: URL, userAgent: String, client: HTTPFollowServerClient)?

    /// Applies a local change optimistically so a switch moves at once, before the server answers.
    public func applyLocally(preferences: NotificationPreferences) {
        payload.preferences = preferences
        WatchSnapshot.write(payload)
    }

    public func applyLocally(alerts: FollowAlerts, forFollow id: String) {
        guard let index = payload.follows.firstIndex(where: { $0.id == id }) else { return }
        payload.follows[index].alerts = alerts
        WatchSnapshot.write(payload)
    }

    /// `KeychainCredentialStore`'s own methods are synchronous — the `async` in the protocol is
    /// there for stores that are actors — so this is a fast local call, not a hop.
    private func refreshCredentialFlag() {
        hasCredential = ChessTVAppGroup.defaults.string(forKey: Self.credentialHostKey) == payload.serverBaseURL?.absoluteString
            && ((try? credentials.load()) ?? nil) != nil
    }

    // MARK: - Receiving

    /// Pulls the two `Data` values out of the context while still on whatever thread
    /// WatchConnectivity called on. `[String: Any]` is not `Sendable`; `Data` is, so this is what
    /// crosses to the main actor.
    nonisolated private static func extract(_ context: [String: Any]) -> ReceivedContext {
        ReceivedContext(
            payload: context[WatchSyncKey.payload] as? Data,
            credential: context[WatchSyncKey.credential] as? Data,
            clearsCredential: context[WatchSyncKey.clearsCredential] as? Bool ?? false
        )
    }

    struct ReceivedContext: Sendable {
        var payload: Data?
        var credential: Data?
        var clearsCredential: Bool = false
        var isEmpty: Bool { payload == nil && credential == nil && !clearsCredential }
    }

    /// Applies one application context.
    ///
    /// The payload is decoded and checked *before* anything is committed, because whether the
    /// credential survives depends on what the payload says: a context that moves this install to a
    /// different server must not leave the old server's install token in the Keychain, and a
    /// context that is simply stale must not be allowed to clear anything at all.
    private func adopt(_ context: ReceivedContext) {
        guard !context.isEmpty else { return }

        var incoming: WatchSyncPayload?
        if let data = context.payload {
            guard let decoded = try? FollowJSON.decoder.decode(WatchSyncPayload.self, from: data) else {
                watchLinkLog.error("Could not decode the payload the phone sent")
                return
            }
            guard decoded.isReadable else {
                watchLinkLog.notice("Ignoring a payload of version \(decoded.version); this build reads \(WatchSyncPayload.currentVersion)")
                return
            }
            // Last-write-wins, but never backwards: contexts can be delivered out of order after a
            // reconnect, and an older follow list overwriting a newer one is a visible bug.
            guard !hasSynced || decoded.updatedAt >= payload.updatedAt else {
                watchLinkLog.notice("Ignoring an application context older than the one already held")
                return
            }
            incoming = decoded
        }

        let serverChanged = incoming.map { $0.serverBaseURL != payload.serverBaseURL } ?? false

        // Clear first so a failed write on a host transition cannot leave the old secret usable.
        if serverChanged { clearCredential(because: "the follow server changed") }

        // The credential goes to the Keychain and nowhere else; it is never written to the
        // snapshot on disk with the rest of the payload.
        if let credentialData = context.credential,
           let credential = try? FollowJSON.decoder.decode(DeviceCredential.self, from: credentialData),
           !credential.installToken.isEmpty {
            do {
                try credentials.save(credential)
                ChessTVAppGroup.defaults.set((incoming ?? payload).serverBaseURL?.absoluteString, forKey: Self.credentialHostKey)
                hasCredential = true
                watchLinkLog.notice("Stored a device credential from the phone")
            } catch {
                // The OSStatus, never the token.
                watchLinkLog.error("Could not store the credential: \(logLabel(for: error), privacy: .public)")
            }
        } else if context.clearsCredential {
            clearCredential(because: "the phone dropped its install identity")
        } else if serverChanged, hasSynced {
            // Belt and braces against a phone build that changes host without saying so: the token
            // we hold was minted by the old server and must never be presented to the new one.
            clearCredential(because: "the follow server changed")
        }

        guard let incoming else { return }
        let pinnedChanged = incoming.pinned != payload.pinned
        payload = incoming
        hasSynced = true
        WatchSnapshot.write(payload)
        // The Smart Stack widget uses `.never` and relies on this reload; without it the corner
        // would show the previous pinned game until the system happened to refresh it.
        if pinnedChanged { WidgetCenter.shared.reloadTimelines(ofKind: WatchPinnedWidget.kind) }
        watchLinkLog.notice("Adopted \(incoming.follows.count) follow(s) from the phone")
    }

    private func clearCredential(because reason: String) {
        hasCredential = false
        ChessTVAppGroup.defaults.removeObject(forKey: Self.credentialHostKey)
        do {
            try credentials.clear()
            watchLinkLog.notice("Cleared the stored credential: \(reason, privacy: .public)")
        } catch {
            watchLinkLog.error("Could not clear the credential: \(logLabel(for: error), privacy: .public)")
        }
    }
}

extension WatchSyncStore: WCSessionDelegate {

    nonisolated public func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?
    ) {
        if let error {
            watchLinkLog.error("WatchConnectivity activation failed: \(logLabel(for: error), privacy: .public)")
            return
        }
        let context = Self.extract(session.receivedApplicationContext)
        Task { @MainActor in self.adopt(context) }
    }

    nonisolated public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let context = Self.extract(applicationContext)
        Task { @MainActor in self.adopt(context) }
    }
}
#endif
