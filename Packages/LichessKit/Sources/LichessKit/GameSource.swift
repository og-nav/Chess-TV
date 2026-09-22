import Foundation

/// Where a board on screen gets its moves from.
///
/// The three live sources the app offers — a Lichess TV channel, an arena's featured game and
/// one board of a tournament broadcast — all produce `TVEvent`s, so the UI only has to know
/// which `GameSource` it is showing.
public enum GameSource: Sendable, Equatable, Hashable {
    case tvChannel(TVChannel)
    case arena(tournamentId: String)
    case broadcastBoard(roundId: String, gameId: String)

    /// A short human label. Arenas and broadcasts carry only ids here, so the caller should
    /// prefer the tournament's own name when it has already fetched it.
    public var displayTitle: String {
        switch self {
        case .tvChannel(let channel): "Lichess TV — \(channel.displayName)"
        case .arena(let tournamentId): "Arena \(tournamentId)"
        case .broadcastBoard(_, let gameId): "Broadcast board \(gameId)"
        }
    }

    /// `true` when standard-chess engine analysis is meaningful for this source.
    /// Arenas and broadcasts can be variant events, so only TV channels are classified here.
    public var isStandardChess: Bool {
        switch self {
        case .tvChannel(let channel): channel.isStandardChess
        case .arena, .broadcastBoard: true
        }
    }
}

/// One entry point for every live board the app can show.
///
/// Hands back the right stream for a `GameSource` and republishes that stream's connection
/// states on its own `connectionStates`, so a view can bind to a single client and switch
/// sources without rewiring anything.
///
/// ## History
///
/// Every source now starts with the moves that were already played, so a viewer who joins at
/// move 30 gets the whole game rather than a board in an unexplained position:
///
/// * **`.tvChannel`** is a two-stage stream. The channel feed is watched only for *which* game
///   is featured; that game is then streamed from `/api/stream/game/{id}`, which replays it from
///   move one. When the channel promotes a different game — the old one ended, or a better one
///   started — the game stream is swapped for the new one, which again begins with its history.
/// * **`.broadcastBoard`** reads the round's PGN push stream (`BroadcastPGNStream`), replaying
///   the movetext into one event per ply. `BroadcastBoardStream`, which polls and has no
///   history, is kept as the fallback for a round whose PGN will not parse.
/// * **`.arena`** is the same two stages as a TV channel, with the arena's own polling standing
///   in for the channel feed: the featured game is streamed from `/api/stream/game/{id}`, so it
///   too arrives with its history marked and is fast-forwarded rather than played out.
///
/// ## The end of a game
///
/// `TVEvent` is frozen and cannot carry a result, so `sourcedEvents(for:)` produces `FeedItem`s:
/// an event, or `.gameEnded` with the terminal status Lichess reported. A source that rotates —
/// a TV channel, an arena — then **holds** the next game back for `gameOverHold`, so the board
/// that just finished stays on screen long enough to be read.
///
/// `sourcedEvents(for:)` marks each event as history or live; `events(for:)` is the same stream
/// with the flag and the game-over item dropped, and is what `TVEvent`-only callers keep using.
public final class GameSourceStreamer: @unchecked Sendable {   // @unchecked: mutable state is lock-guarded

    private let tvFeed: TVFeedStream
    private let games: GameStream
    private let arenaFeatured: ArenaFeaturedStream
    private let broadcastPGN: BroadcastPGNStream
    private let broadcastBoards: BroadcastBoardStream
    private let broadcaster = ConnectionStateBroadcaster()

    private let lock = NSLock()
    private var forwarding: Task<Void, Never>?
    private var preferPolling: Bool
    private let hold: Duration
    private let switchGrace: Duration

    /// Allow a delayed game's final moves/result to arrive when the channel promotes its
    /// successor. A channel can also switch away from an ongoing game, so this wait is bounded.
    public static let gameSwitchGrace: Duration = .seconds(3)

