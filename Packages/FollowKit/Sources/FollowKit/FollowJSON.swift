// The coders. Four codebases encode these types; if they disagree about a date the bug shows up
// as a notification with the wrong clock, so there is exactly one place that builds a coder.

import Foundation

public enum FollowJSON {

    /// The REST API's encoder: ISO 8601 dates, sorted keys so a logged body diffs cleanly.
    ///
    /// ISO 8601 without fractional seconds, which is the interoperable spelling and what every
    /// other client of this API would expect. Dates therefore round-trip to the second, not to
    /// the millisecond; nothing here is finer-grained than a chess clock.
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// The REST API's decoder.
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The encoder for the `d` key of a push. Same ISO 8601 dates as the REST API — the extension
    /// decodes it with `pushDecoder` — but compact, because the payload has 4 KB to live in.
    public static var pushEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    /// What a notification extension should decode a `MovePush` or `TournamentPush` with.
    public static var pushDecoder: JSONDecoder { decoder }

    /// The encoder for an ActivityKit `content-state`, and for nothing else.
    ///
    /// ActivityKit decodes the content state with a stock `JSONDecoder`, so its dates must be
    /// `.deferredToDate` — a `Double` of seconds since the 2001 reference date. Encoding
    /// `LiveActivityState.asOf` as an ISO 8601 string here makes the whole update fail to decode
    /// silently on the device, which looks exactly like "Live Activities do not work".
    public static var activityEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    /// The matching decoder, for tests and for the app reading back a state it stored.
    public static var activityDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }
}
