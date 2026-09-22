// The one object that owns everything with a lifetime: the source stream, the engine, the clock
// ticker, the sounds and the settings. Views only read GameState and AppSettings through it.
import Foundation
import SwiftUI
import ChessCore
import ChessUI
import LichessKit
import EngineKit
import ImageryKit
#if canImport(UIKit)
import UIKit
#endif

/// What AppModel needs from `GameSourceStreamer`. Declared here so the tests can hand the model
/// a fake; `GameSourceStreamer` itself already has this shape.
public protocol SourceStreaming: Sendable {
    /// Events with the history flag — the streamer replays the moves already played first —
    /// and the game-over item that ends each of them.
    func sourcedEvents(for source: GameSource) -> AsyncThrowingStream<FeedItem, Error>
    var connectionStates: AsyncStream<ConnectionState> { get }
    func finish()
}

extension GameSourceStreamer: SourceStreaming {}

/// What AppModel needs from `ArenaClient`: one arena's live state. Declared here so the tests can
/// hand the model a fake and never reach the network; `ArenaClient` already has this shape.
public protocol ArenaDetailing: Sendable {
    func detail(id: String) async throws -> ArenaDetail
}

extension ArenaClient: ArenaDetailing {}

public protocol BroadcastRoundFetching: Sendable {
    func round(id: String) async throws -> (round: BroadcastTournament, boards: [BroadcastBoard])
}
extension BroadcastClient: BroadcastRoundFetching {}

/// The FIDE ids a portrait lookup has already been started for, one per side.
struct PortraitRequest: Equatable, Sendable {
    var white: Int?
    var black: Int?
}

/// The FIDE record lookup behind the portraits. A protocol so a test can make it fail the way
/// Lichess's anonymous rate limit does and check that the round's own pictures still show.
public protocol FIDEPlayerLooking: Sendable {
    func player(fideId: Int) async throws -> FIDEPlayer?
}
extension FIDEPlayerClient: FIDEPlayerLooking {}

public protocol EngineProviding: Sendable {
    func evaluate(fen: String, maxDepth: Int, revision: Int) async -> AsyncStream<Evaluation>
    func stop() async
    func shutdown() async
}
extension UCIEngine: EngineProviding {}

@Observable
@MainActor
public final class GameSession {

    // MARK: - Owned state

    public let settings: AppSettings
    public let game = GameState()
    public var state: GameState { game }
    /// Index into the available history. Nil follows live play; zero is its starting position.
    public var viewedPly: Int? {
        didSet {
            if let ply = viewedPly, !(0...game.moveHistory.count).contains(ply) { viewedPly = nil }
            scrubEvaluation = nil
            requestEvaluation()
        }
    }
    public var viewedPosition: Position? {
        guard let ply = viewedPly else { return game.position }
        if ply == 0 { return game.reducer.initialPosition }
        guard game.moveHistory.indices.contains(ply - 1) else { return game.position }
        return try? Position(fen: game.moveHistory[ply - 1].fen)
    }
    public var viewedLastMove: LastMove? {
        guard let ply = viewedPly else { return game.lastMove }
        guard ply > 0, game.moveHistory.indices.contains(ply - 1), let position = viewedPosition else { return nil }
        return LastMove(uci: game.moveHistory[ply - 1].uci, position: position)
    }
    public private(set) var scrubEvaluation: Evaluation?
    public var viewedEvaluation: Evaluation? { viewedPly == nil ? game.evaluation : scrubEvaluation }
    public var viewedEvaluationText: String? {
        guard let evaluation = viewedEvaluation else { return nil }
        switch evaluation.score {
        case .centipawns(let value): return EvalMapping.displayString(centipawns: value)
        case .mate(let value): return EvalMapping.displayString(mateIn: value)
        }
    }
    public var viewedWhiteShare: Double? {
        guard let evaluation = viewedEvaluation else { return nil }
        switch evaluation.score {
        case .centipawns(let value): return EvalMapping.whiteShare(centipawns: value)
        case .mate(let value): return EvalMapping.whiteShare(mateIn: value)
        }
    }
    public func setViewedPly(_ ply: Int?) { viewedPly = ply }
    public private(set) var thermalLimited = false
    @ObservationIgnored private var isForeground = true
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var engineStopTask: Task<Void, Never>?
    @ObservationIgnored private var shuttingDown = false


    /// The header line for whatever the game screen is showing.
    public private(set) var sourceTitle = ""
    /// Federations for the two sides, when a broadcast board told us.
    public private(set) var whiteFederation: String?
    public private(set) var blackFederation: String?
    /// FIDE records for the two sides, once looked up: the portrait and the photographer.
    public private(set) var whiteFIDEPlayer: FIDEPlayer?
    public private(set) var blackFIDEPlayer: FIDEPlayer?
    /// The portraits the broadcast round itself published for these two players. They arrive with
    /// the boards, so they are what the panel shows while — or instead of — the FIDE lookup.
    public private(set) var whitePhoto: PlayerPhoto?
    public private(set) var blackPhoto: PlayerPhoto?
    /// True while history is reduced privately. The board and move list publish together once
    /// the stream reaches its live boundary; analysis starts on that final position.
    public private(set) var isReplayingHistory = false
    /// The tournament alert in the header right now, if one is showing.
    public private(set) var toast: TournamentAlert?
    /// The open arena's leaderboard as of the last poll. `nil` for every other kind of source:
    /// the public API has no leaderboard for broadcasts, and TV channels have no standings.
    public private(set) var arenaStandings: ArenaStandings?

    /// Bumped by the one-second ticker. Reading it inside a view body is what makes the clocks
    /// redraw; `displayedClock` does that read for its callers.
    public private(set) var tick = 0
    /// The wall clock in the header.
    public private(set) var wallClock = Date()

