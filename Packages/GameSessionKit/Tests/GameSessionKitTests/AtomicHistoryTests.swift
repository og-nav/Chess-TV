import ChessCore
import Foundation
import LichessKit
import Testing
@testable import GameSessionKit

@Suite("Atomic history publication")
@MainActor struct AtomicHistoryTests {
    private let source = GameSource.tvChannel(.rapid)
    private func session() -> (GameSession, FakeStreamer) {
        let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.sounds = false
        settings.engineEnabled = false
        settings.tournamentAlerts = false
        let streamer = FakeStreamer()
        let session = GameSession(settings: settings, streamer: streamer, arenas: FakeArenas())
        session.open(source: source, title: "Fixture")
        return (session, streamer)
    }
    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
    private func moves() throws -> [TVEvent] { try FixtureFeed.events(named: "feed-blitz") }

    @Test("An explicit replay remains invisible across network gaps and publishes all scrub history once")
    func delayedBatch() async throws {
        let (model, feed) = session()
        defer { model.close() }
        let events = try moves()
        for event in events.dropLast() { feed.emit(event, to: source, isHistorical: true, historyComplete: false) }
        #expect(await settle { model.isReplayingHistory })
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.game.position == nil)
        #expect(model.game.revision == 0)
        feed.emit(events.last!, to: source, isHistorical: true, historyComplete: true)
        #expect(await settle { !model.isReplayingHistory })
        var expected = GameReducer()
        for event in events { expected.apply(event) }
        #expect(model.game.reducer.position == expected.position)
        #expect(model.game.moveHistory == expected.moveHistory)
        model.setViewedPly(0)
        #expect(model.viewedPosition == expected.initialPosition)
        model.setViewedPly(1)
        #expect(model.viewedPosition?.fen == expected.moveHistory.first?.fen)
    }

    @Test("A live featured position stays visible while its historical replay is staged")
    func liveFeaturedIsPreserved() async throws {
        let (model, feed) = session()
        defer { model.close() }
        let events = try moves()
        var expected = GameReducer()
        for event in events { expected.apply(event) }
        let live = TVEvent.featured(gameId: "live", orientation: .white, players: [], fen: expected.position!.fen)
        feed.emit(live, to: source)
        #expect(await settle { model.game.gameId == "live" })
        for event in events.dropLast() { feed.emit(event, to: source, isHistorical: true, historyComplete: false) }
        #expect(await settle { model.isReplayingHistory })
        #expect(model.game.position == expected.position)
        #expect(model.game.gameId == "live")
        feed.emit(events.last!, to: source, isHistorical: true, historyComplete: true)
        #expect(await settle { !model.isReplayingHistory })
        #expect(model.game.moveHistory == expected.moveHistory)
    }

    @Test("A terminal event commits final history before setting the result")
    func terminalDuringBatch() async throws {
        let (model, feed) = session()
        defer { model.close() }
        let events = try moves()
        var expected = GameReducer()
        for event in events { expected.apply(event); feed.emit(event, to: source, isHistorical: true, historyComplete: false) }
        #expect(await settle { model.isReplayingHistory })
        feed.endGame(expected.gameId!, status: .init(id: 30, name: "mate", winner: .white), to: source)
        #expect(await settle { model.game.finished != nil })
        #expect(model.game.position == expected.position)
        #expect(model.game.moveHistory == expected.moveHistory)
        #expect(model.game.finished?.result == "1-0")
        #expect(!model.isReplayingHistory)
    }

    @Test("Closing discards an unfinished replay and its delayed publication")
    func cancellation() async throws {
        let (model, feed) = session()
        for event in try moves() { feed.emit(event, to: source, isHistorical: true) }
        #expect(await settle { model.isReplayingHistory })
        model.close()
        // Cross the actual fallback deadline: checking earlier would miss a retired timer
        // that incorrectly republishes its staged snapshot after teardown.
        try await Task.sleep(for: GameSession.historySettleDelay + .milliseconds(50))
        #expect(model.game.position == nil)
        #expect(model.game.moveHistory.isEmpty)
        #expect(!model.isReplayingHistory)
    }

    @Test("A completed correction replaces history atomically and resets a stale scrub index")
    func correction() async throws {
        let (model, feed) = session()
        defer { model.close() }
        let events = try moves()
        for (index, event) in events.enumerated() { feed.emit(event, to: source, isHistorical: true, historyComplete: index == events.count - 1) }
        #expect(await settle { model.game.revision == events.count })
        let original = model.game.position
        model.setViewedPly(model.game.moveHistory.count)
        feed.emit(events[0], to: source, isHistorical: true, historyComplete: false)
        #expect(await settle { model.isReplayingHistory })
        #expect(model.game.position == original)
        feed.emit(events[1], to: source, isHistorical: true, historyComplete: true)
        #expect(await settle { !model.isReplayingHistory })
        #expect(model.game.moveHistory.count == 1)
        #expect(model.viewedPly == nil)
    }
}
