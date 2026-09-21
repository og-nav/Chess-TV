// The phone's half of the WatchConnectivity link.
//
// This is the API the iOS app calls. Everything else about the watch is the watch's problem.
//
//     PhoneWatchBridge.shared.activate()                       // once, at launch
//     PhoneWatchBridge.shared.sync(                            // whenever follows or prefs change
//         follows: watchFollows,
//         preferences: preferences,
//         serverBaseURL: serverURL,
//         pinned: LiveActivityController.shared.pinned,
//         credential: credential                               // after registering; see below
//     )
//
// **The bridge retains the latest complete context and the current credential**, and rebuilds the
// context from both on every send. That is not an optimisation, it is the correctness rule:
//
//   * `updateApplicationContext` replaces rather than queues, so a context sent without the
//     credential moments after one sent with it used to *overwrite* the credential before the
//     watch had seen either. Now every context carries it.
//   * a watch that is paired, or has the app installed, later — a new watch, a reinstall, a watch
//     that was simply not set up yet when the phone first synced — used to get nothing until the
//     follow list happened to change. Now the retained context is replayed the moment the session
//     reports a usable watch.
//   * a credential is scoped to the host that minted it. Changing the server URL clears the
//     retained credential *and* tells the watch to clear its copy, so an old host's install token
//     is never presented to a new one.
//
// `updateApplicationContext` throws if the session is not activated or the watch app is not
// installed; both are ordinary states, not errors worth surfacing, so they are logged and the
// context is kept for the replay.
#if canImport(WatchConnectivity) && os(iOS)
import Foundation
import WatchConnectivity

import FollowKit

@MainActor
public final class PhoneWatchBridge: NSObject {

    public static let shared = PhoneWatchBridge()

    /// True when there is a paired watch with this app installed on it. The Settings screen uses
    /// it to decide whether to mention the watch at all.
    public private(set) var isWatchReachableForSync = false

    private static let credentialHostKey = "phoneWatchCredentialHost"
    private let credentialStore = KeychainCredentialStore(service: "com.navin.chesstv.watch-bridge")

    public override init() {
        super.init()
        if let payload = WatchSnapshot.read() {
            latestPayload = try? FollowJSON.encoder.encode(payload)
            lastServer = payload.serverBaseURL?.absoluteString ?? ""
            if ChessTVAppGroup.defaults.string(forKey: Self.credentialHostKey) == lastServer,
               let credential = try? credentialStore.load() {
                retainedCredential = try? FollowJSON.encoder.encode(credential)
            }
        }
        clearsCredential = retainedCredential == nil
    }

    private var session: WCSession?
    private var sequence = 0

    /// The latest complete payload, kept **after** a successful send as well as after a failed
    /// one, because the next watch to appear needs it as much as this one did.
    private var latestPayload: Data?
    /// The current credential, included in every context built from here on.
    private var retainedCredential: Data?
    /// Set when the host changed and no new credential has arrived: the next context tells the
    /// watch to wipe the token it holds for the old host.
    private var clearsCredential = false
    /// The host the retained credential belongs to. nil means "nothing synced yet in this launch",
    /// which is not a change and must not trigger a clear.
    private var lastServer: String?
    /// Whether the watch has a usable link right now, so a transition into usable is a replay.
    private var wasUsable = false

    public func activate() {
        guard WCSession.isSupported() else {
            watchLinkLog.notice("WatchConnectivity is not supported on this device")
            return
        }
        let session = WCSession.default
        session.delegate = self
        self.session = session
        session.activate()
    }

    /// Sends the current state to the watch. Safe to call often: WatchConnectivity coalesces, and
    /// the sequence number makes sure an otherwise-identical context is still counted as new.
    ///
    /// - Parameter credential: pass it whenever the app has one — after registering, and on any
    ///   launch where it reads one back out of the Keychain. Passing nil keeps whatever the bridge
    ///   already holds; use `setCredential(nil)` to actively clear it.
    public func sync(
        follows: [WatchFollow],
        preferences: NotificationPreferences?,
        serverBaseURL: URL?,
        pinned: PinnedGameSnapshot?,
        credential: DeviceCredential? = nil
    ) {
        let payload = WatchSyncPayload(
            updatedAt: Date(),
            serverBaseURL: serverBaseURL,
            follows: follows,
            preferences: preferences,
            pinned: pinned
        )
        guard let encoded = try? FollowJSON.encoder.encode(payload) else {
            watchLinkLog.error("Could not encode the watch payload")
            return
        }

        let identity = serverBaseURL?.absoluteString ?? ""
        if let lastServer, lastServer != identity {
            // A different host. The credential we hold was minted by the old one and means nothing
            // to the new one, and a watch left holding it would keep presenting it.
            retainedCredential = nil
            ChessTVAppGroup.defaults.removeObject(forKey: Self.credentialHostKey)
            try? credentialStore.clear()
            clearsCredential = true
            watchLinkLog.notice("The follow server changed; the watch will be told to clear its credential")
        }
        lastServer = identity

        if let credential, let data = try? FollowJSON.encoder.encode(credential), !credential.installToken.isEmpty {
            retainedCredential = data
            do {
                try credentialStore.save(credential)
                ChessTVAppGroup.defaults.set(lastServer, forKey: Self.credentialHostKey)
            } catch {
                ChessTVAppGroup.defaults.removeObject(forKey: Self.credentialHostKey)
                watchLinkLog.error("Could not persist the Watch credential: \(logLabel(for: error), privacy: .public)")
            }
            clearsCredential = false
        }

        latestPayload = encoded
        WatchSnapshot.write(payload)
        deliver()
    }