    // MARK: - Machinery

    /// One streamer for the app's lifetime; `finish()` is only called on teardown.
    @ObservationIgnored private let streamer: any SourceStreaming
    @ObservationIgnored private let broadcasts: any BroadcastRoundFetching
    @ObservationIgnored private let arenas: any ArenaDetailing
    @ObservationIgnored private let fidePlayers: any FIDEPlayerLooking
    @ObservationIgnored private lazy var sounds = SoundBoard(set: settings.soundSet)

    @ObservationIgnored private var feedTask: Task<Void, Never>?
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var tickerTask: Task<Void, Never>?
    @ObservationIgnored private var evaluationTask: Task<Void, Never>?
    /// Fallback publication timer for streams without an explicit replay boundary.
    @ObservationIgnored private var historyEvaluationTask: Task<Void, Never>?
    @ObservationIgnored private var stagedHistory: GameReducer?
    @ObservationIgnored private var historyResetsScrub = false
    @ObservationIgnored private var historyConfirmsGame = false
    @ObservationIgnored private var hasPreviewResult = false
    @ObservationIgnored private var titleTask: Task<Void, Never>?
    @ObservationIgnored private var openingRoundTask: Task<(round: BroadcastTournament, boards: [BroadcastBoard])?, Never>?
    @ObservationIgnored private var liveClockRevision: UInt64 = 0
    @ObservationIgnored private var joinClock: GamePreview?
    @ObservationIgnored private var clockRepairTask: Task<Void, Never>?
    @ObservationIgnored private var clockRepairID = UUID()
    /// One per lookup started for the open board — never more than two, and they are only ever
    /// cancelled together, when the source goes away.
    @ObservationIgnored private var portraitTasks: [Task<Void, Never>] = []
    /// Which ids those lookups were started for, so no id is ever asked for twice.
    @ObservationIgnored private var portraitRequest = PortraitRequest()
    /// Polls the round behind a broadcast board for results and time scrambles elsewhere.
    @ObservationIgnored private var roundWatchTask: Task<Void, Never>?
    /// Polls the open arena for its standing and its remaining time.
    @ObservationIgnored private var arenaStandingsTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var toastQueue: [TournamentAlert] = []
    @ObservationIgnored private var engineStartTask: Task<UCIEngine?, Never>?

    @ObservationIgnored private var engine: (any EngineProviding)?
    @ObservationIgnored private var didStart = false
    /// What the game screen is showing, nil while the home screen is up.
    @ObservationIgnored public private(set) var openDestination: GameDestination?
    /// Milestones of the current opening, written to the `timing` log. See `OpenTiming`.
    @ObservationIgnored public private(set) var openTiming: OpenTiming?
    @ObservationIgnored private var pendingTap: ContinuousClock.Instant?

    public static let networkResourceName = "nn-1a298aa575a0"
    /// The engine keeps deepening on the shown position until the depth the user picked in
    /// Settings, or until the next move supersedes the search. Classical and broadcast games
    /// leave minutes between moves, so a fixed time slice would stop far too early; the cap is
    /// a depth instead, and `EngineDepth` is how the user trades heat for sharper evaluation.
    /// The silence after the last replayed move that counts as "the burst is over".
    public static let historySettleDelay: Duration = .milliseconds(1500)
    /// How often the round behind a broadcast board is polled for alerts.
    public static let roundWatchInterval: Duration = .seconds(30)
    /// How often the open arena's standing is refreshed. Lichess asks clients to be gentle, and
    /// one detail request every ten seconds per open arena is well inside that.
    public static let arenaStandingsInterval: Duration = .seconds(10)
    /// The longest an arena poll waits after a run of failures.
    public static let arenaStandingsMaxInterval: Duration = .seconds(80)
    /// How long one toast stays in the header.
    public static let toastDuration: Duration = .seconds(7)

    public init(
        settings: AppSettings = AppSettings(),
        streamer: any SourceStreaming = GameSourceStreamer(),
        arenas: any ArenaDetailing = ArenaClient(),
        engine: (any EngineProviding)? = nil,
        broadcasts: any BroadcastRoundFetching = BroadcastClient(),
        fidePlayers: any FIDEPlayerLooking = FIDEPlayerClient.shared
    ) {
        self.settings = settings
        self.streamer = streamer
        self.arenas = arenas
        self.engine = engine
        self.broadcasts = broadcasts
        self.fidePlayers = fidePlayers
    }

    // MARK: - Launch

    public func start() {
        guard !didStart else { return }
        didStart = true
        if settings.sounds { _ = sounds }
        observeConnection()
        startTicker()
        if settings.engineEnabled { startEngine() }
    }

    /// Retires the streamer. Only the app teardown calls this.
    public func teardown() {
        appLog.notice("Teardown: finishing the streamer")
        close()
        connectionTask?.cancel()
        tickerTask?.cancel()
        streamer.finish()
        didStart = false
        isForeground = false
    }

    // MARK: - Opening and closing a source

