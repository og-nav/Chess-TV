// What the phone tells the watch.
//
// The phone and the watch share **nothing** at rest: not an App Group, not a Keychain. watchOS is
// a separate device with separate containers, and the only bridge is WatchConnectivity. So every
// fact the watch needs — which follows exist, what they are called, where the server is, and the
// credential that lets it speak to that server — travels in this one payload.
//
// It goes through `updateApplicationContext`, not `sendMessage`: the application context is the
// "latest state wins" channel, it is delivered when the watch app next runs rather than requiring
// both apps to be awake, and it replaces rather than queues. That is exactly the semantics of a
// follow list.
//
// The **credential is a separate key in the context dictionary**, never a field of this payload,
// so that the snapshot this app writes to its own container never contains it; on arrival it goes
// into the watch's Keychain. Note what that does *not* achieve: WatchConnectivity itself persists
// the latest application context on both devices, so as long as the credential rides in the
// context a copy also lives in WCSession's store. The alternative — handing it over only with
// `sendMessage` while the two are reachable — was judged not worth its failure modes for a token
// that only authorises reading and editing this install's own follows. See `WatchSyncStore`.
import Foundation

import FollowKit

/// The keys of the WatchConnectivity application context.
public enum WatchSyncKey {
    /// `Data` — a JSON `WatchSyncPayload`.
    public static let payload = "payload"
    /// `Data` — a JSON `DeviceCredential`. Copied into the Keychain on arrival (WCSession keeps
    /// the latest context too; see the header). The phone includes it in **every** context, because
    /// `updateApplicationContext` replaces rather than queues: a context without it, sent before
    /// the watch had read the one with it, would otherwise take the credential away again.
    public static let credential = "credential"
    /// `Bool` — present and true only when the phone has actively dropped its install identity,
    /// which the server URL changing is the usual cause of. The watch clears its Keychain.
    /// Distinct from the credential key being *absent*, which means "keep what you have".
    public static let clearsCredential = "clearCredential"
    /// `Int` — bumped by the phone on every send so a context that is otherwise identical still
    /// counts as a change. WatchConnectivity drops a context equal to the last one.
    public static let sequence = "seq"
}

/// One follow, with the display text already resolved by the phone.
///
/// The watch does not look players up. Resolving a FIDE id to a name means the FIDE endpoint and a
/// portrait cache, which is a lot of work for a screen that exists to be glanced at; the phone has
/// already done it, so it sends the answer.
public struct WatchFollow: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var target: FollowTarget
    /// "Magnus Carlsen", "Tata Steel Masters", "Carlsen – Nepomniachtchi".
    public var title: String
    /// "Round 5 · live · 14 boards", "Not playing", "Round 6 · tomorrow 14:00".
    public var subtitle: String?
    public var alerts: FollowAlerts

    public init(id: String, target: FollowTarget, title: String, subtitle: String?, alerts: FollowAlerts) {
        self.id = id
        self.target = target
        self.title = title
        self.subtitle = subtitle
        self.alerts = alerts
    }

    public init(follow: Follow, title: String, subtitle: String? = nil) {
        self.init(id: follow.id, target: follow.target, title: title, subtitle: subtitle, alerts: follow.alerts)
    }

    /// Which switch list this follow shows: a player or a game has game alerts, a tournament has
    /// tournament alerts.
    public var isTournament: Bool {
        if case .tournament = target { return true }
        return false
    }
}

public struct WatchSyncPayload: Codable, Sendable, Hashable {
    /// Bumped when the shape changes so an old watch build ignores a payload it cannot read.
    public static let currentVersion = 1

    public var version: Int
    public var updatedAt: Date
    /// Where the follow server lives. Nil means "no server configured"; the watch then shows the
    /// follows it has and disables the switches rather than pretending.
    public var serverBaseURL: URL?
    public var follows: [WatchFollow]
    public var preferences: NotificationPreferences?
    /// The game the phone has pinned, for the Smart Stack widget and the top of the list.
    public var pinned: PinnedGameSnapshot?

    public init(
        version: Int = WatchSyncPayload.currentVersion,
        updatedAt: Date = Date(),
        serverBaseURL: URL? = nil,
        follows: [WatchFollow] = [],
        preferences: NotificationPreferences? = nil,
        pinned: PinnedGameSnapshot? = nil
    ) {
        self.version = version
        self.updatedAt = updatedAt
        self.serverBaseURL = serverBaseURL
        self.follows = follows
        self.preferences = preferences
        self.pinned = pinned
    }

    public var isReadable: Bool { version <= WatchSyncPayload.currentVersion }
}
