// Counts and latencies for the hourly "delivery summary" log line.
//
// Two latencies per delivered push: `since_observed_ms`, from the watcher taking the block off
// the Lichess stream to APNs accepting the request (the delay a person feels), and `apns_ms`,
// the APNs round trip alone. The difference is this server's own share. Pure value type so the
// percentiles can be tested without a queue.

import Foundation
import Logging

struct DeliveryStats: Sendable, Equatable {
    private(set) var delivered = 0
    private(set) var retried = 0
    private(set) var dropped = 0
    private(set) var gone = 0
    private(set) var sinceObserved: [Int] = []
    private(set) var apns: [Int] = []

    var isEmpty: Bool { delivered == 0 && retried == 0 && dropped == 0 && gone == 0 }

    mutating func recordDelivered(sinceObservedMs: Int, apnsMs: Int) {
        delivered += 1
        sinceObserved.append(max(0, sinceObservedMs))
        apns.append(max(0, apnsMs))
    }

    mutating func recordRetry() { retried += 1 }
    mutating func recordDrop() { dropped += 1 }
    mutating func recordGone() { gone += 1 }

    /// Nearest-rank percentile; nil for no samples.
    static func percentile(_ samples: [Int], _ p: Double) -> Int? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[max(0, min(sorted.count - 1, rank - 1))]
    }

    func summary() -> Logger.Metadata {
        var metadata: Logger.Metadata = [
            "delivered": .stringConvertible(delivered),
            "retried": .stringConvertible(retried),
            "dropped": .stringConvertible(dropped),
            "tokens_retired": .stringConvertible(gone),
        ]
        if let p50 = Self.percentile(sinceObserved, 50), let p95 = Self.percentile(sinceObserved, 95), let max = sinceObserved.max() {
            metadata["since_observed_ms_p50"] = .stringConvertible(p50)
            metadata["since_observed_ms_p95"] = .stringConvertible(p95)
            metadata["since_observed_ms_max"] = .stringConvertible(max)
        }
        if let p50 = Self.percentile(apns, 50), let p95 = Self.percentile(apns, 95), let max = apns.max() {
            metadata["apns_ms_p50"] = .stringConvertible(p50)
            metadata["apns_ms_p95"] = .stringConvertible(p95)
            metadata["apns_ms_max"] = .stringConvertible(max)
        }
        return metadata
    }
}

extension Duration {
    /// Whole milliseconds, for a log line.
    var milliseconds: Int {
        Int(components.seconds * 1000) + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}