    /// Starts one source. Any previous one is cancelled first, so the model only ever has a
    /// single live feed.
    public func open(_ destination: GameDestination) {
        let source = destination.source
        if openDestination?.source == source, feedTask != nil { return }
        appLog.notice("Opening \(source.storageKey, privacy: .public)")
        openTiming?.summarise(reason: "replaced")
        openTiming = OpenTiming(source: source.storageKey, start: pendingTap ?? .now, fromTap: pendingTap != nil)
        pendingTap = nil
        cancelFeed()
        game.clearGame()
        viewedPly = nil
        game.connection = .connecting
        game.source = source
        openDestination = destination
        whiteFederation = destination.whiteFederation
        blackFederation = destination.blackFederation
        whiteFIDEPlayer = nil
        blackFIDEPlayer = nil
        whitePhoto = destination.whitePhoto
        blackPhoto = destination.blackPhoto
        isReplayingHistory = false
        sourceTitle = destination.title ?? SourceTitle.text(for: source)
        settings.lastSource = source
        if case .broadcastBoard(let roundId, let gameId) = source {
            game.hasReliableClocks = false
            if let preview = destination.preview, preview.board.gameId == gameId,
               (try? Position(fen: preview.board.fen)) != nil {
                game.seed(preview)
                hasPreviewResult = !preview.board.isOngoing
                joinClock = preview
                game.hasReliableClocks = preview.clocksRunning
                isReplayingHistory = true
                BroadcastReplayWarmup.retainMatching(roundId: roundId, gameId: gameId, fen: preview.board.fen)
                markTiming(.board)
            }
            // One round read supplies missing metadata/current clocks and the first alert poll.
            let client = broadcasts
            openingRoundTask = Task { try? await client.round(id: roundId) }
            resolveTitle(for: source)
        } else if destination.title == nil { resolveTitle(for: source) }
        loadPortraits(white: destination.whiteFideId, black: destination.blackFideId, for: source)
        startFeed(for: source)
        startRoundWatch(for: source)
        startArenaStandings(for: source)
        if ProcessInfo.processInfo.arguments.contains("-demoAlert") { demoAlert() }
    }

