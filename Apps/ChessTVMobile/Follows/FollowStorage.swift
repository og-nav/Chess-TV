// Where the follow list, the notification preferences and the queue of edits that have not
// reached the server yet are kept between launches.
//
// The file lives in the app group so the notification extensions and the watch can read the same
// copy. Follows are a few hundred bytes; the read and the write are synchronous on purpose,
// because an async save would let two edits race each other onto disk in the wrong order.
import Foundation
import FollowKit

/// Everything the Following tab needs with no network at all.
struct FollowSnapshot: Codable, Sendable {
    var follows: [Follow] = []
    var preferences: NotificationPreferences = .mobileDefault()
    /// Edits made while the server was unreachable, oldest first.
    var pending: [PendingEdit] = []
    /// When the server last confirmed this list. `nil` means it never has.
    var lastSyncedAt: Date?
    /// Edits the server refused outright, kept so the user can be told.
    ///
    /// Optional, not defaulted: a synthesised `Codable` treats a missing key for a non-optional
    /// property as a decode failure, and `load()` answers an unreadable file with an empty
    /// snapshot — so adding a required field here would silently wipe the follow list of every
    /// install that upgrades.
    var failed: [FailedEdit]?

    init(
        follows: [Follow] = [],
        preferences: NotificationPreferences = .mobileDefault(),
        pending: [PendingEdit] = [],
        lastSyncedAt: Date? = nil,
        failed: [FailedEdit]? = nil
    ) {
        self.follows = follows
        self.preferences = preferences
        self.pending = pending
        self.lastSyncedAt = lastSyncedAt
        self.failed = failed
    }
}

/// An edit the server answered and refused.
///
/// Refusals are kept and shown rather than dropped: "the switch you flipped never reached the
/// server" is a thing the user needs to know, and a queue that quietly forgets is worse than one
/// that complains.
struct FailedEdit: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    /// What the edit was, in the same token-free wording the log uses.
    var summary: String
    /// Why the server said no, already in the app's plain phrasing.
    var reason: String
    var at: Date

    init(id: UUID = UUID(), summary: String, reason: String, at: Date = .now) {
        self.id = id
        self.summary = summary
        self.reason = reason
        self.at = at
    }

    init(edit: PendingEdit, reason: String, at: Date = .now) {
        self.init(id: edit.id, summary: edit.shortDescription, reason: reason, at: at)
    }
}

/// One local change waiting to be told to the server.
struct PendingEdit: Codable, Sendable, Identifiable {
    enum Operation: Codable, Sendable {
        case add(Follow)
        case alerts(followID: String, alerts: FollowAlerts)
        case remove(followID: String)
        case preferences(NotificationPreferences)
    }

    var id: UUID
    var operation: Operation
    /// How many times sending this has failed. Diagnostic only: it is *not* a budget, because a
    /// transient failure must never retire an edit. See `FollowStore.SendFailure`.
    var attempts: Int
    /// Persisted before sending an add. A lost response or process termination cannot prove the
    /// server did nothing, so a later unfollow must retain an idempotent add-then-delete sequence.
    /// Optional so snapshots written before this field existed continue to decode.
    var mayHaveReachedServer: Bool?

    /// Older queues counted failed requests but had no submission marker. Treat those attempts
    /// conservatively too: a transport failure may have happened after the server committed.
    var wasSubmitted: Bool { mayHaveReachedServer == true || attempts > 0 }

    init(id: UUID = UUID(), operation: Operation, attempts: Int = 0, mayHaveReachedServer: Bool? = nil) {
        self.id = id
        self.operation = operation
        self.attempts = attempts
        self.mayHaveReachedServer = mayHaveReachedServer
    }

    /// The follow this edit is about, when it is about one.
    var followID: String? {
        switch operation {
        case .add(let follow): follow.id
        case .alerts(let id, _): id
        case .remove(let id): id
        case .preferences: nil
        }
    }

    /// A line for the log and for the "waiting to sync" row. Carries no token and no name.
    var shortDescription: String {
        switch operation {
        case .add(let follow): "add \(follow.followKind.rawValue)"
        case .alerts: "alerts"
        case .remove: "remove"
        case .preferences: "preferences"
        }
    }
}

protocol FollowStoring: Sendable {
    func load() -> FollowSnapshot
    func save(_ snapshot: FollowSnapshot)
}

/// JSON in the app group container, with ISO-8601 dates so the same file is readable by the
/// server tooling and the extensions without a second date convention.
struct FollowFileStore: FollowStoring {

    /// The group the extensions and the watch widget also read, from the shared sources.
    static let appGroup = ChessTVAppGroup.identifier
    static let fileName = "follows.json"

    let url: URL

    /// The app group container when the entitlement is present, and Application Support when it
    /// is not, so the app still works on a simulator that was built without the group.
    init(appGroup: String = FollowFileStore.appGroup, fileName: String = FollowFileStore.fileName) {
        let manager = FileManager.default
        if let container = manager.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            url = container.appendingPathComponent(fileName)
        } else {
            let support = (try? manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? URL.temporaryDirectory
            url = support.appendingPathComponent(fileName)
            mobileLog.notice("No app group container; follows live in Application Support")
        }
    }

    init(url: URL) { self.url = url }

    /// FollowKit's coders, not this file's own: the snapshot holds `Follow` and
    /// `NotificationPreferences` verbatim, and a second date convention for the same types is
    /// how a file written by one build stops being readable by the next.
    static var encoder: JSONEncoder { FollowJSON.encoder }
    static var decoder: JSONDecoder { FollowJSON.decoder }

    func load() -> FollowSnapshot {
        guard let data = try? Data(contentsOf: url) else { return FollowSnapshot() }
        do {
            return try Self.decoder.decode(FollowSnapshot.self, from: data)
        } catch {
            // A snapshot this app cannot read is a snapshot from a future build, or a truncated
            // write. Starting empty and letting the next sync refill it beats refusing to launch.
            mobileLog.error("Follows on disk are unreadable: \(String(describing: error), privacy: .public)")
            return FollowSnapshot()
        }
    }

    func save(_ snapshot: FollowSnapshot) {
        do {
            let data = try Self.encoder.encode(snapshot)
            try data.write(to: url, options: [.atomic])
        } catch {
            mobileLog.error("Could not write follows: \(String(describing: error), privacy: .public)")
        }
    }
}

/// For tests and previews.
final class InMemoryFollowStore: FollowStoring, @unchecked Sendable {   // @unchecked: guarded by the lock below
    private let lock = NSLock()
    private var snapshot: FollowSnapshot

    init(_ snapshot: FollowSnapshot = FollowSnapshot()) { self.snapshot = snapshot }

    func load() -> FollowSnapshot { lock.withLock { snapshot } }
    func save(_ snapshot: FollowSnapshot) { lock.withLock { self.snapshot = snapshot } }
}
