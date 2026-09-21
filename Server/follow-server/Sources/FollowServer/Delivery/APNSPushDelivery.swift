// APNs, with the headers the plan specifies.
//
//   apns-push-type: alert            board and event alerts
//   apns-collapse-id: <gameId>       so the newest move replaces the previous one
//                    <tourId>:<roundId>:<kind>   for event alerts
//   apns-topic: com.navin.chesstv
//   aps.thread-id = roundId, aps.category = GAME_MOVE | TOURNAMENT_EVENT
//   aps.mutable-content = 1          so the service extension can draw the board
//   aps.sound = default              an alert the user asked for should be audible
//   aps.relevance-score              higher for a game end and for a round going live
//
// Live Activities go to the `.push-type.liveactivity` topic with `event: update` per move and
// `event: end` with a dismissal date at game end.
//
// The payload under `d` (and a Live Activity's `content-state`) is passed through as the outbox
// row wrote it — see `WirePayload.swift` for why that matters.

import APNS
import APNSCore
import Crypto
import Foundation
import FollowKit
import Logging
import NIOPosix

public final class APNSPushDelivery: PushDelivering, Sendable {

    private typealias Client = APNSClient<JSONDecoder, JSONEncoder>

    private let production: Client
    private let sandbox: Client
    private let configuration: ServerConfig
    private let logger: Logger

