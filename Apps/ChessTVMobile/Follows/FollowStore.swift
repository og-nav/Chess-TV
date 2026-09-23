// The Following tab's truth.
//
// Every screen reads this object and never the network. An edit lands locally, is written to
// disk, and is queued for the server; the queue drains whenever the app comes forward or the
// server becomes reachable. With no server configured at all the app is still a perfectly good
// follow list — it just says so, rather than pretending an alert will arrive.
import Foundation
import FollowKit
import Observation

@MainActor
@Observable
final class FollowStore {

    /// What the Following tab's footer says about the server.
    enum SyncState: Equatable, Sendable {
        /// No server URL configured. Follows are local and honest about it.
        case noServer
        /// A server is configured and we have not talked to it yet.
        case neverSynced
        case syncing
        case synced(Date)
        case failed(String)
    }

    /// What a failed send means for the edit at the head of the queue.
    ///
    /// The distinction is the whole of offline durability. **A transient failure never costs an
    /// edit, however many times it happens**: a follow made in a tunnel on Monday is still the
    /// user's intent on Friday, and an attempt counter that eventually throws it away would turn
    /// a bad week of signal into silently missing follows. Only a server that has actually
    /// answered, and refused, retires an edit — and then visibly.
    enum SendFailure: Equatable, Sendable {
        /// The server has already done it. A `DELETE` of a follow it no longer has is the goal
        /// state, not an error.
        case alreadyDone
        /// Offline, the server is down, this phone is not registered yet, the address is wrong.
        /// Keep the edit and stop draining; the next activation tries again.
        case retry
        /// The server understood and refused. Dropping this quietly would be a lie, so the edit
        /// moves to `failedEdits` and the Following footer says so.
        case rejected(String)
    }

    /// How many drain/read passes one reconcile will make before giving up and leaving the rest
    /// to the next activation. Each pass exists because an edit made *during* the round trip must
    /// not be overwritten by the answer to a question asked before it.
    static let reconcilePasses = 3

    private(set) var follows: [Follow] = []
    private(set) var preferences: NotificationPreferences = .mobileDefault()
    private(set) var state: SyncState = .noServer
    /// Edits the server has not been told about yet.
    private(set) var pendingCount = 0
    /// Edits the server refused outright. Kept so the user is told rather than left believing a
    /// change landed; cleared by `dismissFailures()`.
    private(set) var failedEdits: [FailedEdit] = []

    @ObservationIgnored private let storage: any FollowStoring
    @ObservationIgnored private var pending: [PendingEdit] = []
    @ObservationIgnored private var lastSyncedAt: Date?
    @ObservationIgnored private var client: (any FollowServerClient)?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    /// Bumped whenever the server this store talks to changes. A sync that started under an older
    /// generation must never write its result: that result came from the previous host.
    @ObservationIgnored private var generation = 0
    /// Bumped by every local edit. `runReconcile` compares it across its awaits, so a follow added
    /// while `GET /v1/follows` was in flight is not erased by the answer.
    @ObservationIgnored private var editGeneration = 0
    /// Set when a sync is asked for while one is running, so the edit that asked for it is not
    /// left waiting for the *next* activation.
    @ObservationIgnored private var needsAnotherReconcile = false
    /// The edit currently on the wire. Compaction must not cancel it — the server will act on it
    /// whatever the queue says — so `PendingQueue` is told which one it is.
    @ObservationIgnored private var inFlightEditID: UUID?
    /// Called whenever the list or the preferences change, so the watch and the app group's copy
    /// are never a launch behind. Set by `AppEnvironment`.
    @ObservationIgnored var didChange: (() -> Void)?
    /// The server no longer accepts this install's token. The registrar owns the identity, so
    /// the store only reports it; `AppEnvironment` wires the two together.
    @ObservationIgnored var unauthorized: (() -> Void)?

