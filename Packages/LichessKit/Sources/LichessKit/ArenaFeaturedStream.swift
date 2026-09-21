import Foundation
import ChessCore

/// Follows whatever game an arena is currently featuring, across game changes.
///
/// An arena has no push feed for its featured board, so this is a poll-plus-stream hybrid:
/// fetch `/api/tournament/{id}`, stream `featured.id` with ``GameStream`` until that game ends,
/// then poll the arena every `pollInterval` until a *different* featured game appears and
/// stream that one. A `.featured` event is emitted for each new game, `.fen` for each move.
/// The stream finishes normally when the arena is over, and on cancellation.
///
/// ## History and the end of a game
///
/// `/api/stream/game/{id}` replays the game it is given from move one, so a viewer joining an
/// arena mid-game gets the moves already played. Those are marked as history
/// (`sourcedEvents(tournamentId:)`), with the arena's own `featured.fen` as the live position so
/// the boundary is exact; a consumer fast-forwards through them rather than playing the game out
/// move by move. When the game ends, its terminal status is emitted as `.gameEnded` before the
/// rotation goes back to polling, which is the only way the app can tell a finished game from a
/// dropped connection.
public final class ArenaFeaturedStream: @unchecked Sendable {   // @unchecked: every stored property is immutable

    private let client: ArenaClient
    private let gameStream: GameStream
    private let pollInterval: Duration
    private let broadcaster = ConnectionStateBroadcaster()

    /// - Parameters:
    ///   - pollInterval: how often the arena is re-read while no new featured game is available.
    public init(
        client: ArenaClient = ArenaClient(),
        gameStream: GameStream = GameStream(),
        pollInterval: Duration = .seconds(10)
    ) {
        self.client = client
        self.gameStream = gameStream
        self.pollInterval = pollInterval
    }

    /// Convenience initialiser that points both the client and the game stream at one base URL.
    public convenience init(baseURL: URL, pollInterval: Duration = .seconds(10)) {
        self.init(
            client: ArenaClient(baseURL: baseURL),
            gameStream: GameStream(baseURL: baseURL),
            pollInterval: pollInterval
        )
    }

    public var connectionStates: AsyncStream<ConnectionState> { broadcaster.subscribe() }
    public var currentConnectionState: ConnectionState? { broadcaster.current }
    public func finish() { broadcaster.finish() }

    /// The events alone, with the history flag and the game-over item dropped.
    public func events(tournamentId: String) -> AsyncThrowingStream<TVEvent, Error> {
        let items = sourcedEvents(tournamentId: tournamentId)
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do {
                    for try await item in items {
                        if let event = item.event { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Every featured game in full: its replayed history marked as such, its live moves, and a
    /// `.gameEnded` item carrying the terminal status when it finishes.
    public func sourcedEvents(tournamentId: String) -> AsyncThrowingStream<FeedItem, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                await self.run(tournamentId: tournamentId, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Rotation loop

    private func run(tournamentId: String, continuation: AsyncThrowingStream<FeedItem, Error>.Continuation) async {
        var lastGameId: String?
        var backoff = BackoffPolicy(base: pollInterval, cap: .seconds(60), jitterFraction: { 0 })

        while !Task.isCancelled {
            broadcaster.send(.connecting)
            let detail: ArenaDetail
            do {
                detail = try await client.detail(id: tournamentId)
                backoff.reset()
            } catch {
                if Task.isCancelled || error.isCancellation { return }
                if let lichess = error as? LichessError, lichess.isUnrecoverable {
                    broadcaster.send(.failed(lichess.description))
                    continuation.finish(throwing: lichess)
                    return
                }
                var delay = backoff.nextDelay()
                if case .rateLimited(let retryAfter)? = error as? LichessError {
                    delay = max(delay, .seconds(60))
                    if let retryAfter { delay = max(delay, retryAfter) }
                }
                log.error("Arena \(tournamentId, privacy: .public) detail failed: \(String(describing: error), privacy: .public); retrying in \(delay.seconds, format: .fixed(precision: 1))s")
                broadcaster.send(.reconnecting(attempt: backoff.attempt, nextRetryIn: delay))
                guard await sleep(delay) else { return }
                continue
            }

            if detail.summary.isFinished {
                log.info("Arena \(tournamentId, privacy: .public) is finished; ending the featured stream")
                return
            }

            guard let featured = detail.featured, featured.gameId != lastGameId else {
                // No featured game yet, or still the one we just finished: wait and look again.
                guard await sleep(pollInterval) else { return }
                continue
            }

            lastGameId = featured.gameId
            log.info("Arena \(tournamentId, privacy: .public) featuring game \(featured.gameId, privacy: .public)")
            broadcaster.send(.live)
            do {
                // The arena knows where the game stands, so the replay's last ply is exact
                // rather than guessed from the timing of the lines.
                for try await sourced in gameStream.sourcedEvents(gameId: featured.gameId, liveFen: featured.fen) {
                    try Task.checkCancellation()
                    continuation.yield(.event(sourced))
                }
            } catch {
                if Task.isCancelled || error.isCancellation { return }
                // A failed game stream is not fatal to the arena: go back to polling.
                log.error("Arena \(tournamentId, privacy: .public) game \(featured.gameId, privacy: .public) stream failed: \(String(describing: error), privacy: .public)")
            }
            if Task.isCancelled { return }
            // A stream that ran to its terminal line left the reason behind; one that merely
            // dropped left nothing, and the board just stays where it was.
            if let termination = gameStream.termination(forGameId: featured.gameId) {
                continuation.yield(.gameEnded(gameId: termination.gameId, status: termination.status))
            }
            // The game is over (or dropped). Poll until a different one is featured.
            guard await sleep(pollInterval) else { return }
        }
    }

    /// `false` when the sleep was cancelled.
    private func sleep(_ duration: Duration) async -> Bool {
        do { try await Task.sleep(for: duration); return true } catch { return false }
    }
}
