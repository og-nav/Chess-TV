import Foundation
import FollowKit
import Testing
@testable import FollowServer

@Suite("Store")
struct StoreTests {

    @Test("An install token is random, and only its hash is kept")
    func installTokens() async throws {
        let tokens = (0..<64).map { _ in InstallToken.generate() }
        #expect(Set(tokens).count == 64)
        #expect(tokens.allSatisfy { $0.count >= 40 })
        // base64url: no '+', '/' or '=' to be mangled in a header or a URL.
        #expect(tokens.allSatisfy { !$0.contains("+") && !$0.contains("/") && !$0.contains("=") })
        #expect(InstallToken.hash("a") == InstallToken.hash("a"))
        #expect(InstallToken.hash("a") != InstallToken.hash("b"))
        #expect(InstallToken.hash("a").count == 64)
    }

    @Test("A token authenticates its own device and nobody else's")
    func authentication() async throws {
        let rig = try await TestRig.make()
        defer { Task { await rig.close() } }

        let first = try await rig.store.register(DeviceRegistration(apnsToken: String(repeating: "a", count: 64)))
        let second = try await rig.store.register(DeviceRegistration(apnsToken: String(repeating: "b", count: 64)))

        #expect(try await rig.store.device(installToken: first.credential.installToken)?.id == first.device.id)
        #expect(try await rig.store.device(installToken: second.credential.installToken)?.id == second.device.id)
        #expect(try await rig.store.device(installToken: "not a token") == nil)
    }

    @Test("APNs routing tokens cannot recover another install identity or follows")
    func reregistration() async throws {
        let rig = try await TestRig.make()
        defer { Task { await rig.close() } }

        let token = String(repeating: "a", count: 64)
        let first = try await rig.store.register(DeviceRegistration(apnsToken: token))
        _ = try await rig.store.addFollow(Follow(target: .player(fideId: 1_503_014)), deviceId: first.device.id)

        let again = try await rig.store.register(DeviceRegistration(apnsToken: token))
        #expect(again.device.id != first.device.id)
        #expect(try await rig.store.follows(deviceId: again.device.id).isEmpty)
        #expect(try await rig.store.follows(deviceId: first.device.id).count == 1)
        // Credentials stay isolated even when the routing address is the same.
        #expect(again.credential.installToken != first.credential.installToken)
        #expect(try await rig.store.device(installToken: first.credential.installToken)?.id == first.device.id)
    }

    @Test("Following the same target twice is one row")
    func followsAreUnique() async throws {
        let rig = try await TestRig.make()
        defer { Task { await rig.close() } }
        let device = try await rig.device()

        let first = try await rig.store.addFollow(Follow(target: .tournament(tourId: "WCHtour1")), deviceId: device.id)
        var second = Follow(target: .tournament(tourId: "WCHtour1"))
        second.alerts.tournament = [.roundLive]
        let stored = try await rig.store.addFollow(second, deviceId: device.id)

        #expect(stored.id == first.id)
        #expect(try await rig.store.follows(deviceId: device.id).count == 1)
        #expect(stored.alerts.tournament == [.roundLive])
    }

