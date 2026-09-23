import Foundation
import FollowKit
import Testing
@testable import FollowServer

@Suite("Eval swings")
struct SwingTests {

    // MARK: Classifier

    private let classifier = SwingClassifier()

    @Test("Losing a big share of the chances is a blunder; the same move by Black mirrors it")
    func blunders() {
        #expect(classifier.classify(before: .centipawns(20), after: .centipawns(20), whiteMoved: true) == nil)
        #expect(classifier.classify(before: .centipawns(10), after: .centipawns(-250), whiteMoved: true)?.kind == .blunder)
        #expect(classifier.classify(before: .centipawns(-10), after: .centipawns(250), whiteMoved: false)?.kind == .blunder)
        // Good for the mover is never a blunder, however large the swing.
        #expect(classifier.classify(before: .centipawns(-250), after: .centipawns(10), whiteMoved: true) == nil)
    }

    @Test("A swing inside a decided position is not news")
    func saturation() {
        #expect(classifier.classify(before: .centipawns(1200), after: .centipawns(800), whiteMoved: true) == nil)
        #expect(classifier.classify(before: .mate(4), after: .centipawns(1500), whiteMoved: true) == nil)
        // Lichess's inaccuracy is not a push.
        #expect(classifier.classify(before: .centipawns(0), after: .centipawns(-60), whiteMoved: true) == nil)
    }

    @Test("The flavours: a thrown win, an allowed mate, a missed mate")
    func flavours() {
        #expect(classifier.classify(before: .centipawns(350), after: .centipawns(20), whiteMoved: true)?.kind == .throwsWin)
        #expect(classifier.classify(before: .centipawns(30), after: .mate(-3), whiteMoved: true)?.kind == .allowsMate)
        #expect(classifier.classify(before: .mate(-3), after: .centipawns(150), whiteMoved: false)?.kind == .missesMate)
        // Delivering mate is the opposite of a blunder.
        #expect(classifier.classify(before: .mate(1), after: .mate(0), whiteMoved: true) == nil)
    }

    @Test("Scores print from White's side, the way chess sites write them")
    func display() {
        #expect(EngineScore.centipawns(43).display == "+0.4")
        #expect(EngineScore.centipawns(-280).display == "\u{2212}2.8")
        #expect(EngineScore.centipawns(2).display == "0.0")
        #expect(EngineScore.mate(3).display == "#3")
        #expect(EngineScore.mate(-2).display == "#\u{2212}2")
    }

    // MARK: UCI

    @Test("UCI scores are the side to move's; bounds and other lines are ignored")
    func uciParsing() {
        let line = "info depth 20 seldepth 27 multipv 1 score cp -35 nodes 1 nps 1 time 1 pv e7e5"
        #expect(UCIProcess.parseInfo(line, whiteToMove: true)?.score == .centipawns(-35))
        #expect(UCIProcess.parseInfo(line, whiteToMove: false)?.score == .centipawns(35))
        #expect(UCIProcess.parseInfo(line, whiteToMove: true)?.depth == 20)
        #expect(UCIProcess.parseInfo("info depth 12 score mate -2 pv a1a2", whiteToMove: false)?.score == .mate(2))
        #expect(UCIProcess.parseInfo("info depth 18 score cp 40 lowerbound nodes 5", whiteToMove: true) == nil)
        #expect(UCIProcess.parseInfo("info depth 18 multipv 2 score cp 40", whiteToMove: true) == nil)
        #expect(UCIProcess.parseInfo("info string NNUE evaluation using nn-1a298aa575a0.nnue", whiteToMove: true) == nil)
    }

    // MARK: PGN

    @Test("A snapshot knows the position the mover was looking at")
    func previousPosition() throws {
        let block = """
        [Event "Test"]
        [GameURL "https://lichess.org/broadcast/-/-/r0000001/gam00001"]
        [White "A"]
        [Black "B"]
        [Result "*"]

        1. e4 e5 2. Nf3 *
        """
        let snapshot = try #require(PGNSnapshot.snapshot(block: block, roundId: "r0000001"))
        #expect(snapshot.ply == 3)
        #expect(snapshot.previousFen?.hasPrefix("rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w") == true)
    }

    // MARK: Watcher

