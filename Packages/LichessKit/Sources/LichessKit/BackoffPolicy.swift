import Foundation

/// Exponential backoff with jitter for feed reconnection.
///
/// Nominal delays double from `base` (1 s → 2 s → 4 s …) up to `cap` (60 s). Jitter of up to
/// +25 % is added so that many clients do not reconnect in lockstep; the jitter never shortens
/// a delay, which keeps the "never faster than 60 s after a 429" guarantee simple to reason about.
public struct BackoffPolicy: Sendable {
    /// Attempts since the last reset. `0` means the next delay is the first one.
    private(set) var attempt = 0

    let base: Duration
    let cap: Duration
    /// Injectable so tests are deterministic.
    let jitterFraction: @Sendable () -> Double

    public init(
        base: Duration = .seconds(1),
        cap: Duration = .seconds(60),
        jitterFraction: @escaping @Sendable () -> Double = { Double.random(in: 0...0.25) }
    ) {
        self.base = base
        self.cap = cap
        self.jitterFraction = jitterFraction
    }

    /// Advances the attempt counter and returns how long to wait before the next connection.
    public mutating func nextDelay() -> Duration {
        attempt += 1
        let baseSeconds = base.seconds
        let capSeconds = cap.seconds
        let nominal = min(baseSeconds * pow(2, Double(attempt - 1)), capSeconds)
        return .seconds(nominal * (1 + jitterFraction()))
    }

    /// Called after a connection that stayed up long enough to count as healthy.
    public mutating func reset() {
        attempt = 0
    }
}

extension Duration {
    /// The duration in seconds as a `Double`.
    var seconds: Double {
        let (secs, atto) = components
        return Double(secs) + Double(atto) * 1e-18
    }
}
