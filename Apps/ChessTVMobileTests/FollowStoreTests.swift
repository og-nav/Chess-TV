import Testing
import Foundation
import FollowKit
@testable import ChessTVMobile

@Suite("Follows are local first and reconcile when the server answers")
@MainActor
struct FollowStoreTests {

    private func store(
        server: FakeFollowServer? = nil,
        storage: InMemoryFollowStore = InMemoryFollowStore()
    ) -> (FollowStore, InMemoryFollowStore) {
        (FollowStore(storage: storage, client: server), storage)
    }

    // MARK: - Offline

    @Test("With no server at all, a follow is kept and the app says so rather than pretending")
    func noServerIsHonest() {
        let (follows, storage) = store()
        follows.add(.player(fideId: 1_503_014))

        #expect(follows.follows.count == 1)
        #expect(follows.state == .noServer)
        #expect(storage.load().follows.count == 1)
    }

    @Test("An edit made offline survives a relaunch and reaches the server afterwards")
    func offlineEditIsDurable() async throws {
        let server = FakeFollowServer()
        await server.setOffline(true)
        let storage = InMemoryFollowStore()

        let (first, _) = store(server: server, storage: storage)
        first.add(.tournament(tourId: "tata-steel-2027"))
        await first.reconcileAndWait()
        #expect(first.pendingCount == 1)

        // A relaunch: a brand new store over the same file.
        let (second, _) = store(server: server, storage: storage)
        #expect(second.follows.count == 1)
        #expect(second.pendingCount == 1)

        await server.setOffline(false)
        await second.reconcileAndWait()

        #expect(second.pendingCount == 0)
        let stored = await server.stored
        #expect(stored.count == 1)
        #expect(stored[0].target == .tournament(tourId: "tata-steel-2027"))
    }

    @Test("A follow added and removed while offline never reaches the server")
    func offlineAddAndRemoveCancel() async throws {
        let server = FakeFollowServer()
        await server.setOffline(true)
        let (follows, _) = store(server: server)

        let follow = follows.add(.game(roundId: "r1", gameId: "g1"))
        follows.remove(id: follow.id)
        await server.setOffline(false)
        await follows.reconcileAndWait()

        let adds = await server.callCount("add")
        let removes = await server.callCount("remove")
        #expect(adds == 0)
        #expect(removes == 0)
        #expect(follows.follows.isEmpty)
    }

    // MARK: - Ids

    @Test("An open follow detail survives server ID replacement and edits the current follow")
    func detailTargetSurvivesRegistration() async throws {
        let server = FakeFollowServer()
        let (follows, _) = store(server: server)
        let created = follows.add(.tournament(tourId: "olympiad"))
        let route = MobileRoute.followDetail(target: created.target)
        await follows.reconcileAndWait()

        guard case .followDetail(let target) = route else {
            Issue.record("Expected a follow detail route")
            return
        }
        let current = try #require(follows.follow(for: target))
        #expect(current.id != created.id)
        var alerts = current.alerts
        alerts.topBoards = 3
        follows.setAlerts(alerts, for: current.id)
        await follows.reconcileAndWait()
        #expect(follows.follow(for: target)?.alerts.topBoards == 3)
        #expect(await server.stored.first?.alerts.topBoards == 3)

        follows.remove(target)
        await follows.reconcileAndWait()
        #expect(follows.follow(for: target) == nil)
        #expect(await server.stored.isEmpty)
    }

    @Test("The server's id replaces the local one, and later edits address the server's follow")
    func localIDIsRewritten() async throws {
        let server = FakeFollowServer()
        await server.setOffline(true)
        let (follows, _) = store(server: server)

        let created = follows.add(.player(fideId: 1_503_014))
        #expect(FollowFactory.isLocal(created.id))

        var alerts = created.alerts
        alerts.game.insert(.move)
        follows.setAlerts(alerts, for: created.id)

        await server.setOffline(false)
        await follows.reconcileAndWait()

        let stored = await server.stored
        #expect(stored.count == 1)
        #expect(stored[0].id.hasPrefix("server-"))
        #expect(stored[0].alerts.game.contains(.move))
        #expect(follows.follows.first?.id == stored[0].id)
        // The add carried the switches, so no separate PATCH was needed.
        let updates = await server.callCount("update")
        #expect(updates == 0)
    }