    /// A fixed table of evaluations, keyed by FEN and by whether it is the long confirmation search.
    actor TableEngine: PositionEvaluating {
        var quick: [String: EngineScore]
        var confirmed: [String: EngineScore]
        var searched: [(fen: String, ms: Int)] = []
        init(quick: [String: EngineScore], confirmed: [String: EngineScore]? = nil) {
            self.quick = quick
            self.confirmed = confirmed ?? quick
        }
        func evaluate(fen: String, movetimeMs: Int) async throws -> EngineScore {
            searched.append((fen, movetimeMs))
            let table = movetimeMs >= 3000 ? confirmed : quick
            return table[fen] ?? .centipawns(0)
        }
        func shutDown() async {}
    }

    actor Received {
        var events: [MoveEvent] = []
        func add(_ event: MoveEvent) { events.append(event) }
    }

    private static let before = "r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R b KQkq - 3 3"
    private static let after = "r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4"

    private func snapshot(gameId: String = "wchGam01", ply: Int = 10, previous: String = before, fen: String = after, clock: Int = 3600) -> GameSnapshot {
        var snapshot = GameSnapshot.make(gameId: gameId, ply: ply, fen: fen, whiteClock: clock, blackClock: clock)
        snapshot.previousFen = previous
        return snapshot
    }

    private func watcher(_ engine: TableEngine, boards: Int = 20) async -> (SwingWatcher, Received) {
        var configuration = SwingConfiguration()
        configuration.maximumBoards = boards
        let watcher = SwingWatcher(engine: engine, configuration: configuration, now: { Fixture.now })
        let received = Received()
        await watcher.setHandler { event, _ in await received.add(event) }
        return (watcher, received)
    }

    @Test("A confirmed blunder becomes one swing event for the move that caused it")
    func confirmedSwing() async {
        // Black to move before, then Black played …Nf6?? and White is winning.
        let engine = TableEngine(quick: [Self.before: .centipawns(-20), Self.after: .centipawns(320)])
        let (watcher, received) = await watcher(engine)
        await watcher.consider(snapshot: snapshot(), context: .make())
        await watcher.drain()

        let events = await received.events
        #expect(events.count == 1)
        #expect(events.first?.kind == .evalSwing)
        #expect(events.first?.swing?.kind == .blunder)
        #expect(events.first?.snapshot.ply == 10)
        // Two quick searches, then both again at the confirmation time.
        #expect(await engine.searched.map(\.ms) == [1000, 1000, 3000, 3000])
    }

    @Test("A candidate the longer search does not confirm is dropped")
    func unconfirmed() async {
        let engine = TableEngine(
            quick: [Self.before: .centipawns(-20), Self.after: .centipawns(320)],
            confirmed: [Self.before: .centipawns(-20), Self.after: .centipawns(30)]
        )
        let (watcher, received) = await watcher(engine)
        await watcher.consider(snapshot: snapshot(), context: .make())
        await watcher.drain()
        #expect(await received.events.isEmpty)
    }

    @Test("The position after one move is not searched again as the position before the next")
    func cache() async {
        let next = "r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/3P1N2/PPP2PPP/RNBQK2R b KQkq - 0 4"
        let engine = TableEngine(quick: [:])
        let (watcher, _) = await watcher(engine)
        await watcher.consider(snapshot: snapshot(ply: 10), context: .make())
        await watcher.drain()
        await watcher.consider(snapshot: snapshot(ply: 11, previous: Self.after, fen: next), context: .make())
        await watcher.drain()
        #expect(await engine.searched.map(\.fen) == [Self.before, Self.after, next])
    }

    @Test("A full queue gives its last place to a higher board, never to a lower one")
    func priority() async {
        let engine = TableEngine(quick: [:])
        let (watcher, _) = await watcher(engine, boards: 1)
        let context = RoundContext.make(boards: ["board1", "board2", "board3"])
        await watcher.consider(snapshot: snapshot(gameId: "board2"), context: context)
        await watcher.consider(snapshot: snapshot(gameId: "board3"), context: context)
        #expect(await watcher.queuedGameIds == ["board2"])
        await watcher.consider(snapshot: snapshot(gameId: "board1"), context: context)
        #expect(await watcher.queuedGameIds == ["board1"])
    }

    @Test("A game whose clocks say rapid is never searched")
    func fastGamesSkipped() async {
        let engine = TableEngine(quick: [:])
        let (watcher, _) = await watcher(engine)
        await watcher.consider(snapshot: snapshot(ply: 6, clock: 14 * 60), context: .make())
        // Still skipped later, when the clock alone could no longer tell.
        await watcher.consider(snapshot: snapshot(ply: 40, clock: 5 * 60), context: .make())
        await watcher.drain()
        #expect(await engine.searched.isEmpty)
    }

