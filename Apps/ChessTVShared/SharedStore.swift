// What the app, its extensions and the widgets agree to keep in the App Group.
//
// Two containers, same identifier, different devices. `group.com.navin.chesstv` on the **phone**
// is shared by the phone app, the notification service extension, the notification content
// extension and the Live Activity widget extension. `group.com.navin.chesstv` on the **watch** is
// shared by the watch app and the watch widget only. These are separate containers: iOS and
// watchOS do not share App Group storage, and nothing here assumes they do. Everything the watch
// knows arrives over WatchConnectivity (see `WatchSyncPayload`).
//
// Nothing secret lives here. The install token is in the Keychain on each device, and the two
// Keychains are separate too.
import Foundation

import FollowKit

public enum ChessTVAppGroup {
    public static let identifier = "group.com.navin.chesstv"

    /// The group's defaults, or `.standard` if the entitlement is missing. Falling back keeps a
    /// misconfigured build running with per-process settings rather than crashing in an extension.
    public static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }
}

/// The board settings the extensions and widgets need in order to draw the same board the app
/// draws. The **phone app owns these keys**; it must mirror its own `UserDefaults` into the group
/// whenever the Settings screen changes one. The key names match the tvOS app's `AppSettings.Key`
/// so the eventual iCloud mirror has one vocabulary.
public enum SharedAppearanceKey {
    public static let boardTheme = "boardTheme"
    public static let pieceSet = "pieceSet"
    public static let coordinates = "coordinates"
    public static let flipBoard = "flipBoard"
}

/// The last activity/pinned-game snapshot, so a widget has something to draw without the app
/// running. Written by `LiveActivityController` on the phone and by the watch app on the watch.
public enum SharedSnapshotKey {
    public static let pinnedGame = "pinnedGameSnapshot"
    /// Set by the phone app; the watch's copy arrives in the sync payload instead.
    public static let serverBaseURL = "followServerBaseURL"
    /// Activity calls the follow server has not accepted yet. See `ActivityWorkQueue`.
    public static let pendingActivityWork = "pendingActivityWork"
}

/// A game the user pinned: enough to draw a board, a pair of names and a pair of clocks with no
/// network. Small on purpose — it is read by a widget with a tight budget.
public struct PinnedGameSnapshot: Codable, Sendable, Hashable {
    public var roundId: String
    public var gameId: String
    public var tourName: String
    public var roundName: String
    public var whiteName: String
    public var blackName: String
    public var whiteTitle: String?
    public var blackTitle: String?
    public var state: LiveActivityState

    public init(
        roundId: String, gameId: String, tourName: String, roundName: String,
        whiteName: String, blackName: String, whiteTitle: String? = nil, blackTitle: String? = nil,
        state: LiveActivityState
    ) {
        self.roundId = roundId
        self.gameId = gameId
        self.tourName = tourName
        self.roundName = roundName
        self.whiteName = whiteName
        self.blackName = blackName
        self.whiteTitle = whiteTitle
        self.blackTitle = blackTitle
        self.state = state
    }
}

/// Reads and writes the App Group. Every accessor tolerates an empty or corrupt store, because a
/// widget that throws is a widget that shows "Unable to load".
public enum SharedStore {

    // MARK: - Appearance

    public static func boardThemeName(defaults: UserDefaults = ChessTVAppGroup.defaults) -> String {
        defaults.string(forKey: SharedAppearanceKey.boardTheme) ?? "Sage"
    }

    public static func pieceSetName(defaults: UserDefaults = ChessTVAppGroup.defaults) -> String {
        defaults.string(forKey: SharedAppearanceKey.pieceSet) ?? "cburnett"
    }

    /// Coordinates default to off in a notification: at 600 px the board is small enough that the
    /// labels cost more than they explain.
    public static func showsCoordinates(defaults: UserDefaults = ChessTVAppGroup.defaults) -> Bool {
        defaults.object(forKey: SharedAppearanceKey.coordinates) as? Bool ?? false
    }

    public static func flipBoard(defaults: UserDefaults = ChessTVAppGroup.defaults) -> Bool {
        defaults.bool(forKey: SharedAppearanceKey.flipBoard)
    }

    /// Called by the phone app when the Settings screen changes a board setting, so the next push
    /// renders in the colours the user just chose.
    public static func writeAppearance(
        boardThemeName: String, pieceSetName: String, coordinates: Bool, flipBoard: Bool,
        defaults: UserDefaults = ChessTVAppGroup.defaults
    ) {
        defaults.set(boardThemeName, forKey: SharedAppearanceKey.boardTheme)
        defaults.set(pieceSetName, forKey: SharedAppearanceKey.pieceSet)
        defaults.set(coordinates, forKey: SharedAppearanceKey.coordinates)
        defaults.set(flipBoard, forKey: SharedAppearanceKey.flipBoard)
    }

    // MARK: - The pinned game

    public static func pinnedGame(defaults: UserDefaults = ChessTVAppGroup.defaults) -> PinnedGameSnapshot? {
        guard let data = defaults.data(forKey: SharedSnapshotKey.pinnedGame) else { return nil }
        return try? FollowJSON.decoder.decode(PinnedGameSnapshot.self, from: data)
    }

