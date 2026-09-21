import ChessCore
import Foundation
import LichessKit
import Testing
@testable import GameSessionKit

/// Requests deliberately ignore cancellation until the test replies, like an already completed
/// network response whose continuation is waiting for its turn on the main actor.
private final class OpeningRounds: BroadcastRoundFetching, @unchecked Sendable {
    typealias Response = (round: BroadcastTournament, boards: [BroadcastBoard])
    private let lock = NSLock()
    private var calls: [String] = []
    private var pending: [Int: CheckedContinuation<Response, Error>] = [:]
    private var finished = false
    var count: Int { lock.withLock { calls.count } }

    func round(id: String) async throws -> Response {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                guard !finished else { continuation.resume(throwing: CancellationError()); return }
                let index = calls.count
                calls.append(id)
                pending[index] = continuation
            }
        }
    }

    func reply(_ index: Int = 0, boards: [BroadcastBoard], name: String = "Test tournament") {
        let request = lock.withLock { (pending.removeValue(forKey: index), calls[index]) }
        request.0?.resume(returning: (
            BroadcastTournament(tourId: "tour", name: name, tier: nil, roundId: request.1,
                roundName: "Round 1", roundOngoing: true, roundStartsAt: nil,
                format: nil, location: nil, isActive: true), boards
        ))
    }

    func finish() {
        let remaining = lock.withLock {
            finished = true
            let remaining = Array(pending.values)
            pending.removeAll()
            return remaining
        }
        for continuation in remaining { continuation.resume(throwing: CancellationError()) }
    }
}

@Suite("Opening a broadcast game without losing its current position")
@MainActor struct GameOpeningTests {
    private let source = GameSource.broadcastBoard(roundId: "round", gameId: "game")
    private let afterE4 = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1"
    private let afterE5 = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2"

    private func board(id: String = "game", fen: String? = nil, blackMs: Int = 100_000, status: String = "*") -> BroadcastBoard {
        BroadcastBoard(gameId: id, name: "Alice — Bob", fen: fen ?? afterE4,
            lastMove: "e2e4", status: status, players: [
                BroadcastPlayer(name: "Alice", title: "GM", rating: 2700, federation: "USA", clockMs: 60_000),
                BroadcastPlayer(name: "Bob", title: "IM", rating: 2500, federation: "CAN", clockMs: blackMs),
            ])
    }

