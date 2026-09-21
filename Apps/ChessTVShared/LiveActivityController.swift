// The lifecycle of the one Live Activity this app ever runs.
//
// The phone app calls `pin(_:state:)` from the game screen's pin button and `unpin()` from the
// same button; everything else — the push token, the 8-hour limit, a user swiping the activity
// away from the Lock Screen, an activity that survived a crash — is this type's problem.
//
// Rules it enforces, each of which is a bug if it slips:
//   * **exactly one activity.** Before starting, every existing `ChessGameAttributes` activity is
//     ended, including ones this process did not start. Two boards on the Lock Screen is worse
//     than none.
//   * **the server is told the token, and told when it stops mattering** — eventually, not just on
//     the first try. Both calls fail silently when they are lost, so neither is allowed to be
//     lost: see `ActivityWorkQueue`. A pin made in a tunnel registers when the tunnel ends; a pin
//     made before the device had a credential registers when `configure` supplies one.
//   * **the app group always holds the last state**, so the Smart Stack and home-screen widgets
//     have something to draw whether or not an activity is running.
//   * **a finished game freezes.** The final state is pushed with no running clock and the
//     activity is ended with a dismissal date, so the result stays on screen for a while and then
//     goes away on its own.
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import Foundation
import Observation
import WidgetKit

import FollowKit

@MainActor
@Observable
public final class LiveActivityController {

    public static let shared = LiveActivityController()

    /// How long after a push the state should be treated as possibly stale. Classical moves are
    /// minutes apart, so a quarter of an hour is generous without being meaningless.
    public static let staleAfter: TimeInterval = 15 * 60

    /// How long a finished game stays on the Lock Screen before the system clears it.
    public static let resultLingers: TimeInterval = 10 * 60

    /// The retry ladder for queued server calls, while the app is in the foreground. Bounded on
    /// purpose: after the last delay the loop stops and waits for the next `pin`, the next token,
    /// or the next `reconcileOnForeground`, all of which flush again.
    static let retryDelays: [Duration] = [.seconds(5), .seconds(20), .seconds(60), .seconds(180), .seconds(600)]

    /// The pinned game, or nil. Mirrors the App Group, which is the copy the widgets read.
    public private(set) var pinned: PinnedGameSnapshot?

    /// Set when an activity ends for a reason that was not the user unpinning — the 8-hour limit,
    /// most often. The game screen reads it to offer "pin again" on the next game.
    public private(set) var endedUnexpectedlyGameId: String? {
        didSet { ChessTVAppGroup.defaults.set(endedUnexpectedlyGameId, forKey: "endedActivityGameId") }
    }

    /// nil until the app has registered with the follow server. Until then an activity still runs
    /// locally and its token is **queued**, not dropped; `configure` sends it.
    @ObservationIgnored private var client: (any FollowServerClient)?

    /// `serverBaseURL?.absoluteString ?? ""` — the host every queued call is scoped to.
    @ObservationIgnored private var server: String

    /// Bumped by `configure`. Every `await` in the flush loop is followed by a check that this is
    /// still the generation the loop started in, so a host change mid-flush cannot send the rest of
    /// the old server's queue through the new server's client.
    @ObservationIgnored private var generation = 0

    /// What the server has already accepted, so a foreground reconciliation with nothing to do
    /// costs nothing. Cleared whenever the host changes.
    @ObservationIgnored private var registered: Registration?

    @ObservationIgnored private var activity: Activity<ChessGameAttributes>?
    @ObservationIgnored private var tokenTask: Task<Void, Never>?
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    /// One flush at a time. Two concurrent drains would interleave across their awaits and send the
    /// same row twice.
    @ObservationIgnored private var isFlushing = false
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var lifecycleRevision = 0
    @ObservationIgnored private var renewingActivityID: String?
    @ObservationIgnored private var lifetime: Lifetime? {
        didSet {
            ChessTVAppGroup.defaults.set(lifetime.flatMap { try? JSONEncoder().encode($0) }, forKey: "activityLifetime")
        }
    }

    private struct Lifetime: Codable {
        var activityID: String
        var startedAt: Date
        var wasDismissed = false
    }

