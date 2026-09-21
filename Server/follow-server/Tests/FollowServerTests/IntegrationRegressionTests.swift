import ChessCore
import Foundation
import FollowKit
import Testing
@testable import FollowServer

@Suite("Backend integration regressions")
struct IntegrationRegressionTests {
    @Test("Actual APNS alert serializer retains ISO8601 dates and default sound")
    func alertWire() throws {
        let payload = MovePush(roundId: "r", gameId: "g", sentAt: Fixture.now)
        let row = OutboxEntry(deviceId: "d", dedupeKey: "m", collapseId: "g", category: .gameMove,
            payloadJSON: String(decoding: try FollowJSON.pushEncoder.encode(payload), as: UTF8.self))
        let data = try APNSPushDelivery.wireBody(for: row, topic: PushTopic.app, liveActivityTopic: PushTopic.liveActivity)
        let decoded = try FollowJSON.pushDecoder.decode(PushEnvelope<MovePush>.self, from: data)
        #expect(decoded.payload == payload)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["aps"] as? [String: Any])?["sound"] as? String == "default")
        #expect((json["d"] as? [String: Any])?["sentAt"] is String)
    }

    @Test("Actual tournament serializer retains both date fields")
    func tournamentWire() throws {
        let payload = TournamentPush(startsAt: Fixture.now.addingTimeInterval(600), sentAt: Fixture.now)
        let row = OutboxEntry(deviceId: "d", dedupeKey: "t", collapseId: "t", category: .tournamentEvent,
            payloadJSON: String(decoding: try FollowJSON.pushEncoder.encode(payload), as: UTF8.self))
        let data = try APNSPushDelivery.wireBody(for: row, topic: PushTopic.app, liveActivityTopic: PushTopic.liveActivity)
        #expect(try FollowJSON.pushDecoder.decode(PushEnvelope<TournamentPush>.self, from: data).payload == payload)
    }

    @Test("Actual activity serializer has numeric reference date and Unix APNs timestamp")
    func activityWire() throws {
        let payload = LiveActivityState(asOf: Fixture.now)
        let row = OutboxEntry(deviceId: "d", dedupeKey: "a", collapseId: "g", category: .activityEnd,
            payloadJSON: String(decoding: try FollowJSON.activityEncoder.encode(payload), as: UTF8.self))
        let data = try APNSPushDelivery.wireBody(for: row, topic: PushTopic.app, liveActivityTopic: PushTopic.liveActivity)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let aps = try #require(json["aps"] as? [String: Any])
        #expect(aps["timestamp"] as? Int == Int(Fixture.now.timeIntervalSince1970))
        #expect(aps["event"] as? String == "end")
        let content = try #require(aps["content-state"] as? [String: Any])
        #expect(content["asOf"] is NSNumber)
        #expect(try JSONDecoder().decode(LiveActivityState.self, from: JSONSerialization.data(withJSONObject: content)) == payload)
    }

    @Test("Single PGN completes while stream remains open and UTF8 chunks stay intact")
    func streamFraming() throws {
        let pgn = "[Event \"Événement\"]\n[Site \"https://lichess.org/broadcast/-/r/g\"]\n[White \"Muñoz\"]\n\n1. e4 *\n\n"
        var splitter = PGNStreamSplitter()
        var blocks: [String] = []
        for byte in pgn.utf8 { blocks += splitter.append(bytes: [byte]) }
        #expect(blocks.count == 1)
        #expect(blocks[0].contains("Muñoz"))
        #expect(blocks[0].contains("Événement"))
        #expect(splitter.flush() == nil)
    }

    @Test("Setup PGN clocks belong to the actual mover")
    func blackSetupClock() throws {
        let pgn = """
        [Event "Setup"]
        [Site "https://lichess.org/broadcast/-/round001/game0001"]
        [SetUp "1"]
        [FEN "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"]
        [Result "*"]

        1... e5 { [%clk 0:01:23] } 2. Nf3 { [%clk 0:02:34] } *
        """
        let snapshot = try #require(PGNSnapshot.snapshot(block: pgn, roundId: "round001"))
        #expect(snapshot.blackClock == 83)
        #expect(snapshot.whiteClock == 154)
    }

