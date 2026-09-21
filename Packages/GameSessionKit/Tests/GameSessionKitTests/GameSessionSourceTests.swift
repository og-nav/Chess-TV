import Testing
import Foundation
import ChessCore
import LichessKit
@testable import GameSessionKit

/// A `SourceStreaming` that never touches the network: it hands out streams the test drives by
/// hand and records which ones were asked for and which ones were torn down.
final class FakeStreamer: SourceStreaming, @unchecked Sendable {   // @unchecked: the state below is lock-guarded

    private let lock = NSLock()
    private var opened: [GameSource] = []
    private var cancelled: [GameSource] = []
    private var continuations: [GameSource: AsyncThrowingStream<FeedItem, Error>.Continuation] = [:]
    private var didFinish = false

    var openedSources: [GameSource] { lock.withLock { opened } }
    var cancelledSources: [GameSource] { lock.withLock { cancelled } }
    var isFinished: Bool { lock.withLock { didFinish } }

    func sourcedEvents(for source: GameSource) -> AsyncThrowingStream<FeedItem, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            lock.withLock {
                opened.append(source)
                continuations[source] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                lock.withLock { cancelled.append(source) }
            }
        }
    }

    var connectionStates: AsyncStream<ConnectionState> { AsyncStream { _ in } }

    func finish() {
        lock.withLock { didFinish = true }
    }

    func emit(_ event: TVEvent, to source: GameSource, isHistorical: Bool = false, historyComplete: Bool? = nil) {
        lock.withLock { continuations[source] }?.yield(.event(SourcedEvent(event: event, isHistorical: isHistorical, historyComplete: historyComplete)))
    }

    func endGame(_ gameId: String, status: GameStatus, to source: GameSource) {
        lock.withLock { continuations[source] }?.yield(.gameEnded(gameId: gameId, status: status))
    }

    func end(_ source: GameSource) {
        lock.withLock { continuations[source] }?.finish()
    }
}

/// An `ArenaDetailing` that never touches the network: it hands back one canned detail and counts
/// how often it was asked.
final class FakeArenas: ArenaDetailing, @unchecked Sendable {   // @unchecked: the state below is lock-guarded

    private let lock = NSLock()
    private var calls = 0
    private let detail: ArenaDetail?

    var callCount: Int { lock.withLock { calls } }

    init(detail: ArenaDetail? = nil) {
        self.detail = detail
    }

    func detail(id: String) async throws -> ArenaDetail {
        lock.withLock { calls += 1 }
        guard let detail else { throw CancellationError() }
        return detail
    }

    /// The shape one poll of a running arena has: ten rows, a field, and a time left.
    static func standing(secondsToFinish: Int? = 5681, nbPlayers: Int = 1087) -> ArenaDetail {
        let rows = (1...10).map { rank in
            ArenaStanding(
                name: "Player\(rank)",
                title: rank == 1 ? "GM" : nil,
                score: 30 - rank,
                rank: rank,
                rating: 2600 - rank * 10,
                onStreak: rank == 2,
                withdrawn: rank == 9
            )
        }
        let summary = ArenaSummary(
            id: "A1",
            fullName: "Hourly Arena",
            perfKey: "blitz",
            variantKey: "standard",
            nbPlayers: nbPlayers,
            startsAt: Date(timeIntervalSince1970: 1_789_696_800),
            minutes: 120,
            secondsToFinish: secondsToFinish,
            isStarted: true,
            isFinished: false
        )
        return ArenaDetail(summary: summary, featured: nil, standings: rows)
    }
}

@Suite("GameSession starts one source at a time")
@MainActor
struct GameSessionSourceTests {