    public static func setPinnedGame(_ snapshot: PinnedGameSnapshot?, defaults: UserDefaults = ChessTVAppGroup.defaults) {
        guard let snapshot else {
            defaults.removeObject(forKey: SharedSnapshotKey.pinnedGame)
            return
        }
        guard let data = try? FollowJSON.encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: SharedSnapshotKey.pinnedGame)
    }

    // MARK: - Server

    public static func serverBaseURL(defaults: UserDefaults = ChessTVAppGroup.defaults) -> URL? {
        defaults.string(forKey: SharedSnapshotKey.serverBaseURL).flatMap(URL.init(string:))
    }

    public static func setServerBaseURL(_ url: URL?, defaults: UserDefaults = ChessTVAppGroup.defaults) {
        defaults.set(url?.absoluteString, forKey: SharedSnapshotKey.serverBaseURL)
    }

    // MARK: - Activity calls the server has not accepted yet

    public static func pendingActivityWork(defaults: UserDefaults = ChessTVAppGroup.defaults) -> ActivityWorkQueue {
        guard let data = defaults.data(forKey: SharedSnapshotKey.pendingActivityWork) else { return ActivityWorkQueue() }
        return (try? FollowJSON.decoder.decode(ActivityWorkQueue.self, from: data)) ?? ActivityWorkQueue()
    }

    public static func setPendingActivityWork(
        _ queue: ActivityWorkQueue, defaults: UserDefaults = ChessTVAppGroup.defaults
    ) {
        guard !queue.isEmpty else {
            defaults.removeObject(forKey: SharedSnapshotKey.pendingActivityWork)
            return
        }
        guard let data = try? FollowJSON.encoder.encode(queue) else { return }
        defaults.set(data, forKey: SharedSnapshotKey.pendingActivityWork)
    }
}

// MARK: - The retry queue for activity registrations

/// One call to the follow server about a Live Activity that has not succeeded yet.
///
/// Both kinds of call fail silently when they are dropped, which is why they are queued rather
/// than logged and forgotten. A `.register` that never lands is an activity that sits on the Lock
/// Screen and never moves — ActivityKit hands out a push token once and `pushTokenUpdates` will
/// not repeat it just because the request failed. An `.end` that never lands is a watcher the
/// server keeps running for a game nobody is looking at, until the registration expires.
///
/// The queue is written to the App Group, not held in memory, because the ordinary way to be
/// offline at the moment of pinning is to be offline until the app is next launched.
public struct PendingActivityWork: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case register
        case end
    }

    public var kind: Kind
    public var roundId: String
    public var gameId: String
    /// The lowercase-hex ActivityKit token for `.register`; empty for `.end`.
    public var activityToken: String
    /// Which server this call was meant for — `serverBaseURL?.absoluteString ?? ""`.
    ///
    /// A queued call is **never** replayed against a different host. The game ids mean nothing
    /// there, the credential that would authorise it belongs to the old install, and sending an
    /// old host's activity token to a new one is exactly the leak the mobile agent's
    /// `DeviceRegistrar.reset()` exists to prevent.
    public var server: String
    public var attempts: Int
    public var queuedAt: Date
    /// Stable across JSON date precision changes; optional to read queues written by older builds.
    public var workID: String?

    /// Acknowledgements identify one immutable queued operation, including token rotations.
    public var id: String { workID ?? "\(server)|\(kind.rawValue)|\(gameId)|\(activityToken)|\(queuedAt.timeIntervalSinceReferenceDate)" }

    public init(
        kind: Kind, roundId: String = "", gameId: String, activityToken: String = "",
        server: String, attempts: Int = 0, queuedAt: Date = Date()
    ) {
        self.kind = kind
        self.roundId = roundId
        self.gameId = gameId
        self.activityToken = activityToken
        self.server = server
        self.attempts = attempts
        self.queuedAt = queuedAt
        self.workID = UUID().uuidString
    }
}

/// The queue itself: coalesced, ordered, durable, and pure — no ActivityKit, no network, no clock — so
/// the retry rules can be tested without either.
public struct ActivityWorkQueue: Codable, Sendable, Hashable {

    public private(set) var items: [PendingActivityWork]

    public init(items: [PendingActivityWork] = []) { self.items = items }

    public var isEmpty: Bool { items.isEmpty }

    /// Adds work, replacing any earlier call of the same kind for the same game.
    ///
    /// Two details that are rules rather than tidying:
    ///
    ///   * an `.end` removes a queued `.register` for the same game — the activity is over, and
    ///     registering a token for it would hand the server a watcher to immediately retire;
    ///   * a replacement **keeps the attempt count**. A token that rotates every few seconds while
    ///     the server is down must not keep resetting the retry budget.
    public mutating func enqueue(_ work: PendingActivityWork) {
        if work.kind == .end {
            items.removeAll { $0.kind == .register && $0.gameId == work.gameId && $0.server == work.server }
        }
        if let index = items.firstIndex(where: { $0.kind == work.kind && $0.gameId == work.gameId && $0.server == work.server }) {
            var merged = work
            merged.attempts = items[index].attempts
            merged.queuedAt = items[index].queuedAt
            if merged.activityToken == items[index].activityToken { merged.workID = items[index].workID }
            items[index] = merged
        } else {
            items.append(work)
        }
    }

    /// Called when a call succeeds, or when the server says there is nothing of that name to end.
    public mutating func remove(_ work: PendingActivityWork) {
        items.removeAll { $0.id == work.id }
    }

    public func contains(_ work: PendingActivityWork) -> Bool { items.contains { $0.id == work.id } }

    /// Drops everything meant for another host, which is what a server URL change means.
    public mutating func keep(server: String) {
        items.removeAll { $0.server != server }
    }

    /// Records a failed attempt.
    /// Transient failures never discard work. The controller bounds retries per foreground run.
    /// Returns false only when newer work superseded this call while it was in flight.
    @discardableResult
    public mutating func recordFailure(of work: PendingActivityWork) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == work.id && $0.server == work.server }) else {
            return false
        }
        items[index].attempts = min(items[index].attempts, 999) + 1
        return true
    }
}
