// One poll of an arena's leaderboard, as the side panel and the header read it.
import Foundation
import LichessKit

/// The first page of `standing.players` from `GET /api/tournament/{id}`, the size of the field,
/// and how long the arena had left when the poll landed.
///
/// `receivedAt` is what lets the header count down between polls: the arena's remaining time is
/// `secondsToFinish` minus the time since, exactly as the clocks count down from `ClockReading`.
public struct ArenaStandings: Equatable {
    /// Ten rows: what Lichess sends on page one.
    public var rows: [ArenaStanding]
    /// Everyone in the arena, not just the rows above.
    public var playerCount: Int
    /// `nil` before the arena starts.
    public var secondsToFinish: Int?
    public var receivedAt: ContinuousClock.Instant
    public init(rows: [ArenaStanding], playerCount: Int, secondsToFinish: Int?, receivedAt: ContinuousClock.Instant) {
        self.rows = rows; self.playerCount = playerCount; self.secondsToFinish = secondsToFinish; self.receivedAt = receivedAt
    }

    /// Whole seconds of arena left at `now`, never below zero.
    public func secondsLeft(at now: ContinuousClock.Instant) -> Int? {
        guard let secondsToFinish else { return nil }
        let elapsed = receivedAt.duration(to: now).inSeconds
        return max(0, Int((Double(secondsToFinish) - elapsed).rounded(.down)))
    }

    /// "1,087 players".
    public var playerCountText: String {
        let count = playerCount.formatted(.number)
        return playerCount == 1 ? "1 player" : "\(count) players"
    }
}
