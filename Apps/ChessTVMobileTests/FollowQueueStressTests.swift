import Foundation
import Testing
import FollowKit
@testable import ChessTVMobile

@Suite("Adversarial offline follow reconciliation")
@MainActor
struct FollowQueueStressTests {
    @Test("Unfollow survives a lost add acknowledgement and a relaunch")
    func lostAddAcknowledgementThenUnfollow() async throws {
        let remote = AdversarialFollowServer()
        let disk = InMemoryFollowStore()
        var store = FollowStore(storage: disk, client: remote)
        await remote.loseNextAddResponse()
        let follow = store.add(.player(fideId: 1234))
        await store.reconcileAndWait()
        #expect(await remote.snapshot().count == 1)
        #expect(store.pendingCount == 1)
        store.setClient(nil)
        store.remove(id: follow.id)
        store = FollowStore(storage: disk, client: remote)
        await store.reconcileAndWait()
        #expect(store.follows.isEmpty)
        #expect(await remote.snapshot().isEmpty)
        #expect(store.pendingCount == 0)
    }

    @Test("Switch changes after a lost add reply remain a separate server update")
    func editAfterLostAcknowledgement() async throws {
        let remote = AdversarialFollowServer()
        await remote.keepAlertsOnIdempotentAdd()
        await remote.loseNextAddResponse()
        let store = FollowStore(storage: InMemoryFollowStore(), client: remote)
        let follow = store.add(.player(fideId: 1234))
        await store.reconcileAndWait()
        store.setClient(nil)
        var latest = follow.alerts
        latest.game.insert(.move)
        latest.minMinutesBetweenMoveAlerts = 15
        store.setAlerts(latest, for: follow.id)
        store.setClient(remote)
        await store.reconcileAndWait()
        #expect(await remote.intent() == [follow.target: latest])
        #expect(store.follow(for: follow.target)?.alerts == latest)
        #expect(store.pendingCount == 0)
    }

    @Test("Removing and readding an uncertain follow uses its new defaults exactly once")
    func removeAndReaddAfterLostAcknowledgement() async throws {
        let remote = AdversarialFollowServer()
        await remote.loseNextAddResponse()
        let disk = InMemoryFollowStore()
        var store = FollowStore(storage: disk, client: remote)
        let first = store.add(.player(fideId: 1234))
        await store.reconcileAndWait()
        store.setClient(nil)
        store.remove(id: first.id)
        var preferences = store.preferences
        var defaults = FollowAlerts.playerDefaults
        defaults.game = [.end]
        preferences.setDefaults(defaults, for: .player)
        store.setPreferences(preferences)
        let replacement = store.add(first.target)
        #expect(replacement.id != first.id)
        store = FollowStore(storage: disk, client: remote)
        await store.reconcileAndWait()
        #expect(await remote.intent() == [first.target: defaults])
        #expect(await remote.snapshot().count == 1)
        #expect(store.follows.count == 1)
        #expect(store.pendingCount == 0)
    }

    @Test("Old snapshots without a submission field keep failed adds uncertain")
    func legacyFailedAddSnapshot() throws {
        let follow = Follow(id: "local-legacy", target: .player(fideId: 1234), alerts: .playerDefaults, createdAt: .now)
        let edit = PendingEdit(operation: .add(follow), attempts: 1)
        let encoded = try FollowFileStore.encoder.encode(FollowSnapshot(follows: [follow], pending: [edit]))
        #expect(!String(decoding: encoded, as: UTF8.self).contains("mayHaveReachedServer"))
        let restored = try FollowFileStore.decoder.decode(FollowSnapshot.self, from: encoded)
        #expect(restored.pending.first?.mayHaveReachedServer == nil)
        let queue = PendingQueue.appending(PendingEdit(operation: .remove(followID: follow.id)), to: restored.pending)
        #expect(queue.count == 2)
        if case .add = queue.first?.operation {} else { Issue.record("uncertain add must precede delete") }
        if case .remove = queue.last?.operation {} else { Issue.record("delete must survive") }
    }

    @Test("Relaunch during an accepted POST keeps enough intent to unfollow it")
    func relaunchDuringCommittedAdd() async throws {
        let remote = AdversarialFollowServer()
        let disk = InMemoryFollowStore()
        let first = FollowStore(storage: disk, client: remote)
        let gate = StressGate()
        await remote.pauseNextAddResponse(using: gate)
        let follow = first.add(.player(fideId: 4321))
        let oldWork = Task { await first.reconcileAndWait() }
        await gate.waitUntilPaused()
        // The server committed; the app was suspended or killed before receiving the response.
        first.setClient(nil)
        let restored = try FollowFileStore.decoder.decode(FollowSnapshot.self, from: FollowFileStore.encoder.encode(disk.load()))
        let second = FollowStore(storage: InMemoryFollowStore(restored))
        second.remove(id: follow.id)
        await gate.release()
        await oldWork.value
        second.setClient(remote)
        await second.reconcileAndWait()
        #expect(second.follows.isEmpty)
        #expect(await remote.snapshot().isEmpty)
        #expect(second.pendingCount == 0)
    }