    /// How long a finished game stays on screen before the next one starts arriving.
    ///
    /// Long enough to read the result and hear the chime, short enough that a bullet arena does
    /// not feel stalled. An arena's own poll interval already covers most of it; the hold is what
    /// makes a TV channel, which promotes the next game the moment the old one ends, behave the
    /// same way.
    public static let gameOverHold: Duration = .seconds(10)

    /// When `true`, `.broadcastBoard` polls the round JSON (`BroadcastBoardStream`) instead of
    /// reading the PGN push stream — no move history, but the older and cheaper path.
    /// Defaults to `false`: history is the point of this type.
    public var preferPollingForBroadcasts: Bool {
        get { lock.lock(); defer { lock.unlock() }; return preferPolling }
        set { lock.lock(); preferPolling = newValue; lock.unlock() }
    }

    public init(
        tvFeed: TVFeedStream = TVFeedStream(),
        arenaFeatured: ArenaFeaturedStream = ArenaFeaturedStream(),
        broadcastBoards: BroadcastBoardStream = BroadcastBoardStream(),
        games: GameStream = GameStream(),
        broadcastPGN: BroadcastPGNStream = BroadcastPGNStream(),
        preferPollingForBroadcasts: Bool = false,
        gameOverHold: Duration = GameSourceStreamer.gameOverHold,
        gameSwitchGrace: Duration = GameSourceStreamer.gameSwitchGrace
    ) {
        self.tvFeed = tvFeed
        self.arenaFeatured = arenaFeatured
        self.broadcastBoards = broadcastBoards
        self.games = games
        self.broadcastPGN = broadcastPGN
        self.preferPolling = preferPollingForBroadcasts
        self.hold = gameOverHold
        self.switchGrace = gameSwitchGrace
    }

    /// Convenience initialiser pointing every underlying client at one base URL.
    public convenience init(
        baseURL: URL,
        configuration: TVFeedStream.Configuration = TVFeedStream.Configuration(),
        preferPollingForBroadcasts: Bool = false,
        gameOverHold: Duration = GameSourceStreamer.gameOverHold,
        gameSwitchGrace: Duration = GameSourceStreamer.gameSwitchGrace
    ) {
        self.init(
            tvFeed: TVFeedStream(baseURL: baseURL, configuration: configuration),
            arenaFeatured: ArenaFeaturedStream(baseURL: baseURL),
            broadcastBoards: BroadcastBoardStream(baseURL: baseURL),
            games: GameStream(baseURL: baseURL, configuration: configuration),
            broadcastPGN: BroadcastPGNStream(baseURL: baseURL, configuration: configuration),
            preferPollingForBroadcasts: preferPollingForBroadcasts,
            gameOverHold: gameOverHold,
            gameSwitchGrace: gameSwitchGrace
        )
    }

    /// Connection states of whichever source was most recently requested.
    public var connectionStates: AsyncStream<ConnectionState> { broadcaster.subscribe() }
    public var currentConnectionState: ConnectionState? { broadcaster.current }

    /// The reason the last `.tvChannel` game or `.broadcastBoard` finished, when it finished.
    public var lastGameTermination: GameStream.Termination? { games.lastTermination }
    public var lastBroadcastResult: BroadcastPGNStream.Termination? { broadcastPGN.lastResult }

    /// Retires the streamer and every underlying client.
    public func finish() {
        lock.lock()
        let task = forwarding
        forwarding = nil
        lock.unlock()
        task?.cancel()
        tvFeed.finish()
        games.finish()
        arenaFeatured.finish()
        broadcastPGN.finish()
        broadcastBoards.finish()
        broadcaster.finish()
    }

