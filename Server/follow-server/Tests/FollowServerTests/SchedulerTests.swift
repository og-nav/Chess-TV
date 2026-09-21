import Foundation
import FollowKit
import Testing
@testable import FollowServer

/// The tournament scheduler, over the broadcast snapshots: what the plan calls "a tournament
/// follow over the `broadcast-top.json` snapshot emits starting-soon once and only once across a
/// restart; a round going live emits one alert, not one per board".
@Suite("Tournament scheduling")
struct SchedulerTests {

    private func rig(tour: String = "wch-tour.json", now: Date = Fixture.now) async throws -> (TestRig, FixtureSource, WatchCoordinator) {
        let rig = try await TestRig.make(now: now)
        let source = FixtureSource(
            top: try Fixture.top("broadcast-top.json"),
            tours: [try Fixture.tour(tour)],
            rounds: [try Fixture.round("wch-round.json")]
        )
        var configuration = rig.configuration
        // Nothing in these tests should open a stream; the fixture source hands out none anyway.
        configuration.maximumWatchedRounds = 4
        let coordinator = WatchCoordinator(
            store: rig.store,
            source: source,
            pipeline: rig.pipeline,
            configuration: configuration,
            now: rig.clock.read
        )
        return (rig, source, coordinator)
    }

    @Test("A tournament follow gets starting-soon once, and not again after a restart")
    func startingSoonOnce() async throws {
        let (rig, _, coordinator) = try await self.rig()
        defer { Task { await coordinator.stopAll(); await rig.close() } }
        _ = try await rig.device(follows: [Follow(target: .tournament(tourId: "WCHtour1"), alerts: .tournamentDefaults)])

        try await coordinator.pollOnce()
        await rig.outbox.drain()
        var pushes = await rig.delivery.record()
        let soon = pushes.filter { $0.entry.dedupeKey.hasSuffix(":startingSoon") }
        #expect(soon.count == 1)
        #expect(soon[0].entry.title == "Round 3 starts in 10 minutes")
        #expect(soon[0].entry.dedupeKey == "t:WCHtour1:WCHr0003:startingSoon")

        // Polls again, and again after a "restart" — the outbox row is the memory, and it is in
        // the database, so neither produces a second push.
        try await coordinator.pollOnce()
        rig.clock.advance(by: 120)
        try await coordinator.pollOnce()
        await rig.outbox.drain()
        pushes = await rig.delivery.record()
        #expect(pushes.filter { $0.entry.dedupeKey.hasSuffix(":startingSoon") }.count == 1)
    }

    @Test("A round going live is one alert, not one per board")
    func roundLiveOnce() async throws {
        // Round 2 has not started yet in this snapshot, so the first poll baselines it as
        // upcoming and the second poll sees it actually go live.
        let (rig, source, coordinator) = try await self.rig(tour: "wch-tour-upcoming.json")
        defer { Task { await coordinator.stopAll(); await rig.close() } }
        _ = try await rig.device(follows: [Follow(target: .tournament(tourId: "WCHtour1"), alerts: .tournamentDefaults)])

        try await coordinator.pollOnce()
        await source.set(tour: try Fixture.tour("wch-tour.json"))
        rig.clock.advance(by: 700)
        try await coordinator.pollOnce()
        try await coordinator.pollOnce()
        await rig.outbox.drain()

        let live = await rig.delivery.record().filter { $0.entry.dedupeKey.hasSuffix(":roundLive") }
        #expect(live.count == 1)
        #expect(live[0].entry.title == "Round 2 is live")
        // Two boards in the fixture, one alert.
        #expect(live[0].entry.body == "2 boards · World Championship 2026")
    }

    @Test("A round whose every board has a result produces one summary with the results in it")
    func roundSummary() async throws {
        let (rig, source, coordinator) = try await self.rig(tour: "wch-tour-upcoming.json")
        defer { Task { await coordinator.stopAll(); await rig.close() } }
        _ = try await rig.device(follows: [Follow(target: .tournament(tourId: "WCHtour1"), alerts: .tournamentDefaults)])

        try await coordinator.pollOnce()
        await source.set(tour: try Fixture.tour("wch-tour.json"))
        rig.clock.advance(by: 700)
        try await coordinator.pollOnce()

        await source.set(round: try Fixture.round("wch-round-finished.json"))
        rig.clock.advance(by: 300)
        try await coordinator.pollOnce()
        await rig.outbox.drain()

        let summaries = await rig.delivery.record().filter { $0.entry.dedupeKey.hasSuffix(":roundFinished") }
        #expect(summaries.count == 1)
        #expect(summaries[0].entry.title == "Round 2 finished")
        #expect(summaries[0].entry.body.contains("Carlsen, Magnus 1–0 Nepomniachtchi, Ian"))
        #expect(summaries[0].entry.body.contains("½–½"))
    }