    @Test("Late reads from invalidated server generations never overwrite the active install")
    func delayedOldGenerationResponses() async throws {
        for generation in 0..<32 {
            let old = AdversarialFollowServer()
            let current = AdversarialFollowServer()
            _ = try await old.add(Follow(id: "old", target: .player(fideId: 999), alerts: .playerDefaults, createdAt: .now))
            let keep = Follow(id: "local-existing", target: .tournament(tourId: "keep-\(generation)"), alerts: .tournamentDefaults, createdAt: .now)
            let store = FollowStore(storage: InMemoryFollowStore(FollowSnapshot(follows: [keep])), client: old)
            let gate = StressGate()
            await old.pauseNextList(using: gate)
            let previousReconcile = Task { await store.reconcileAndWait() }
            await gate.waitUntilPaused()
            store.serverIdentityChanged()
            store.setClient(current)
            await store.reconcileAndWait()
            let active = store.follows
            await gate.release()
            await previousReconcile.value
            #expect(store.follows == active)
            #expect(store.follows.map(\.target) == [keep.target])
            #expect(store.pendingCount == 0)
            #expect(await old.listCallCount() == 1)
        }
    }

    @Test("Seeded edits survive offline stretches, identity remapping, and JSON relaunches", arguments: [UInt64(7), 19, 73, 2026])
    func seededConvergence(_ seed: UInt64) async throws {
        var random = StressRandom(seed: seed)
        let remote = AdversarialFollowServer()
        var disk = InMemoryFollowStore()
        var store = FollowStore(storage: disk)
        var intended: [FollowTarget: FollowAlerts] = [:]
        var preferences = store.preferences
        let targets: [FollowTarget] = (0..<12).map { index in
            switch index % 3 {
            case 0: .player(fideId: 1000 + index)
            case 1: .game(roundId: "round", gameId: "game\(index)")
            default: .tournament(tourId: "tour\(index)")
            }
        }

        for step in 0..<480 {
            let target = targets[random.next(targets.count)]
            switch random.next(5) {
            case 0, 1:
                let created = store.add(target)
                if intended[target] == nil { intended[target] = created.alerts }
            case 2:
                store.remove(target)
                intended.removeValue(forKey: target)
            case 3:
                if let current = store.follow(for: target) {
                    var alerts = current.alerts
                    if alerts.game.contains(.move) { alerts.game.remove(.move) } else { alerts.game.insert(.move) }
                    alerts.minMinutesBetweenMoveAlerts = [0, 1, 5, 15][random.next(4)]
                    store.setAlerts(alerts, for: current.id)
                    intended[target] = alerts.clamped()
                }
            default:
                preferences.muteAll.toggle()
                preferences.quietHoursStart = random.next(1440)
                store.setPreferences(preferences)
            }

            #expect(Dictionary(uniqueKeysWithValues: store.follows.map { ($0.target, $0.alerts) }) == intended)
            #expect(Set(store.pendingEditsForTesting.map(\.id)).count == store.pendingCount)
            if step % 17 == 0 {
                // Exercise the actual Codable format, including sub-second creation dates.
                let snapshot = try FollowFileStore.decoder.decode(FollowSnapshot.self, from: FollowFileStore.encoder.encode(disk.load()))
                disk = InMemoryFollowStore(snapshot)
                store = FollowStore(storage: disk)
            }
            if step % 41 == 40 {
                store.setClient(remote)
                await store.reconcileAndWait()
                #expect(store.failedEdits.isEmpty)
                #expect(store.pendingCount == 0)
                #expect(await remote.intent() == intended)
                #expect(await remote.preferences() == preferences)
                store.setClient(nil)
            }
        }
        store.setClient(remote)
        await store.reconcileAndWait()
        #expect(await remote.intent() == intended)
        #expect(store.pendingCount == 0)
        #expect(store.failedEdits.isEmpty)
    }
}

