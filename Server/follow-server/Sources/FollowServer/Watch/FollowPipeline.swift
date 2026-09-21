// Where a PGN block becomes a push.
//
//   snapshot → baseline diff → events → alert policy → outbox → APNs
//
// Everything that needs the database lives here; everything that needs a decision lives in
// `GameDiffer` and `AlertEngine`, which are pure. The replay mode and the live watcher drive this
// same object, which is what makes "what would the server have sent" a question with an answer.

import Foundation
import FollowKit
import Logging

public actor FollowPipeline {

    private let store: FollowStore
    private let engine: AlertEngine
    private let outbox: OutboxWorker
    private let logger: Logger

    public init(store: FollowStore, outbox: OutboxWorker, engine: AlertEngine = AlertEngine(), logger: Logger = ServerLog.make("pipeline")) {
        self.store = store
        self.engine = engine
        self.outbox = outbox
        self.logger = logger
    }

    // Serializes read/plan/write across actor suspension points. Different watcher tasks and
    // the long-think timer must not plan against the same stale baseline/cooldown.
    private var processing = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private func acquire() async {
        while processing { await withCheckedContinuation { waiters.append($0) } }
        processing = true
    }
    private func release() {
        processing = false
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    /// Feeds one game's current PGN in.
    ///
    /// - Returns: the events it produced, which is empty for the first sight of a game (the
    ///   baseline rule), for a re-send that changed nothing, and for a correction.
    @discardableResult
    public func ingest(snapshot: GameSnapshot, context: RoundContext, now: Date, continuouslyObserved: Bool = true) async throws -> [MoveEvent] {
        await acquire()
        defer { release() }
        let baseline = try await store.baseline(roundId: snapshot.roundId, gameId: snapshot.gameId)
        var outcome = GameDiffer.advance(baseline: baseline, snapshot: snapshot, now: now)
        if !continuouslyObserved {
            // The first snapshot on every stream is a fresh observation, including a process
            // restart with a persisted baseline. Whatever moved while the server was not
            // connected is still reported — a result that landed during a two-second reconnect
            // is the alert the viewer most wanted — but the think on the new position starts
            // being measured from now, and an outage cannot count as continuous thinking.
            outcome.baseline = snapshot.baseline(observedAt: now, longThinkEligible: false)
        }
        // Queue before advancing the baseline. A crash between these writes then repeats a
        // candidate (deduped by SQLite) instead of permanently losing its alert.
        if !outcome.events.isEmpty {
            try await dispatch(events: outcome.events, context: context, now: now)
        } else if baseline?.fen != snapshot.fen || baseline?.ply != snapshot.ply || baseline?.status != snapshot.status {
            // Alert silence for a correction does not mean leave the pinned board stale.
            // Activity identity includes the observation time, so a takeback followed by a
            // return to a previously shown position still updates the card.
            let activities = try await store.activities(gameId: snapshot.gameId)
            try await commit(engine.planActivity(snapshot: snapshot, activities: activities, now: now), now: now)
        }
        try await store.save(outcome.baseline)
        return outcome.events
    }

    /// Raises a long-think event for any watched game that has been still long enough.
    ///
    /// The threshold used here is the *smallest* any follow asked for; each follow's own
    /// threshold is applied again inside the policy, so a ten-minute follow and a thirty-minute
    /// follow on the same board each get what they asked for.
    @discardableResult
    public func longThinkTick(snapshots: [GameSnapshot], context: RoundContext, now: Date) async throws -> [MoveEvent] {
        await acquire()
        defer { release() }
        let devices = try await store.deviceContexts()
        guard let minimum = Self.minimumLongThinkSeconds(devices) else { return [] }

        var events: [MoveEvent] = []
        for snapshot in snapshots {
            guard let baseline = try await store.baseline(roundId: snapshot.roundId, gameId: snapshot.gameId) else { continue }
            guard let event = GameDiffer.longThink(baseline: baseline, snapshot: snapshot, now: now, minimumSeconds: minimum) else { continue }
            events.append(event)
        }
        guard !events.isEmpty else { return [] }
        try await dispatch(events: events, context: context, now: now, devices: devices)
        return events
    }

    static func minimumLongThinkSeconds(_ devices: [DeviceContext]) -> Int? {
        let thresholds = devices.flatMap { device in
            device.follows.compactMap { follow -> Int? in
                guard case .tournament = follow.target else {
                    return follow.alerts.game.contains(.longThink) ? follow.alerts.longThinkMinutes * 60 : nil
                }
                return nil     // a tournament follow has no long-think switch
            }
        }
        return thresholds.min()
    }

    private func dispatch(events: [MoveEvent], context: RoundContext, now: Date, devices: [DeviceContext]? = nil) async throws {
        let resolved: [DeviceContext]
        if let devices { resolved = devices } else { resolved = try await store.deviceContexts() }
        let cooldowns = try await store.moveAlertCooldowns()
        var activities: [ActivityRecord] = []
        for gameId in Set(events.map(\.snapshot.gameId)) {
            activities.append(contentsOf: try await store.activities(gameId: gameId))
        }

        let plan = engine.plan(
            events: events,
            context: context,
            devices: resolved,
            cooldowns: cooldowns,
            activities: activities,
            now: now
        )
        try await commit(plan, now: now)
    }

    public func dispatch(tournamentEvents: [TournamentEvent], now: Date) async throws {
        guard !tournamentEvents.isEmpty else { return }
        await acquire()
        defer { release() }
        let devices = try await store.deviceContexts()
        let plan = engine.plan(tournamentEvents: tournamentEvents, devices: devices, now: now)
        try await commit(plan, now: now)
    }

    /// Writes the plan down and then tries to deliver it. The write is what makes a restart safe;
    /// the immediate drain is what makes a push arrive in a second rather than in fifteen.
    private func commit(_ plan: AlertPlan, now: Date) async throws {
        guard !plan.isEmpty else { return }
        var queued = 0
        for entry in plan.entries {
            if try await store.enqueue(entry) { queued += 1 }
        }
        // The cooldown moves for every push the policy chose to send, including one that lost to
        // the dedupe index: that row exists because this device was already told about this
        // event, which is exactly what the interval is counting from.
        for touch in plan.cooldowns {
            try await store.recordMoveAlert(followId: touch.followId, gameId: touch.gameId, at: touch.at)
        }
        guard queued > 0 else { return }
        logger.info("queued pushes", metadata: ["count": .stringConvertible(queued)])
        await outbox.drain()
    }
}