    /// - Throws: whatever reading or parsing the `.p8` throws. The key is read once, here, and
    ///   the file's contents never leave this initializer.
    public init(configuration: ServerConfig, logger: Logger = ServerLog.make("apns")) throws {
        let privateKey = try P256.Signing.PrivateKey(pemRepresentation: String(contentsOfFile: configuration.apnsKeyPath, encoding: .utf8))
        let authentication = APNSClientConfiguration.AuthenticationMethod.jwt(
            privateKey: privateKey,
            keyIdentifier: configuration.apnsKeyId,
            teamIdentifier: configuration.apnsTeamId
        )
        // Live Activity updates and alerts both go through these two; APNSwift holds one HTTP/2
        // connection per client, which is what Apple asks for. One request encoder serves both
        // because neither payload reaches it holding a `Date`.
        self.production = Client(
            configuration: APNSClientConfiguration(authenticationMethod: authentication, environment: .production),
            eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton),
            responseDecoder: JSONDecoder(),
            requestEncoder: Self.requestEncoder
        )
        self.sandbox = Client(
            configuration: APNSClientConfiguration(authenticationMethod: authentication, environment: .development),
            eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton),
            responseDecoder: JSONDecoder(),
            requestEncoder: Self.requestEncoder
        )
        self.configuration = configuration
        self.logger = logger
    }

    /// What the clients encode requests with.
    ///
    /// Its date strategy is deliberately irrelevant: the only values it ever sees are `aps` (no
    /// dates — APNs wants `timestamp` and `dismissal-date` as unix-second integers, and APNSwift
    /// already stores them as `Int`) and a `JSONValue` parsed from the outbox row. Slashes are
    /// left alone so a banner URL in the payload is readable in a packet capture.
    static var requestEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    /// APNSwift only offers a callback shutdown, so it is bridged here. Called once, from the
    /// process's shutdown path.
    public func shutdown() async {
        for client in [production, sandbox] {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                client.shutdown { _ in continuation.resume() }
            }
        }
    }

    private func client(for environment: String) -> Client {
        environment == "sandbox" ? sandbox : production
    }

    /// The `d` key. APNSwift encodes the payload at the root of the JSON and writes `aps`
    /// alongside it, which is exactly the shape `PushEnvelope` in FollowKit decodes.
    struct Envelope: Encodable, Sendable {
        let d: JSONValue
    }

    public func deliver(_ push: OutboundPush) async -> DeliveryOutcome {
        do {
            switch push.entry.category {
            case .gameMove, .tournamentEvent:
                _ = try await client(for: push.environment)
                    .sendAlertNotification(Self.alertNotification(for: push.entry, topic: configuration.apnsTopic), deviceToken: push.token)
            case .activityUpdate, .activityEnd:
                _ = try await client(for: push.environment)
                    .sendLiveActivityNotification(Self.activityNotification(for: push.entry, topic: configuration.liveActivityTopic), deviceToken: push.token)
            }
            return .delivered
        } catch let error as APNSError {
            return outcome(for: error, push: push)
        } catch is DecodingError {
            // A row this build cannot read is a bug in this build, not something to retry for a
            // week.
            return .drop("payload could not be decoded")
        } catch {
            return .retry(String(describing: type(of: error)))
        }
    }

    // MARK: - Building the notifications
    //
    // Static and pure so a test can assert on the exact bytes without an APNs key: see
    // `APNSWireTests`.

    static func alertNotification(for entry: OutboxEntry, topic: String) throws -> APNSAlertNotification<Envelope> {
        // Decoded once for validation only — a row that is not a push this build understands is
        // dropped rather than sent. The value that actually travels is the parsed JSON.
        let payload = try JSONValue.parse(entry.payloadJSON)
        switch entry.category {
        case .gameMove: _ = try FollowJSON.pushDecoder.decode(MovePush.self, from: Data(entry.payloadJSON.utf8))
        case .tournamentEvent: _ = try FollowJSON.pushDecoder.decode(TournamentPush.self, from: Data(entry.payloadJSON.utf8))
        case .activityUpdate, .activityEnd: throw DeliveryBuildError.wrongCategory
        }

        var notification = APNSAlertNotification(
            alert: APNSAlertNotificationContent(
                title: .raw(entry.title),
                body: .raw(entry.body)
            ),
            // A move alert that arrives an hour late is noise. An hour is generous for a board
            // that updates every few minutes and short enough that a phone coming back from
            // airplane mode does not replay the morning.
            expiration: .timeIntervalSince1970InSeconds(Int(entry.queuedAt.timeIntervalSince1970) + 3600),
            priority: .immediately,
            topic: topic,
            payload: Envelope(d: payload),
            threadID: entry.threadId,
            category: entry.category.rawValue,
            mutableContent: 1,
            relevanceScore: entry.relevance,
            apnsID: nil
        )
        notification.collapseID = entry.collapseId
        // These alerts exist because the user asked to be told about a move or a result. Quiet
        // hours and mute are already applied on the server, so anything that reaches here is
        // wanted; delivering it silently would just make it easy to miss.
        notification.sound = .default
        return notification
    }

    static func activityNotification(for entry: OutboxEntry, topic: String) throws -> APNSLiveActivityNotification<JSONValue> {
        guard entry.category == .activityUpdate || entry.category == .activityEnd else {
            throw DeliveryBuildError.wrongCategory
        }
        let state = try FollowJSON.activityDecoder.decode(LiveActivityState.self, from: Data(entry.payloadJSON.utf8))
        let contentState = try JSONValue.parse(entry.payloadJSON)
        let isEnd = entry.category == .activityEnd

        return APNSLiveActivityNotification(
            expiration: .timeIntervalSince1970InSeconds(Int(entry.queuedAt.timeIntervalSince1970) + 3600),
            priority: .immediately,
            topic: topic,
            contentState: contentState,
            event: isEnd ? .end : .update,
            // APNs wants unix seconds here, and it uses the value to discard an update that
            // arrives out of order — so it must be the time the state was true, not now.
            timestamp: Int(state.asOf.timeIntervalSince1970),
            // Leave the final position on the Lock Screen for a while rather than snapping it
            // away the instant the game ends.
            dismissalDate: isEnd ? .date(state.asOf.addingTimeInterval(15 * 60)) : .none
        )
    }

    /// Exactly the JSON that would go on the wire for a row, for the wire tests.
    static func wireBody(for entry: OutboxEntry, topic: String, liveActivityTopic: String) throws -> Data {
        switch entry.category {
        case .gameMove, .tournamentEvent:
            return try requestEncoder.encode(alertNotification(for: entry, topic: topic))
        case .activityUpdate, .activityEnd:
            return try requestEncoder.encode(activityNotification(for: entry, topic: liveActivityTopic))
        }
    }

    enum DeliveryBuildError: Error, Sendable, Equatable {
        case wrongCategory
    }

    private func outcome(for error: APNSError, push: OutboundPush) -> DeliveryOutcome {
        // 410 Gone, or a 400 naming the token. Either way this token will never work again.
        if error.responseStatus == 410 || error.reason == .badDeviceToken || error.reason == .unregistered {
            return .deviceGone(error.reason?.reason ?? "gone")
        }
        switch error.reason {
        case .some(.payloadTooLarge), .some(.badTopic), .some(.topicDisallowed), .some(.deviceTokenNotForTopic),
             .some(.badCollapseIdentifier), .some(.invalidPushType), .some(.badExpirationDate):
            // Our fault, and the same request will fail the same way next time.
            logger.error("APNs refused a push", metadata: [
                "reason": .string(error.reason?.reason ?? "?"),
                "category": .string(push.entry.category.rawValue),
            ])
            return .drop(error.reason?.reason ?? "refused")
        default:
            return .retry(error.reason?.reason ?? "HTTP \(error.responseStatus)")
        }
    }
}