    init(storage: any FollowStoring = FollowFileStore(), client: (any FollowServerClient)? = nil) {
        self.storage = storage
        self.client = client
        let snapshot = storage.load()
        follows = snapshot.follows
        preferences = snapshot.preferences
        pending = snapshot.pending
        pendingCount = snapshot.pending.count
        failedEdits = snapshot.failed ?? []
        lastSyncedAt = snapshot.lastSyncedAt
        state = client == nil ? .noServer : (lastSyncedAt.map(SyncState.synced) ?? .neverSynced)
    }

    // MARK: - Server wiring

    var hasServer: Bool { client != nil }

    /// Points the store at a server, or at none. Changing it starts a sync; clearing it leaves
    /// every follow in place and says the app is offline by configuration, not by accident.
    ///
    /// The old client's sync is cancelled *and* generation-invalidated. Cancellation alone is not
    /// enough: a request already past its last suspension point will return normally, and without
    /// the generation check that answer — the previous host's follow list, or an id the previous
    /// host minted — would be written into a store now pointed somewhere else.
    func setClient(_ client: (any FollowServerClient)?) {
        invalidateInFlightSync()
        self.client = client
        guard client != nil else {
            state = .noServer
            return
        }
        state = lastSyncedAt.map(SyncState.synced) ?? .neverSynced
        reconcile()
    }

    /// The app now talks to a *different* server, so this install is new there.
    ///
    /// The old host's follow ids mean nothing to the new one, and the new one's list — almost
    /// certainly empty — is not an instruction to forget what the user follows. So every local
    /// follow goes back to a local id and is re-queued as an add, along with the preferences.
    /// The first sync against the new host therefore uploads the list rather than being wiped by
    /// it. Call before `setClient` with the new client.
    func serverIdentityChanged() {
        invalidateInFlightSync()
        lastSyncedAt = nil
        failedEdits = []
        follows = follows.map { FollowFactory.replacingID($0, with: FollowFactory.localID()) }
        pending = follows.map { PendingEdit(operation: .add($0)) }
        pending.append(PendingEdit(operation: .preferences(preferences)))
        pendingCount = pending.count
        editGeneration &+= 1
        state = client == nil ? .noServer : .neverSynced
        persist()
        publish()
        mobileLog.notice("Server changed: re-queued \(self.follows.count) follows for a new install")
    }

    private func invalidateInFlightSync() {
        generation &+= 1
        syncTask?.cancel()
        syncTask = nil
        needsAnotherReconcile = false
        inFlightEditID = nil
    }

    // MARK: - Reading

    func follow(id: String) -> Follow? { follows.first { $0.id == id } }

    func follow(for target: FollowTarget) -> Follow? { follows.first { $0.target == target } }

    /// How many follows other than `id` have big swings on, against the server's per-install cap.
    func swingFollowCount(excluding id: String?) -> Int {
        follows.filter { $0.alerts.evalSwings && $0.id != id }.count
    }

    func isFollowing(_ target: FollowTarget) -> Bool { follow(for: target) != nil }

