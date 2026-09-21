// The shape of a push as it arrives on the device, so the notification extensions decode what the
// server encodes without either side reading the other's source.

import Foundation

/// `aps.category`. The extension tells a board-shaped alert from an event-shaped one by this and
/// nothing else, because both carry their payload under the same `d` key.
public enum PushCategory {
    /// A board alert: `d` holds a `MovePush`.
    public static let gameMove = "GAME_MOVE"
    /// An event alert: `d` holds a `TournamentPush`.
    public static let tournamentEvent = "TOURNAMENT_EVENT"
}

/// The APNs topic and its Live Activity variant. One universal-purchase bundle id covers iPhone,
/// iPad and the watch, so there is one topic.
public enum PushTopic {
    public static let app = "com.navin.chesstv"
    public static let liveActivity = "com.navin.chesstv.push-type.liveactivity"
}

/// A decoded push: the parts of `aps` the extensions care about, plus the payload under `d`.
///
/// The extension does not have to build this by hand — `PushEnvelope.decode(_:)` takes the
/// `userInfo` dictionary `UNNotificationRequest` hands over.
public struct PushEnvelope<Payload: Decodable & Sendable>: Decodable, Sendable {
    public var payload: Payload
    public var category: String?
    public var threadId: String?
    public var title: String?
    public var subtitle: String?
    public var body: String?

    private enum CodingKeys: String, CodingKey { case aps, d }

    private struct APS: Decodable {
        var category: String?
        var threadId: String?
        var alert: Alert?

        struct Alert: Decodable {
            var title: String?
            var subtitle: String?
            var body: String?
        }

        private enum CodingKeys: String, CodingKey {
            case category
            case threadId = "thread-id"
            case alert
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        payload = try container.decode(Payload.self, forKey: .d)
        let aps = try container.decodeIfPresent(APS.self, forKey: .aps)
        category = aps?.category
        threadId = aps?.threadId
        title = aps?.alert?.title
        subtitle = aps?.alert?.subtitle
        body = aps?.alert?.body
    }

    /// Decodes a push from the `userInfo` a `UNNotificationRequest` carries.
    ///
    /// Returns nil rather than throwing when the payload is not ours or not readable: an extension
    /// that cannot decode must still deliver the notification the server already worded, and
    /// throwing here would only make that harder to write.
    public static func decode(_ userInfo: [AnyHashable: Any]) -> PushEnvelope<Payload>? {
        guard JSONSerialization.isValidJSONObject(userInfo),
              let data = try? JSONSerialization.data(withJSONObject: userInfo) else { return nil }
        return try? FollowJSON.pushDecoder.decode(PushEnvelope<Payload>.self, from: data)
    }
}