    /// The event stream for a source. Starting a new source replaces the connection-state
    /// forwarding, so `connectionStates` always describes the source you last asked for.
    public func events(for source: GameSource) -> AsyncThrowingStream<TVEvent, Error> {
        let sourced = sourcedEvents(for: source)
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do {
                    for try await item in sourced {
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

    /// The same stream, with each event marked as replayed history or live play, and the end of
    /// a game reported as its own item.
    ///
    /// (A second `events(for:)` overload differing only in its element type would make every
    /// existing `for try await … in streamer.events(for:)` ambiguous, so the history-carrying
    /// stream gets its own name.)
    public func sourcedEvents(for source: GameSource) -> AsyncThrowingStream<FeedItem, Error> {
        switch source {
        case .tvChannel(let channel):
            forward(tvFeed.connectionStates, games.connectionStates)
            return held(stream { await self.runTVChannel(channel: channel, continuation: $0) })
        case .arena(let tournamentId):
            forward(arenaFeatured.connectionStates)
            return held(arenaFeatured.sourcedEvents(tournamentId: tournamentId))
        case .broadcastBoard(let roundId, let gameId):
            forward(broadcastPGN.connectionStates, broadcastBoards.connectionStates)
            // One board, one game: the stream itself finishing *is* the end of it, so there is
            // nothing to hold back.
            return stream { await self.runBroadcastBoard(roundId: roundId, gameId: gameId, continuation: $0) }
        }
    }

    // MARK: - TV channel: which game, then that game with its history

    /// Watches the channel feed for the featured game id and streams that game in full.
    ///
    /// Only `.featured` matters here: the feed's own `.fen` events are dropped, because the game
    /// stream carries the same moves *plus* everything that came before them. A new featured id
    /// gives the game in flight a bounded grace period to finish before starting the next one.
    private func runTVChannel(
        channel: TVChannel,
        continuation: AsyncThrowingStream<FeedItem, Error>.Continuation
    ) async {
        let gate = EventGate(continuation: continuation)
        var currentId: String?
        var gameTask: Task<Void, Never>?
        defer { gameTask?.cancel() }

        do {
            for try await event in tvFeed.events(for: channel) {
                guard case .featured(let gameId, _, _, let liveFen) = event else { continue }
                guard gameId != currentId else { continue }
                if let gameTask { await drainEnding(of: gameTask) }
                try Task.checkCancellation()
                log.info("TV channel \(channel.rawValue, privacy: .public) featured game is now \(gameId, privacy: .public)")
                currentId = gameId
                gameTask?.cancel()
                let generation = gate.startGeneration()
                gameTask = Task { [games, gate] in
                    do {
                        for try await sourced in games.sourcedEvents(gameId: gameId, liveFen: liveFen) {
                            gate.yield(.event(sourced), generation: generation)
                        }
                    } catch {
                        guard !Task.isCancelled, !error.isCancellation else { return }
                        log.error("Game \(gameId, privacy: .public) stream failed: \(String(describing: error), privacy: .public)")
                        return
                    }
                    guard !Task.isCancelled else { return }
                    // The stream ran to its terminal line: say so, and let the hold keep the next
                    // game off the screen for a moment.
                    if let termination = games.termination(forGameId: gameId) {
                        gate.yieldGameEnded(.gameEnded(gameId: termination.gameId, status: termination.status), generation: generation)
                    }
                }
            }
        } catch {
            guard !Task.isCancelled, !error.isCancellation else { return }
            continuation.finish(throwing: error)
        }
    }

    private func drainEnding(of gameTask: Task<Void, Never>) async {
        let timeout = Task { [switchGrace] in
            do { try await Task.sleep(for: switchGrace) } catch { return }
            gameTask.cancel()
        }
        defer { timeout.cancel() }
        await withTaskCancellationHandler {
            await gameTask.value
        } onCancel: {
            gameTask.cancel()
        }
    }

    // MARK: - Broadcast board: PGN first, polling as the fallback

    private func runBroadcastBoard(
        roundId: String,
        gameId: String,
        continuation: AsyncThrowingStream<FeedItem, Error>.Continuation
    ) async {
        if !preferPollingForBroadcasts {
            do {
                for try await event in broadcastPGN.sourcedEvents(roundId: roundId, gameId: gameId) {
                    continuation.yield(.event(event))
                }
                return                                          // the board finished
            } catch {
                if Task.isCancelled || error.isCancellation { return }
                let fallback = error is BroadcastPGNStream.UnparseablePGN
                    || (error as? LichessError)?.isUnrecoverable == true
                guard fallback else {
                    continuation.finish(throwing: error)
                    return
                }
                log.error("Broadcast PGN for \(gameId, privacy: .public) unusable (\(String(describing: error), privacy: .public)); falling back to polling the round")
            }
        }

        do {
            for try await event in broadcastBoards.events(roundId: roundId, gameId: gameId) {
                // Polling has no history to offer: every position it reports is the current one.
                continuation.yield(.event(SourcedEvent(event: event, isHistorical: false)))
            }
        } catch {
            guard !Task.isCancelled, !error.isCancellation else { return }
            continuation.finish(throwing: error)
        }
    }

    // MARK: - Plumbing

    private func stream(
        _ body: @escaping @Sendable (AsyncThrowingStream<FeedItem, Error>.Continuation) async -> Void
    ) -> AsyncThrowingStream<FeedItem, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                await body(continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Gives a finished game the screen to itself for `gameOverHold`.
    ///
    /// The first item *after* a `.gameEnded` waits out whatever is left of the hold, so the
    /// arena — which already sits out its poll interval — usually waits no longer than it did,
    /// while a TV channel, which can promote the next game instantly, is slowed to the same
    /// pace. Nothing is dropped: the upstream buffer keeps the next game's replay, which the
    /// consumer fast-forwards through anyway. A source that never ends a game (the first game of
    /// a channel, or a swap away from one still in progress) is never held.
    private func held(_ upstream: AsyncThrowingStream<FeedItem, Error>) -> AsyncThrowingStream<FeedItem, Error> {
        let hold = self.hold
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                var endedAt: ContinuousClock.Instant?
                do {
                    for try await item in upstream {
                        if let end = endedAt {
                            endedAt = nil
                            let remaining = hold - end.duration(to: .now)
                            if remaining > .zero { try await Task.sleep(for: remaining) }
                        }
                        if case .gameEnded = item { endedAt = .now }
                        continuation.yield(item)
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled || error.isCancellation {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func forward(_ states: AsyncStream<ConnectionState>...) {
        let task = Task { [broadcaster] in
            await withTaskGroup(of: Void.self) { group in
                for stream in states {
                    group.addTask {
                        for await state in stream {
                            if Task.isCancelled { return }
                            broadcaster.send(state)
                        }
                    }
                }
            }
        }
        lock.lock()
        let previous = forwarding
        forwarding = task
        lock.unlock()
        previous?.cancel()
    }
}

/// Keeps a cancelled game stream from writing into the output after its successor started.
///
/// Cancellation is not instantaneous: the task streaming the old game can be part-way through a
/// `yield` when the channel promotes a new game. Every game stream is given a generation, and
/// only the newest one's events are let through.
private final class EventGate: @unchecked Sendable {   // @unchecked: state is lock-guarded
    private let lock = NSLock()
    private var generation = 0
    /// Whether the newest generation has put anything on screen yet.
    private var yielded = false
    private let continuation: AsyncThrowingStream<FeedItem, Error>.Continuation

    init(continuation: AsyncThrowingStream<FeedItem, Error>.Continuation) {
        self.continuation = continuation
    }

    /// Opens a new generation and returns its number.
    func startGeneration() -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        yielded = false
        return generation
    }

    // The yields are made under the lock — `yield` on an unbounded continuation neither suspends
    // nor calls back in — so two racing game streams cannot interleave their items.

    func yield(_ item: FeedItem, generation: Int) {
        lock.lock(); defer { lock.unlock() }
        guard generation == self.generation else { return }
        yielded = true
        continuation.yield(item)
    }

    /// The end of a game, which is allowed through one generation late.
    ///
    /// The channel promotes the next game the moment the old one ends, so the feed's `.featured`
    /// and the finished game's own last breath race. Losing that race must not cost the viewer
    /// the result — but only while the new game has yet to show anything, because after that the
    /// result would be read as belonging to the game now on screen.
    func yieldGameEnded(_ item: FeedItem, generation: Int) {
        lock.lock(); defer { lock.unlock() }
        let isCurrent = generation == self.generation
        let isLastGasp = generation == self.generation - 1 && !yielded
        guard isCurrent || isLastGasp else { return }
        continuation.yield(item)
    }
}
