import ChessCore
import Foundation
import LichessKit
import Testing
@testable import GameSessionKit

@Suite("Live move presentation")
@MainActor struct LiveMovePresentationTests {
    private func makeSession() -> (GameSession, FakeStreamer) {
        let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.sounds = false
        settings.engineEnabled = false
        settings.tournamentAlerts = false
        let feed = FakeStreamer()
        return (GameSession(settings: settings, streamer: feed, arenas: FakeArenas()), feed)
    }

    @Test("A burst of final live moves displays every position before the result", arguments: [
        GameSource.tvChannel(.blitz), .arena(tournamentId: "blitz")
    ])
    func finalBurst(source: GameSource) async throws {
        let (session, feed) = makeSession()
        defer { session.close() }
        session.open(source: source)
        let events = Array(try FixtureFeed.events(named: "feed-blitz").prefix(4))
        var expected = GameReducer()
        for event in events { expected.apply(event); feed.emit(event, to: source) }
        feed.endGame(expected.gameId!, status: .init(id: 31, name: "resign", winner: .white), to: source)

        var observed: [(fen: String, at: ContinuousClock.Instant)] = []
        let deadline = ContinuousClock.now + .seconds(3)
        while session.game.finished == nil && ContinuousClock.now < deadline {
            // The featured header may be observed before the first live ply; it is not a
            // move. Measure publication times from the reducer rather than polling latency.
            if !session.game.moveHistory.isEmpty,
               let fen = session.game.position?.fen, fen != observed.last?.fen,
               let receivedAt = session.game.clocks?.receivedAt {
                observed.append((fen, receivedAt))
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(session.game.finished != nil)
        #expect(observed.map(\.fen) == expected.moveHistory.map(\.fen))
        for pair in zip(observed, observed.dropFirst()) {
            #expect(pair.0.at.duration(to: pair.1.at) >= GameSession.liveMoveDisplayDuration - .milliseconds(40))
        }
        let final = try #require(observed.last)
        #expect(final.at.duration(to: .now) >= GameSession.liveMoveDisplayDuration - .milliseconds(40))
    }

    @Test("Closing during a live burst cancels queued moves and the result")
    func cancellation() async throws {
        let (session, feed) = makeSession()
        let source = GameSource.tvChannel(.blitz)
        session.open(source: source)
        for event in try FixtureFeed.events(named: "feed-blitz") { feed.emit(event, to: source) }
        let deadline = ContinuousClock.now + .seconds(2)
        while session.game.position == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(session.game.position != nil)
        session.close()
        try await Task.sleep(for: GameSession.liveMoveDisplayDuration + .milliseconds(40))
        #expect(session.game.position == nil)
        #expect(session.game.finished == nil)
    }
}