    private func makeModel() -> (GameSession, FakeStreamer) {
        let streamer = FakeStreamer()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "ChessTVTests-\(UUID().uuidString)")!)
        settings.sounds = false
        settings.tournamentAlerts = false
        // The arena client is faked everywhere, so no test ever polls Lichess.
        return (GameSession(settings: settings, streamer: streamer, arenas: FakeArenas()), streamer)
    }

    /// Waits for something the feed task has to do on its own turn of the main actor.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test("Opening a source streams it and remembers it for Continue watching")
    func opening() async throws {
        let (model, streamer) = makeModel()
        let blitz = GameSource.tvChannel(.blitz)
        model.open(source: blitz, title: "Blitz \u{00B7} Lichess TV")
        #expect(streamer.openedSources == [blitz])
        #expect(model.settings.lastSource == blitz)
        #expect(model.sourceTitle == "Blitz \u{00B7} Lichess TV")

        let events = try FixtureFeed.events(named: "feed-castling")
        streamer.emit(events[0], to: blitz)
        #expect(await eventually { model.game.position != nil })
        #expect(model.game.source == blitz)
    }

    @Test("Opening another source cancels the first one and clears the board")
    func switching() async throws {
        let (model, streamer) = makeModel()
        let blitz = GameSource.tvChannel(.blitz)
        let arena = GameSource.arena(tournamentId: "abc123")
        model.open(source: blitz, title: "Blitz \u{00B7} Lichess TV")
        let events = try FixtureFeed.events(named: "feed-castling")
        streamer.emit(events[0], to: blitz)
        #expect(await eventually { model.game.position != nil })

        model.open(source: arena, title: "Hourly SuperBlitz Arena \u{00B7} Lichess")
        #expect(model.game.source == arena)
        #expect(model.game.position == nil)
        #expect(model.game.revision == 0)
        #expect(model.settings.lastSource == arena)
        #expect(streamer.openedSources == [blitz, arena])
        #expect(await eventually { streamer.cancelledSources == [blitz] })

        // Events from the source we left behind are ignored.
        streamer.emit(events[0], to: blitz)
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.game.position == nil)
    }

    @Test("Closing stops the feed and empties the screen")
    func closing() async throws {
        let (model, streamer) = makeModel()
        let blitz = GameSource.tvChannel(.blitz)
        model.open(source: blitz, title: "Blitz \u{00B7} Lichess TV")
        let events = try FixtureFeed.events(named: "feed-castling")
        streamer.emit(events[0], to: blitz)
        #expect(await eventually { model.game.position != nil })

        model.close()
        #expect(model.game.position == nil)
        #expect(model.openDestination == nil)
        #expect(model.sourceTitle.isEmpty)
        #expect(await eventually { streamer.cancelledSources == [blitz] })
        // The streamer itself is kept alive for the next source.
        #expect(!streamer.isFinished)
    }

    @Test("A stream that ends on its own leaves Game over and the final position")
    func gameOver() async throws {
        let (model, streamer) = makeModel()
        let blitz = GameSource.tvChannel(.blitz)
        model.open(source: blitz, title: "Blitz \u{00B7} Lichess TV")
        let events = try FixtureFeed.events(named: "feed-castling")
        streamer.emit(events[0], to: blitz)
        #expect(await eventually { model.game.position != nil })

        streamer.end(blitz)
        #expect(await eventually { model.game.finished != nil })
        #expect(model.game.position != nil)
        #expect(model.game.finished?.text == "Game over")
        #expect(!model.game.isLive)
    }

    @Test("Teardown is the only thing that retires the streamer")
    func teardown() {
        let (model, streamer) = makeModel()
        model.open(source: .tvChannel(.blitz), title: "Blitz")
        model.teardown()
        #expect(streamer.isFinished)
        #expect(model.openDestination == nil)
    }

    /// A featured header for a game the test invents, so the ids are its own.
    private static func featured(gameId: String) -> TVEvent {
        .featured(
            gameId: gameId,
            orientation: .white,
            players: [
                TVPlayer(name: "Alice", title: "GM", rating: 2700, color: .white, secondsRemaining: 180),
                TVPlayer(name: "Bob", title: nil, rating: 2500, color: .black, secondsRemaining: 180),
            ],
            fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
        )
    }

    @Test("A game that ends shows its result, and the next game clears it")
    func gameEndedShowsTheResult() async throws {
        let (model, streamer) = makeModel()
        let arena = GameSource.arena(tournamentId: "A1")
        model.open(source: arena, title: "Hourly Arena")
        streamer.emit(Self.featured(gameId: "AAAA"), to: arena)
        #expect(await eventually { model.game.gameId == "AAAA" })

        streamer.endGame("AAAA", status: GameStatus(id: 30, name: "mate", winner: .white), to: arena)
        #expect(await eventually { model.game.finished != nil })
        #expect(model.game.finished?.result == "1-0")
        #expect(model.game.finished?.text == "Game over \u{00B7} 1-0")
        // The clocks freeze rather than falling back to the ESTIMATED label.
        #expect(!model.game.isLive)
        #expect(!model.clockIsEstimated(.white))
        #expect(model.game.position != nil)

        // The next game the arena features takes the chip away with the old one.
        streamer.emit(Self.featured(gameId: "BBBB"), to: arena)
        #expect(await eventually { model.game.gameId == "BBBB" })
        #expect(model.game.finished == nil)
    }

    @Test("A draw ends half a point each")
    func drawIsHalfEach() async throws {
        let (model, streamer) = makeModel()
        let arena = GameSource.arena(tournamentId: "A1")
        model.open(source: arena, title: "Hourly Arena")
        streamer.emit(Self.featured(gameId: "AAAA"), to: arena)
        #expect(await eventually { model.game.gameId == "AAAA" })

        streamer.endGame("AAAA", status: GameStatus(id: 34, name: "draw", winner: nil), to: arena)
        #expect(await eventually { model.game.finished != nil })
        #expect(model.game.finished?.result == "\u{00BD}-\u{00BD}")
    }

    @Test("The end of a game we are no longer showing is ignored")
    func staleGameEndIsIgnored() async throws {
        let (model, streamer) = makeModel()
        let arena = GameSource.arena(tournamentId: "A1")
        model.open(source: arena, title: "Hourly Arena")
        streamer.emit(Self.featured(gameId: "BBBB"), to: arena)
        #expect(await eventually { model.game.gameId == "BBBB" })

        streamer.endGame("AAAA", status: GameStatus(id: 30, name: "mate", winner: .black), to: arena)
        try await Task.sleep(for: .milliseconds(80))
        #expect(model.game.finished == nil)
    }

    @Test("Replayed history fills the move list without a sound and gets one evaluation at the end")
    func historyReplay() async throws {
        let (model, streamer) = makeModel()
        let blitz = GameSource.tvChannel(.blitz)
        model.open(source: blitz, title: "Blitz")
        let events = try FixtureFeed.events(named: "feed-blitz")
        #expect(events.count > 3)
        for event in events.dropLast() { streamer.emit(event, to: blitz, isHistorical: true) }
        #expect(await eventually { model.isReplayingHistory })
        #expect(model.game.revision == 0)
        #expect(model.game.moveHistory.isEmpty)

        streamer.emit(events[events.count - 1], to: blitz, isHistorical: false)
        #expect(await eventually { model.game.revision == events.count })
        #expect(!model.isReplayingHistory)
    }
}