    @Test("The event is only finished when every round in the tour's list is")
    func tournamentFinished() async throws {
        let (rig, source, coordinator) = try await self.rig(tour: "wch-tour-upcoming.json")
        defer { Task { await coordinator.stopAll(); await rig.close() } }
        _ = try await rig.device(follows: [Follow(target: .tournament(tourId: "WCHtour1"), alerts: .tournamentDefaults)])

        // Rounds 2 and 3 are still to come, so the tour is not finished.
        try await coordinator.pollOnce()
        await rig.outbox.drain()
        #expect(await rig.delivery.record().allSatisfy { !$0.entry.dedupeKey.hasSuffix(":tournamentFinished") })

        await source.set(tour: try Fixture.tour("wch-tour-finished.json"))
        rig.clock.advance(by: 300)
        try await coordinator.pollOnce()
        await rig.outbox.drain()

        let finished = await rig.delivery.record().filter { $0.entry.dedupeKey.hasSuffix(":tournamentFinished") }
        #expect(finished.count == 1)
        #expect(finished[0].entry.title == "World Championship 2026 has finished")
    }

    @Test("Following an event that is already under way announces none of what was missed")
    func firstSightIsSilent() async throws {
        // Round 1 is over and round 2 is live at the moment the follow is created. Neither is
        // news; only round 3, which is still ahead, is.
        let (rig, _, coordinator) = try await self.rig()
        defer { Task { await coordinator.stopAll(); await rig.close() } }
        _ = try await rig.device(follows: [Follow(target: .tournament(tourId: "WCHtour1"), alerts: .tournamentDefaults)])

        try await coordinator.pollOnce()
        await rig.outbox.drain()
        let kinds = await rig.delivery.record().map(\.entry.dedupeKey)
        #expect(kinds == ["t:WCHtour1:WCHr0003:startingSoon"])
    }

    @Test("A device that follows a player, not the event, gets none of the event's alerts")
    func playerFollowIsNotATournamentFollow() async throws {
        let (rig, _, coordinator) = try await self.rig()
        defer { Task { await coordinator.stopAll(); await rig.close() } }
        _ = try await rig.device(follows: [Follow(target: .player(fideId: 1_503_014), alerts: .playerDefaults)])

        try await coordinator.pollOnce()
        await rig.outbox.drain()
        #expect(await rig.delivery.record().isEmpty)
    }

    @Test("A followed player is resolved to the round they are playing in")
    func playerResolution() async throws {
        let (rig, _, coordinator) = try await self.rig()
        defer { Task { await coordinator.stopAll(); await rig.close() } }
        _ = try await rig.device(follows: [Follow(target: .player(fideId: 1_503_014), alerts: .playerDefaults)])

        try await coordinator.pollOnce()
        // `broadcast-top.json` has the championship's round 2 active, and its round JSON has
        // Carlsen on board 1, so that is the round the server holds a stream for.
        #expect(await coordinator.watchedRoundIds == ["WCHr0002"])
    }

    @Test("A player nobody is playing today costs no connection")
    func unknownPlayer() async throws {
        let (rig, _, coordinator) = try await self.rig()
        defer { Task { await coordinator.stopAll(); await rig.close() } }
        _ = try await rig.device(follows: [Follow(target: .player(fideId: 999_999), alerts: .playerDefaults)])

        try await coordinator.pollOnce()
        #expect(await coordinator.watchedRoundIds.isEmpty)
    }

    @Test("A game follow is watched by name, without searching for it")
    func gameFollowWatchesItsRound() async throws {
        let (rig, source, coordinator) = try await self.rig()
        defer { Task { await coordinator.stopAll(); await rig.close() } }
        _ = try await rig.device(follows: [Follow(target: .game(roundId: "WCHr0002", gameId: "wchGam01"), alerts: .gameDefaults)])

        try await coordinator.pollOnce()
        #expect(await coordinator.watchedRoundIds == ["WCHr0002"])
        // No search was needed to work that out: the top listing is only read for player follows.
        // (The watcher itself reads the round JSON as soon as it starts, so counting round fetches
        // here would race it.)
        #expect(await source.topFetches == 0)
    }

    @Test("With nothing followed, nothing is watched")
    func noFollowsNoWatchers() async throws {
        let (rig, source, coordinator) = try await self.rig()
        defer { Task { await coordinator.stopAll(); await rig.close() } }
        try await coordinator.pollOnce()
        #expect(await coordinator.watchedRoundIds.isEmpty)
        #expect(await source.topFetches == 0)     // not even a request to Lichess
    }
}