    /// Renewal is conservative: absence alone cannot distinguish expiry from user dismissal.
    nonisolated static func mayRenew(systemEnded: Bool, finished: Bool, startedAt: Date?, now: Date = Date()) -> Bool {
        guard systemEnded, !finished, let startedAt else { return false }
        return now.timeIntervalSince(startedAt) >= 8 * 60 * 60
    }

    private struct Registration: Hashable {
        var server: String
        var gameId: String
        var token: String
    }

    public init() {
        pinned = SharedStore.pinnedGame()
        endedUnexpectedlyGameId = ChessTVAppGroup.defaults.string(forKey: "endedActivityGameId")
        lifetime = ChessTVAppGroup.defaults.data(forKey: "activityLifetime")
            .flatMap { try? JSONDecoder().decode(Lifetime.self, from: $0) }
        server = SharedStore.serverBaseURL()?.absoluteString ?? ""
        // Work queued by a previous launch survives; work queued for a host this install no longer
        // talks to does not.
        var queue = SharedStore.pendingActivityWork()
        let before = queue.items.count
        queue.keep(server: server)
        if queue.items.count != before { SharedStore.setPendingActivityWork(queue) }
    }

    /// Called by the app once it holds a credential, and again if the server URL changes.
    ///
    /// - Parameters:
    ///   - client: the authenticated client, or nil when the install has no credential.
    ///   - serverBaseURL: which host `client` talks to; nil explicitly selects local-only mode.
    public func configure(client: (any FollowServerClient)?, serverBaseURL: URL?) {
        let identity = serverBaseURL?.absoluteString ?? ""
        if identity != server {
            server = identity
            registered = nil
            var queue = SharedStore.pendingActivityWork()
            let dropped = queue.items.count
            queue.keep(server: identity)
            if dropped != queue.items.count {
                SharedStore.setPendingActivityWork(queue)
                activityLog.notice("The follow server changed; dropped \(dropped - queue.items.count) queued activity call(s) meant for the old one")
            }
        }
        self.client = client
        // A new install identity on the same host needs its own registration too.
        registered = nil
        generation += 1
        cancelRetries()
        guard client != nil else { return }
        // The running activity's *current* token, not the next one it happens to rotate to: this
        // is the whole point of the fix. `pushTokenUpdates` already delivered it, and if that
        // delivery failed — no client yet, or no network — nothing else will offer it again.
        enqueueCurrentTokenIfNeeded()
        Task { [weak self] in await self?.flushPendingWork() }
    }

    /// Whether the system will allow an activity at all — the user can turn them off per app.
    public var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    public var isRunning: Bool { activity != nil }

    /// How many server calls are waiting. For a Settings row, and for tests.
    public var pendingServerCallCount: Int { SharedStore.pendingActivityWork().items.count }

    // MARK: - Pinning

    /// Starts the activity for a game, replacing whatever was pinned before.
    ///
    /// - Throws: `ActivityAuthorizationError` when the user has turned Live Activities off, or the
    ///   system refuses for its own reasons (too many activities, a device in Low Power Mode with
    ///   the setting disabled). The caller shows that as a row in Settings, not an alert.
    @discardableResult
    public func pin(
        _ game: ChessGameAttributesPayload, state: ChessGameActivityState
    ) async throws -> Bool {
        guard areActivitiesEnabled else {
            activityLog.notice("Live Activities are turned off for this app")
            return false
        }

        lifecycleRevision += 1
        let revision = lifecycleRevision
        lifetime = nil

        // Everything that is about to stop existing, named before it does. Pinning a second game
        // used to end the first one silently as far as the server was concerned, so a new
        // registration that then failed left the server pushing to an activity that had gone.
        var ending = Set(Activity<ChessGameAttributes>.activities.map(\.attributes.gameId))
        if let previous = pinned?.gameId { ending.insert(previous) }

        // One at a time, including activities this process did not start.
        for gameId in ending.sorted() { enqueueEnd(gameId: gameId) }
        await endAllActivities(dismissing: .immediate)
        guard lifecycleRevision == revision else { return false }
        clearSnapshot()

        let attributes = ChessGameAttributes(game: game)
        let content = ActivityContent(
            state: state,
            staleDate: state.asOf.addingTimeInterval(Self.staleAfter),
            relevanceScore: 100
        )
        let started: Activity<ChessGameAttributes>
        do {
            started = try Activity.request(attributes: attributes, content: content, pushType: .token)
        } catch {
            // The old ones really did end, so the server still has to hear about them.
            await flushPendingWork()
            throw error
        }
        activity = started
        lifetime = Lifetime(activityID: started.id, startedAt: Date())
        endedUnexpectedlyGameId = nil
        writeSnapshot(game: game, state: state)
        observe(started, game: game)
        activityLog.notice("Pinned \(game.gameId, privacy: .public) in round \(game.roundId, privacy: .public)")
        // A token is occasionally available the moment the activity starts; usually it arrives on
        // the stream a beat later. Both paths go through the same queue.
        enqueueCurrentTokenIfNeeded()
        await flushPendingWork()
        return true
    }