@Suite("Toasts and board orientation")
@MainActor
struct ToastAndOrientationTests {

    /// Opening a broadcast board reads its round once; the test must not reach lichess.org.
    private struct SilentRounds: BroadcastRoundFetching {
        func round(id: String) async throws -> (round: BroadcastTournament, boards: [BroadcastBoard]) { throw CancellationError() }
    }

    private func makeModel() -> GameSession {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "ChessTVTests-\(UUID().uuidString)")!)
        return GameSession(settings: settings, streamer: FakeStreamer(), arenas: FakeArenas(), broadcasts: SilentRounds())
    }

    @Test("Queued alerts show one at a time and clear when the source closes")
    func toasts() {
        let model = makeModel()
        model.open(source: .broadcastBoard(roundId: "r", gameId: "g"), title: "Board")
        let first = TournamentAlert(kind: .result, headline: "Board 2", detail: "GM A beat GM B")
        let second = TournamentAlert(kind: .timeScramble, headline: "Board 4", detail: "Time scramble")
        model.enqueue([first, second])
        #expect(model.toast == first)
        model.close()
        #expect(model.toast == nil)
    }

    @Test("Flip the board turns White's view into Black's, on top of following")
    func flip() {
        let model = makeModel()
        #expect(model.boardOrientation == .white)
        model.settings.flipBoard = true
        #expect(model.boardOrientation == .black)
        model.settings.flipBoard = false
        #expect(model.boardOrientation == .white)
    }

    @Test("The button under the board flips the view both ways and the choice survives a relaunch")
    func toggleFlipFromTheGameScreen() {
        let suite = "chesstv.flipboard.button"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = GameSession(settings: AppSettings(defaults: defaults), streamer: FakeStreamer(), arenas: FakeArenas())
        #expect(model.boardOrientation == .white)

        model.toggleFlipBoard()
        #expect(model.boardOrientation == .black)
        // A second AppSettings on the same defaults is what a relaunch sees.
        #expect(AppSettings(defaults: defaults).flipBoard)

        model.toggleFlipBoard()
        #expect(model.boardOrientation == .white)
        #expect(!AppSettings(defaults: defaults).flipBoard)
    }
}

