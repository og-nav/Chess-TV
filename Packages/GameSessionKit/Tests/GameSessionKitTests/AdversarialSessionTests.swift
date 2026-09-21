import Foundation
import Testing
import ChessCore
import EngineKit
import LichessKit
@testable import GameSessionKit

/// Retains each connection independently, including old connections to the same source.
/// Tests can deliver delayed completions to exactly the generation that produced them.
private final class GenerationFeed: SourceStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var feeds: [AsyncThrowingStream<FeedItem, Error>.Continuation] = []
    private var retired: Set<Int> = []
    let connectionStates: AsyncStream<ConnectionState>
    let states: AsyncStream<ConnectionState>.Continuation
    init() { (connectionStates, states) = AsyncStream.makeStream() }
    var count: Int { lock.withLock { feeds.count } }
    var retiredCount: Int { lock.withLock { retired.count } }
    func sourcedEvents(for source: GameSource) -> AsyncThrowingStream<FeedItem, Error> {
        let (stream, continuation) = AsyncThrowingStream<FeedItem, Error>.makeStream()
        let index = lock.withLock { let index = feeds.count; feeds.append(continuation); return index }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }; _ = self.lock.withLock { self.retired.insert(index) }
        }
        return stream
    }
    func send(_ item: FeedItem, generation: Int) { lock.withLock { feeds[generation] }.yield(item) }
    func end(_ generation: Int) { lock.withLock { feeds[generation] }.finish() }
    func finish() { for continuation in lock.withLock({ feeds }) { continuation.finish() }; states.finish() }
}

/// Simulates an engine crossing its actor boundary late, after cancellation. Returning a buffered
/// result after release exercises the await-before-stream race, not only normal stream teardown.
private actor GatedEngine: EngineProviding {
    struct Request: Sendable { let fen: String; let revision: Int }
    private(set) var requests: [Request] = []
    private var gates: [Int: CheckedContinuation<AsyncStream<Evaluation>, Never>] = [:]
    func evaluate(fen: String, maxDepth: Int, revision: Int) async -> AsyncStream<Evaluation> {
        let index = requests.count
        requests.append(Request(fen: fen, revision: revision))
        return await withCheckedContinuation { gates[index] = $0 }
    }
    func release(_ index: Int, score: Int) {
        guard let gate = gates.removeValue(forKey: index) else { return }
        let request = requests[index]
        gate.resume(returning: AsyncStream { continuation in
            continuation.yield(Evaluation(score: .centipawns(score), depth: 18, principalVariation: [],
                                          positionFEN: request.fen, revision: request.revision))
            continuation.finish()
        })
    }
    func stop() {}
    func shutdown() { for index in Array(gates.keys) { release(index, score: -999) } }
}

@Suite("Adversarial session sequencing") @MainActor
struct AdversarialSessionTests {
    private func model(engine: (any EngineProviding)? = nil) -> (GameSession, GenerationFeed) {
        let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.sounds = false
        settings.tournamentAlerts = false
        settings.engineEnabled = engine != nil
        let feed = GenerationFeed()
        return (GameSession(settings: settings, streamer: feed, arenas: FakeArenas(), engine: engine), feed)
    }
    private func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<100 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
    private func header(_ id: String, historical: Bool = false, complete: Bool? = nil) -> FeedItem {
        .event(SourcedEvent(event: .featured(gameId: id, orientation: .white, players: [], fen: Position.standard.fen),
                            isHistorical: historical, historyComplete: complete))
    }
    private func events(_ pgn: String, historical: Bool, complete: Bool = true) throws -> [FeedItem] {
        let moves = try #require(PGN.parseGame(pgn)).replay()
        return moves.enumerated().map { index, ply in
            .event(SourcedEvent(event: .fen(fen: ply.fen, lastMove: ply.uci, whiteClock: 100, blackClock: 100),
                                isHistorical: historical, historyComplete: historical ? (complete && index == moves.count - 1) : nil))
        }
    }
    private func result(_ id: String) -> FeedItem { .gameEnded(gameId: id, status: .init(id: 30, name: "mate", winner: .white)) }

    @Test("Forty source switches reject every retired snapshot, result and end, including same-source reopens")
    func rapidSwitchesAndLateCompletions() async throws {
        let (session, feed) = model()
        defer { session.teardown() }
        let history = try events("1. e4 e5 2. Nf3 Nc6 *", historical: true)
        var channel: TVChannel = .blitz
        for index in 0..<40 {
            // Alternate source changes with explicit close/reopen of an identical source.
            if index % 3 == 0 { session.close() }
            else { channel = channel == .blitz ? .rapid : .blitz }
            let source = GameSource.tvChannel(channel)
            session.open(source: source, title: "Generation \(index)")
            session.open(source: source, title: "Duplicate request")
            #expect(feed.count == index + 1)
            feed.send(header("g\(index)", historical: true, complete: false), generation: index)
            #expect(await eventually { session.isReplayingHistory })
            if index > 0 {
                feed.send(history.last!, generation: index - 1)
                feed.send(result("g\(index - 1)"), generation: index - 1)
                feed.end(index - 1)
            }
            for event in history { feed.send(event, generation: index) }
            #expect(await eventually { session.game.gameId == "g\(index)" && !session.isReplayingHistory })
            #expect(session.game.finished == nil)
            #expect(session.game.moveHistory.map(\.san) == ["e4", "e5", "Nf3", "Nc6"])
            #expect(session.game.source == source)
        }
        session.close()
        #expect(await eventually { feed.retiredCount == 40 })
        feed.send(header("late", historical: true, complete: true), generation: 39)
        for _ in 0..<10 { await Task.yield() }
        #expect(session.game.position == nil)
    }