    /// The user tapped the pin button again, or opened a different game and pinned that.
    public func unpin() async {
        lifetime = nil
        lifecycleRevision += 1
        let revision = lifecycleRevision
        var ending = Set(Activity<ChessGameAttributes>.activities.map(\.attributes.gameId))
        if let gameId = pinned?.gameId { ending.insert(gameId) }
        for gameId in ending.sorted() { enqueueEnd(gameId: gameId) }
        await endAllActivities(dismissing: .immediate)
        guard lifecycleRevision == revision else { return }
        clearSnapshot()
        endedUnexpectedlyGameId = nil
        await flushPendingWork()
        activityLog.notice("Unpinned")
    }

    /// A new state, from the app's own live session rather than from a push.
    ///
    /// The server drives the activity in normal operation; this exists for the seconds between
    /// pinning and the server's first push, and for a device with no server at all.
    public func update(_ state: ChessGameActivityState) async {
        guard let activity else {
            // No activity, but the widgets should still see the newest board.
            if var snapshot = pinned {
                snapshot.state = state.asLiveActivityState
                writeSnapshot(snapshot)
            }
            return
        }
        let content = ActivityContent(
            state: state,
            staleDate: state.asOf.addingTimeInterval(Self.staleAfter),
            relevanceScore: state.isFinished ? 50 : 100
        )
        if state.isFinished {
            // Let go of the activity *before* the await: while `end` is suspended the state
            // observer can see `.ended` and run `handleEnded`, which would otherwise take the
            // activity away underneath this method, leave the widget snapshot saying "live", and
            // offer "pin again" for a game that is over.
            activityLog.notice("Activity ending: the game finished \(state.status, privacy: .public)")
            self.activity = nil
            lifetime = nil
            cancelObservation()
            if var snapshot = pinned {
                snapshot.state = state.asLiveActivityState
                writeSnapshot(snapshot)
            }
            await ActivityHandle(activity).end(content, dismissing: .after(Date().addingTimeInterval(Self.resultLingers)))
            enqueueEnd(gameId: activity.attributes.gameId)
            await flushPendingWork()
        } else {
            await ActivityHandle(activity).update(content)
            guard self.activity?.id == activity.id else { return }
            if var snapshot = pinned {
                snapshot.state = state.asLiveActivityState
                writeSnapshot(snapshot)
            }
        }
    }

    // MARK: - Reconciliation

