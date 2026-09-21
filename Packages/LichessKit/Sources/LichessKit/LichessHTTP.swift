import Foundation

/// Status-code handling shared by every one-shot Lichess request.
///
/// The mapping is the same one `TVFeedStream` and `TVChannelsClient` already use: 429 becomes
/// `.rateLimited` carrying `Retry-After`, 404/410/501 are unrecoverable, everything else non-200
/// is worth retrying.
enum LichessHTTP {

    /// Validates the response, throwing the matching `LichessError`.
    static func check(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw LichessError.notHTTP }
        switch http.statusCode {
        case 200: return http
        case 429: throw LichessError.rateLimited(retryAfter: http.retryAfterDuration)
        case 404, 410, 501: throw LichessError.unrecoverableStatus(http.statusCode)
        default: throw LichessError.retryableStatus(http.statusCode)
        }
    }

    /// `GET url` with the package headers, returning the body of a 200.
    static func get(_ url: URL, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: LichessURLSession.request(url))
        _ = try check(response)
        return data
    }

    /// Decodes a JSON body, mapping any decoding failure to `LichessError.malformedBody`.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, what: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            log.error("Could not decode \(what, privacy: .public): \(String(describing: error), privacy: .public)")
            throw LichessError.malformedBody
        }
    }
}

extension Date {
    /// Lichess sends every timestamp as milliseconds since the epoch.
    init(epochMilliseconds: Double) {
        self.init(timeIntervalSince1970: epochMilliseconds / 1000)
    }
}

/// `variant` is `{"key":"standard",…}` on `/api/tournament` but a bare `"standard"` string on
/// `/api/tournament/{id}`. This accepts both.
struct VariantKey: Decodable {
    let key: String

    init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let raw = try? single.decode(String.self) {
            key = raw
            return
        }
        struct Keyed: Decodable { let key: String }
        key = try Keyed(from: decoder).key
    }
}

/// `startsAt` is epoch milliseconds on `/api/tournament` and an ISO-8601 string on
/// `/api/tournament/{id}`. This accepts both, and anything unparseable becomes the epoch.
struct LichessTimestamp: Decodable {
    let date: Date

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let milliseconds = try? container.decode(Double.self) {
            date = Date(epochMilliseconds: milliseconds)
            return
        }
        let raw = try container.decode(String.self)
        // `ISO8601DateFormatter` is not `Sendable`, so a format *style* is used instead;
        // Lichess sends whole seconds, but tolerate fractional seconds too.
        if let parsed = try? Date(raw, strategy: .iso8601) {
            date = parsed
        } else if let parsed = try? Date(raw, strategy: .iso8601.time(includingFractionalSeconds: true)) {
            date = parsed
        } else {
            log.notice("Unparseable timestamp \(raw, privacy: .public); using the epoch")
            date = Date(timeIntervalSince1970: 0)
        }
    }
}
