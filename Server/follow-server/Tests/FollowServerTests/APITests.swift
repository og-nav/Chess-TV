import Foundation
import FollowKit
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
@testable import FollowServer

@Suite("HTTP API")
struct APITests {

    private func application(requireHTTPS: Bool = false) async throws -> (Application<some HTTPResponder<FollowRequestContext>>, FollowStore) {
        var configuration = ServerConfig()
        configuration.databasePath = ":memory:"
        configuration.requireHTTPS = requireHTTPS
        let store = try await FollowStore.open(path: ":memory:")
        let api = FollowAPI(store: store, configuration: configuration, health: {
            ServerHealth(ok: true, roundsWatched: 2, roundsScheduled: 3, lastLichessEventAt: Fixture.now)
        })
        return (Application(router: api.router()), store)
    }

    private func body(_ value: some Encodable) throws -> ByteBuffer {
        ByteBuffer(data: try FollowJSON.encoder.encode(value))
    }

    private func bearer(_ token: String) -> HTTPFields {
        [.authorization: "Bearer \(token)", .contentType: "application/json"]
    }

    private let registration = DeviceRegistration(platform: "ios", environment: "sandbox", apnsToken: String(repeating: "a", count: 64), appVersion: "1.0")

    @Test("Health needs no token and reports what the watcher is doing")
    func health() async throws {
        let (app, store) = try await application()
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/health", method: .get) { response in
                #expect(response.status == .ok)
                let health = try FollowJSON.decoder.decode(ServerHealth.self, from: Data(buffer: response.body))
                #expect(health.ok)
                #expect(health.roundsWatched == 2)
                #expect(health.roundsScheduled == 3)
            }
        }
        await store.close()
    }

    @Test("Registration mints a credential; a malformed one is refused")
    func registering() async throws {
        let (app, store) = try await application()
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/devices", method: .post, headers: [.contentType: "application/json"], body: try body(registration)) { response in
                #expect(response.status == .created)
                let credential = try FollowJSON.decoder.decode(DeviceCredential.self, from: Data(buffer: response.body))
                #expect(credential.deviceId.hasPrefix("d_"))
                #expect(credential.installToken.count >= 40)
            }
            let bad = DeviceRegistration(platform: "android", environment: "sandbox", apnsToken: "nope", appVersion: "1.0")
            try await client.execute(uri: "/v1/devices", method: .post, headers: [.contentType: "application/json"], body: try body(bad)) { response in
                #expect(response.status == .unprocessableContent)
            }
        }
        await store.close()
    }

    @Test("Everything else needs a token, and a wrong one is a 401")
    func authentication() async throws {
        let (app, store) = try await application()
        try await app.test(.router) { client in
            for (uri, method) in [("/v1/follows", HTTPRequest.Method.get), ("/v1/preferences", .get), ("/v1/activities", .post)] {
                try await client.execute(uri: uri, method: method) { response in
                    #expect(response.status == .unauthorized, "\(uri) should need a token")
                }
            }
            try await client.execute(uri: "/v1/follows", method: .get, headers: bearer("not-a-real-token")) { response in
                #expect(response.status == .unauthorized)
            }
        }
        await store.close()
    }

    @Test("An install can delete itself, taking its follows; its token then stops working")
    func unregister() async throws {
        let (app, store) = try await application()
        let mine = try await store.register(registration).credential
        let theirs = try await store.register(DeviceRegistration(apnsToken: String(repeating: "b", count: 64))).credential
        _ = try await store.addFollow(Follow(target: .player(fideId: 1_503_014), alerts: .playerDefaults), deviceId: mine.deviceId)
        _ = try await store.addFollow(Follow(target: .player(fideId: 1_503_014), alerts: .playerDefaults), deviceId: theirs.deviceId)

        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/devices/me", method: .delete) { response in
                #expect(response.status == .unauthorized)
            }
            try await client.execute(uri: "/v1/devices/me", method: .delete, headers: bearer(mine.installToken)) { response in
                #expect(response.status == .noContent)
            }
            try await client.execute(uri: "/v1/follows", method: .get, headers: bearer(mine.installToken)) { response in
                #expect(response.status == .unauthorized)
            }
        }
        #expect(try await store.device(id: mine.deviceId) == nil)
        #expect(try await store.allFollows().map(\.deviceId) == [theirs.deviceId])
        await store.close()
    }

    @Test("Follows: create, list, patch, delete — and one device cannot touch another's")
    func follows() async throws {
        let (app, store) = try await application()
        let mine = try await store.register(registration).credential
        let theirs = try await store.register(DeviceRegistration(apnsToken: String(repeating: "b", count: 64))).credential

        try await app.test(.router) { client in
            var created = Follow(id: "client-made-this-up", target: .player(fideId: 1_503_014), alerts: .playerDefaults)
            try await client.execute(uri: "/v1/follows", method: .post, headers: bearer(mine.installToken), body: try body(created)) { response in
                #expect(response.status == .created)
                created = try FollowJSON.decoder.decode(Follow.self, from: Data(buffer: response.body))
                // The plan says the id is ignored on create.
                #expect(created.id != "client-made-this-up")
                #expect(created.target == .player(fideId: 1_503_014))
            }

            try await client.execute(uri: "/v1/follows", method: .get, headers: bearer(mine.installToken)) { response in
                let follows = try FollowJSON.decoder.decode([Follow].self, from: Data(buffer: response.body))
                #expect(follows.map(\.id) == [created.id])
            }
            try await client.execute(uri: "/v1/follows", method: .get, headers: bearer(theirs.installToken)) { response in
                let theirFollows = try FollowJSON.decoder.decode([Follow].self, from: Data(buffer: response.body))
                #expect(theirFollows.isEmpty)
            }

            let alerts = FollowAlerts(game: [.start, .move, .end], minMinutesBetweenMoveAlerts: 5)
            try await client.execute(uri: "/v1/follows/\(created.id)", method: .patch, headers: bearer(mine.installToken), body: try body(alerts)) { response in
                #expect(response.status == .ok)
                let updated = try FollowJSON.decoder.decode(Follow.self, from: Data(buffer: response.body))
                #expect(updated.alerts.game == [.start, .move, .end])
                #expect(updated.alerts.minMinutesBetweenMoveAlerts == 5)
            }
            // Another device's token must not be able to patch or delete it.
            try await client.execute(uri: "/v1/follows/\(created.id)", method: .patch, headers: bearer(theirs.installToken), body: try body(alerts)) { response in
                #expect(response.status == .notFound)
            }
            try await client.execute(uri: "/v1/follows/\(created.id)", method: .delete, headers: bearer(theirs.installToken)) { response in
                #expect(response.status == .notFound)
            }
            try await client.execute(uri: "/v1/follows/\(created.id)", method: .delete, headers: bearer(mine.installToken)) { response in
                #expect(response.status == .noContent)
            }
            try await client.execute(uri: "/v1/follows/\(created.id)", method: .delete, headers: bearer(mine.installToken)) { response in
                #expect(response.status == .notFound)
            }
        }
        await store.close()
    }

    @Test("Malformed identifiers and follow quota return actionable client errors")
    func targetValidationAndQuota() async throws {
        let (app, store) = try await application()
        let credential = try await store.register(registration).credential
        for fideId in 1...100 { _ = try await store.addFollow(Follow(target: .player(fideId: fideId)), deviceId: credential.deviceId) }
        try await app.test(.router) { client in
            for target in [FollowTarget.player(fideId: 101), .player(fideId: -1), .game(roundId: "", gameId: "g"), .tournament(tourId: "../bad")] {
                try await client.execute(uri: "/v1/follows", method: .post, headers: bearer(credential.installToken), body: try body(Follow(target: target))) { response in
                    #expect(response.status == .unprocessableContent)
                }
            }
            try await client.execute(uri: "/v1/follows", method: .post, headers: bearer(credential.installToken), body: try body(Follow(target: .player(fideId: 1)))) { response in
                #expect(response.status == .created)
            }
        }
        await store.close()
    }

    @Test("Follow and pin mutations request immediate watcher reconciliation")
    func watcherCallback() async throws {
        var configuration = ServerConfig()
        configuration.requireHTTPS = false
        let store = try await FollowStore.open(path: ":memory:")
        let credential = try await store.register(registration).credential
        let counter = WatchChangeCounter()
        let api = FollowAPI(store: store, configuration: configuration, watchSetChanged: { await counter.increment() })
        let app = Application(router: api.router())
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/follows", method: .post, headers: bearer(credential.installToken), body: try body(Follow(target: .player(fideId: 1)))) { response in
                #expect(response.status == .created)
            }
            try await client.execute(uri: "/v1/activities", method: .post, headers: bearer(credential.installToken), body: try body(ActivityRegistration(roundId: "r", gameId: "g", activityToken: "token"))) { response in
                #expect(response.status == .noContent)
            }
        }
        #expect(await counter.value == 2)
        await store.close()
    }

    @Test("Preferences round-trip through the API")
    func preferences() async throws {
        let (app, store) = try await application()
        let credential = try await store.register(registration).credential

        try await app.test(.router) { client in
            var wanted = NotificationPreferences(muteAll: true, quietHoursStart: 22 * 60, quietHoursEnd: 7 * 60, timeZoneIdentifier: "Europe/Berlin")
            wanted.gameEndIgnoresQuietHours = true
            try await client.execute(uri: "/v1/preferences", method: .put, headers: bearer(credential.installToken), body: try body(wanted)) { response in
                #expect(response.status == .noContent)
            }
            try await client.execute(uri: "/v1/preferences", method: .get, headers: bearer(credential.installToken)) { response in
                let stored = try FollowJSON.decoder.decode(NotificationPreferences.self, from: Data(buffer: response.body))
                #expect(stored == wanted)
            }
        }
        await store.close()
    }

    @Test("Activities register, replace and end")
    func activities() async throws {
        let (app, store) = try await application()
        let credential = try await store.register(registration).credential

        try await app.test(.router) { client in
            let first = ActivityRegistration(roundId: "WCHr0002", gameId: "wchGam01", activityToken: "act_1")
            try await client.execute(uri: "/v1/activities", method: .post, headers: bearer(credential.installToken), body: try body(first)) { response in
                #expect(response.status == .noContent)
            }
            let second = ActivityRegistration(roundId: "WCHr0002", gameId: "wchGam02", activityToken: "act_2")
            try await client.execute(uri: "/v1/activities", method: .post, headers: bearer(credential.installToken), body: try body(second)) { response in
                #expect(response.status == .noContent)
            }
            let empty = ActivityRegistration(roundId: "r", gameId: "", activityToken: "")
            try await client.execute(uri: "/v1/activities", method: .post, headers: bearer(credential.installToken), body: try body(empty)) { response in
                #expect(response.status == .unprocessableContent)
            }
            try await client.execute(uri: "/v1/activities/wchGam02", method: .delete, headers: bearer(credential.installToken)) { response in
                #expect(response.status == .noContent)
            }
        }
        #expect(try await store.activity(deviceId: credential.deviceId) == nil)
        await store.close()
    }

    @Test("Rotating the APNs token keeps the device and its follows")
    func tokenRotation() async throws {
        let (app, store) = try await application()
        let credential = try await store.register(registration).credential
        _ = try await store.addFollow(Follow(target: .player(fideId: 1)), deviceId: credential.deviceId)

        try await app.test(.router) { client in
            struct Body: Encodable { var apnsToken: String }
            let rotated = String(repeating: "c", count: 64)
            try await client.execute(uri: "/v1/devices/me/token", method: .put, headers: bearer(credential.installToken), body: try body(Body(apnsToken: rotated))) { response in
                #expect(response.status == .noContent)
            }
            try await client.execute(uri: "/v1/devices/me/token", method: .put, headers: bearer(credential.installToken), body: try body(Body(apnsToken: "junk"))) { response in
                #expect(response.status == .unprocessableContent)
            }
        }
        #expect(try await store.device(id: credential.deviceId)?.apnsToken == String(repeating: "c", count: 64))
        #expect(try await store.follows(deviceId: credential.deviceId).count == 1)
        await store.close()
    }

    @Test("A body that is too large is refused rather than read")
    func bodyLimit() async throws {
        let (app, store) = try await application()
        try await app.test(.router) { client in
            let huge = ByteBuffer(repeating: UInt8(ascii: "x"), count: 200 * 1024)
            try await client.execute(uri: "/v1/devices", method: .post, headers: [.contentType: "application/json", .contentLength: "204800"], body: huge) { response in
                #expect(response.status == .contentTooLarge)
            }
        }
        await store.close()
    }

    @Test("With TLS required, a request that did not come through Caddy is refused")
    func httpsRequired() async throws {
        let (app, store) = try await application(requireHTTPS: true)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/health", method: .get) { response in
                #expect(response.status == .forbidden)
            }
            let forwarded: HTTPFields = [HTTPField.Name("x-forwarded-proto")!: "https"]
            try await client.execute(uri: "/v1/health", method: .get, headers: forwarded) { response in
                #expect(response.status == .ok)
            }
        }
        await store.close()
    }

    @Test("A malformed body is a 400, not a crash")
    func malformedBody() async throws {
        let (app, store) = try await application()
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/devices", method: .post, headers: [.contentType: "application/json"], body: ByteBuffer(string: "{not json")) { response in
                #expect(response.status == .badRequest)
            }
        }
        await store.close()
    }

    @Test("The 24-hour alert count is there for the Settings screen")
    func alertCount() async throws {
        let (app, store) = try await application()
        let credential = try await store.register(registration).credential
        _ = try await store.enqueue(OutboxEntry(deviceId: credential.deviceId, dedupeKey: "k", collapseId: "c", category: .gameMove, payloadJSON: "{}"))
        for entry in try await store.queuedEntries() { try await store.markDelivered(id: entry.id) }

        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/alerts/count", method: .get, headers: bearer(credential.installToken)) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("\"last24h\":1"))
            }
        }
        await store.close()
    }
}

private actor WatchChangeCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
