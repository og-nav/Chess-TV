import Foundation
import ChessCore

/// Streams `GET /api/tv/{channel}/feed` as NDJSON, reconnecting on its own.
///
/// One instance can serve many channels over its lifetime: call `events(for:)` again with a new
/// channel and cancel the task consuming the old stream. `connectionStates` belongs to the
/// instance rather than to one feed session, so a channel switch does not tear it down; call
/// `finish()` when the client is retired for good.
public final class TVFeedStream: TVFeedStreaming, @unchecked Sendable {  // @unchecked: URLSession is not Sendable; every stored property is immutable

    /// Timing knobs. The defaults are the shipping policy; tests shrink them.
    public struct Configuration: Sendable {
        /// First reconnect delay; doubles from here.
        public var baseDelay: Duration = .seconds(1)
        /// Ceiling for the doubling.
        public var maxDelay: Duration = .seconds(60)
        /// A connection that lasted at least this long resets the backoff.
        public var healthyConnectionThreshold: Duration = .seconds(30)
        /// After HTTP 429 we never retry sooner than this, whatever `Retry-After` says.
        public var minimumRateLimitDelay: Duration = .seconds(60)
        /// Injectable jitter, 0...0.25 of the nominal delay by default.
        public var jitterFraction: @Sendable () -> Double = { Double.random(in: 0...0.25) }

        public init() {}
    }

    private let session: URLSession
    private let baseURL: URL
    private let configuration: Configuration
    private let broadcaster = ConnectionStateBroadcaster()
    private let eventDecoder = TVEventDecoder()

    public init(
        session: URLSession = LichessURLSession.streaming,
        baseURL: URL = LichessConfig.baseURL,
        configuration: Configuration = Configuration()
    ) {
        self.session = session
        self.baseURL = baseURL
        self.configuration = configuration
    }

    /// Every connection transition, from now on, with the current state replayed first.
    public var connectionStates: AsyncStream<ConnectionState> { broadcaster.subscribe() }

    /// The most recent state, for callers that just want to read it once.
    public var currentConnectionState: ConnectionState? { broadcaster.current }

    /// Ends all `connectionStates` subscriptions. Only for retiring the client;
    /// a channel switch must not call this.
    public func finish() { broadcaster.finish() }

    public func events(for channel: TVChannel) -> AsyncThrowingStream<TVEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            // Strong capture on purpose: the stream must stay alive for as long as someone
            // is consuming it, and the task ends as soon as the consumer goes away.
            let task = Task {
                await self.run(channel: channel, continuation: continuation)
                continuation.finish()
            }
            // Consumer cancelled (or dropped the iterator): stop the URLSession task now.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Reconnect loop

    private func run(channel: TVChannel, continuation: AsyncThrowingStream<TVEvent, Error>.Continuation) async {
        var backoff = BackoffPolicy(
            base: configuration.baseDelay,
            cap: configuration.maxDelay,
            jitterFraction: configuration.jitterFraction
        )

        while !Task.isCancelled {
            broadcaster.send(.connecting)
            let startedAt = ContinuousClock.now
            do {
                try await connectOnce(channel: channel, continuation: continuation)
                // A normal return means the server closed a stream that should never close.
                throw LichessError.streamEndedUnexpectedly
            } catch {
                if Task.isCancelled || error.isCancellation {
                    log.debug("TV feed for \(channel.rawValue, privacy: .public) cancelled")
                    return
                }
                if let lichess = error as? LichessError, lichess.isUnrecoverable {
                    log.error("TV feed for \(channel.rawValue, privacy: .public) failed: \(lichess.description, privacy: .public)")
                    broadcaster.send(.failed(lichess.description))
                    continuation.finish(throwing: lichess)
                    return
                }

                let lasted = startedAt.duration(to: .now)
                if lasted >= configuration.healthyConnectionThreshold { backoff.reset() }
                let delay = retryDelay(after: error, backoff: &backoff)
                log.error("TV feed for \(channel.rawValue, privacy: .public) dropped after \(lasted.seconds, format: .fixed(precision: 1))s: \(String(describing: error), privacy: .public); retrying in \(delay.seconds, format: .fixed(precision: 1))s")
                broadcaster.send(.reconnecting(attempt: backoff.attempt, nextRetryIn: delay))
                do { try await Task.sleep(for: delay) } catch { return }   // cancelled while waiting
            }
        }
    }

    /// Backoff for this error, floored at 60 s (and at `Retry-After`) for HTTP 429.
    private func retryDelay(after error: any Error, backoff: inout BackoffPolicy) -> Duration {
        var delay = backoff.nextDelay()
        if case .rateLimited(let retryAfter)? = error as? LichessError {
            delay = max(delay, configuration.minimumRateLimitDelay)
            if let retryAfter { delay = max(delay, retryAfter) }
        }
        return delay
    }

    // MARK: - One connection

    /// Runs one HTTP connection to exhaustion. Returns when the server closes the body.
    private func connectOnce(
        channel: TVChannel,
        continuation: AsyncThrowingStream<TVEvent, Error>.Continuation
    ) async throws {
        let url = baseURL.appendingPathComponent("api/tv/\(channel.rawValue)/feed")
        let (bytes, response) = try await session.bytes(for: LichessURLSession.request(url))
        guard let http = response as? HTTPURLResponse else { throw LichessError.notHTTP }
        switch http.statusCode {
        case 200: break
        case 429: throw LichessError.rateLimited(retryAfter: http.retryAfterDuration)
        case 404, 410, 501: throw LichessError.unrecoverableStatus(http.statusCode)
        default: throw LichessError.retryableStatus(http.statusCode)
        }

        var lineDecoder = NDJSONLineDecoder()
        var sawEvent = false
        for try await byte in bytes {
            try Task.checkCancellation()
            guard let line = lineDecoder.append(byte: byte) else { continue }
            guard let event = decodeOrSkip(line) else { continue }
            if !sawEvent {
                sawEvent = true
                broadcaster.send(.live)
            }
            continuation.yield(event)
        }
        if lineDecoder.flush() != nil {
            log.notice("TV feed ended mid-line; discarding the partial event")
        }
    }

    /// Malformed lines are logged and skipped; they must never end the stream.
    private func decodeOrSkip(_ line: String) -> TVEvent? {
        do {
            return try eventDecoder.decode(line: line)
        } catch {
            log.error("Skipping malformed NDJSON line (\(line.count) chars): \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

extension Error {
    /// `URLSession` reports cancellation as `URLError.cancelled`, Swift as `CancellationError`.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let urlError = self as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}
