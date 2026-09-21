// A follow server that never touches the network.
//
// It keeps the same rules the real one does where the app can tell the difference: `add` mints
// its own id (so the local-id rewrite is exercised), `update` and `remove` answer `.notFound` for
// an id it has never seen, and `isOffline` makes every call throw `.unavailable` the way a flight
// does. The errors are FollowKit's own, not a private type, because `FollowStore` decides whether
// an edit is durable or refused by *which* error it is — a fake that threw one opaque error would
// test the wrong thing.
import Foundation
import FollowKit
@testable import ChessTVMobile

actor FakeFollowServer: FollowServerClient {

    /// What the server holds.
    var stored: [Follow] = []
    var storedPreferences: NotificationPreferences = .mobileDefault()
    var credential = DeviceCredential(deviceId: "device-1", installToken: "token-1")

    /// Every call made, in order, for asserting that an offline burst collapsed.
    private(set) var calls: [String] = []
    /// While true every call throws `.unavailable`: transient, so nothing may be discarded.
    var isOffline = false
    /// Ids handed out by `add`.
    private var nextID = 1
    /// Run inside a call, before it answers, so a test can make a local edit while this one is
    /// still on the wire. That suspension is where the races live.
    private var hookName: String?
    private var duringCall: (@Sendable (String) async -> Void)?

    init(stored: [Follow] = [], preferences: NotificationPreferences = .mobileDefault()) {
        self.stored = stored
        self.storedPreferences = preferences
    }

    func setOffline(_ offline: Bool) { isOffline = offline }

    /// Installs the hook and clears it, so it fires exactly once — a hook that re-entered the
    /// store on every call would never terminate.
    func onceDuringCall(named name: String? = nil, _ body: @escaping @Sendable (String) async -> Void) {
        hookName = name
        duringCall = body
    }

    func callCount(_ name: String) -> Int { calls.count { $0 == name } }

    private func record(_ name: String) async throws {
        calls.append(name)
        if let hook = duringCall, hookName == nil || hookName == name {
            duringCall = nil
            await hook(name)
        }
        if isOffline { throw FollowServerError.unavailable("offline") }
    }

    // MARK: - FollowServerClient

    func register(_ device: DeviceRegistration) async throws -> DeviceCredential {
        try await record("register")
        return credential
    }

    func updateToken(_ apnsToken: String) async throws {
        try await record("updateToken")
    }

    func follows() async throws -> [Follow] {
        try await record("follows")
        return stored
    }

    func add(_ follow: Follow) async throws -> Follow {
        try await record("add")
        let created = FollowFactory.replacingID(follow, with: "server-\(nextID)")
        nextID += 1
        stored.append(created)
        return created
    }

    func update(_ follow: Follow) async throws -> Follow {
        try await record("update")
        guard let index = stored.firstIndex(where: { $0.id == follow.id }) else {
            throw FollowServerError.notFound
        }
        stored[index] = follow
        return follow
    }

    func remove(id: String) async throws {
        try await record("remove")
        guard stored.contains(where: { $0.id == id }) else { throw FollowServerError.notFound }
        stored.removeAll { $0.id == id }
    }

    func preferences() async throws -> NotificationPreferences {
        try await record("preferences")
        return storedPreferences
    }

    func setPreferences(_ preferences: NotificationPreferences) async throws {
        try await record("setPreferences")
        storedPreferences = preferences
    }

    func registerActivity(_ activity: ActivityRegistration) async throws {
        try await record("registerActivity")
    }

    func endActivity(gameId: String) async throws {
        try await record("endActivity")
    }
}
