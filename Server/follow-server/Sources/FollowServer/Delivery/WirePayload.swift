// A payload that is already encoded, carried to APNs without being re-encoded.
//
// This exists because of a real bug. An outbox row's `payload_json` is written by the coder that
// the *device* will read it with: `FollowJSON.pushEncoder` (ISO 8601 dates) for an alert, because
// the notification extension decodes `d` with `FollowJSON.pushDecoder`; and
// `FollowJSON.activityEncoder` (`.deferredToDate`, a number of seconds since 2001) for a Live
// Activity content state, because ActivityKit decodes it with a stock `JSONDecoder`.
//
// `APNSClient` is generic over one request encoder and re-encodes whatever payload it is handed.
// Decoding a row back into a `MovePush` and passing the struct therefore threw away the row's date
// spelling and substituted the client's, which silently broke every real alert on the device while
// the outbox-payload tests still passed. Parsing the row into a `JSONValue` instead means no
// `Date` ever reaches the client's encoder, so the bytes on the wire are the bytes in the row
// whatever that encoder is configured to do.

import Foundation

/// A JSON document, structurally. Decoded from the outbox row and re-encoded verbatim.
enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            // Before `Double`, so a ply stays `41` rather than becoming `41.0`.
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not JSON")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Parses a row's `payload_json`.
    static func parse(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }
}