    @Test("Same-ply position correction resets long-think eligibility")
    func correction() {
        let initial = GameSnapshot.make()
        let baseline = initial.baseline(observedAt: Fixture.now, longThinkEligible: true)
        var corrected = initial
        corrected.fen = Position.standard.fen
        let result = GameDiffer.advance(baseline: baseline, snapshot: corrected, now: Fixture.now.addingTimeInterval(600))
        #expect(result.events.isEmpty)
        #expect(!result.baseline.longThinkEligible)
        #expect(result.baseline.observedAt == Fixture.now.addingTimeInterval(600))
    }

    @Test("Expired activity token retires only that activity, preserving phone alerts")
    func deadActivity() async throws {
        let rig = try await TestRig.make()
        let device = try await rig.device()
        try await rig.store.registerActivity(ActivityRegistration(roundId: "r", gameId: "g", activityToken: "dead"), deviceId: device.id)
        await rig.delivery.markDead("dead")
        _ = try await rig.store.enqueue(OutboxEntry(deviceId: device.id, dedupeKey: "a", collapseId: "g", category: .activityUpdate, payloadJSON: "{}", reference: "g"))
        await rig.outbox.drain()
        #expect(try await rig.store.activity(deviceId: device.id) == nil)
        #expect(try await rig.store.device(id: device.id)?.isActive == true)
        _ = try await rig.store.enqueue(OutboxEntry(deviceId: device.id, dedupeKey: "b", collapseId: "g", category: .gameMove, payloadJSON: "{}"))
        #expect(await rig.outbox.drain() == 1)
        await rig.close()
    }

    @Test("Knowing another routing token cannot disable its install by registration or update")
    func routingTokenCannotDisableOwner() async throws {
        let rig = try await TestRig.make()
        let original = try await rig.store.register(DeviceRegistration(apnsToken: "original"))
        _ = try await rig.store.addFollow(Follow(target: .player(fideId: 1)), deviceId: original.device.id)
        let retry = try await rig.store.register(DeviceRegistration(apnsToken: "original"))
        #expect(try await rig.store.device(id: original.device.id)?.isActive == true)
        #expect(try await rig.store.follows(deviceId: retry.device.id).isEmpty)
        try await rig.store.updateAPNsToken(deviceId: retry.device.id, apnsToken: "original")
        #expect(try await rig.store.device(id: original.device.id)?.apnsToken == "original")
        #expect(try await rig.store.device(id: original.device.id)?.isActive == true)
        await rig.close()
    }

    @Test("Disabled installs keep API data but no longer request watcher streams")
    func disabledFollowsStopWatching() async throws {
        let rig = try await TestRig.make()
        let device = try await rig.device(follows: [Follow(target: .game(roundId: "r", gameId: "g"))])
        #expect(try await rig.store.allFollows().count == 1)
        try await rig.store.disableDevice(id: device.id, reason: "gone")
        #expect(try await rig.store.allFollows().isEmpty)
        #expect(try await rig.store.follows(deviceId: device.id).count == 1)
        try await rig.store.updateAPNsToken(deviceId: device.id, apnsToken: "replacement")
        #expect(try await rig.store.allFollows().count == 1)
        await rig.close()
    }

    @Test("A late rejection of an old token cannot retire its replacement")
    func tokenRotationRace() async throws {
        let rig = try await TestRig.make()
        let device = try await rig.device()
        try await rig.store.registerActivity(ActivityRegistration(roundId: "r", gameId: "g", activityToken: "new"), deviceId: device.id)
        try await rig.store.retireActivity(deviceId: device.id, gameId: "g", reason: "gone", expectedToken: "old")
        #expect(try await rig.store.activity(deviceId: device.id)?.activityToken == "new")
        try await rig.store.updateAPNsToken(deviceId: device.id, apnsToken: "replacement")
        try await rig.store.disableDevice(id: device.id, reason: "gone", expectedToken: device.apnsToken)
        #expect(try await rig.store.device(id: device.id)?.isActive == true)
        await rig.close()
    }

    @Test("Pinned-only round is watched, then released after registration expires")
    func pinnedOnly() async throws {
        let rig = try await TestRig.make()
        let device = try await rig.device()
        try await rig.store.registerActivity(ActivityRegistration(roundId: "r", gameId: "g", activityToken: "token"), deviceId: device.id)
        let source = FixtureSource()
        let coordinator = WatchCoordinator(store: rig.store, source: source, pipeline: rig.pipeline, configuration: rig.configuration, now: rig.clock.read)
        try await coordinator.pollOnce()
        #expect(await coordinator.watchedRoundIds == ["r"])
        #expect(await source.topFetches == 0)
        rig.clock.advance(by: rig.configuration.activityLifetime + 1)
        try await coordinator.pollOnce()
        #expect(await coordinator.watchedRoundIds.isEmpty)
        await coordinator.stopAll()
        await rig.close()
    }