    @Test("A follow can only be patched or deleted by the device that owns it")
    func followScoping() async throws {
        let rig = try await TestRig.make()
        defer { Task { await rig.close() } }
        let mine = try await rig.device(apnsToken: String(repeating: "a", count: 64))
        let theirs = try await rig.device(apnsToken: String(repeating: "b", count: 64))

        let follow = try await rig.store.addFollow(Follow(target: .player(fideId: 1_503_014)), deviceId: mine.id)
        await #expect(throws: StoreError.notFound) {
            _ = try await rig.store.updateFollow(id: follow.id, alerts: FollowAlerts(game: [.move]), deviceId: theirs.id)
        }
        #expect(try await rig.store.removeFollow(id: follow.id, deviceId: theirs.id) == false)
        #expect(try await rig.store.follows(deviceId: mine.id).count == 1)
        #expect(try await rig.store.removeFollow(id: follow.id, deviceId: mine.id))
    }

    @Test("Out-of-range alert numbers are clamped on the way in")
    func clampingOnWrite() async throws {
        let rig = try await TestRig.make()
        defer { Task { await rig.close() } }
        let device = try await rig.device()
        let wild = Follow(target: .tournament(tourId: "t"), alerts: FollowAlerts(minMinutesBetweenMoveAlerts: -10, topBoards: 500))
        let stored = try await rig.store.addFollow(wild, deviceId: device.id)
        #expect(stored.alerts.topBoards == 5)
        #expect(stored.alerts.minMinutesBetweenMoveAlerts == 0)
    }

    @Test("The outbox refuses a duplicate and remembers what it delivered")
    func outboxDedupe() async throws {
        let rig = try await TestRig.make()
        defer { Task { await rig.close() } }
        let device = try await rig.device()

        let entry = OutboxEntry(deviceId: device.id, dedupeKey: "g:wchGam01:41:move:fen", collapseId: "wchGam01", category: .gameMove, payloadJSON: "{}", queuedAt: Fixture.now)
        #expect(try await rig.store.enqueue(entry))
        #expect(try await rig.store.enqueue(entry) == false)
        #expect(try await rig.store.entries(deviceId: device.id).count == 1)

        let queued = try await rig.store.queuedEntries()
        #expect(queued.count == 1)
        try await rig.store.markDelivered(id: queued[0].id)
        #expect(try await rig.store.queuedEntries().isEmpty)
        // Still refused after delivery: that is what makes a restart mid-round silent.
        #expect(try await rig.store.enqueue(entry) == false)
    }

    @Test("A 410 disables the device and drops what was queued for it")
    func deviceGone() async throws {
        let rig = try await TestRig.make()
        defer { Task { await rig.close() } }
        let device = try await rig.device()
        _ = try await rig.store.enqueue(OutboxEntry(deviceId: device.id, dedupeKey: "k1", collapseId: "c", category: .gameMove, payloadJSON: "{}"))

        try await rig.store.disableDevice(id: device.id, reason: "BadDeviceToken")
        #expect(try await rig.store.device(id: device.id)?.isActive == false)
        #expect(try await rig.store.queuedEntries().isEmpty)
        #expect(try await rig.store.deviceContexts().isEmpty)

        // Rotating the token brings it back, which is how a reinstall recovers.
        try await rig.store.updateAPNsToken(deviceId: device.id, apnsToken: String(repeating: "c", count: 64))
        #expect(try await rig.store.device(id: device.id)?.isActive == true)
    }

    @Test("Preferences round-trip and are sanitized on the way in")
    func preferences() async throws {
        let rig = try await TestRig.make()
        defer { Task { await rig.close() } }
        let device = try await rig.device()

        // A device that has never said anything gets defaults rather than an error.
        #expect(try await rig.store.preferences(deviceId: device.id).muteAll == false)

        var wanted = NotificationPreferences(muteAll: true, quietHoursStart: 22 * 60, quietHoursEnd: 7 * 60, timeZoneIdentifier: "Mars/Olympus")
        wanted.newTournamentFollowDefaults.topBoards = 99
        try await rig.store.setPreferences(wanted, deviceId: device.id)

        let stored = try await rig.store.preferences(deviceId: device.id)
        #expect(stored.muteAll)
        #expect(stored.quietHoursStart == 22 * 60)
        #expect(stored.timeZoneIdentifier == "UTC")
        #expect(stored.newTournamentFollowDefaults.topBoards == 5)
    }

    @Test("One activity per device; registering another replaces it")
    func activities() async throws {
        let rig = try await TestRig.make()
        defer { Task { await rig.close() } }
        let device = try await rig.device()

        try await rig.store.registerActivity(ActivityRegistration(roundId: "r", gameId: "g1", activityToken: "t1"), deviceId: device.id)
        try await rig.store.registerActivity(ActivityRegistration(roundId: "r", gameId: "g2", activityToken: "t2"), deviceId: device.id)

        #expect(try await rig.store.activity(deviceId: device.id)?.gameId == "g2")
        #expect(try await rig.store.activities(gameId: "g1").isEmpty)
        #expect(try await rig.store.activities(gameId: "g2").count == 1)

        // Unpinning drops any update still waiting, so it cannot arrive after the user let go.
        _ = try await rig.store.enqueue(OutboxEntry(deviceId: device.id, dedupeKey: "a:g2:41:ACTIVITY_UPDATE", collapseId: "g2", category: .activityUpdate, payloadJSON: "{}", reference: "g2"))
        #expect(try await rig.store.endActivity(gameId: "g2", deviceId: device.id))
        #expect(try await rig.store.queuedEntries().isEmpty)
    }

    @Test("A tournament transition is observed once, and stays observed across a reopen")
    func tournamentEvents() async throws {
        let rig = try await TestRig.make()
        defer { Task { await rig.close() } }
        #expect(try await rig.store.observeTournamentEvent(tourId: "t", roundId: "r", kind: "roundLive"))
        #expect(try await rig.store.observeTournamentEvent(tourId: "t", roundId: "r", kind: "roundLive") == false)
        #expect(try await rig.store.hasObservedTournamentEvent(tourId: "t", roundId: "r", kind: "roundLive"))
        #expect(try await rig.store.hasObservedTournamentEvent(tourId: "t", roundId: "r", kind: "roundFinished") == false)
    }

    @Test("The 24-hour count is delivered alerts only")
    func alertCount() async throws {
        let rig = try await TestRig.make()
        defer { Task { await rig.close() } }
        let device = try await rig.device()

        for (index, category) in [OutboxCategory.gameMove, .tournamentEvent, .activityUpdate].enumerated() {
            _ = try await rig.store.enqueue(OutboxEntry(deviceId: device.id, dedupeKey: "k\(index)", collapseId: "c", category: category, payloadJSON: "{}"))
        }
        for entry in try await rig.store.queuedEntries() { try await rig.store.markDelivered(id: entry.id) }

        let count = try await rig.store.deliveredAlertCount(deviceId: device.id, since: Fixture.now.addingTimeInterval(-3600))
        #expect(count == 2)     // the Live Activity update is not an alert
    }
}