    /// Sets, or clears, the credential the watch should hold.
    ///
    /// Call with nil when the install identity is dropped — a server change, a reset, a sign-out —
    /// so the watch wipes its Keychain rather than keeping a token for a host it no longer talks
    /// to. The change is pushed at once, with the payload already retained.
    public func setCredential(_ credential: DeviceCredential?) {
        if let credential, let data = try? FollowJSON.encoder.encode(credential), !credential.installToken.isEmpty {
            retainedCredential = data
            do {
                try credentialStore.save(credential)
                ChessTVAppGroup.defaults.set(lastServer, forKey: Self.credentialHostKey)
            } catch {
                ChessTVAppGroup.defaults.removeObject(forKey: Self.credentialHostKey)
                watchLinkLog.error("Could not persist the Watch credential: \(logLabel(for: error), privacy: .public)")
            }
            clearsCredential = false
        } else {
            retainedCredential = nil
            ChessTVAppGroup.defaults.removeObject(forKey: Self.credentialHostKey)
            try? credentialStore.clear()
            clearsCredential = true
        }
        guard let data = latestPayload,
              var payload = try? FollowJSON.decoder.decode(WatchSyncPayload.self, from: data) else { return }
        payload.updatedAt = Date()
        latestPayload = try? FollowJSON.encoder.encode(payload)
        WatchSnapshot.write(payload)
        deliver()
    }

    /// A watch was paired, unpaired, or the app was installed or removed on it.
    private func watchStateChanged(usable: Bool) {
        let becameUsable = usable && !wasUsable
        wasUsable = usable
        isWatchReachableForSync = usable
        // A newly usable watch is a watch that has never seen any of this — most often because it
        // was set up, or the app installed on it, after the phone had already synced.
        guard becameUsable, latestPayload != nil else { return }
        watchLinkLog.notice("A watch became available; replaying the latest context")
        deliver()
    }

    /// Builds a fresh context out of the retained parts and hands it to WatchConnectivity.
    ///
    /// The sequence number is bumped here rather than in `sync`, so a replay of the same payload is
    /// still a new context as far as WatchConnectivity is concerned — it drops one equal to the
    /// last.
    private func deliver() {
        guard let payload = latestPayload else { return }
        guard let session, session.activationState == .activated else {
            watchLinkLog.notice("Holding the watch context until the session activates")
            return
        }
        guard session.isPaired, session.isWatchAppInstalled else {
            isWatchReachableForSync = false
            wasUsable = false
            watchLinkLog.notice("No watch app installed; holding the context until there is one")
            return
        }

        sequence += 1
        var context: [String: Any] = [
            WatchSyncKey.payload: payload,
            WatchSyncKey.sequence: sequence,
        ]
        if let retainedCredential {
            context[WatchSyncKey.credential] = retainedCredential
        } else {
            context[WatchSyncKey.clearsCredential] = true
        }

        do {
            try session.updateApplicationContext(context)
            isWatchReachableForSync = true
            wasUsable = true
            // The count and the sequence, never the contents: the context holds a credential.
            watchLinkLog.notice("Sent watch context #\(self.sequence)")
        } catch {
            // The payload and the credential stay retained, so the next activation, watch-state
            // change or sync sends them again.
            watchLinkLog.error("Could not send the watch context: \(logLabel(for: error), privacy: .public)")
        }
    }
}

extension PhoneWatchBridge: WCSessionDelegate {

    nonisolated public func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?
    ) {
        if let error {
            watchLinkLog.error("WatchConnectivity activation failed: \(logLabel(for: error), privacy: .public)")
        }
        // Read off the session here: `WCSession` is not `Sendable`, a `Bool` is.
        let usable = session.isPaired && session.isWatchAppInstalled
        Task { @MainActor in self.watchStateChanged(usable: usable) }
    }

    nonisolated public func sessionDidBecomeInactive(_ session: WCSession) {
        watchLinkLog.notice("WatchConnectivity session became inactive")
        Task { @MainActor in self.watchStateChanged(usable: false) }
    }

    /// The user switched to a different watch. Re-activating gets a session for the new one; the
    /// activation callback then replays the retained context, which includes the credential the new
    /// watch does not have.
    nonisolated public func sessionDidDeactivate(_ session: WCSession) {
        watchLinkLog.notice("WatchConnectivity session deactivated; re-activating for the new watch")
        Task { @MainActor in self.watchStateChanged(usable: false) }
        WCSession.default.activate()
    }

    nonisolated public func sessionWatchStateDidChange(_ session: WCSession) {
        let usable = session.isPaired && session.isWatchAppInstalled
        Task { @MainActor in self.watchStateChanged(usable: usable) }
    }
}
#endif
