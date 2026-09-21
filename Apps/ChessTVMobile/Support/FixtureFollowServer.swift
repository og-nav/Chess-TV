// The follow server in fixture mode: in memory, never offline, mints ids like the real one.
//
// Only reachable when the app was launched with `-uiFixtures` (see `FollowClientFactory`), and
// compiled to nothing in Release. It keeps the rules the app can observe: `add` replaces the
// local id, `update` and `remove` refuse an id they have never seen, and the health and alert
// count answer as a healthy server would.
#if DEBUG
import Foundation
import FollowKit

actor FixtureFollowServer: FollowServerClient {

    static let shared = FixtureFollowServer()

    private var stored: [Follow] = []
    private var storedPreferences = NotificationPreferences.mobileDefault()
    private var nextID = 1
    private var registrations = 0

    func register(_ device: DeviceRegistration) async throws -> DeviceCredential {
        registrations += 1
        return DeviceCredential(deviceId: "fixture-device-\(registrations)", installToken: "fixture-token-\(registrations)")
    }

    func updateToken(_ apnsToken: String) async throws {}

    func follows() async throws -> [Follow] { stored }

    func add(_ follow: Follow) async throws -> Follow {
        if let existing = stored.first(where: { $0.target == follow.target }) { return existing }
        let created = FollowFactory.replacingID(follow, with: "fixture-\(nextID)")
        nextID += 1
        stored.append(created)
        return created
    }

    func update(_ follow: Follow) async throws -> Follow {
        guard let index = stored.firstIndex(where: { $0.id == follow.id }) else { throw FollowServerError.notFound }
        stored[index] = follow
        return follow
    }

    func remove(id: String) async throws {
        guard stored.contains(where: { $0.id == id }) else { throw FollowServerError.notFound }
        stored.removeAll { $0.id == id }
    }

    func preferences() async throws -> NotificationPreferences { storedPreferences }

    func setPreferences(_ preferences: NotificationPreferences) async throws { storedPreferences = preferences }

    func registerActivity(_ activity: ActivityRegistration) async throws {}

    func endActivity(gameId: String) async throws {}

    func health() async throws -> ServerHealth {
        ServerHealth(ok: true, roundsWatched: 1, roundsScheduled: 3, lastLichessEventAt: Date())
    }

    func alertCount() async throws -> AlertCount? { AlertCount(last24h: 4) }

    func unregister(_ credential: DeviceCredential) async throws {}
}
#endif