@Suite("Arena standings and the arena countdown")
@MainActor
struct ArenaStandingsTests {

    private func makeModel(_ arenas: FakeArenas) -> (GameSession, FakeStreamer) {
        let streamer = FakeStreamer()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "ChessTVTests-\(UUID().uuidString)")!)
        return (GameSession(settings: settings, streamer: streamer, arenas: arenas), streamer)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test("Opening an arena polls the standing; the panel gets all ten rows and the field size")
    func polling() async throws {
        let arenas = FakeArenas(detail: FakeArenas.standing())
        let (model, _) = makeModel(arenas)
        model.open(source: .arena(tournamentId: "A1"), title: "Hourly Arena")
        #expect(await eventually { model.arenaStandings != nil })

        let standings = try #require(model.arenaStandings)
        #expect(standings.rows.count == 10)
        #expect(standings.rows.first?.title == "GM")
        #expect(standings.rows.first { $0.rank == 2 }?.onStreak == true)
        #expect(standings.rows.first { $0.rank == 9 }?.withdrawn == true)
        #expect(standings.playerCount == 1087)
        #expect(standings.playerCountText.hasSuffix(" players"))

        // Leaving the screen clears the panel and stops the poll.
        model.close()
        #expect(model.arenaStandings == nil)
        let afterClose = arenas.callCount
        try await Task.sleep(for: .milliseconds(100))
        #expect(arenas.callCount == afterClose)
    }

    @Test("The header counts the arena down from the instant the poll landed")
    func countdown() async throws {
        let arenas = FakeArenas(detail: FakeArenas.standing(secondsToFinish: 5681))
        let (model, _) = makeModel(arenas)
        model.open(source: .arena(tournamentId: "A1"), title: "Hourly Arena")
        #expect(await eventually { model.arenaStandings != nil })

        let standings = try #require(model.arenaStandings)
        #expect(model.arenaTimeLeftText(at: standings.receivedAt) == "1:34:41")
        #expect(model.arenaTimeLeftText(at: standings.receivedAt + .seconds(41)) == "1:34:00")
        #expect(model.arenaTimeLeftText(at: standings.receivedAt + .seconds(5681 - 60)) == "1:00")
        // Never negative, and never past the end of the arena.
        #expect(model.arenaTimeLeftText(at: standings.receivedAt + .seconds(9999)) == "0:00")
    }

    @Test("A TV channel has no standing and no countdown, and is never polled")
    func tvChannelHasNeither() async throws {
        let arenas = FakeArenas(detail: FakeArenas.standing())
        let (model, _) = makeModel(arenas)
        model.open(source: .tvChannel(.blitz), title: "Blitz \u{00B7} Lichess TV")
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.arenaStandings == nil)
        #expect(model.arenaTimeLeftText == nil)
        #expect(arenas.callCount == 0)
    }

    @Test("An arena that has not started sends no secondsToFinish, so there is no countdown")
    func noSecondsToFinish() async throws {
        let arenas = FakeArenas(detail: FakeArenas.standing(secondsToFinish: nil))
        let (model, _) = makeModel(arenas)
        model.open(source: .arena(tournamentId: "A1"), title: "Hourly Arena")
        #expect(await eventually { model.arenaStandings != nil })
        #expect(model.arenaTimeLeftText == nil)
        #expect(model.arenaStandings?.rows.count == 10)
    }

    @Test("Failing polls back off, and a good one puts the interval back")
    func backoff() {
        #expect(GameSession.arenaStandingsDelay(afterFailures: 0) == .seconds(10))
        #expect(GameSession.arenaStandingsDelay(afterFailures: 1) == .seconds(10))
        #expect(GameSession.arenaStandingsDelay(afterFailures: 2) == .seconds(20))
        #expect(GameSession.arenaStandingsDelay(afterFailures: 9) == GameSession.arenaStandingsMaxInterval)
    }
}
