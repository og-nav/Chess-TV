import Foundation
import ChessCore

/// Follows one board of a broadcast round by polling `/api/broadcast/-/-/{roundId}`.
///
/// There is a per-round PGN push stream, but a single board is cheaper and simpler to poll:
/// the round payload is a few kilobytes and carries the FEN, last move, status and both clocks
/// for every board at once. The first successful poll emits `.featured` and `.fen`; after that
/// `.fen` is emitted **only when the position or a clock changed**, so an idle board costs the
/// consumer nothing. The stream finishes normally once the board's `status` is a result
/// (`"1-0"`, `"0-1"`, `"½-½"`), after emitting the final position.
public final class BroadcastBoardStream: @unchecked Sendable {   // @unchecked: every stored property is immutable

    private let client: BroadcastClient
    private let pollInterval: Duration
    private let errorPollInterval: Duration
    private let minimumRateLimitDelay: Duration
    private let broadcaster = ConnectionStateBroadcaster()

    /// - Parameters:
    ///   - pollInterval: normal cadence between round fetches.
    ///   - errorPollInterval: cadence after a failed fetch.
    ///   - minimumRateLimitDelay: floor applied after HTTP 429, as `TVFeedStream` does.
    public init(
        client: BroadcastClient = BroadcastClient(),
        pollInterval: Duration = .seconds(5),
        errorPollInterval: Duration = .seconds(30),
        minimumRateLimitDelay: Duration = .seconds(60)
    ) {
        self.client = client
        self.pollInterval = pollInterval
        self.errorPollInterval = errorPollInterval
        self.minimumRateLimitDelay = minimumRateLimitDelay
    }

    /// Convenience initialiser for a custom base URL (tests, or a mirror).
    public convenience init(
        baseURL: URL,
        pollInterval: Duration = .seconds(5),
        errorPollInterval: Duration = .seconds(30)
    ) {
        self.init(
            client: BroadcastClient(baseURL: baseURL),
            pollInterval: pollInterval,
            errorPollInterval: errorPollInterval
        )
    }

    public var connectionStates: AsyncStream<ConnectionState> { broadcaster.subscribe() }
    public var currentConnectionState: ConnectionState? { broadcaster.current }
    public func finish() { broadcaster.finish() }

    public func events(roundId: String, gameId: String) -> AsyncThrowingStream<TVEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                await self.run(roundId: roundId, gameId: gameId, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Poll loop

    private func run(
        roundId: String,
        gameId: String,
        continuation: AsyncThrowingStream<TVEvent, Error>.Continuation
    ) async {
        var emittedFeatured = false
        var lastFen: String?
        var lastClocks: (Int?, Int?) = (nil, nil)
        var attempt = 0

        broadcaster.send(.connecting)
        while !Task.isCancelled {
            let boards: [BroadcastBoard]
            do {
                boards = try await client.round(id: roundId).boards
                attempt = 0
            } catch {
                if Task.isCancelled || error.isCancellation { return }
                if let lichess = error as? LichessError, lichess.isUnrecoverable {
                    log.error("Broadcast round \(roundId, privacy: .public) failed: \(lichess.description, privacy: .public)")
                    broadcaster.send(.failed(lichess.description))
                    continuation.finish(throwing: lichess)
                    return
                }
                attempt += 1
                var delay = errorPollInterval
                if case .rateLimited(let retryAfter)? = error as? LichessError {
                    delay = max(delay, minimumRateLimitDelay)
                    if let retryAfter { delay = max(delay, retryAfter) }
                }
                log.error("Broadcast round \(roundId, privacy: .public) poll failed: \(String(describing: error), privacy: .public); retrying in \(delay.seconds, format: .fixed(precision: 1))s")
                broadcaster.send(.reconnecting(attempt: attempt, nextRetryIn: delay))
                guard await sleep(delay) else { return }
                continue
            }

            guard let board = boards.first(where: { $0.gameId == gameId }) else {
                // The round has not published this board yet (games[] is empty before it starts).
                guard await sleep(pollInterval) else { return }
                continue
            }

            let white = board.white?.clockSeconds
            let black = board.black?.clockSeconds
            if !emittedFeatured {
                emittedFeatured = true
                broadcaster.send(.live)
                continuation.yield(.featured(
                    gameId: board.gameId,
                    orientation: .white,
                    players: [
                        Self.player(board.white, color: .white),
                        Self.player(board.black, color: .black),
                    ],
                    fen: board.fen
                ))
            }
            if board.fen != lastFen || white != lastClocks.0 || black != lastClocks.1 {
                lastFen = board.fen
                lastClocks = (white, black)
                continuation.yield(.fen(fen: board.fen, lastMove: board.lastMove, whiteClock: white, blackClock: black))
            }

            if !board.isOngoing {
                log.info("Broadcast board \(gameId, privacy: .public) finished: \(board.status, privacy: .public)")
                return
            }
            guard await sleep(pollInterval) else { return }
        }
    }

    private static func player(_ player: BroadcastPlayer?, color: PieceColor) -> TVPlayer {
        TVPlayer(
            name: player?.name ?? "Unknown",
            title: player?.title,
            rating: player?.rating,
            color: color,
            secondsRemaining: player?.clockSeconds
        )
    }

    private func sleep(_ duration: Duration) async -> Bool {
        do { try await Task.sleep(for: duration); return true } catch { return false }
    }
}
