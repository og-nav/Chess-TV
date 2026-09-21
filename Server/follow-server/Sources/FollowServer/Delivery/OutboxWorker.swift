// The durable outbox, drained.
//
// A row is written *before* anything is handed to APNs and marked delivered *after*. That gives
// at-least-once delivery, not exactly-once: APNs can accept a push and the process can die before
// the `delivered_at` write lands, in which case the row is picked up again and the same push is
// sent a second time. What keeps that from being visible is the rest of the design — one
// `apns-collapse-id` per game, so a repeat replaces rather than stacks, and a
// `UNIQUE(device_id, dedupe_key)` index, so the same *event* is never queued twice however many
// times it is observed. Exactly-once across the APNs acknowledgement boundary is not available
// without a distributed transaction with Apple, and is not worth one.
//
// Tokens are resolved here, at the moment of delivery, rather than being copied into the row —
// an APNs token can rotate and an ActivityKit token can be replaced while a row is waiting.

import Foundation
import FollowKit
import Logging

public actor OutboxWorker {

    private let store: FollowStore
    private let delivery: any PushDelivering
    private let configuration: ServerConfig
    private let logger: Logger
    private let now: @Sendable () -> Date

    /// True while a pass is running. The timer in `run()` and the kick from `FollowPipeline.commit`
    /// both call `drain()`, and an actor is re-entrant: without this, the second call would read
    /// the same `queued` rows the first is in the middle of delivering and send every one of them
    /// twice. `queuedEntries` is a plain `SELECT … WHERE state = 'queued'`, so the row is not
    /// claimed until its outcome is written.
    private var isDraining = false
    /// Set when a kick arrives during a pass, so the pass loops once more instead of the kick
    /// being silently dropped: whatever was just enqueued must still go out promptly.
    private var drainRequested = false
    /// Delivery counts and latencies since the last hourly summary line. See `DeliveryStats`.
    private var stats = DeliveryStats()
    private var lastSummaryAt: Date?

    public init(store: FollowStore, delivery: any PushDelivering, configuration: ServerConfig, logger: Logger = ServerLog.make("outbox"), now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.delivery = delivery
        self.configuration = configuration
        self.logger = logger
        self.now = now
    }

    /// Drains the queue, and keeps draining while kicks arrive.
    /// - Returns: how many rows were delivered, for the log line and for the tests. A call that
    ///   found a pass already running returns 0 and lets that pass carry its work.
    @discardableResult
    public func drain(limit: Int = 200) async -> Int {
        guard !isDraining else {
            drainRequested = true
            return 0
        }
        isDraining = true
        defer { isDraining = false }

        var delivered = 0
        repeat {
            drainRequested = false
            delivered += await pass(limit: limit)
        } while drainRequested
        return delivered
    }

    /// One pass over the queue.
    private func pass(limit: Int) async -> Int {
        let entries: [OutboxEntry]
        do {
            entries = try await store.queuedEntries(limit: limit)
        } catch {
            logger.error("outbox read failed", metadata: ["error": .string(String(describing: type(of: error)))])
            return 0
        }

        var delivered = 0
        for entry in entries {
            guard let outbound = await resolve(entry) else { continue }
            let started = ContinuousClock.now
            let outcome = await delivery.deliver(outbound)
            let apnsMs = (ContinuousClock.now - started).milliseconds
            // Stream receipt to APNs acceptance, the number a person feels as "how late was
            // the buzz". `queued_at` is the watcher's observation instant, not the insert time.
            let sinceObservedMs = Int((now().timeIntervalSince(entry.queuedAt) * 1000).rounded())
            let common: Logger.Metadata = [
                "category": .string(entry.category.rawValue),
                "device": .string(entry.deviceId),
                "dedupe": .string(entry.dedupeKey),
                "attempt": .stringConvertible(entry.attempts + 1),
                "apns_ms": .stringConvertible(apnsMs),
                "since_observed_ms": .stringConvertible(sinceObservedMs),
            ]
            switch outcome {
            case .delivered:
                try? await store.markDelivered(id: entry.id)
                delivered += 1
                stats.recordDelivered(sinceObservedMs: sinceObservedMs, apnsMs: apnsMs)
                logger.info("delivered", metadata: common)
            case .retry(let reason):
                try? await store.markAttemptFailed(id: entry.id, error: reason, maximumAttempts: configuration.maximumDeliveryAttempts)
                stats.recordRetry()
                logger.warning("delivery will be retried", metadata: common.merging(["reason": .string(reason)]) { $1 })
            case .deviceGone(let reason):
                await retire(entry, token: outbound.token, reason: reason)
                stats.recordGone()
                logger.notice("token retired", metadata: common.merging(["reason": .string(reason)]) { $1 })
            case .drop(let reason):
                try? await store.markDropped(id: entry.id, reason: reason)
                stats.recordDrop()
                logger.notice("dropped", metadata: common.merging(["reason": .string(reason)]) { $1 })
            }
        }
        return delivered
    }

    /// A 410, or a `BadDeviceToken`. *Which* token died depends on the row.
    ///
    /// An ActivityKit push token is invalidated whenever its activity ends — the user swiped the
    /// Lock Screen card away, the eight-hour limit ran out, the app replaced it. That says nothing
    /// about the device's own APNs token, and disabling the install for it would silently stop
    /// every move alert on the phone because somebody dismissed a Live Activity.
    private func retire(_ entry: OutboxEntry, token: String, reason: String) async {
        switch entry.category {
        case .activityUpdate, .activityEnd:
            try? await store.retireActivity(deviceId: entry.deviceId, gameId: entry.reference, reason: reason, expectedToken: token)
            try? await store.markDropped(id: entry.id, reason: reason)
        case .gameMove, .tournamentEvent:
            try? await store.disableDevice(id: entry.deviceId, reason: reason, expectedToken: token)
            try? await store.markDropped(id: entry.id, reason: reason)
        }
    }

    /// Finds the token this row should go to, or drops the row.
    private func resolve(_ entry: OutboxEntry) async -> OutboundPush? {
        do {
            guard let device = try await store.device(id: entry.deviceId), device.isActive else {
                try await store.markDropped(id: entry.id, reason: "device gone")
                return nil
            }
            switch entry.category {
            case .gameMove, .tournamentEvent:
                // Preferences may change while a transient APNs failure leaves this row queued.
                // Re-evaluate immediately before sending; an old alert must not bypass mute or
                // enter a quiet-hours window merely because it was originally queued earlier.
                let preferences = try await store.preferences(deviceId: entry.deviceId)
                let allowed: Bool
                if entry.category == .gameMove {
                    let push = try? FollowJSON.pushDecoder.decode(MovePush.self, from: Data(entry.payloadJSON.utf8))
                    allowed = preferences.allowsAlert(kind: push?.pushKind ?? .move, at: now())
                } else {
                    let push = try? FollowJSON.pushDecoder.decode(TournamentPush.self, from: Data(entry.payloadJSON.utf8))
                    allowed = preferences.allowsAlert(kind: push?.pushKind ?? .roundLive, at: now())
                }
                guard allowed else {
                    try await store.markDropped(id: entry.id, reason: "current notification preferences")
                    return nil
                }
                return OutboundPush(entry: entry, token: device.apnsToken, environment: device.environment)
            case .activityUpdate, .activityEnd:
                // The user may have unpinned the game, or pinned a different one, since this row
                // was queued. Either way the update has nowhere to go.
                guard let activity = try await store.activity(deviceId: entry.deviceId), activity.gameId == entry.reference else {
                    try await store.markDropped(id: entry.id, reason: "activity not registered")
                    return nil
                }
                return OutboundPush(entry: entry, token: activity.activityToken, environment: device.environment)
            }
        } catch {
            logger.error("outbox resolve failed", metadata: ["error": .string(String(describing: type(of: error)))])
            return nil
        }
    }

    /// Once an hour, one line with the counts and the latency percentiles since the last one,
    /// so a week of logs answers "how many, how late, how many retries" with a grep.
    private func summariseIfDue() {
        let current = now()
        guard let last = lastSummaryAt else { lastSummaryAt = current; return }
        guard current.timeIntervalSince(last) >= Self.summaryInterval else { return }
        lastSummaryAt = current
        guard !stats.isEmpty else { return }
        logger.info("delivery summary", metadata: stats.summary())
        stats = DeliveryStats()
    }

    static let summaryInterval: TimeInterval = 3600

    /// Drains on a timer until cancelled. Enqueuing also kicks a drain, so this is the safety net
    /// for rows that failed and are waiting for another try.
    public func run() async {
        while !Task.isCancelled {
            await drain()
            summariseIfDue()
            do {
                try await Task.sleep(for: configuration.outboxInterval)
            } catch {
                return
            }
        }
    }
}