    // MARK: Policy

    private func swingEvent(gameId: String = "wchGam01") -> MoveEvent {
        MoveEvent(
            kind: .evalSwing,
            snapshot: GameSnapshot.make(gameId: gameId, ply: 10),
            at: Fixture.now,
            swing: EvalSwing(kind: .throwsWin, before: .centipawns(-320), after: .centipawns(-10), loss: 0.6)
        )
    }

    @Test("A swing reaches follows with the switch on, worded as one, replacing the move's notification")
    func policy() throws {
        let engine = AlertEngine()
        var on = Follow(id: "f_on", target: .player(fideId: 4_168_119), alerts: .playerDefaults)
        on.alerts.evalSwings = true
        let off = Follow(id: "f_off", target: .game(roundId: "WCHr0002", gameId: "wchGam01"), alerts: .gameDefaults)
        let devices = [DeviceContext.make(id: "d_on", follows: [on]), DeviceContext.make(id: "d_off", follows: [off])]

        let plan = engine.plan(events: [swingEvent()], context: .make(), devices: devices, cooldowns: [:], activities: [], now: Fixture.now)
        #expect(plan.entries.map(\.deviceId) == ["d_on"])
        #expect(plan.entries.first?.collapseId == "wchGam01")
        #expect(plan.entries.first?.title == "Nepomniachtchi, Ian lets the win slip: 3... Nc6")
        #expect(plan.entries.first?.body.hasPrefix("Carlsen, Magnus – Nepomniachtchi, Ian · Stockfish \u{2212}3.2 → \u{2212}0.1") == true)
        #expect(plan.cooldowns.isEmpty)
        let push = try FollowJSON.pushDecoder.decode(MovePush.self, from: Data(try #require(plan.entries.first).payloadJSON.utf8))
        #expect(push.pushKind == .evalSwing)
        #expect(push.swing == PushSwing(kind: "throwsWin", before: "\u{2212}3.2", after: "\u{2212}0.1"))

        #expect(engine.wantsSwings(snapshot: GameSnapshot.make(), context: .make(), devices: devices, now: Fixture.now))
        #expect(!engine.wantsSwings(snapshot: GameSnapshot.make(), context: .make(), devices: [devices[1]], now: Fixture.now))
    }

    @Test("A tournament follow's swings cover its top boards only")
    func tournamentSwings() {
        let engine = AlertEngine()
        var follow = Follow(id: "f_tour", target: .tournament(tourId: "WCHtour1"), alerts: .tournamentDefaults)
        follow.alerts.evalSwings = true
        let device = DeviceContext.make(follows: [follow])
        let context = RoundContext.make(boards: ["wchGam01", "wchGam02"])
        let neither = GameSnapshot.make(gameId: "wchGam02", whiteFideId: nil, blackFideId: nil)
        #expect(engine.wantsSwings(snapshot: GameSnapshot.make(gameId: "wchGam01"), context: context, devices: [device], now: Fixture.now))
        #expect(!engine.wantsSwings(snapshot: neither, context: context, devices: [device], now: Fixture.now))
    }

    @Test("An install gets at most ten follows with swings on")
    func swingCap() async throws {
        let rig = try await TestRig.make()
        defer { Task { await rig.close() } }
        let device = try await rig.device()
        var alerts = FollowAlerts.playerDefaults
        alerts.evalSwings = true
        for fideId in 1...10 {
            _ = try await rig.store.addFollow(Follow(target: .player(fideId: fideId), alerts: alerts), deviceId: device.id)
        }
        await #expect(throws: StoreError.self) {
            try await rig.store.addFollow(Follow(target: .player(fideId: 11), alerts: alerts), deviceId: device.id)
        }
        // Without swings the eleventh is fine, and switching them on for it is what is refused.
        let eleventh = try await rig.store.addFollow(Follow(target: .player(fideId: 11)), deviceId: device.id)
        await #expect(throws: StoreError.self) {
            try await rig.store.updateFollow(id: eleventh.id, alerts: alerts, deviceId: device.id)
        }
        // Re-saving one that already has them on is not a new one.
        let first = try await rig.store.follows(deviceId: device.id)[0]
        _ = try await rig.store.updateFollow(id: first.id, alerts: alerts, deviceId: device.id)
    }
}