    private func makeSession(alerts: Bool = false) -> (GameSession, FakeStreamer, OpeningRounds) {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "GameOpening-\(UUID())")!)
        settings.sounds = false
        settings.engineEnabled = false
        settings.tournamentAlerts = alerts
        let feed = FakeStreamer()
        let rounds = OpeningRounds()
        return (GameSession(settings: settings, streamer: feed, arenas: FakeArenas(), broadcasts: rounds), feed, rounds)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private var featured: TVEvent {
        .featured(gameId: "game", orientation: .white, players: [
            TVPlayer(name: "Alice", title: "GM", rating: 2700, color: .white, secondsRemaining: 60),
            TVPlayer(name: "Bob", title: "IM", rating: 2500, color: .black, secondsRemaining: 100),
        ], fen: Position.standard.fen)
    }
    private var e4: TVEvent { .fen(fen: afterE4, lastMove: "e2e4", whiteClock: 60, blackClock: 100) }
    private var e5: TVEvent { .fen(fen: afterE5, lastMove: "e7e5", whiteClock: 60, blackClock: 80) }

    @Test("A board-wall preview renders synchronously, aging its clock without inventing history")
    func synchronousPreview() throws {
        let (model, _, rounds) = makeSession()
        defer { model.close(); rounds.finish() }
        model.open(GameDestination(source: source, preview: GamePreview(
            board: board(), receivedAt: .now - .seconds(12), clocksRunning: true)))
        // No suspension: neither the round request nor a feed callback can have run yet.
        #expect(rounds.count == 0)
        #expect(model.game.position == (try Position(fen: afterE4)))
        #expect(model.game.white?.name == "Alice")
        #expect(model.game.black?.rating == 2500)
        #expect(model.game.moveHistory.isEmpty)
        #expect(model.isReplayingHistory)
        #expect(model.game.hasReliableClocks)
        let clock = try #require(model.game.clocks)
        #expect(clock.whiteSeconds == 60)
        #expect((87...88).contains(try #require(clock.blackSeconds)))
    }

    @Test("Wrong-game and malformed previews do not leak a board into a new screen", arguments: [false, true])
    func invalidPreview(wrongID: Bool) {
        let (model, _, rounds) = makeSession()
        defer { model.close(); rounds.finish() }
        let preview = board(id: wrongID ? "other" : "game", fen: wrongID ? afterE4 : "invalid FEN")
        model.open(GameDestination(source: source, preview: GamePreview(
            board: preview, receivedAt: .now, clocksRunning: true)))
        #expect(model.game.position == nil)
        #expect(model.game.gameId == nil)
        #expect(model.game.clocks == nil)
        #expect(!model.game.hasReliableClocks)
    }

    @Test("Historical replay retains the preview's elapsed clock and publishes complete history atomically")
    func previewSurvivesReplay() async throws {
        let (model, feed, rounds) = makeSession()
        defer { model.close(); rounds.finish() }
        model.open(GameDestination(source: source, preview: GamePreview(
            board: board(), receivedAt: .now - .seconds(12), clocksRunning: true)))
        feed.emit(featured, to: source, isHistorical: true, historyComplete: false)
        #expect(await eventually { rounds.count == 1 })
        #expect(model.game.position == (try Position(fen: afterE4)))
        #expect(model.game.moveHistory.isEmpty)
        feed.emit(e4, to: source, isHistorical: true, historyComplete: true)
        #expect(await eventually { !model.isReplayingHistory })
        #expect(model.game.moveHistory.map(\.uci) == ["e2e4"])
        #expect(model.game.reducer.initialPosition == Position.standard)
        #expect(model.game.hasReliableClocks)
        #expect((86...88).contains(try #require(model.game.clocks?.blackSeconds)))
        model.setViewedPly(0)
        #expect(model.viewedPosition == Position.standard)
    }

    @Test("A fast round response seeds a missing preview before any history arrives")
    func roundSeedsMissingPreview() async throws {
        let (model, _, rounds) = makeSession()
        defer { model.close(); rounds.finish() }
        model.open(source: source)
        #expect(model.game.position == nil)
        #expect(await eventually { rounds.count == 1 })
        rounds.reply(boards: [board(blackMs: 72_000)])
        #expect(await eventually { model.game.position != nil })
        #expect(model.game.position == (try Position(fen: afterE4)))
        // ClockDisplay floors elapsed seconds; seeding can cross that first subsecond.
        #expect((71...72).contains(try #require(model.game.clocks?.blackSeconds)))
        #expect(model.game.hasReliableClocks)
        #expect(model.game.moveHistory.isEmpty)
        #expect(model.isReplayingHistory)
    }

    @Test("Title and the first alert poll share one round request")
    func titleAndAlertsShareRequest() async {
        let (model, _, rounds) = makeSession(alerts: true)
        defer { model.close(); rounds.finish() }
        model.open(source: source)
        #expect(await eventually { rounds.count == 1 })
        rounds.reply(boards: [board()], name: "Shared title")
        #expect(await eventually { model.sourceTitle.contains("Shared title") })
        // Allow both awaiters of the shared response to finish their first iteration.
        for _ in 0..<20 { await Task.yield() }
        #expect(rounds.count == 1)
    }

    @Test("A delayed round read cannot roll back a newer streamed position or its clocks")
    func delayedJSONCannotRollbackLiveMove() async throws {
        let (model, feed, rounds) = makeSession()
        defer { model.close(); rounds.finish() }
        model.open(GameDestination(source: source, preview: GamePreview(board: board(), receivedAt: .now, clocksRunning: true)))
        #expect(await eventually { rounds.count == 1 })
        feed.emit(e5, to: source)
        #expect(await eventually { model.game.position?.sideToMove == .white })
        let liveClock = model.game.clocks
        rounds.reply(boards: [board(blackMs: 99_000)], name: "Response arrived")
        #expect(await eventually { model.sourceTitle.contains("Response arrived") })
        #expect(model.game.position == (try Position(fen: afterE5)))
        #expect(model.game.clocks == liveClock)
        #expect(model.game.hasReliableClocks)
    }

    @Test("Closing and reopening even the same source rejects its retired JSON response")
    func cancelledOpeningCannotOverwriteReopen() async throws {
        let (model, feed, rounds) = makeSession()
        defer { model.close(); rounds.finish() }
        model.open(source: source)
        #expect(await eventually { rounds.count == 1 })
        feed.emit(featured, to: source, isHistorical: true, historyComplete: false)
        #expect(await eventually { model.isReplayingHistory })
        model.close()
        model.open(GameDestination(source: source, preview: GamePreview(
            board: board(fen: afterE5), receivedAt: .now, clocksRunning: true)))
        #expect(await eventually { rounds.count == 2 })
        rounds.reply(1, boards: [board(fen: afterE5)], name: "Current opening")
        #expect(await eventually { model.sourceTitle.contains("Current opening") })
        rounds.reply(0, boards: [board()], name: "Retired opening")
        for _ in 0..<20 { await Task.yield() }
        #expect(model.sourceTitle.contains("Current opening"))
        #expect(model.game.position == (try Position(fen: afterE5)))
        #expect(model.game.moveHistory.isEmpty)
    }

    @Test("Late opening JSON cannot replace a newer live clock correction on the same position")
    func openingJSONCannotRollbackClockOnlyUpdate() async throws {
        let (model, feed, rounds) = makeSession()
        defer { model.close(); rounds.finish() }
        model.open(GameDestination(source: source, preview: GamePreview(
            board: board(), receivedAt: .now, clocksRunning: true)))
        #expect(await eventually { rounds.count == 1 })
        let positionRevision = model.game.revision
        feed.emit(.fen(fen: afterE4, lastMove: nil, whiteClock: 60, blackClock: 65), to: source)
        #expect(await eventually { model.game.clocks?.blackSeconds == 65 })
        #expect(model.game.revision == positionRevision)
        let correctedClock = try #require(model.game.clocks)
        rounds.reply(boards: [board(blackMs: 99_000)], name: "Late clock response")
        #expect(await eventually { model.sourceTitle.contains("Late clock response") })
        #expect(model.game.position == (try Position(fen: afterE4)))
        #expect(model.game.clocks == correctedClock)
        #expect(model.game.hasReliableClocks)
    }

    @Test("An in-flight clock repair cannot overwrite a subsequent live clock on the same position")
    func pendingRepairCannotRollbackClockOnlyUpdate() async throws {
        let (model, feed, rounds) = makeSession()
        defer { model.close(); rounds.finish() }
        model.open(source: source)
        feed.emit(featured, to: source, isHistorical: true, historyComplete: false)
        feed.emit(e4, to: source, isHistorical: true, historyComplete: true)
        #expect(await eventually { model.game.moveHistory.count == 1 && rounds.count == 1 })
        // The opening JSON is behind the stream, so it cannot supply the needed clock anchor.
        rounds.reply(boards: [board(fen: Position.standard.fen)])
        #expect(await eventually { rounds.count == 2 })
        #expect(!model.game.hasReliableClocks)
        let positionRevision = model.game.revision
        feed.emit(.fen(fen: afterE4, lastMove: nil, whiteClock: 60, blackClock: 65), to: source)
        #expect(await eventually { model.game.clocks?.blackSeconds == 65 })
        #expect(model.game.revision == positionRevision)
        #expect(model.game.hasReliableClocks)
        let correctedClock = try #require(model.game.clocks)
        rounds.reply(1, boards: [board(blackMs: 99_000)])
        for _ in 0..<20 { await Task.yield() }
        #expect(model.game.clocks == correctedClock)
        #expect(model.game.position == (try Position(fen: afterE4)))
        #expect(model.game.hasReliableClocks)
        #expect(rounds.count == 2)
    }

    @Test("Historical clock values stay frozen until JSON or a live move supplies a real anchor", arguments: [false, true])
    func historicalClocksNeedAnchor(useJSON: Bool) async {
        let (model, feed, rounds) = makeSession()
        defer { model.close(); rounds.finish() }
        model.open(source: source)
        feed.emit(featured, to: source, isHistorical: true, historyComplete: false)
        feed.emit(e4, to: source, isHistorical: true, historyComplete: true)
        #expect(await eventually { model.game.moveHistory.count == 1 && rounds.count == 1 })
        model.game.connection = .live
        #expect(!model.game.hasReliableClocks)
        #expect(!model.game.clocksAreLive)
        #expect(model.clockIsEstimated(.black))
        if useJSON {
            rounds.reply(boards: [board(blackMs: 72_000)])
        } else {
            feed.emit(e5, to: source)
        }
        #expect(await eventually { model.game.hasReliableClocks })
        #expect(model.game.clocksAreLive)
        #expect(!model.clockIsEstimated(model.game.position!.sideToMove))
    }

    @Test("A live move that ends a staged replay immediately establishes reliable clocks")
    func firstLiveMoveEndsHistoryWithReliableClock() async throws {
        let (model, feed, rounds) = makeSession()
        defer { model.close(); rounds.finish() }
        model.open(source: source)
        feed.emit(featured, to: source, isHistorical: true, historyComplete: false)
        feed.emit(e4, to: source, isHistorical: true, historyComplete: false)
        #expect(await eventually { model.isReplayingHistory })
        feed.emit(e5, to: source)
        #expect(await eventually { model.game.moveHistory.count == 2 })
        #expect(model.game.position == (try Position(fen: afterE5)))
        #expect(!model.isReplayingHistory)
        #expect(model.game.hasReliableClocks)
        #expect(model.game.clocks?.blackSeconds == 80)
    }

    @Test("A preview FEN in Lichess's spelling (no en passant square) still anchors the clocks")
    func lichessSpelledPreviewMatchesTheStream() async throws {
        let (model, feed, rounds) = makeSession()
        defer { model.close(); rounds.finish() }
        // Lichess writes the en passant field only when a capture is legal; ChessCore always
        // writes it after a double push. Same position, two spellings.
        let lichessAfterE4 = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"
        model.open(GameDestination(source: source, preview: GamePreview(
            board: board(fen: lichessAfterE4), receivedAt: .now, clocksRunning: true)))
        #expect(model.game.hasReliableClocks)
        feed.emit(featured, to: source, isHistorical: true, historyComplete: false)
        feed.emit(e4, to: source, isHistorical: true, historyComplete: true)
        #expect(await eventually { !model.isReplayingHistory && model.game.moveHistory.count == 1 })
        #expect(model.game.hasReliableClocks)
        #expect(model.game.clocks != nil)
        #expect(rounds.count == 1)   // the opening read only; no clock repair request was needed
    }

    @Test("Fresh history clears a stale preview result only when its full snapshot publishes")
    func freshHistoryCorrectsFinishedPreview() async throws {
        let (model, feed, rounds) = makeSession()
        defer { model.close(); rounds.finish() }
        model.open(GameDestination(source: source, preview: GamePreview(
            board: board(status: "1-0"), receivedAt: .now, clocksRunning: false)))
        #expect(model.game.finished?.result == "1-0")
        feed.emit(featured, to: source, isHistorical: true, historyComplete: false)
        #expect(await eventually { rounds.count == 1 })
        for _ in 0..<20 { await Task.yield() }
        #expect(model.game.position == (try Position(fen: afterE4)))
        #expect(model.game.finished?.result == "1-0")
        #expect(model.game.moveHistory.isEmpty)
        feed.emit(e4, to: source, isHistorical: true, historyComplete: true)
        #expect(await eventually { model.game.moveHistory.count == 1 && !model.isReplayingHistory })
        #expect(model.game.finished == nil)
        #expect(model.game.position == (try Position(fen: afterE4)))
    }
}