    // MARK: - Defaults

    @Test("A new follow inherits the Settings defaults for its kind")
    func newFollowInheritsDefaults() {
        let (follows, _) = store()
        var preferences = NotificationPreferences.mobileDefault()
        var tournamentDefaults = FollowAlerts.tournamentDefaults
        tournamentDefaults.topBoards = 3
        tournamentDefaults.startingSoonMinutes = 30
        preferences.setDefaults(tournamentDefaults, for: .tournament)
        follows.setPreferences(preferences)

        let tournament = follows.add(.tournament(tourId: "wcc-2026"))
        let player = follows.add(.player(fideId: 1_503_014))

        #expect(tournament.alerts.topBoards == 3)
        #expect(tournament.alerts.startingSoonMinutes == 30)
        #expect(player.alerts == .playerDefaults)
    }

    @Test("Changing a default and applying it rewrites the existing follows of that kind only")
    func applyingDefaultsRewritesExisting() async throws {
        let server = FakeFollowServer()
        let (follows, _) = store(server: server)

        let tournament = follows.add(.tournament(tourId: "wcc-2026"))
        let player = follows.add(.player(fideId: 1_503_014))
        await follows.reconcileAndWait()

        var newDefaults = FollowAlerts.tournamentDefaults
        newDefaults.tournament.insert(.topBoardMoves)
        newDefaults.minMinutesBetweenMoveAlerts = 5

        let affected = follows.countAffectedByDefaults(newDefaults, kind: .tournament)
        #expect(affected == 1)

        let changed = follows.applyDefaults(newDefaults, toExisting: .tournament)
        #expect(changed == 1)

        let rewritten = follows.follows.first { $0.target == tournament.target }
        #expect(rewritten?.alerts.tournament.contains(.topBoardMoves) == true)
        #expect(rewritten?.alerts.minMinutesBetweenMoveAlerts == 5)

        // The player follow is untouched: the defaults are per kind.
        let untouched = follows.follows.first { $0.target == player.target }
        #expect(untouched?.alerts == .playerDefaults)
    }

    // MARK: - Reconciliation

    @Test("After the queue drains, the server's list is the one kept")
    func serverListWinsAfterDrain() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let remote = Follow(
            id: "server-99",
            target: .player(fideId: 1_111_111),
            alerts: .playerDefaults,
            createdAt: now
        )
        let server = FakeFollowServer(stored: [remote])
        let storage = InMemoryFollowStore(
            FollowSnapshot(follows: [
                Follow(id: "server-50", target: .player(fideId: 2_222_222), alerts: .playerDefaults, createdAt: now)
            ])
        )
        let (follows, _) = store(server: server, storage: storage)

        // Before syncing, the phone shows what it had.
        #expect(follows.follows.map(\.id) == ["server-50"])

        await follows.reconcileAndWait()