/// Models server target uniqueness and replacement of temporary IDs. Failure can happen AFTER
/// mutation, as when an HTTP response is lost; a transport-only offline stub cannot cover that.
private actor AdversarialFollowServer: FollowServerClient {
    private var records: [FollowTarget: Follow] = [:]
    private var settings = NotificationPreferences.mobileDefault()
    private var serial = 0
    private var preserveExistingAlerts = false
    func keepAlertsOnIdempotentAdd() { preserveExistingAlerts = true }
    private var loseAdd = false
    private var addResponseGate: StressGate?
    func pauseNextAddResponse(using gate: StressGate) { addResponseGate = gate }
    private var listGate: StressGate?
    private var listCalls = 0
    func pauseNextList(using gate: StressGate) { listGate = gate }
    func listCallCount() -> Int { listCalls }
    func loseNextAddResponse() { loseAdd = true }
    func snapshot() -> [Follow] { Array(records.values) }
    func intent() -> [FollowTarget: FollowAlerts] { records.mapValues(\.alerts) }
    func register(_ device: DeviceRegistration) async throws -> DeviceCredential { DeviceCredential(deviceId: "test", installToken: "test") }
    func updateToken(_ apnsToken: String) async throws {}
    func follows() async throws -> [Follow] {
        listCalls += 1
        let captured = snapshot()
        if let gate = listGate { listGate = nil; await gate.pause() }
        return captured
    }
    func add(_ follow: Follow) async throws -> Follow {
        var created: Follow
        if let existing = records[follow.target] {
            created = preserveExistingAlerts ? existing : FollowFactory.replacingAlerts(existing, with: follow.alerts)
        } else {
            serial += 1
            created = FollowFactory.replacingID(follow, with: "remote-\(serial)")
        }
        records[follow.target] = created
        if let gate = addResponseGate { addResponseGate = nil; await gate.pause() }
        if loseAdd { loseAdd = false; throw FollowServerError.unavailable("response lost after commit") }
        return created
    }
    func update(_ follow: Follow) async throws -> Follow {
        guard records[follow.target]?.id == follow.id else { throw FollowServerError.notFound }
        records[follow.target] = follow
        return follow
    }
    func remove(id: String) async throws {
        guard let target = records.first(where: { $0.value.id == id })?.key else { throw FollowServerError.notFound }
        records.removeValue(forKey: target)
    }
    func preferences() async -> NotificationPreferences { settings }
    func setPreferences(_ preferences: NotificationPreferences) async throws { settings = preferences }
    func registerActivity(_ activity: ActivityRegistration) async throws {}
    func endActivity(gameId: String) async throws {}
}

private struct StressRandom {
    var seed: UInt64
    mutating func next(_ upperBound: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int((seed >> 32) % UInt64(upperBound))
    }
}

/// A deterministic await boundary; no wall-clock sleeps or polling loops are required.
private actor StressGate {
    private var entered = false
    private var released = false
    private var suspension: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        entered = true
        observers.forEach { $0.resume() }
        observers.removeAll()
        guard !released else { return }
        await withCheckedContinuation { suspension = $0 }
    }
    func waitUntilPaused() async {
        guard !entered else { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() {
        released = true
        suspension?.resume()
        suspension = nil
    }
}

@Suite("Credential reads across identity invalidation")
struct CredentialReadStressTests {
    @Test("An already-started credential load cannot deliver an old-host token after scope changes")
    func invalidatedReadDoesNotEscape() async throws {
        let disk = PausingCredentialStore()
        let defaults = UserDefaults(suiteName: "ChessTV.CredentialStress.\(UUID())")!
        let scoped = ScopedCredentialStore(wrapping: disk, scope: "https://old.example", defaults: defaults)
        for generation in 0..<32 {
            let oldHost = "https://host-\(generation).example"
            scoped.setScope(oldHost)
            try await scoped.save(DeviceCredential(deviceId: "old-\(generation)", installToken: "old-test-token"))
            let oldClient = scoped.clientStore()
            let gate = StressGate()
            await disk.pauseNextLoad(using: gate)
            let oldRead = Task { try await oldClient.load() }
            await gate.waitUntilPaused()
            scoped.setScope("https://next-\(generation).example")
            try await scoped.save(DeviceCredential(deviceId: "new-\(generation)", installToken: "new-test-token"))
            await gate.release()
            #expect(try await oldRead.value == nil)
            #expect(try await oldClient.load() == nil)
            #expect(try await scoped.clientStore().load()?.deviceId == "new-\(generation)")
        }
    }
}

private actor PausingCredentialStore: FollowCredentialStore {
    private var value: DeviceCredential?
    private var gate: StressGate?
    func pauseNextLoad(using gate: StressGate) { self.gate = gate }
    func load() async throws -> DeviceCredential? {
        let captured = value
        if let current = gate { gate = nil; await current.pause() }
        return captured
    }
    func save(_ credential: DeviceCredential) throws { value = credential }
    func clear() throws { value = nil }
}
