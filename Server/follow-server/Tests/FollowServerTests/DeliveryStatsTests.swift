import Foundation
import Logging
import Testing
@testable import FollowServer

@Suite("Delivery statistics")
struct DeliveryStatsTests {

    @Test("Percentiles use the nearest rank and the summary carries counts and latencies")
    func summary() {
        var stats = DeliveryStats()
        #expect(stats.isEmpty)
        for ms in [100, 300, 200, 900, 250] { stats.recordDelivered(sinceObservedMs: ms, apnsMs: ms / 10) }
        stats.recordRetry()
        stats.recordDrop()
        stats.recordGone()
        #expect(!stats.isEmpty)

        #expect(DeliveryStats.percentile([100, 300, 200, 900, 250], 50) == 250)
        #expect(DeliveryStats.percentile([100, 300, 200, 900, 250], 95) == 900)
        #expect(DeliveryStats.percentile([], 50) == nil)
        #expect(DeliveryStats.percentile([7], 99) == 7)

        let metadata = stats.summary()
        #expect(metadata["delivered"]?.description == "5")
        #expect(metadata["retried"]?.description == "1")
        #expect(metadata["dropped"]?.description == "1")
        #expect(metadata["tokens_retired"]?.description == "1")
        #expect(metadata["since_observed_ms_p50"]?.description == "250")
        #expect(metadata["since_observed_ms_p95"]?.description == "900")
        #expect(metadata["since_observed_ms_max"]?.description == "900")
        #expect(metadata["apns_ms_p50"]?.description == "25")
        #expect(metadata["apns_ms_max"]?.description == "90")
    }

    @Test("A negative latency from clock skew is clamped rather than poisoning the percentiles")
    func clamps() {
        var stats = DeliveryStats()
        stats.recordDelivered(sinceObservedMs: -40, apnsMs: 12)
        #expect(stats.sinceObserved == [0])
        #expect(Duration.milliseconds(1500).milliseconds == 1500)
    }
}