    /// The follows of one kind, newest first — the order the Following tab lists them in.
    func follows(ofKind kind: FollowKind) -> [Follow] {
        follows.filter { $0.followKind == kind }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Players and single games share the top section; tournaments have their own below.
    var boardFollows: [Follow] {
        follows.filter { $0.followKind.isBoardShaped }.sorted { $0.createdAt > $1.createdAt }
    }

    var tournamentFollows: [Follow] { follows(ofKind: .tournament) }

    // MARK: - Editing

    /// Follows `target` if it is not already followed, inheriting the Settings defaults for its
    /// kind. Returns the follow either way, so a button can go straight to its switch list.
    @discardableResult
    func add(_ target: FollowTarget, now: Date = .now) -> Follow {
        if let existing = follow(for: target) { return existing }
        let follow = FollowFactory.make(target: target, preferences: preferences, now: now)
        follows.append(follow)
        enqueue(.add(follow))
        mobileLog.notice("Following a \(follow.followKind.rawValue, privacy: .public)")
        return follow
    }

    func remove(id: String) {
        guard follows.contains(where: { $0.id == id }) else { return }
        follows.removeAll { $0.id == id }
        enqueue(.remove(followID: id))
        mobileLog.notice("Unfollowed")
    }

    func remove(_ target: FollowTarget) {
        guard let follow = follow(for: target) else { return }
        remove(id: follow.id)
    }

    /// The switch list writing back one follow's alerts.
    ///
    /// Clamped on the way in, to the ranges the server enforces, so the copy on screen and the
    /// copy the server will store are the same object and a no-op edit is recognised as one.
    func setAlerts(_ alerts: FollowAlerts, for id: String) {
        let alerts = alerts.clamped()
        guard let index = follows.firstIndex(where: { $0.id == id }), follows[index].alerts != alerts else { return }
        follows[index].alerts = alerts
        enqueue(.alerts(followID: id, alerts: alerts))
    }

    func setPreferences(_ preferences: NotificationPreferences) {
        self.preferences = preferences
        enqueue(.preferences(preferences))
    }

    /// Quiet hours are enforced by the server in the zone the phone last reported. A phone that
    /// has travelled reports the new one on its next activation, so the footer's "in this
    /// phone's time zone" stays true.
    func refreshTimeZone(_ zone: TimeZone = .current) {
        guard preferences.timeZoneIdentifier != zone.identifier else { return }
        var updated = preferences
        updated.timeZoneIdentifier = zone.identifier
        setPreferences(updated)
        mobileLog.notice("Time zone changed to \(zone.identifier, privacy: .public); preferences re-queued")
    }

    /// Settings changed a default and the user chose to apply it to what they already follow.
    /// - Returns: how many follows were rewritten, for the confirmation the sheet shows.
    @discardableResult
    func applyDefaults(_ alerts: FollowAlerts, toExisting kind: FollowKind) -> Int {
        var changed = 0
        for follow in follows where follow.followKind == kind && follow.alerts != alerts {
            setAlerts(alerts, for: follow.id)
            changed += 1
        }
        if changed > 0 { mobileLog.notice("Applied \(kind.rawValue, privacy: .public) defaults to \(changed) follows") }
        return changed
    }

    /// How many existing follows a default change would rewrite, for the offer's wording.
    func countAffectedByDefaults(_ alerts: FollowAlerts, kind: FollowKind) -> Int {
        follows.count { $0.followKind == kind && $0.alerts != alerts }
    }

    // MARK: - Syncing

    /// Kicks off a reconcile in the background. Safe to call from `onAppear`, a pull to refresh
    /// and the scene becoming active; a sync already running is left alone.
    func reconcile() {
        guard client != nil else { return }
        guard syncTask == nil else {
            // A sync is already running and was started before this edit existed. Remembering the
            // ask is what stops the edit sitting until the next activation.
            needsAnotherReconcile = true
            return
        }
        let myGeneration = generation
        syncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.needsAnotherReconcile = false
                await self.runReconcile(generation: myGeneration)
            } while self.needsAnotherReconcile
                && self.client != nil
                && !Task.isCancelled
                && myGeneration == self.generation
            // Only clear the handle if it is still ours: `setClient` may have replaced it while
            // this task was winding down, and nilling the new one would strand it.
            if myGeneration == self.generation { self.syncTask = nil }
        }
    }

    /// The same thing, awaited — what `.refreshable` and the tests use.
    func reconcileAndWait() async {
        reconcile()
        await syncTask?.value
    }

    private func runReconcile(generation: Int) async {
        guard let client else { state = .noServer; return }
        state = .syncing
        do {
            // Several passes, because the server's answer describes the moment the question was
            // asked. If the user followed something while `GET /v1/follows` was in flight, that
            // answer predates the edit and adopting it would erase it. So: drain, note the edit
            // generation, read, and only adopt when nothing local moved in between.
            for _ in 0..<Self.reconcilePasses {
                try await drainQueue(with: client, generation: generation)
                let stamp = editGeneration
                let remote = try await client.follows()
                guard generation == self.generation, !Task.isCancelled else { return }
                let remotePreferences = try await client.preferences()
                guard generation == self.generation, !Task.isCancelled else { return }
                guard stamp == editGeneration, pending.isEmpty else { continue }
                // The queue is empty and nothing changed under us, so the server holds every
                // local edit and its copy is the one to keep. Anything else would resurrect a
                // follow the user just deleted.
                follows = remote.sorted { $0.createdAt > $1.createdAt }
                preferences = remotePreferences
                lastSyncedAt = .now
                state = .synced(lastSyncedAt ?? .now)
                persist()
                publish()
                mobileLog.notice("Follows reconciled: \(self.follows.count) follows")
                return
            }
            // Edits kept arriving faster than the round trip. Nothing is lost — they are all on
            // disk and queued — so say where we stand and, if anything is still queued, ask the
            // loop in `reconcile()` for one more pass rather than leaving it until the next
            // activation.
            guard generation == self.generation else { return }
            state = lastSyncedAt.map(SyncState.synced) ?? .neverSynced
            needsAnotherReconcile = !pending.isEmpty
            mobileLog.notice("Follow sync deferred: edits arrived faster than the server answered")
        } catch {
            guard generation == self.generation, !(error is CancellationError), !Task.isCancelled else { return }
            persist()
            state = .failed(Self.message(for: error))
            mobileLog.error("Follow sync failed: \(Self.message(for: error), privacy: .public)")
            if case FollowServerError.unauthorized = error { unauthorized?() }
        }
    }

    /// Sends the queued edits oldest first, stopping at the first transient failure so ordering is
    /// never broken.
    ///
    /// Two things here are load-bearing. **Edits are acknowledged by their own id, not by
    /// position**: `send` suspends, and a user edit during that suspension can collapse the queue
    /// underneath it, so `removeFirst()` would delete a *different*, unsent edit. And a transient
    /// failure only counts attempts — it never retires the edit.
    private func drainQueue(with client: any FollowServerClient, generation: Int) async throws {
        while let edit = pending.first {
            guard generation == self.generation, !Task.isCancelled else { throw CancellationError() }
            let editID = edit.id
            if case .add = edit.operation, pending[0].mayHaveReachedServer != true {
                // Persist before crossing the network boundary. Cancellation or a crash may
                // prevent any reply while the server has already applied the add.
                pending[0].mayHaveReachedServer = true
                persist()
            }
            do {
                inFlightEditID = editID
                defer { if inFlightEditID == editID { inFlightEditID = nil } }
                try await send(edit, with: client, generation: generation)
            } catch {
                if error is CancellationError { throw error }
                guard generation == self.generation else { throw CancellationError() }
                // Compacted away while it was in flight: whatever it asked for has been
                // superseded locally, so there is nothing to retry and nothing to report.
                guard let index = pending.firstIndex(where: { $0.id == editID }) else { continue }
                switch Self.classify(error, for: pending[index].operation) {
                case .alreadyDone:
                    pending.remove(at: index)
                case .rejected(let reason):
                    let dropped = pending.remove(at: index)
                    failedEdits.append(FailedEdit(edit: dropped, reason: reason))
                    mobileLog.error("The server refused a queued \(dropped.shortDescription, privacy: .public) edit: \(reason, privacy: .public)")
                case .retry:
                    pending[index].attempts += 1
                    pendingCount = pending.count
                    persist()
                    throw error
                }
                pendingCount = pending.count
                persist()
                publish()
                continue
            }
            guard generation == self.generation else { throw CancellationError() }
            if let index = pending.firstIndex(where: { $0.id == editID }) { pending.remove(at: index) }
            pendingCount = pending.count
            persist()
        }
    }

    /// Whether a failed send costs the edit. See `SendFailure`.
    static func classify(_ error: Error, for operation: PendingEdit.Operation) -> SendFailure {
        if let serverError = error as? FollowServerError {
            switch serverError {
            case .notFound:
                // Deleting something the server no longer has is the outcome we wanted, and an
                // alert change to a follow the server has lost will never apply. An add or a
                // preferences write has no server-side row to be missing, so a 404 there is a
                // route or proxy problem: keep the edit, or the follow would be dropped from the
                // queue and then wiped by the first successful reconcile.
                switch operation {
                case .remove: return .alreadyDone
                case .alerts: return .rejected("The server has no record of that follow")
                default: return .retry
                }
            case .rejected(let reason):
                // The server's own words when it gave any: "at most 10 follows" says what to do.
                return .rejected(reason.isEmpty ? "The server refused the change" : reason)
            // Everything below is worth trying again: the phone is offline, the host is down,
            // the address is wrong and can be corrected, or registration has not happened yet.
            case .unavailable, .malformedResponse, .notRegistered, .unauthorized, .insecureBaseURL:
                return .retry
            }
        }
        return .retry
    }

    /// Clears the refused-edit list once the user has seen it.
    func dismissFailures() {
        guard !failedEdits.isEmpty else { return }
        failedEdits = []
        persist()
    }

    private func send(_ edit: PendingEdit, with client: any FollowServerClient, generation: Int) async throws {
        switch edit.operation {
        case .add(let follow):
            let created = try await client.add(follow)
            guard generation == self.generation, !Task.isCancelled else { throw CancellationError() }
            if created.id != follow.id {
                // The server minted its own id. Rewrite the local copy and everything still
                // queued against the local one, or a later switch flip would address a follow
                // the server has never heard of.
                if let index = follows.firstIndex(where: { $0.id == follow.id }) {
                    follows[index] = FollowFactory.replacingID(follows[index], with: created.id)
                }
                pending = PendingQueue.rewriting(localID: follow.id, to: created.id, in: pending)
            }
        case .alerts(let followID, let alerts):
            guard let local = follows.first(where: { $0.id == followID }) else { return }
            _ = try await client.update(FollowFactory.replacingAlerts(local, with: alerts))
        case .remove(let followID):
            try await client.remove(id: followID)
        case .preferences(let preferences):
            try await client.setPreferences(preferences)
        }
    }

    private func enqueue(_ operation: PendingEdit.Operation) {
        pending = PendingQueue.appending(PendingEdit(operation: operation), to: pending, inFlight: inFlightEditID)
        pendingCount = pending.count
        // A running reconcile compares this across its awaits; bumping it is what stops the
        // server's older answer from overwriting the edit just made.
        editGeneration &+= 1
        persist()
        publish()
        reconcile()
    }

    private func persist() {
        storage.save(
            FollowSnapshot(
                follows: follows,
                preferences: preferences,
                pending: pending,
                lastSyncedAt: lastSyncedAt,
                failed: failedEdits.isEmpty ? nil : failedEdits
            )
        )
    }

    private func publish() {
        didChange?()
    }

    /// A short, honest line for the footer. Never carries a token: the transport is described,
    /// not the credential. `nonisolated` because the health probe, which runs off the main
    /// actor, words its failures the same way.
    nonisolated static func message(for error: Error) -> String {
        if let serverError = error as? FollowServerError {
            switch serverError {
            case .insecureBaseURL: return "That address isn\u{2019}t https"
            case .notRegistered: return "This phone hasn\u{2019}t registered yet"
            case .unauthorized: return "The server doesn\u{2019}t know this phone any more"
            case .notFound: return "The server has no record of that"
            case .rejected: return "The server refused the change"
            case .unavailable: return "Can\u{2019}t reach the server"
            case .malformedResponse: return "The server answered with something unexpected"
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost: return "No connection"
            case .timedOut: return "The server timed out"
            case .cannotFindHost, .cannotConnectToHost: return "Can\u{2019}t reach the server"
            default: return "Connection failed"
            }
        }
        return "The server refused the change"
    }
}

// MARK: - Test seam

#if DEBUG
extension FollowStore {
    /// The queue, for tests that assert on collapsing and ordering.
    var pendingEditsForTesting: [PendingEdit] { pending }
    var lastSyncedAtForTesting: Date? { lastSyncedAt }
}
#endif