    /// Called when the app comes to the foreground.
    ///
    /// Four things can have happened while it was away: the activity ended on its own (the 8-hour
    /// limit, or the user swiped it away), an activity is running that this process does not hold a
    /// handle to (the app was relaunched), a call to the server is still owed from last time, or
    /// nothing changed. All four end with `pinned`, the App Group and the server agreeing — or with
    /// the disagreement queued for the next try.
    public func reconcileOnForeground() async {
        foreground = true
        let revision = lifecycleRevision
        let all = Activity<ChessGameAttributes>.activities
        let live = all.filter {
            $0.activityState == .active || $0.activityState == .stale || $0.activityState == .pending
        }

        if live.isEmpty {
            guard let snapshot = pinned else {
                await flushPendingWork()
                return
            }
            if let ended = all.first(where: { $0.id == lifetime?.activityID }), canRenew(ended) {
                await renewExpired(ended)
                return
            }
            let finished = ChessFormat.isFinished(status: snapshot.state.status)
            activityLog.notice("No activity is running; \(finished ? "keeping the result" : "clearing the pin") for \(snapshot.gameId, privacy: .public)")
            activity = nil
            cancelObservation()
            endedUnexpectedlyGameId = finished ? nil : snapshot.gameId
            lifetime = nil
            // A finished game keeps its result in the widget, as `PinnedGameWidget` promises;
            // the next pin replaces it. Only a game that is still going has lost its activity.
            if !finished { clearSnapshot() }
            enqueueEnd(gameId: snapshot.gameId)
            await flushPendingWork()
            return
        }

        // Adopt the newest and end any others, so a relaunch does not leave an orphan.
        let adopted = live.last!
        for other in live where other.id != adopted.id {
            await ActivityHandle(other).end(nil, dismissing: .immediate)
            guard lifecycleRevision == revision else { return }
            if other.attributes.gameId != adopted.attributes.gameId {
                enqueueEnd(gameId: other.attributes.gameId)
            }
        }
        if activity?.id != adopted.id {
            activity = adopted
            observe(adopted, game: adopted.attributes.game)
            activityLog.notice("Adopted a running activity for \(adopted.attributes.gameId, privacy: .public)")
        }
        writeSnapshot(game: adopted.attributes.game, state: adopted.content.state)
        // The adopted activity's token may never have reached the server — this process may not
        // even be the one that started it.
        enqueueCurrentTokenIfNeeded()
        await flushPendingWork()
    }

    // MARK: - Observation

