// How long a screen waits between polls, and how it gives up gently.
//
// The TV app has the same rule inside `AppModel.arenaStandingsDelay`. It is repeated here as a
// value rather than reached for across the package boundary, because the phone polls three
// different things at three different cadences and each wants its own ceiling.
import Foundation

struct PollBackoff: Sendable, Equatable {
    /// The cadence while the polls are landing.
    let interval: Duration
    /// The longest gap after a run of failures.
    let maximum: Duration

    init(interval: Duration, maximum: Duration) {
        self.interval = interval
        self.maximum = maximum
    }

    /// The boards wall: every 10 s while visible, backing off to 80 s while the round endpoint
    /// is unhappy. Matches what the TV app does to the arena standings.
    static let boards = PollBackoff(interval: .seconds(10), maximum: .seconds(80))
    /// A round list changes on the scale of hours, not seconds.
    static let rounds = PollBackoff(interval: .seconds(60), maximum: .seconds(300))

    /// `interval` while everything is fine, doubling per consecutive failure up to `maximum`.
    func delay(afterFailures failures: Int) -> Duration {
        guard failures > 0 else { return interval }
        let scaled = interval * (1 << min(failures - 1, 8))
        return min(scaled, maximum)
    }
}