    @Test("Concurrent creates and tournament observations remain unique")
    func concurrentWrites() async throws {
        let rig = try await TestRig.make()
        let device = try await rig.device()
        let results = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<30 {
                group.addTask {
                    _ = try await rig.store.addFollow(Follow(target: .player(fideId: 1)), deviceId: device.id)
                    return try await rig.store.observeTournamentEvent(tourId: "t", roundId: "r", kind: "roundLive")
                }
            }
            var values: [Bool] = []
            for try await result in group { values.append(result) }
            return values
        }
        #expect(results.filter { $0 }.count == 1)
        #expect(try await rig.store.follows(deviceId: device.id).count == 1)
        await rig.close()
    }

    @Test("Overlapping drains do not deliver a queued row twice")
    func simultaneousDrains() async throws {
        let rig = try await TestRig.make()
        let device = try await rig.device()
        let delivery = SuspendedDelivery()
        let worker = OutboxWorker(store: rig.store, delivery: delivery, configuration: rig.configuration)
        _ = try await rig.store.enqueue(OutboxEntry(deviceId: device.id, dedupeKey: "x", collapseId: "g", category: .gameMove, payloadJSON: "{}"))
        let first = Task { await worker.drain() }
        await delivery.waitUntilStarted()
        #expect(await worker.drain() == 0)
        await delivery.finish()
        #expect(await first.value == 1)
        #expect(await delivery.count == 1)
        await rig.close()
    }

    @Test("Queued alerts obey mute enabled after enqueue, while activities keep updating")
    func queuedMute() async throws {
        let rig = try await TestRig.make()
        let device = try await rig.device()
        try await rig.store.registerActivity(ActivityRegistration(roundId: "r", gameId: "g", activityToken: "activity"), deviceId: device.id)
        for (index, category) in [OutboxCategory.gameMove, .tournamentEvent, .activityUpdate].enumerated() {
            _ = try await rig.store.enqueue(OutboxEntry(deviceId: device.id, dedupeKey: "mute-\(index)", collapseId: "g", category: category, payloadJSON: "{}", reference: "g"))
        }
        try await rig.store.setPreferences(NotificationPreferences(muteAll: true), deviceId: device.id)
        #expect(await rig.outbox.drain() == 1)
        #expect(await rig.delivery.record().map(\.entry.category) == [.activityUpdate])
        await rig.close()
    }

    @Test("Queued alert entering quiet hours is dropped; opted-in game ends still deliver")
    func queuedQuietHours() async throws {
        let rig = try await TestRig.make()
        let device = try await rig.device()
        let now = rig.clock.read()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        var preferences = NotificationPreferences(quietHoursStart: minute, quietHoursEnd: (minute + 60) % 1440, timeZoneIdentifier: "UTC")
        preferences.gameEndIgnoresQuietHours = true
        try await rig.store.setPreferences(preferences, deviceId: device.id)
        for (index, kind) in [MovePushKind.move, .gameEnd].enumerated() {
            let data = try FollowJSON.pushEncoder.encode(MovePush(kind: kind))
            _ = try await rig.store.enqueue(OutboxEntry(deviceId: device.id, dedupeKey: "quiet-\(index)", collapseId: "g", category: .gameMove, payloadJSON: String(decoding: data, as: UTF8.self)))
        }
        #expect(await rig.outbox.drain() == 1)
        #expect(await rig.delivery.record().first?.entry.dedupeKey == "quiet-1")
        await rig.close()
    }

    @Test("Concurrent follow additions cannot exceed quota; updates remain allowed")
    func followQuota() async throws {
        let rig = try await TestRig.make()
        let device = try await rig.device()
        for fideId in 1...99 { _ = try await rig.store.addFollow(Follow(target: .player(fideId: fideId)), deviceId: device.id) }
        let added = await withTaskGroup(of: Bool.self) { group in
            for fideId in 100...109 {
                group.addTask {
                    do { _ = try await rig.store.addFollow(Follow(target: .player(fideId: fideId)), deviceId: device.id); return true }
                    catch { return false }
                }
            }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }
        #expect(added == 1)
        #expect(try await rig.store.follows(deviceId: device.id).count == 100)
        _ = try await rig.store.addFollow(Follow(target: .player(fideId: 1)), deviceId: device.id)
        #expect(try await rig.store.follows(deviceId: device.id).count == 100)
        await rig.close()
    }

    @Test("Registration limiter has a bounded window and resets without trusting client headers")
    func registrationThrottle() async {
        let clock = MutableClock(Fixture.now)
        let throttle = RegistrationThrottle(limit: 2, now: clock.read)
        #expect(await throttle.allow())
        #expect(await throttle.allow())
        #expect(await throttle.allow() == false)
        clock.advance(by: 60)
        #expect(await throttle.allow())
    }

    @Test("PGN corrections update pinned cards silently, including return to an earlier position")
    func correctionUpdatesActivity() async throws {
        let rig = try await TestRig.make()
        let device = try await rig.device(follows: [Follow(target: .game(roundId: "WCHr0002", gameId: "wchGam01"), alerts: FollowAlerts(game: [.move]))])
        let context = RoundContext.make()
        let original = GameSnapshot.make(ply: 10)
        _ = try await rig.pipeline.ingest(snapshot: original, context: context, now: rig.clock.read())
        try await rig.store.registerActivity(ActivityRegistration(roundId: original.roundId, gameId: original.gameId, activityToken: "activity"), deviceId: device.id)
        var corrected = original
        corrected.fen = MovePush.startingFEN
        rig.clock.advance(by: 1)
        #expect(try await rig.pipeline.ingest(snapshot: corrected, context: context, now: rig.clock.read()).isEmpty)
        rig.clock.advance(by: 1)
        #expect(try await rig.pipeline.ingest(snapshot: original, context: context, now: rig.clock.read()).isEmpty)
        var takeback = corrected
        takeback.ply = 8
        rig.clock.advance(by: 1)
        #expect(try await rig.pipeline.ingest(snapshot: takeback, context: context, now: rig.clock.read()).isEmpty)
        let delivered = await rig.delivery.record()
        #expect(delivered.count == 3)
        #expect(delivered.allSatisfy { $0.entry.category == .activityUpdate })
        let states = try delivered.map { try FollowJSON.activityDecoder.decode(LiveActivityState.self, from: Data($0.entry.payloadJSON.utf8)) }
        #expect(states.map(\.fen) == [corrected.fen, original.fen, takeback.fen])
        #expect(states.last?.ply == 8)
        await rig.close()
    }

    @Test("Restart and reconnect exclude outage time from long-think observation")
    func connectionRebaseline() async throws {
        let rig = try await TestRig.make()
        let context = RoundContext.make()
        _ = try await rig.device(follows: [Follow(target: .game(roundId: "WCHr0002", gameId: "wchGam01"), alerts: FollowAlerts(game: [.longThink], longThinkMinutes: 1))])
        _ = try await rig.pipeline.ingest(snapshot: .make(ply: 10), context: context, now: rig.clock.read())
        rig.clock.advance(by: 1)
        _ = try await rig.pipeline.ingest(snapshot: .make(ply: 11), context: context, now: rig.clock.read())
        #expect(try await rig.store.baseline(roundId: context.roundId, gameId: "wchGam01")?.longThinkEligible == true)
        rig.clock.advance(by: 3600)
        // A new pipeline simulates process restart while SQLite state remains.
        let restarted = FollowPipeline(store: rig.store, outbox: rig.outbox)
        _ = try await restarted.ingest(snapshot: .make(ply: 11), context: context, now: rig.clock.read(), continuouslyObserved: false)
        #expect(try await restarted.longThinkTick(snapshots: [.make(ply: 11)], context: context, now: rig.clock.read()).isEmpty)
        rig.clock.advance(by: 1)
        _ = try await restarted.ingest(snapshot: .make(ply: 12), context: context, now: rig.clock.read())
        rig.clock.advance(by: 61)
        #expect(try await restarted.longThinkTick(snapshots: [.make(ply: 12)], context: context, now: rig.clock.read()).count == 1)
        rig.clock.advance(by: 3600)
        // A reconnect in the same process also resets eligibility.
        _ = try await restarted.ingest(snapshot: .make(ply: 13), context: context, now: rig.clock.read(), continuouslyObserved: false)
        #expect(try await restarted.longThinkTick(snapshots: [.make(ply: 13)], context: context, now: rig.clock.read()).isEmpty)
        #expect(await rig.delivery.alerts().count == 1)
        await rig.close()
    }

    @Test("Watcher marks the first PGN of every connection as a silent baseline")
    func watcherConnectionBoundary() async throws {
        let rig = try await TestRig.make()
        let context = RoundContext(try Fixture.round("replay-round.json"))
        let blocks = PGNStreamSplitter.blocks(in: try Fixture.text("stream-round-22.pgn"))
        let initial = try #require(PGNSnapshot.snapshot(block: blocks[0], roundId: context.roundId, context: context))
        var earlier = initial
        earlier.ply -= 1
        _ = try await rig.pipeline.ingest(snapshot: earlier, context: context, now: rig.clock.read())
        _ = try await rig.pipeline.ingest(snapshot: initial, context: context, now: rig.clock.read())
        let watcher = RoundWatcher(roundId: context.roundId, source: FixtureSource(), pipeline: rig.pipeline, store: rig.store, configuration: rig.configuration, now: rig.clock.read)
        await watcher.handle(block: blocks[0])
        #expect(try await rig.store.baseline(roundId: context.roundId, gameId: initial.gameId)?.longThinkEligible == false)
        await watcher.handle(block: blocks[1])
        #expect(try await rig.store.baseline(roundId: context.roundId, gameId: initial.gameId)?.longThinkEligible == true)
        await watcher.beginConnection()
        await watcher.handle(block: blocks[1])
        #expect(try await rig.store.baseline(roundId: context.roundId, gameId: initial.gameId)?.longThinkEligible == false)
        await rig.close()
    }

    @Test("Delivery failures stop after the configured attempt limit")
    func retryBound() async throws {
        let rig = try await TestRig.make()
        let device = try await rig.device()
        let delivery = FailingDelivery()
        var config = rig.configuration
        config.maximumDeliveryAttempts = 3
        let worker = OutboxWorker(store: rig.store, delivery: delivery, configuration: config)
        _ = try await rig.store.enqueue(OutboxEntry(deviceId: device.id, dedupeKey: "x", collapseId: "g", category: .gameMove, payloadJSON: "{}"))
        // Kicks inside the retry delay do not count as attempts.
        for _ in 0..<8 { await worker.drain() }
        #expect(await delivery.count == 1)
        #expect(try await rig.store.entries(deviceId: device.id).first?.state == .queued)
        for _ in 0..<8 {
            rig.clock.advance(by: 1000)
            await worker.drain()
        }
        #expect(await delivery.count == 3)
        #expect(try await rig.store.entries(deviceId: device.id).first?.state == .failed)
        await rig.close()
    }

    @Test("A reconnect still reports the result that landed in the gap; only the think measurement resets")
    func reconnectReportsGapEvents() async throws {
        let rig = try await TestRig.make()
        let context = RoundContext.make()
        _ = try await rig.device(follows: [Follow(target: .game(roundId: "WCHr0002", gameId: "wchGam01"), alerts: FollowAlerts(game: [.end, .longThink], longThinkMinutes: 1))])
        _ = try await rig.pipeline.ingest(snapshot: .make(ply: 10), context: context, now: rig.clock.read())
        rig.clock.advance(by: 1)
        _ = try await rig.pipeline.ingest(snapshot: .make(ply: 11), context: context, now: rig.clock.read())
        rig.clock.advance(by: 5)
        let events = try await rig.pipeline.ingest(snapshot: .make(ply: 12, status: "1-0"), context: context, now: rig.clock.read(), continuouslyObserved: false)
        #expect(events.map(\.kind) == [.gameEnd])
        #expect(try await rig.store.baseline(roundId: context.roundId, gameId: "wchGam01")?.longThinkEligible == false)
        await rig.outbox.drain()
        #expect(await rig.delivery.alerts().count == 1)
        await rig.close()
    }
}

private actor SuspendedDelivery: PushDelivering {
    private var pending: CheckedContinuation<DeliveryOutcome, Never>?
    private var started: [CheckedContinuation<Void, Never>] = []
    private(set) var count = 0
    func deliver(_ push: OutboundPush) async -> DeliveryOutcome {
        count += 1
        return await withCheckedContinuation { continuation in
            pending = continuation
            for waiter in started { waiter.resume() }
            started.removeAll()
        }
    }
    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started.append($0) }
    }
    func finish() { pending?.resume(returning: .delivered); pending = nil }
}

private actor FailingDelivery: PushDelivering {
    private(set) var count = 0
    func deliver(_ push: OutboundPush) async -> DeliveryOutcome {
        count += 1
        return .retry("temporary")
    }
}
