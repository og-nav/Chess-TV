// The HTTP contract from MOBILE_BUILD_PLAN.md, endpoint for endpoint.
//
// | POST   /v1/devices           | DeviceRegistration → DeviceCredential      | no token |
// | PUT    /v1/devices/me/token  | {apnsToken} → 204                          |          |
// | GET    /v1/follows           | → [Follow]                                 |          |
// | POST   /v1/follows           | Follow (id ignored) → Follow               |          |
// | PATCH  /v1/follows/{id}      | FollowAlerts → Follow                      |          |
// | DELETE /v1/follows/{id}      | → 204                                      |          |
// | GET    /v1/preferences       | → NotificationPreferences                  |          |
// | PUT    /v1/preferences       | NotificationPreferences → 204              |          |
// | POST   /v1/activities        | ActivityRegistration → 204                 |          |
// | DELETE /v1/activities/{id}   | → 204                                      |          |
// | GET    /v1/health            | → ServerHealth                             | no token |
//
// Every authenticated route is scoped to the device the token belongs to: a follow id or a game
// id from one install never reaches another's row, because the `WHERE` clause always carries the
// device.

import Foundation
import FollowKit
import Hummingbird
import Logging

public struct FollowAPI: Sendable {

    private let store: FollowStore
    private let configuration: ServerConfig
    private let logger: Logger
    private let watchSetChanged: @Sendable () async -> Void
    /// Filled in by the coordinator; a closure so the API does not have to own the watcher.
    private let health: @Sendable () async -> ServerHealth

    public init(
        store: FollowStore,
        configuration: ServerConfig,
        logger: Logger = ServerLog.make("api"),
        watchSetChanged: @escaping @Sendable () async -> Void = {},
        health: @escaping @Sendable () async -> ServerHealth = { ServerHealth() }
    ) {
        self.store = store
        self.configuration = configuration
        self.logger = logger
        self.health = health
        self.watchSetChanged = watchSetChanged
    }