    /// `-demoAlert`: one sample toast a few seconds after opening, so the header can be checked
    /// on the simulator without waiting for a real round to produce one.
    private func demoAlert() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.enqueue([
                TournamentAlert(kind: .result, headline: "Board 3", detail: "GM Abdusattorov beat GM Caruana"),
                TournamentAlert(kind: .timeScramble, headline: "Board 7", detail: "Time scramble: GM So \u{2013} GM Erigaisi, both under 5:00"),
            ])
        }
    }

    /// Convenience for the shelves, which always know the title they showed.
    public func open(source: GameSource, title: String? = nil) {
        open(GameDestination(source: source, title: title))
    }

    /// The screen that is about to push a game calls this on the tap, so the opening is timed
    /// from what the person did rather than from when the session heard about it.
    public func noteNavigationTap() { pendingTap = .now }

    /// The game screen is on screen.
    public func noteScreenAppeared() { markTiming(.screen) }

    private func markTiming(_ milestone: OpenTiming.Milestone) {
        guard openTiming != nil, openTiming!.mark(milestone) else { return }
        if openTiming!.isComplete { openTiming!.summarise(reason: "opened") }
    }

    /// `clocks` means the clocks shown are counting down from a trusted anchor: live connection,
    /// a reading, and nothing marking it as a historical after-move value.
    private func markClocksIfLive() {
        if game.clocksAreLive, game.clocks != nil { markTiming(.clocks) }
    }

    /// The game screen went away: stop everything that source was doing.
    public func close() {
        guard openDestination != nil || feedTask != nil else { return }
        appLog.notice("Closing the current source")
        openTiming?.summarise(reason: "closed")
        openTiming = nil
        cancelFeed()
        game.clearGame()
        game.connection = .connecting
        openDestination = nil
        whiteFederation = nil
        blackFederation = nil
        whiteFIDEPlayer = nil
        blackFIDEPlayer = nil
        whitePhoto = nil
        blackPhoto = nil
        isReplayingHistory = false
        sourceTitle = ""
    }

    private func cancelFeed() {
        discardHistory()
        searchGeneration &+= 1
        feedTask?.cancel()
        feedTask = nil
        titleTask?.cancel()
        titleTask = nil
        openingRoundTask?.cancel()
        openingRoundTask = nil
        joinClock = nil
        liveClockRevision = 0
        hasPreviewResult = false
        clockRepairTask?.cancel(); clockRepairTask = nil
        clockRepairID = UUID()
        for task in portraitTasks { task.cancel() }
        portraitTasks = []
        portraitRequest = PortraitRequest()
        historyEvaluationTask?.cancel()
        historyEvaluationTask = nil
        evaluationTask?.cancel()
        evaluationTask = nil
        roundWatchTask?.cancel()
        roundWatchTask = nil
        arenaStandingsTask?.cancel()
        arenaStandingsTask = nil
        arenaStandings = nil
        toastTask?.cancel()
        toastTask = nil
        toastQueue = []
        toast = nil
        stopEngineSearch()
    }

    // MARK: - Tournament alerts

    /// Broadcast boards only: the round list is polled and diffed, and whatever changed on the
    /// other boards becomes a toast. Nothing is fetched while the setting is off.
    private func startRoundWatch(for source: GameSource) {
        guard case .broadcastBoard(let roundId, let gameId) = source else { return }
        roundWatchTask = Task { @MainActor [weak self] in
            var detector = RoundAlertDetector()
            let initialRound = self?.openingRoundTask
            var isFirstRead = true
            while !Task.isCancelled {
                guard let self else { return }
                if self.settings.tournamentAlerts {
                    do {
                        let fetched: (round: BroadcastTournament, boards: [BroadcastBoard])
                        if isFirstRead, let initial = await initialRound?.value { fetched = initial }
                        else { fetched = try await self.broadcasts.round(id: roundId) }
                        isFirstRead = false
                        guard !Task.isCancelled, self.game.source == source else { return }
                        self.enqueue(detector.alerts(for: fetched.boards, watching: gameId))
                    } catch {
                        if error is CancellationError { return }
                        appLog.notice("Round watch \(roundId, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    }
                } else {
                    detector.reset()
                }
                isFirstRead = false
                do { try await Task.sleep(for: Self.roundWatchInterval) } catch { return }
            }
        }
    }

    /// Queues alerts for the header and starts showing them if nothing is up.
    public func enqueue(_ alerts: [TournamentAlert]) {
        guard !alerts.isEmpty else { return }
        for alert in alerts { appLog.notice("Alert: \(alert.text, privacy: .public)") }
        toastQueue.append(contentsOf: alerts)
        showNextToast()
    }

    private func showNextToast() {
        guard toastTask == nil, !toastQueue.isEmpty else { return }
        let next = toastQueue.removeFirst()
        toast = next
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.toastDuration)
            guard let self, !Task.isCancelled else { return }
            self.toast = nil
            // A short gap, so two toasts in a row read as two.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self.toastTask = nil
            self.showNextToast()
        }
    }

    // MARK: - Arena standings

    /// Arenas only: the top of the leaderboard, polled while the arena is on screen. The featured
    /// stream fetches the same endpoint only between games, so the panel gets its own poll rather
    /// than waiting for the next pairing; one request every ten seconds is the whole cost.
    private func startArenaStandings(for source: GameSource) {
        guard case .arena(let tournamentId) = source else { return }
        arenaStandingsTask = Task { @MainActor [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let detail = try await self.arenas.detail(id: tournamentId)
                    guard !Task.isCancelled, self.game.source == source else { return }
                    failures = 0
                    self.arenaStandings = ArenaStandings(
                        rows: detail.standings,
                        playerCount: detail.summary.nbPlayers,
                        secondsToFinish: detail.summary.secondsToFinish,
                        receivedAt: .now
                    )
                } catch {
                    if error is CancellationError { return }
                    failures += 1
                    appLog.notice("Arena standings \(tournamentId, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
                do { try await Task.sleep(for: Self.arenaStandingsDelay(afterFailures: failures)) } catch { return }
            }
        }
    }

    /// Ten seconds while the polls land, doubling up to `arenaStandingsMaxInterval` while they do not.
    public static func arenaStandingsDelay(afterFailures failures: Int) -> Duration {
        guard failures > 0 else { return arenaStandingsInterval }
        let scaled = arenaStandingsInterval * (1 << min(failures - 1, 8))
        return min(scaled, arenaStandingsMaxInterval)
    }

    /// The arena's remaining time for the header, counted down locally between polls.
    public var arenaTimeLeftText: String? {
        _ = tick   // registers this view body with the one-second ticker
        return arenaTimeLeftText(at: .now)
    }

    /// Split out so a test can ask for a definite instant.
    public func arenaTimeLeftText(at now: ContinuousClock.Instant) -> String? {
        guard case .arena = game.source, let standings = arenaStandings else { return nil }
        guard let seconds = standings.secondsLeft(at: now) else { return nil }
        return ClockDisplay.text(seconds)
    }

    /// The two players on the board, so the standings panel can mark their rows.
    public var boardPlayerNames: Set<String> {
        Set([game.white?.name, game.black?.name].compactMap { $0 })
    }

    // MARK: - Feed

    /// Give SwiftUI time to render each live ply, including moves delivered together at the
    /// end of a game. History still reduces atomically without this presentation delay.
    static let liveMoveDisplayDuration: Duration = .milliseconds(350)

    private func observeConnection() {
        guard connectionTask == nil else { return }
        let states = streamer.connectionStates
        connectionTask = Task { @MainActor [weak self] in
            for await state in states {
                guard let self else { return }
                guard self.openDestination != nil else { continue }
                self.game.setConnection(state)
                self.markClocksIfLive()
                appLog.debug("Connection \(String(describing: state), privacy: .public)")
            }
        }
    }

    private func startFeed(for source: GameSource) {
        let stream = streamer.sourcedEvents(for: source)
        feedTask = Task { @MainActor [weak self] in
            do {
                for try await item in stream {
                    guard let self, !Task.isCancelled else { return }
                    switch item {
                    case .event(let sourced):
                        let previousRevision = self.game.revision
                        self.handle(sourced.event, isHistorical: sourced.isHistorical, historyComplete: sourced.historyComplete, isCached: sourced.isCached)
                        if !sourced.isHistorical, case .fen = sourced.event,
                           self.game.revision != previousRevision,
                           self.isForeground, self.viewedPly == nil {
                            // Suspend the consumer, not the network reader. Its unbounded queue
                            // preserves every subsequent move and keeps the result behind them.
                            try await Task.sleep(for: Self.liveMoveDisplayDuration)
                        }
                    case .gameEnded(let gameId, let status):
                        self.gameEnded(gameId: gameId, status: status)
                    }
                }
                guard let self, !Task.isCancelled else { return }
                await self.streamEnded(for: source)
            } catch {
                if error is CancellationError { return }
                appLog.error("Feed ended: \(String(describing: error), privacy: .public)")
                guard let self, !Task.isCancelled, self.game.source == source else { return }
                self.discardHistory()
                self.game.setConnection(.failed(String(describing: error)))
            }
        }
    }

    /// Reduce historical positions privately. Only a completed snapshot becomes observable;
    /// the visible board never walks through intermediate plies while joining a game.
    private func handle(_ event: TVEvent, isHistorical: Bool, historyComplete: Bool?, isCached: Bool = false) {
        if isHistorical {
            if stagedHistory == nil {
                stagedHistory = game.reducer
                isReplayingHistory = true
                evaluationTask?.cancel()
                stopEngineSearch()
            }
            if case .featured = event, !isCached { historyConfirmsGame = true }
            let previousRevision = stagedHistory?.revision
            stagedHistory?.apply(event)
            if case .featured = event, stagedHistory?.revision != previousRevision { historyResetsScrub = true }
            if historyComplete == true {
                publishHistory(evaluate: true)
            } else if historyComplete == nil {
                scheduleEvaluationAfterHistory(after: Self.historySettleDelay)
            } else {
                // The source knows more history is coming — but it can be wrong. A TV channel
                // that announced a game at move zero has a live position no replayed ply will
                // ever equal, so the boundary is never signalled and, without this, the moves
                // already played would stay invisible until the next live one. A longer settle
                // still keeps a normal replay atomic.
                scheduleEvaluationAfterHistory(after: Self.unsignalledHistorySettleDelay)
            }
            return
        }

        let previousFEN = game.position?.fen
        let outcome: MoveOutcome?
        if stagedHistory != nil {
            // Include the first live event in the same publication, avoiding one final
            // intermediate board when a legacy stream ends its replay at a live move.
            let revision = stagedHistory?.revision
            outcome = stagedHistory?.apply(event)
            if case .featured = event, stagedHistory?.revision != revision { historyResetsScrub = true }
            publishHistory(evaluate: false)
        } else {
            let revision = game.revision
            outcome = game.apply(event)
            if case .featured = event, game.revision != revision { viewedPly = nil }
        }
        if case .fen = event {
            liveClockRevision &+= 1
            game.hasReliableClocks = true; joinClock = nil
        }
        if game.position != nil { markTiming(.board) }
        markTiming(.live)
        markClocksIfLive()
        if let outcome, settings.sounds { sounds.play(outcome, set: settings.soundSet) }
        if game.position?.fen != previousFEN, viewedPly == nil { requestEvaluation() }
    }

    private func publishHistory(evaluate: Bool) {
        historyEvaluationTask?.cancel()
        historyEvaluationTask = nil
        guard var snapshot = stagedHistory else { return }
        if let preview = joinClock, let position = snapshot.position,
           FENIdentity.same(preview.board.fen, position.fen) {
            let clocks = preview.clocks(at: .now)
            snapshot.apply(.fen(fen: position.fen, lastMove: nil,
                                whiteClock: clocks.whiteSeconds, blackClock: clocks.blackSeconds), at: clocks.receivedAt)
            game.hasReliableClocks = preview.clocksRunning
        } else if case .broadcastBoard = game.source {
            game.hasReliableClocks = false
        }
        stagedHistory = nil
        let resetsScrub = historyResetsScrub
        historyResetsScrub = false
        game.replaceReducer(snapshot)
        // A fresh server replay says the game is being played: the preview's result was stale
        // (or the game was reopened). `streamEnded` restores it if the stream then ends without
        // a re-readable result.
        if historyConfirmsGame, hasPreviewResult {
            game.finished = nil
            hasPreviewResult = false
        }
        historyConfirmsGame = false
        isReplayingHistory = false
        if resetsScrub, viewedPly != nil { viewedPly = nil }
        if game.position != nil { markTiming(.board) }
        markTiming(.history)
        markClocksIfLive()
        if !game.hasReliableClocks { repairBroadcastClocks() }
        if evaluate { requestEvaluation() }
    }

    private func discardHistory() {
        historyEvaluationTask?.cancel()
        historyEvaluationTask = nil
        stagedHistory = nil
        historyResetsScrub = false
        historyConfirmsGame = false
        isReplayingHistory = false
    }

    /// The game on screen is over: freeze it, stop the engine and say so, with a chime.
    ///
    /// The streamer holds the next game back for a few seconds after this, which is the pause
    /// the result needs to be read. `clockIsEstimated` goes quiet once `finished` is set, so the
    /// clocks stop where they stood instead of falling back to the ESTIMATED label.
    private func gameEnded(gameId: String, status: GameStatus) {
        if stagedHistory?.gameId == gameId { publishHistory(evaluate: false) }
        guard game.finished == nil || hasPreviewResult else { return }
        guard let shown = game.gameId, shown == gameId else {
            appLog.debug("Ignoring the end of \(gameId, privacy: .public); the screen shows \(self.game.gameId ?? "nothing", privacy: .public)")
            return
        }
        evaluationTask?.cancel()
        evaluationTask = nil
        historyEvaluationTask?.cancel()
        historyEvaluationTask = nil
        isReplayingHistory = false
        stopEngineSearch()
        let finished = GameState.Finished(status: status)
        game.freezeClocks()
        hasPreviewResult = false
        game.finished = finished
        appLog.notice("Game \(gameId, privacy: .public) ended: \(status.name, privacy: .public) \(finished.result ?? "no result", privacy: .public)")
        if settings.sounds, isForeground { sounds.playGameOver() }
    }

    /// The silence after which a replay the source flagged as incomplete is published anyway.
    static let unsignalledHistorySettleDelay: Duration = .milliseconds(1500)

    private func scheduleEvaluationAfterHistory(after delay: Duration) {
        historyEvaluationTask?.cancel()
        historyEvaluationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.historyEvaluationTask = nil
            self.publishHistory(evaluate: true)
        }
    }

    /// The stream finished on its own: the broadcast board has a result, or the arena is over.
    /// The final position stays on screen until Back.
    private func streamEnded(for source: GameSource) async {
        guard game.source == source else { return }
        // The board list already knew the result when it opened this board; keep it as the
        // answer if the round cannot be re-read (REVIEW.md's "Game over" with no result).
        let previewResult = hasPreviewResult ? game.finished?.result : nil
        publishHistory(evaluate: false)
        guard game.finished == nil || hasPreviewResult else { return }
        historyEvaluationTask?.cancel()
        historyEvaluationTask = nil
        evaluationTask?.cancel()
        evaluationTask = nil
        stopEngineSearch()
        var result: String?
        if case .broadcastBoard(let roundId, let gameId) = source,
           let fetched = try? await broadcasts.round(id: roundId),
           let board = fetched.boards.first(where: { $0.gameId == gameId }),
           !board.isOngoing {
            result = board.status
        }
        guard !Task.isCancelled, game.source == source else { return }
        appLog.notice("Stream finished for \(source.storageKey, privacy: .public): \(result ?? "no result", privacy: .public)")
        game.freezeClocks()
        hasPreviewResult = false
        game.finished = GameState.Finished(result: result ?? previewResult)
    }

    // MARK: - Titles

    /// Fills the header in when we were opened without one (a launch argument, mostly).
    private func resolveTitle(for source: GameSource) {
        switch source {
        case .tvChannel:
            return
        case .arena(let tournamentId):
            titleTask = Task { @MainActor [weak self] in
                guard let detail = try? await self?.arenas.detail(id: tournamentId) else { return }
                guard let self, self.game.source == source else { return }
                self.sourceTitle = SourceTitle.arena(detail.summary)
            }
        case .broadcastBoard(_, let gameId):
            titleTask = Task { @MainActor [weak self] in
                guard let fetched = await self?.openingRoundTask?.value else { return }
                guard let self, !Task.isCancelled, self.game.source == source else { return }
                let index = fetched.boards.firstIndex { $0.gameId == gameId }
                if self.openDestination?.title == nil { self.sourceTitle = SourceTitle.board(
                    tournament: fetched.round.name,
                    round: fetched.round.roundName,
                    boardNumber: index.map { $0 + 1 }
                ) }
                if let board = index.map({ fetched.boards[$0] }) {
                    // JSON clocks include elapsed think time. Use them only for the position
                    // they describe; a stream move arriving meanwhile must never be rolled back.
                    let preview = GamePreview(board: board, receivedAt: .now, clocksRunning: board.isOngoing)
                    if self.game.position == nil {
                        self.game.seed(preview)
                        self.hasPreviewResult = !board.isOngoing
                        self.joinClock = preview
                        self.game.hasReliableClocks = true
                        self.isReplayingHistory = true
                    } else if self.liveClockRevision == 0, let shown = self.game.position?.fen, FENIdentity.same(shown, board.fen) {
                        self.joinClock = preview
                        self.game.apply(.fen(fen: board.fen, lastMove: nil,
                            whiteClock: board.white?.clockSeconds, blackClock: board.black?.clockSeconds))
                        self.game.hasReliableClocks = true
                    }
                    self.whiteFederation = board.white?.federation ?? self.whiteFederation
                    self.blackFederation = board.black?.federation ?? self.blackFederation
                    self.loadPortraits(white: board.white?.fideId ?? self.openDestination?.whiteFideId,
                                       black: board.black?.fideId ?? self.openDestination?.blackFideId,
                                       whitePhoto: board.white?.photo, blackPhoto: board.black?.photo,
                                       for: source)
                }
            }
        }
    }

    public func federation(for color: PieceColor) -> String? {
        color == .white ? whiteFederation : blackFederation
    }

    /// The flag for a side's federation, when the code is one we know.
    public func flag(for color: PieceColor) -> String? {
        federation(for: color).flatMap(Federations.flag(for:))
    }

    /// A join snapshot that differs from the preview needs a current-time clock anchor.
    /// Wait for the shared opening read first; only a position mismatch needs another request.
    private func repairBroadcastClocks() {
        guard clockRepairTask == nil,
              case .broadcastBoard(let roundId, let gameId) = game.source else { return }
        let source = game.source
        let opening = openingRoundTask
        let repairID = UUID(); clockRepairID = repairID
        clockRepairTask = Task { @MainActor [weak self] in
            _ = await opening?.value
            guard let self, !Task.isCancelled, self.game.source == source else { return }
            defer { if self.clockRepairID == repairID { self.clockRepairTask = nil } }
            guard !self.game.hasReliableClocks,
                  let fetched = try? await self.broadcasts.round(id: roundId),
                  !Task.isCancelled, self.game.source == source, !self.game.hasReliableClocks,
                  let board = fetched.boards.first(where: { $0.gameId == gameId }),
                  let shown = self.game.position?.fen, FENIdentity.same(shown, board.fen) else { return }
            let preview = GamePreview(board: board, receivedAt: .now, clocksRunning: board.isOngoing)
            self.joinClock = preview
            self.game.apply(.fen(fen: board.fen, lastMove: nil,
                whiteClock: board.white?.clockSeconds, blackClock: board.black?.clockSeconds))
            self.game.hasReliableClocks = true
            self.markClocksIfLive()
        }
    }

    // MARK: - Portraits

    public func fidePlayer(for color: PieceColor) -> FIDEPlayer? {
        color == .white ? whiteFIDEPlayer : blackFIDEPlayer
    }

    /// The portrait the round itself published for this side, if any.
    public func photo(for color: PieceColor) -> PlayerPhoto? {
        color == .white ? whitePhoto : blackPhoto
    }

    /// The 500 px portrait for the side panel, when Lichess has one for this player.
    ///
    /// Two sources, and the round's own is the one that always arrives: `GET /api/broadcast/-/-/…`
    /// carries a `photos` book for every player of the round, so the picture is already in hand
    /// when the board is. The FIDE record is preferred only because it is the fresher of the two.
    public func portraitURL(for color: PieceColor) -> URL? {
        fidePlayer(for: color)?.photoMediumURL ?? photo(for: color)?.mediumURL
    }

    /// The photographer credited for whichever portrait `portraitURL(for:)` returned. Showing it
    /// is a condition of using the picture, so the two must never come from different records.
    public func photoCredit(for color: PieceColor) -> String? {
        let credit = fidePlayer(for: color)?.photoMediumURL != nil
            ? fidePlayer(for: color)?.photoCredit
            : photo(for: color)?.credit
        guard let credit, !credit.isEmpty else { return nil }
        return credit
    }

    /// Records the portraits a round read handed us, and looks both players up by FIDE id for
    /// the fuller record behind them.
    ///
    /// Failures are silent: the placeholder is the normal look for most players, and the client
    /// caches whatever it learns. What must not happen is a failure *undoing* a portrait already
    /// on screen — a rate-limited second lookup used to write `nil` over the first one's answer —
    /// so nothing here replaces a record or a photo with nothing.
    private func loadPortraits(
        white: Int?, black: Int?,
        whitePhoto: PlayerPhoto? = nil, blackPhoto: PlayerPhoto? = nil,
        for source: GameSource
    ) {
        if let whitePhoto { self.whitePhoto = whitePhoto }
        if let blackPhoto { self.blackPhoto = blackPhoto }
        // The round read calls this again a few seconds after the destination did, usually with
        // the very ids the destination already supplied. Restarting the lookup there cancelled
        // the first one mid-flight and threw its answer away, so a second attempt that came back
        // rate limited left the panel on initials for the rest of the game. Each id is therefore
        // asked for exactly once, and a side already being looked up is left alone.
        var wanted: [(color: PieceColor, fideId: Int)] = []
        if let white, portraitRequest.white != white {
            portraitRequest.white = white
            wanted.append((.white, white))
        }
        if let black, portraitRequest.black != black {
            portraitRequest.black = black
            wanted.append((.black, black))
        }
        guard !wanted.isEmpty else { return }
        let lookups = wanted
        portraitTasks.append(Task { @MainActor [weak self] in
            guard let self else { return }
            await withTaskGroup(of: (PieceColor, FIDEPlayer?).self) { group in
                for lookup in lookups {
                    group.addTask { (lookup.color, await self.lookup(lookup.fideId)) }
                }
                // A lookup that failed says nothing, and nothing is what it must write: the
                // round's own photo, or a record another call already found, stays on screen.
                for await (color, player) in group {
                    guard !Task.isCancelled, self.game.source == source, let player else { continue }
                    if color == .white { self.whiteFIDEPlayer = player }
                    else { self.blackFIDEPlayer = player }
                }
            }
            // Visible portrait views request their own display size; no duplicate prefetch.
        })
    }

    private func lookup(_ fideId: Int?) async -> FIDEPlayer? {
        guard let fideId else { return nil }
        do {
            return try await fidePlayers.player(fideId: fideId)
        } catch {
            appLog.notice("FIDE lookup \(fideId) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Engine

    /// Stockfish only speaks standard chess here; variants and Chess960 show no bar.
    public var engineSupported: Bool {
        game.source.isStandardChess && (viewedPosition?.supportsStandardAnalysis ?? true)
    }
    /// The eval bar is shown only when the engine is both wanted and meaningful here.
    public var showsEvalBar: Bool { settings.engineEnabled && engineSupported }

    public func toggleEngine() {
        settings.engineEnabled.toggle()
        appLog.notice("Stockfish \(self.settings.engineEnabled ? "on" : "off")")
        if settings.engineEnabled {
            startEngine()
            requestEvaluation()
        } else {
            evaluationTask?.cancel()
            evaluationTask = nil
            stopEngineSearch()
        }
    }

    /// Changes how deep the engine searches. With the engine on, the current position restarts
    /// under the new cap rather than waiting for the next move.
    public func setEngineDepth(_ depth: EngineDepth) {
        settings.engineDepth = depth
        appLog.notice("Stockfish depth \(depth.depth) (\(depth.displayName, privacy: .public))")
        if settings.engineEnabled {
            requestEvaluation()
        }
    }

    private func startEngine() {
        guard isForeground, !thermalLimited, !shuttingDown, engine == nil, engineStartTask == nil else { return }
        guard let url = Bundle.main.url(forResource: Self.networkResourceName, withExtension: "nnue") else {
            appLog.error("Stockfish network \(Self.networkResourceName, privacy: .public).nnue is not in the bundle")
            return
        }
        appLog.notice("Starting Stockfish with \(url.lastPathComponent, privacy: .public)")
        // UCIEngine's init blocks for 150-300 ms on the UCI handshake, so it never runs on the
        // main actor. One engine per process: we keep this instance for the app's lifetime and
        // only ever stop its search.
        let task = Task.detached(priority: .userInitiated) { () -> UCIEngine? in
            do {
                return try UCIEngine(networkURL: url, threads: 2, hashMB: 32)
            } catch {
                appLog.error("Stockfish failed to start: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        engineStartTask = task
        Task { @MainActor [weak self] in
            let engine = await task.value
            guard let self else { await engine?.shutdown(); return }
            guard !self.shuttingDown else { await engine?.shutdown(); return }
            self.engineStartTask = nil
            self.engine = engine
            if engine != nil {
                appLog.notice("Stockfish ready")
                self.requestEvaluation()
            }
        }
    }

    private func stopEngineSearch() {
        guard let engine else { return }
        let previous = engineStopTask
        engineStopTask = Task { await previous?.value; await engine.stop() }
    }

    /// Stops Stockfish for good, on the way out of the process.
    ///
    /// Only the app teardown calls this. The engine's UCI loop is a C++ thread, and leaving it
    /// running while the process exits is what used to abort the app on the way down, so this
    /// also waits out a start that is still in flight: an engine that arrives after nobody is
    /// left to own it would be exactly that thread.
    public func shutdownEngine() async {
        shuttingDown = true
        evaluationTask?.cancel()
        evaluationTask = nil
        historyEvaluationTask?.cancel()
        historyEvaluationTask = nil

        if let starting = engineStartTask {
            engineStartTask = nil
            await starting.value?.shutdown()
        }

        if let running = engine {
            engine = nil
            await running.shutdown()
        }

        // `startEngine`'s follow-up may have installed its engine while we were awaiting above.
        if let late = engine {
            engine = nil
            await late.shutdown()
        }
        appLog.notice("Teardown: Stockfish stopped")
    }

    private func requestEvaluation() {
        searchGeneration &+= 1
        let generation = searchGeneration
        evaluationTask?.cancel()
        evaluationTask = nil
        guard isForeground, !thermalLimited, !shuttingDown, settings.engineEnabled,
              engineSupported, (game.finished == nil || viewedPly != nil),
              let engine, let position = viewedPosition else { stopEngineSearch(); return }
        let fen = position.fen
        let revision = game.revision
        let ply = viewedPly
        let maxDepth = settings.engineDepth.depth
        let stopping = engineStopTask
        evaluationTask = Task { @MainActor [weak self] in
            await stopping?.value
            guard !Task.isCancelled else { return }
            appLog.debug("Evaluating rev \(revision) fen \(fen, privacy: .public)")
            for await evaluation in await engine.evaluate(fen: fen, maxDepth: maxDepth, revision: revision) {
                guard let self, !Task.isCancelled else { return }
                guard self.searchGeneration == generation, self.viewedPly == ply,
                      self.viewedPosition?.fen == evaluation.positionFEN else { continue }
                if ply != nil { self.scrubEvaluation = evaluation; continue }
                let accepted = self.game.applyEvaluation(evaluation)
                if accepted {
                    self.markTiming(.evaluation)
                    appLog.debug("Eval rev \(evaluation.revision) depth \(evaluation.depth) \(String(describing: evaluation.score), privacy: .public) fen \(evaluation.positionFEN, privacy: .public)")
                } else {
                    appLog.debug("Discarding stale eval rev \(evaluation.revision) for \(evaluation.positionFEN, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Clocks

    private func startTicker() {
        guard tickerTask == nil else { return }
        tickerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.tick &+= 1
                self.wallClock = Date()
            }
        }
    }

    /// The clock text for one color, counted down locally while the feed is live.
    public func displayedClock(_ color: PieceColor) -> String? {
        _ = tick   // registers this view body with the one-second ticker
        guard let seconds = ClockDisplay.remainingSeconds(
            for: color,
            clocks: game.clocks,
            isLive: game.clocksAreLive,
            now: .now
        ) else { return nil }
        return ClockDisplay.text(seconds)
    }

    /// True when the clock shown is a frozen last-known value rather than a live countdown.
    public func clockIsEstimated(_ color: PieceColor) -> Bool {
        guard let clocks = game.clocks, color == clocks.sideToMove else { return false }
        return !game.clocksAreLive && game.finished == nil
    }

    // MARK: - Board orientation

    /// The color at the bottom of the board: White, or the featured player when followed, and
    /// the other way up when the board is flipped.
    public var boardOrientation: PieceColor {
        let base: PieceColor = settings.followFeaturedPlayer ? game.feedOrientation : .white
        return settings.flipBoard ? base.opposite : base
    }

    /// The player shown at the top of the side panel: the one at the top of the board.
    public var topColor: PieceColor { boardOrientation.opposite }
    public var bottomColor: PieceColor { boardOrientation }

    /// Turns the board around. The button under the board calls this, and the choice is saved.
    public func toggleFlipBoard() {
        settings.flipBoard.toggle()
        appLog.notice("Board flipped: watching as \(self.boardOrientation == .white ? "White" : "Black", privacy: .public)")
    }

    // MARK: - Lifecycle

    public func setThermalState(_ state: ProcessInfo.ThermalState) {
        let limited = state == .serious || state == .critical
        guard limited != thermalLimited else { return }
        thermalLimited = limited
        if limited {
            evaluationTask?.cancel()
            stopEngineSearch()
        } else if isForeground, settings.engineEnabled {
            startEngine()
            requestEvaluation()
        }
    }

    public func scenePhaseChanged(to phase: ScenePhase) {
        switch phase {
        case .background:
            discardHistory()
            isForeground = false
            game.freezeClocks()
            game.connection = .connecting
            historyEvaluationTask?.cancel()
            historyEvaluationTask = nil
            isReplayingHistory = false
            appLog.notice("Entering background: stopping the search and the feed")
            evaluationTask?.cancel()
            evaluationTask = nil
            stopEngineSearch()
            feedTask?.cancel()
            feedTask = nil
            roundWatchTask?.cancel()
            roundWatchTask = nil
            arenaStandingsTask?.cancel()
            arenaStandingsTask = nil
            tickerTask?.cancel()
            tickerTask = nil
            // The join state belongs to the feed that just went away. The next `.active` starts
            // a fresh one, whose clocks come from its own replay and JSON, not from anchors
            // taken before the background.
            titleTask?.cancel()
            titleTask = nil
            clockRepairTask?.cancel()
            clockRepairTask = nil
            clockRepairID = UUID()
            joinClock = nil
            liveClockRevision = 0
        case .active:
            isForeground = true
            guard didStart else { return }
            appLog.notice("Becoming active")
            startTicker()
            if let destination = openDestination, feedTask == nil {
                game.clearGame()
                viewedPly = nil
                game.connection = .connecting
                startFeed(for: destination.source)
                startRoundWatch(for: destination.source)
                startArenaStandings(for: destination.source)
            }
            if settings.engineEnabled { startEngine() }
        default:
            break
        }
    }
}
