import Foundation
import Testing
import ChessCore
import LichessKit
import EngineKit
@testable import GameSessionKit

@Suite("Session lifecycle and replay regressions")
@MainActor struct SessionRegressionTests {
    private func settings() -> AppSettings {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = AppSettings(defaults: defaults, defaultEngineDepth: .light)
        settings.sounds = false
        settings.tournamentAlerts = false
        return settings
    }

    @Test func duplicatePositionUpdatesClocksWithoutRepeatingMove() throws {
        var reducer = GameReducer()
        reducer.apply(.featured(gameId: "g", orientation: .white, players: [], fen: Position.standard.fen))
        let next = try Position(fen: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1")
        let event = TVEvent.fen(fen: next.fen, lastMove: "e2e4", whiteClock: 300, blackClock: 300)
        #expect(reducer.apply(event) == .move)
        let revision = reducer.revision
        #expect(reducer.apply(event) == nil)
        #expect(reducer.revision == revision)
        #expect(reducer.moveHistory.count == 1)
    }

    @Test func invalidFeaturedPreservesFinishedGame() {
        let game = GameState()
        game.apply(.featured(gameId: "old", orientation: .white, players: [], fen: Position.standard.fen))
        game.finished = .init(result: "1-0")
        game.apply(.featured(gameId: "bad", orientation: .white, players: [], fen: "bad"))
        #expect(game.gameId == "old")
        #expect(game.finished?.result == "1-0")
    }

    @Test func diagramAndInvalidCastlingAreNeverSentToStockfish() throws {
        #expect(Position.standard.supportsStandardAnalysis)
        #expect(!(try Position(fen: "8/8/8/8/8/8/8/8 w - - 0 1")).supportsStandardAnalysis)
        #expect(!(try Position(fen: "4k3/8/8/8/8/8/8/4K3 w K - 0 1")).supportsStandardAnalysis)
    }

    @Test func freezingClockDoesNotJumpBackToLastReceivedTime() {
        let game = GameState()
        let now = ContinuousClock.now
        game.connection = .live
        game.apply(.featured(gameId: "g", orientation: .white, players: [.init(name: "W", title: nil, rating: nil, color: .white, secondsRemaining: 60)], fen: Position.standard.fen), at: now)
        game.freezeClocks(at: now + .seconds(9))
        game.finished = .init(result: "1-0")
        #expect(ClockDisplay.remainingSeconds(for: .white, clocks: game.clocks, isLive: false, now: now + .seconds(30)) == 51)
    }

    @Test func disconnectionFreezesWithoutRewindingAndReconnectionChargesOfflineTime() {
        let game = GameState()
        let now = ContinuousClock.now
        game.connection = .live
        game.apply(.featured(gameId: "g", orientation: .white, players: [.init(name: "W", title: nil, rating: nil, color: .white, secondsRemaining: 60)], fen: Position.standard.fen), at: now)
        game.setConnection(.connecting, at: now + .seconds(9))
        #expect(ClockDisplay.remainingSeconds(for: .white, clocks: game.clocks, isLive: game.isLive, now: now + .seconds(30)) == 51)
        // 21 s passed offline while White was still thinking: 51 - 21 = 30 at the reconnect, 28 two seconds on.
        game.setConnection(.live, at: now + .seconds(30))
        #expect(ClockDisplay.remainingSeconds(for: .white, clocks: game.clocks, isLive: game.isLive, now: now + .seconds(32)) == 28)
    }

    @Test func scrubbingUsesAvailableInitialPositionAndReturnsToLive() throws {
        let session = GameSession(settings: settings(), streamer: QuietFeed())
        let events = try FixtureFeed.events(named: "feed-blitz")
        for event in events { session.game.apply(event) }
        session.setViewedPly(0)
        #expect(session.viewedPosition == session.game.reducer.initialPosition)
        session.setViewedPly(1)
        #expect(session.viewedPosition?.fen == session.game.moveHistory.first?.fen)
        session.setViewedPly(nil)
        #expect(session.viewedPosition == session.game.position)
        session.setViewedPly(10_000)
        #expect(session.viewedPly == nil)
    }

    @Test func engineDoesNotRestartInBackgroundOrThermalPressure() async throws {
        let engine = RecordingEngine()
        let session = GameSession(settings: settings(), streamer: QuietFeed(), engine: engine)
        session.game.apply(.featured(gameId: "g", orientation: .white, players: [], fen: Position.standard.fen))
        session.scenePhaseChanged(to: .background)
        session.setEngineDepth(.deep)
        try await Task.sleep(for: .milliseconds(40))
        #expect(await engine.searches == 0)
        session.scenePhaseChanged(to: .active)
        session.setThermalState(.serious)
        session.setEngineDepth(.standard)
        try await Task.sleep(for: .milliseconds(40))
        #expect(await engine.searches == 0)
        session.setThermalState(.nominal)
        try await Task.sleep(for: .milliseconds(40))
        #expect(await engine.searches == 1)
        session.teardown()
        await session.shutdownEngine()
    }
}

private struct QuietFeed: SourceStreaming {
    var connectionStates: AsyncStream<ConnectionState> { AsyncStream { $0.finish() } }
    func sourcedEvents(for source: GameSource) -> AsyncThrowingStream<FeedItem, Error> { AsyncThrowingStream { $0.finish() } }
    func finish() {}
}
private actor RecordingEngine: EngineProviding {
    var searches = 0
    func evaluate(fen: String, maxDepth: Int, revision: Int) -> AsyncStream<Evaluation> {
        searches += 1
        return AsyncStream { $0.finish() }
    }
    func stop() {}
    func shutdown() {}
}