    public func router() -> Router<FollowRequestContext> {
        let router = Router(context: FollowRequestContext.self)
        router.addMiddleware {
            RequireHTTPSMiddleware<FollowRequestContext>(enabled: configuration.requireHTTPS)
            BodyLimitMiddleware<FollowRequestContext>(limit: configuration.maximumRequestBytes)
        }

        let store = store
        let logger = logger
        let health = health
        let watchSetChanged = watchSetChanged
        let registrations = RegistrationThrottle()

        // MARK: Open endpoints

        router.get("/v1/health") { _, _ in
            try JSONBody.response(await health())
        }

        router.post("/v1/devices") { request, context in
            guard await registrations.allow() else {
                throw HTTPError(.tooManyRequests, message: "Registration is busy; retry shortly")
            }
            let registration = try await JSONBody.decode(DeviceRegistration.self, from: request, context: context)
            guard registration.isWellFormed else {
                throw HTTPError(.unprocessableContent, message: "registration is not well formed")
            }
            let result = try await store.register(registration)
            // The device id is fine in a log; the install token is not, ever.
            logger.info("registered", metadata: [
                "device": .string(result.device.id),
                "platform": .string(registration.platform),
                "environment": .string(registration.environment),
            ])
            return try JSONBody.response(result.credential, status: .created)
        }

        // MARK: Authenticated endpoints

        let authenticated = router.group("/v1").add(middleware: BearerAuthMiddleware(store: store, logger: logger))

        authenticated.put("devices/me/token") { request, context in
            struct Body: Decodable { var apnsToken: String }
            let deviceId = try context.requireDevice()
            let body = try await JSONBody.decode(Body.self, from: request, context: context)
            guard DeviceRegistration(apnsToken: body.apnsToken).isWellFormed else {
                throw HTTPError(.unprocessableContent, message: "apnsToken is not a device token")
            }
            try await store.updateAPNsToken(deviceId: deviceId, apnsToken: body.apnsToken)
            await watchSetChanged()
            return JSONBody.empty
        }

        // The install is going away — the phone reset its identity or was pointed at another
        // server — and takes its follows with it, so the row it leaves behind does not go on
        // alerting the same phone in duplicate.
        authenticated.delete("devices/me") { _, context in
            let deviceId = try context.requireDevice()
            try await store.deleteDevice(id: deviceId)
            logger.info("unregistered", metadata: ["device": .string(deviceId)])
            await watchSetChanged()
            return JSONBody.empty
        }

        authenticated.get("follows") { _, context in
            try JSONBody.response(await store.follows(deviceId: try context.requireDevice()))
        }

        authenticated.post("follows") { request, context in
            let deviceId = try context.requireDevice()
            var follow = try await JSONBody.decode(Follow.self, from: request, context: context)
            // The plan says the id is ignored on create; the server mints it.
            follow.id = ""
            guard Self.valid(follow.target) else {
                throw HTTPError(.unprocessableContent, message: "Follow target is not valid")
            }
            do {
                let stored = try await store.addFollow(follow, deviceId: deviceId)
                await watchSetChanged()
                return try JSONBody.response(stored, status: .created)
            } catch StoreError.conflict(let reason) {
                throw HTTPError(.unprocessableContent, message: reason)
            }
        }

        authenticated.patch("follows/:id") { request, context in
            let deviceId = try context.requireDevice()
            guard let id = context.parameters.get("id") else { throw HTTPError(.badRequest) }
            let alerts = try await JSONBody.decode(FollowAlerts.self, from: request, context: context)
            do {
                return try JSONBody.response(await store.updateFollow(id: id, alerts: alerts, deviceId: deviceId))
            } catch StoreError.notFound {
                throw HTTPError(.notFound)
            }
        }

        authenticated.delete("follows/:id") { _, context in
            let deviceId = try context.requireDevice()
            guard let id = context.parameters.get("id") else { throw HTTPError(.badRequest) }
            guard try await store.removeFollow(id: id, deviceId: deviceId) else { throw HTTPError(.notFound) }
            await watchSetChanged()
            return JSONBody.empty
        }

        authenticated.get("preferences") { _, context in
            try JSONBody.response(await store.preferences(deviceId: try context.requireDevice()))
        }

        authenticated.put("preferences") { request, context in
            let deviceId = try context.requireDevice()
            let preferences = try await JSONBody.decode(NotificationPreferences.self, from: request, context: context)
            try await store.setPreferences(preferences, deviceId: deviceId)
            return JSONBody.empty
        }

        authenticated.post("activities") { request, context in
            let deviceId = try context.requireDevice()
            let registration = try await JSONBody.decode(ActivityRegistration.self, from: request, context: context)
            guard Self.validIdentifier(registration.gameId), Self.validIdentifier(registration.roundId),
                  !registration.activityToken.isEmpty, registration.activityToken.count <= 512 else {
                throw HTTPError(.unprocessableContent, message: "gameId and activityToken are required")
            }
            try await store.registerActivity(registration, deviceId: deviceId)
            await watchSetChanged()
            return JSONBody.empty
        }

        authenticated.delete("activities/:gameId") { _, context in
            let deviceId = try context.requireDevice()
            guard let gameId = context.parameters.get("gameId") else { throw HTTPError(.badRequest) }
            _ = try await store.endActivity(gameId: gameId, deviceId: deviceId)
            await watchSetChanged()
            return JSONBody.empty
        }

        // The 24-hour alert count the phone's Settings screen shows. Not in the plan's table
        // because the plan says to read it from the device's own delivered-notification log; the
        // server has the honest number, and a device that was asleep has no log to read.
        authenticated.get("alerts/count") { _, context in
            struct Count: Encodable { var last24h: Int }
            let deviceId = try context.requireDevice()
            let since = Date().addingTimeInterval(-24 * 3600)
            return try JSONBody.response(Count(last24h: await store.deliveredAlertCount(deviceId: deviceId, since: since)))
        }

        return router
    }

    private static func validIdentifier(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
    private static func valid(_ target: FollowTarget) -> Bool {
        switch target {
        case .player(let fideId): return fideId > 0
        case .game(let roundId, let gameId): return validIdentifier(roundId) && validIdentifier(gameId)
        case .tournament(let tourId): return validIdentifier(tourId)
        }
    }
}

/// Aggregate protection for the public credential-minting route. This does not trust forwarded
/// client IP headers; an edge proxy can additionally apply its own trusted-client limits.
actor RegistrationThrottle {
    private var accepted: [Date] = []
    private let limit: Int
    private let now: @Sendable () -> Date
    init(limit: Int = 60, now: @escaping @Sendable () -> Date = { Date() }) {
        self.limit = limit
        self.now = now
    }
    func allow() -> Bool {
        let timestamp = now()
        accepted.removeAll { timestamp.timeIntervalSince($0) >= 60 }
        guard accepted.count < limit else { return false }
        accepted.append(timestamp)
        return true
    }
}