    @Test("Reconnect corrections keep the scrubbed view stable until an atomic replacement, then expose the corrected line")
    func correctionDuringScrubAndReconnect() async throws {
        let (session, feed) = model()
        session.start()
        defer { session.teardown() }
        session.open(source: .tvChannel(.rapid), title: "Test")
        feed.send(header("same", historical: true, complete: false), generation: 0)
        for event in try events("1. e4 e5 2. Nf3 Nc6 *", historical: true) { feed.send(event, generation: 0) }
        #expect(await eventually { session.game.moveHistory.count == 4 })
        session.setViewedPly(2)
        let scrubbed = session.viewedPosition
        feed.states.yield(.reconnecting(attempt: 1, nextRetryIn: .seconds(1)))
        feed.send(header("same", historical: true, complete: false), generation: 0)
        let corrected = try events("1. d4 d5 2. c4 e6 *", historical: true)
        for event in corrected.dropLast() { feed.send(event, generation: 0) }
        #expect(await eventually { session.isReplayingHistory })
        #expect(session.viewedPly == 2)
        #expect(session.viewedPosition == scrubbed)
        #expect(session.game.moveHistory.map(\.san) == ["e4", "e5", "Nf3", "Nc6"])
        feed.states.yield(.live)
        feed.send(corrected.last!, generation: 0)
        #expect(await eventually { !session.isReplayingHistory })
        #expect(session.viewedPly == nil)
        #expect(session.game.moveHistory.map(\.san) == ["d4", "d5", "c4", "e6"])
        session.setViewedPly(2)
        #expect(session.viewedPosition?.fen == session.game.moveHistory[1].fen)
        #expect(session.viewedPosition != scrubbed)
    }

    @Test("Repeated replay, duplicate clock snapshots and terminal statuses neither duplicate moves nor leak results to the next game")
    func repeatedSnapshotLiveResultCycles() async throws {
        let (session, feed) = model()
        defer { session.teardown() }
        session.open(source: .tvChannel(.blitz), title: "Test")
        let history = try events("1. e4 e5 *", historical: true)
        let live = try #require(events("1. e4 e5 2. Nf3 *", historical: false).last)
        for cycle in 0..<20 {
            let id = "cycle\(cycle)"
            feed.send(header(id, historical: true, complete: false), generation: 0)
            for event in history { feed.send(event, generation: 0) }
            feed.send(result("old-game"), generation: 0)
            feed.send(live, generation: 0)
            for _ in 0..<8 { feed.send(live, generation: 0) }
            #expect(await eventually { session.game.gameId == id && session.game.moveHistory.count == 3 })
            #expect(session.game.finished == nil)
            feed.send(result(id), generation: 0)
            feed.send(result(id), generation: 0)
            #expect(await eventually { session.game.finished?.result == "1-0" })
            #expect(session.game.moveHistory.map(\.san) == ["e4", "e5", "Nf3"])
            let priorRevision = session.game.revision
            feed.send(header(id, historical: true, complete: false), generation: 0)
            for event in history { feed.send(event, generation: 0) }
            feed.send(live, generation: 0)
            #expect(await eventually { session.game.revision > priorRevision && !session.isReplayingHistory && session.game.moveHistory.count == 3 })
            #expect(session.game.finished?.result == "1-0")
        }
    }

    @Test("Late engine returns cannot win against backgrounding or a newer search of the identical position")
    func gatedEngineBackgroundAndIdenticalFENRace() async throws {
        let engine = GatedEngine()
        let (session, feed) = model(engine: engine)
        session.start()
        session.open(source: .tvChannel(.blitz), title: "Test")
        feed.send(header("g"), generation: 0)
        #expect(await eventually { await engine.requests.count == 1 })
        session.scenePhaseChanged(to: .background)
        session.scenePhaseChanged(to: .active)
        #expect(feed.count == 2)
        feed.send(header("g"), generation: 1)
        #expect(await eventually { await engine.requests.count == 2 })
        await engine.release(1, score: 42)
        #expect(await eventually { session.game.evaluation?.score == .centipawns(42) })
        await engine.release(0, score: 999)
        for _ in 0..<10 { await Task.yield() }
        #expect(session.game.evaluation?.score == .centipawns(42))
        session.setViewedPly(0)
        #expect(await eventually { await engine.requests.count == 3 })
        session.setViewedPly(nil)
        #expect(await eventually { await engine.requests.count == 4 })
        await engine.release(3, score: 43)
        #expect(await eventually { session.game.evaluation?.score == .centipawns(43) })
        await engine.release(2, score: -999)
        for _ in 0..<10 { await Task.yield() }
        #expect(session.scrubEvaluation == nil)
        #expect(session.viewedEvaluation?.score == .centipawns(43))
        session.teardown()
        await session.shutdownEngine()
    }
}