        // A follow the server no longer has is gone: it was deleted on another device.
        #expect(follows.follows.map(\.id) == ["server-99"])
        if case .synced = follows.state {} else { Issue.record("expected a synced state, got \(follows.state)") }
    }

    @Test("Preferences come back from the server and are stored for the next launch")
    func preferencesReconcile() async throws {
        var remote = NotificationPreferences.mobileDefault()
        remote.muteAll = true
        remote.quietHoursStart = 22 * 60
        remote.quietHoursEnd = 7 * 60
        let server = FakeFollowServer(preferences: remote)
        let storage = InMemoryFollowStore()
        let (follows, _) = store(server: server, storage: storage)

        await follows.reconcileAndWait()

        #expect(follows.preferences.muteAll)
        #expect(storage.load().preferences.quietHoursStart == 22 * 60)
    }

    @Test("An edit the server actually refuses is retired visibly, and the one behind it lands")
    func refusedEditIsReportedNotSilentlyDropped() async throws {
        // A follow this phone believes in and the server has never heard of — what a delete on
        // another device leaves behind. Every PATCH for it is a 404, forever.
        let ghost = Follow(
            id: "server-ghost",
            target: .player(fideId: 7),
            alerts: .playerDefaults,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let server = FakeFollowServer()
        let (follows, _) = store(server: server, storage: InMemoryFollowStore(FollowSnapshot(follows: [ghost])))

        var alerts = ghost.alerts
        alerts.game.insert(.move)
        follows.setAlerts(alerts, for: ghost.id)
        follows.add(.player(fideId: 1_503_014))
        #expect(follows.pendingCount == 2)

        await follows.reconcileAndWait()

        #expect(follows.pendingCount == 0)
        // Refused, not forgotten: the user is told the switch never reached the server.
        #expect(follows.failedEdits.count == 1)
        #expect(follows.failedEdits[0].summary == "alerts")
        let stored = await server.stored
        #expect(stored.contains { $0.target == .player(fideId: 1_503_014) })

        follows.dismissFailures()
        #expect(follows.failedEdits.isEmpty)
    }

    // MARK: - Durability under repeated transient failure

    @Test("A week offline never costs an edit, however many times the send fails")
    func transientFailuresNeverDiscardAnEdit() async throws {
        let server = FakeFollowServer()
        await server.setOffline(true)
        let storage = InMemoryFollowStore()
        let (follows, _) = store(server: server, storage: storage)

        follows.add(.tournament(tourId: "candidates-2028"))
        var preferences = follows.preferences
        preferences.muteAll = true
        follows.setPreferences(preferences)

        // Far more attempts than any retry budget would have allowed.
        for _ in 0..<20 { await follows.reconcileAndWait() }

        #expect(follows.pendingCount == 2)
        #expect(follows.failedEdits.isEmpty)
        #expect(storage.load().pending.count == 2)

        await server.setOffline(false)
        await follows.reconcileAndWait()

        #expect(follows.pendingCount == 0)
        let stored = await server.stored
        #expect(stored.count == 1)
        let remotePreferences = await server.storedPreferences
        #expect(remotePreferences.muteAll)
    }

    @Test("A DELETE the server answers 404 is the outcome we wanted, not a refusal")
    func deleteOfSomethingAlreadyGoneCounts() async throws {
        let ghost = Follow(
            id: "server-ghost",
            target: .player(fideId: 7),
            alerts: .playerDefaults,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let server = FakeFollowServer()
        let (follows, _) = store(server: server, storage: InMemoryFollowStore(FollowSnapshot(follows: [ghost])))

        follows.remove(id: ghost.id)
        await follows.reconcileAndWait()

        #expect(follows.pendingCount == 0)
        #expect(follows.failedEdits.isEmpty)
        #expect(follows.follows.isEmpty)
    }

    // MARK: - Races

    @Test("A follow made while the server's list is in flight is not erased by the answer")
    func editDuringReconcileSurvivesTheRemoteSnapshot() async throws {
        let server = FakeFollowServer()
        let (follows, _) = store(server: server)

        // The moment `GET /v1/follows` is asked, the user follows something. The answer already
        // on its way describes a world without it; adopting it would throw the follow away.
        await server.onceDuringCall { name in
            guard name == "follows" else { return }
            await MainActor.run { follows.add(.player(fideId: 1_503_014)) }
        }

        await follows.reconcileAndWait()

        #expect(follows.follows.count == 1)
        #expect(follows.follows[0].target == .player(fideId: 1_503_014))
        let stored = await server.stored
        #expect(stored.count == 1)
        #expect(follows.pendingCount == 0)
    }

    @Test("Unfollowing while the add is on the wire still deletes it from the server")
    func removeDuringInFlightAddIsNotCompactedAway() async throws {
        let server = FakeFollowServer()
        let (follows, _) = store(server: server)

        let follow = follows.add(.game(roundId: "r1", gameId: "g1"))
        // The add is already past the point of no return when the user changes their mind. The
        // queue cannot cancel it, so the delete has to be sent — against the id the server mints.
        await server.onceDuringCall { name in
            guard name == "add" else { return }
            await MainActor.run { follows.remove(id: follow.id) }
        }

        await follows.reconcileAndWait()

        #expect(follows.follows.isEmpty)
        #expect(follows.pendingCount == 0)
        let stored = await server.stored
        #expect(stored.isEmpty)
        #expect(await server.callCount("remove") == 1)
    }

    @Test("Pointing the app at another server re-queues the local list instead of being wiped")
    func serverIdentityChangeReuploadsFollows() async throws {
        let oldServer = FakeFollowServer()
        let storage = InMemoryFollowStore()
        let (follows, _) = store(server: oldServer, storage: storage)

        follows.add(.player(fideId: 1_503_014))
        follows.add(.tournament(tourId: "tata-steel-2027"))
        await follows.reconcileAndWait()
        #expect(follows.pendingCount == 0)

        // A different host, which has never heard of this phone and holds nothing.
        let newServer = FakeFollowServer()
        follows.serverIdentityChanged()
        follows.setClient(newServer)

        #expect(follows.follows.count == 2)
        await follows.reconcileAndWait()

        #expect(follows.follows.count == 2)
        let stored = await newServer.stored
        #expect(stored.count == 2)
        #expect(follows.pendingCount == 0)
        // Nothing local kept an id the old host minted.
        #expect(follows.follows.allSatisfy { $0.id.hasPrefix("server-") })
    }

    @Test("A sync started against the old host cannot write its answer after the host changes")
    func switchingHostsInvalidatesTheSyncInFlight() async throws {
        let oldServer = FakeFollowServer(stored: [
            Follow(
                id: "old-1",
                target: .player(fideId: 999),
                alerts: .playerDefaults,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ])
        let newServer = FakeFollowServer()
        let (follows, _) = store(server: oldServer)
        follows.add(.tournament(tourId: "mine"))

        // Half way through talking to the old host, Settings points the app somewhere else.
        await oldServer.onceDuringCall(named: "follows") { name in
            guard name == "follows" else { return }
            await MainActor.run {
                follows.serverIdentityChanged()
                follows.setClient(newServer)
            }
        }

        await follows.reconcileAndWait()
        await follows.reconcileAndWait()

        // The old host's follow never appears, and the local one is on the new host.
        #expect(!follows.follows.contains { $0.target == .player(fideId: 999) })
        #expect(follows.follows.contains { $0.target == .tournament(tourId: "mine") })
        let stored = await newServer.stored
        #expect(stored.contains { $0.target == .tournament(tourId: "mine") })
    }
}

@Suite("Edits and identity changes during writes")
@MainActor
struct FollowWriteRaceTests {
    @Test("A late add response cannot rewrite a replacement server's local identifiers")
    func identityChangesDuringAdd() async throws {
        let old = FakeFollowServer()
        let new = FakeFollowServer()
        let storage = InMemoryFollowStore()
        let follows = FollowStore(storage: storage, client: old)
        await old.onceDuringCall(named: "add") { _ in
            await MainActor.run {
                follows.serverIdentityChanged()
                follows.setClient(new)
            }
        }
        follows.add(.player(fideId: 1234))
        await follows.reconcileAndWait()
        await follows.reconcileAndWait()
        #expect(follows.follows.count == 1)
        #expect(follows.pendingCount == 0)
        #expect(await new.stored.count == 1)
    }

    @Test("Replacing preferences during their send preserves the second unsent edit")
    func preferencesDuringWrite() async throws {
        let server = FakeFollowServer()
        let follows = FollowStore(storage: InMemoryFollowStore(), client: server)
        await server.onceDuringCall(named: "setPreferences") { _ in
            await MainActor.run {
                var latest = follows.preferences
                latest.muteAll = false
                latest.quietHoursStart = 120
                follows.setPreferences(latest)
            }
        }
        var first = follows.preferences
        first.muteAll = true
        follows.setPreferences(first)
        await follows.reconcileAndWait()
        #expect(await server.storedPreferences.muteAll == false)
        #expect(await server.storedPreferences.quietHoursStart == 120)
        #expect(follows.pendingCount == 0)
    }
}
