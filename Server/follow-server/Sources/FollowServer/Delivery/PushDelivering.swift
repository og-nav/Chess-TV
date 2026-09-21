// Delivery, behind a protocol so the whole pipeline can be exercised without APNs.

import Foundation
import FollowKit

public enum DeliveryOutcome: Sendable, Equatable {
    /// APNs accepted it.
    case delivered
    /// A transient failure: try again later, up to `maximumDeliveryAttempts`.
    case retry(String)
    /// The token this row was sent to is dead (410, `BadDeviceToken`, `Unregistered`).
    ///
    /// Which token that is depends on the row, and `OutboxWorker` is where the difference is
    /// acted on: for an alert it is the install's APNs token and the device is disabled; for a
    /// Live Activity it is that activity's push token, which dies every time an activity ends,
    /// and only the registration is retired.
    case deviceGone(String)
    /// Not worth retrying and not the device's fault: a payload APNs refused, an activity that is
    /// no longer registered.
    case drop(String)
}

/// One push, with the token resolved at the moment of delivery rather than at enqueue time —
/// an APNs token can rotate and an ActivityKit token can be replaced while a row waits.
public struct OutboundPush: Sendable {
    public var entry: OutboxEntry
    public var token: String
    /// `"sandbox"` or `"production"`, from the device's registration. A token minted against one
    /// host is rejected by the other, which is the classic silent failure this carries around to
    /// avoid.
    public var environment: String

    public init(entry: OutboxEntry, token: String, environment: String) {
        self.entry = entry
        self.token = token
        self.environment = environment
    }
}

public protocol PushDelivering: Sendable {
    func deliver(_ push: OutboundPush) async -> DeliveryOutcome
}

/// Delivers nothing and remembers everything.
///
/// This is what `--replay` runs with and what the tests assert against: the exact pushes the
/// server would have sent, in order.
public actor RecordingDelivery: PushDelivering {
    public private(set) var delivered: [OutboundPush] = []
    /// Tokens that should be reported dead, so the 410 path has a test.
    private var deadTokens: Set<String>

    public init(deadTokens: Set<String> = []) { self.deadTokens = deadTokens }

    public func deliver(_ push: OutboundPush) async -> DeliveryOutcome {
        if deadTokens.contains(push.token) { return .deviceGone("BadDeviceToken") }
        delivered.append(push)
        return .delivered
    }

    public func record() -> [OutboundPush] { delivered }

    public func alerts() -> [OutboundPush] { delivered.filter { $0.entry.category.isAlert } }

    /// The titles, in order — the readable form of "what would this have sent".
    public func titles() -> [String] { delivered.map(\.entry.title) }

    public func markDead(_ token: String) { deadTokens.insert(token) }
}