    private func observe(_ activity: Activity<ChessGameAttributes>, game: ChessGameAttributesPayload) {
        cancelObservation()

        // The token is a stream: iOS reissues it, and a reissued token that never reached the
        // server is an activity that silently stops updating.
        tokenTask = Task { [weak self] in
            for await tokenData in activity.pushTokenUpdates {
                let token = Self.hex(tokenData)
                guard !Task.isCancelled, let self else { return }
                await self.tokenArrived(token, game: game, activityID: activity.id)
            }
        }

        stateTask = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled, let self else { return }
                // Written as a test rather than a `switch` on purpose: `ActivityState` has gained
                // cases before (`.stale`, `.pending`) and the only distinction this code needs is
                // "still on screen" against "gone". A case added tomorrow is treated as still on
                // screen, which is the safe reading — `reconcileOnForeground` catches the rest.
                guard state == .ended || state == .dismissed else { continue }
                await self.handleEnded(gameId: game.gameId, activityID: activity.id, state: state)
                return
            }
        }
    }

    private func cancelObservation() {
        tokenTask?.cancel(); tokenTask = nil
        stateTask?.cancel(); stateTask = nil
    }

    private func handleEnded(gameId: String, activityID: String, state: ActivityState) async {
        guard let ending = activity, ending.id == activityID else { return }
        if state == .dismissed, lifetime?.activityID == activityID { lifetime?.wasDismissed = true }
        if foreground, canRenew(ending) {
            // A fresh task is needed because pin() cancels this activity's observer task.
            Task { [weak self] in await self?.renewExpired(ending) }
            return
        }
        activityLog.notice("Activity for \(gameId, privacy: .public) is no longer live")
        activity = nil
        cancelObservation()
        endedUnexpectedlyGameId = ending.content.state.isFinished ? nil : gameId
        enqueueEnd(gameId: gameId)
        await flushPendingWork()
    }

    private func canRenew(_ candidate: Activity<ChessGameAttributes>) -> Bool {
        guard lifetime?.activityID == candidate.id, lifetime?.wasDismissed == false else { return false }
        return Self.mayRenew(systemEnded: candidate.activityState == .ended,
            finished: candidate.content.state.isFinished, startedAt: lifetime?.startedAt)
    }

    /// At most one foreground request for a known expired activity. No background timer is used.
    private func renewExpired(_ ended: Activity<ChessGameAttributes>) async {
        guard foreground, renewingActivityID == nil, canRenew(ended) else { return }
        renewingActivityID = ended.id
        defer { renewingActivityID = nil }
        do {
            // The ended activity's state is at least eight hours old: pinned as it stands, its
            // stale date is in the past and its clock deadlines have long expired, so the card
            // would open at 0:00 and dimmed. Re-anchor it to now with no clock running; the next
            // server push supplies the real clocks.
            var state = ended.content.state
            state.asOf = Date()
            state.clockRunningFor = nil
            let restarted = try await pin(ended.attributes.game, state: state)
            if !restarted, pinned?.gameId == ended.attributes.gameId {
                endedUnexpectedlyGameId = ended.attributes.gameId
            }
        } catch {
            endedUnexpectedlyGameId = ended.attributes.gameId
            lifetime = nil
            activityLog.notice("The expired activity could not restart: \(logLabel(for: error), privacy: .public)")
        }
    }

    nonisolated static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The server

    private func tokenArrived(_ token: String, game: ChessGameAttributesPayload, activityID: String) async {
        guard activity?.id == activityID else { return }
        enqueueRegistration(token: token, game: game)
        await flushPendingWork()
    }

    /// Queues the running activity's **current** token unless the server has already accepted this
    /// exact one for this game on this host.
    ///
    /// This is the path that rescues an activity pinned while offline, or pinned before the device
    /// had registered. ActivityKit hands out the token once; `pushTokenUpdates` does not repeat it
    /// because the first attempt to use it failed.
    private func enqueueCurrentTokenIfNeeded() {
        guard let activity, let data = activity.pushToken else { return }
        enqueueRegistration(token: Self.hex(data), game: activity.attributes.game)
    }

    private func enqueueRegistration(token: String, game: ChessGameAttributesPayload) {
        guard !token.isEmpty else { return }
        guard registered != Registration(server: server, gameId: game.gameId, token: token) else { return }
        var queue = SharedStore.pendingActivityWork()
        queue.enqueue(PendingActivityWork(
            kind: .register, roundId: game.roundId, gameId: game.gameId,
            activityToken: token, server: server
        ))
        SharedStore.setPendingActivityWork(queue)
    }

    private func enqueueEnd(gameId: String) {
        guard !gameId.isEmpty else { return }
        if registered?.gameId == gameId { registered = nil }
        var queue = SharedStore.pendingActivityWork()
        queue.enqueue(PendingActivityWork(kind: .end, gameId: gameId, server: server))
        SharedStore.setPendingActivityWork(queue)
    }

    /// Drains the queue and, if anything is left, arms the retry ladder.
    private func flushPendingWork() async {
        await drain()
        scheduleRetryIfNeeded()
    }

    /// Sends everything the server has not accepted, oldest first.
    ///
    /// The queue is re-read from the App Group after every call rather than held across the await:
    /// a `pin` on the main actor can queue an end while this loop is suspended, and writing back a
    /// snapshot taken before that would lose it.
    private func drain() async {
        guard let client, !isFlushing else { return }
        let mine = generation
        let host = server
        let work = SharedStore.pendingActivityWork().items.filter { $0.server == host }
        guard !work.isEmpty else { return }

        isFlushing = true
        defer { isFlushing = false }

        for item in work {
            guard generation == mine else { return }
            guard SharedStore.pendingActivityWork().contains(item) else { continue }
            do {
                switch item.kind {
                case .register:
                    try await client.registerActivity(ActivityRegistration(
                        roundId: item.roundId, gameId: item.gameId, activityToken: item.activityToken
                    ))
                    guard generation == mine else { return }
                    registered = Registration(server: host, gameId: item.gameId, token: item.activityToken)
                    activityLog.notice("Registered the activity for \(item.gameId, privacy: .public) with the server")
                case .end:
                    try await client.endActivity(gameId: item.gameId)
                    guard generation == mine else { return }
                    activityLog.notice("Told the server the activity for \(item.gameId, privacy: .public) has ended")
                }
                settle(item)
            } catch FollowServerError.notFound {
                guard generation == mine else { return }
                // Only an absent DELETE has already reached its desired state.
                if item.kind == .end { settle(item) }
            } catch FollowServerError.unauthorized {
                // The credential is dead. Retrying with it cannot work, and the app will register
                // again and call `configure`, which re-queues the current token against the new
                // identity. Stop here rather than spend the whole ladder on 401s.
                guard generation == mine else { return }
                activityLog.notice("Activity calls are unauthorized; waiting for the app to register again")
                return
            } catch {
                guard generation == mine else { return }
                var queue = SharedStore.pendingActivityWork()
                let kept = queue.recordFailure(of: item)
                SharedStore.setPendingActivityWork(queue)
                activityLog.notice(
                    "\(item.kind.rawValue, privacy: .public) for \(item.gameId, privacy: .public) did not reach the server (\(logLabel(for: error), privacy: .public)); \(kept ? "queued for retry" : "out of retries", privacy: .public)"
                )
            }
        }
    }

    private func settle(_ item: PendingActivityWork) {
        var queue = SharedStore.pendingActivityWork()
        queue.remove(item)
        SharedStore.setPendingActivityWork(queue)
    }

    /// A bounded foreground retry, so a pin made on a train registers itself when the tunnel ends
    /// without anyone having to touch the app.
    private func scheduleRetryIfNeeded() {
        guard foreground, retryTask == nil, client != nil else { return }
        guard !SharedStore.pendingActivityWork().isEmpty else { return }
        let mine = generation
        retryTask = Task { [weak self] in
            for delay in Self.retryDelays {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                guard self.retryStillWanted(generation: mine) else { break }
                await self.drain()
            }
            self?.retriesFinished()
        }
    }

    private func retryStillWanted(generation mine: Int) -> Bool {
        foreground && generation == mine && client != nil && !SharedStore.pendingActivityWork().isEmpty
    }

    private func retriesFinished() { retryTask = nil }

    public func suspendRetries() {
        foreground = false
        cancelRetries()
    }

    private func cancelRetries() {
        retryTask?.cancel()
        retryTask = nil
    }

    // MARK: - The App Group

    private func writeSnapshot(game: ChessGameAttributesPayload, state: ChessGameActivityState) {
        writeSnapshot(PinnedGameSnapshot(
            roundId: game.roundId, gameId: game.gameId,
            tourName: game.tourName, roundName: game.roundName,
            whiteName: game.whiteName, blackName: game.blackName,
            whiteTitle: game.whiteTitle, blackTitle: game.blackTitle,
            state: state.asLiveActivityState
        ))
    }

    private func writeSnapshot(_ snapshot: PinnedGameSnapshot) {
        pinned = snapshot
        SharedStore.setPinnedGame(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func clearSnapshot() {
        pinned = nil
        SharedStore.setPinnedGame(nil)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func endAllActivities(dismissing policy: ActivityUIDismissalPolicy) async {
        cancelObservation()
        let ending = Activity<ChessGameAttributes>.activities
        activity = nil
        for running in ending {
            await ActivityHandle(running).end(nil, dismissing: policy)
        }
    }
}

/// `Activity` is not `Sendable` in the SDK, yet `end` and `update` are nonisolated `async`
/// methods on it — so calling either from the main actor is "sending a non-Sendable value" as far
/// as Swift 6 is concerned, and there is no spelling of the call that is not.
///
/// This is the smallest honest way to say what the API means. The handle never escapes the box,
/// every use of it happens inside the box's own nonisolated domain rather than crossing out of the
/// main actor, and the box adds no state of its own — so the `@unchecked` claim is about
/// ActivityKit's missing annotation, not about anything this file does.
private struct ActivityHandle: @unchecked Sendable {
    private let activity: Activity<ChessGameAttributes>

    init(_ activity: Activity<ChessGameAttributes>) { self.activity = activity }

    func end(
        _ content: ActivityContent<ChessGameActivityState>?, dismissing policy: ActivityUIDismissalPolicy
    ) async {
        await activity.end(content, dismissalPolicy: policy)
    }

    func update(_ content: ActivityContent<ChessGameActivityState>) async {
        await activity.update(content)
    }
}
#endif
