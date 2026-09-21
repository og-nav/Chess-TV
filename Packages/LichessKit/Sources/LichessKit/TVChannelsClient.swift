import Foundation

/// Fetches `GET /api/tv/channels`: the current featured game for every TV channel.
public final class TVChannelsClient: TVChannelsFetching, @unchecked Sendable {
    private let session: URLSession
    private let baseURL: URL

    public init(session: URLSession = LichessURLSession.standard, baseURL: URL = LichessConfig.baseURL) {
        self.session = session
        self.baseURL = baseURL
    }

    public func currentGames() async throws -> [TVChannelSummary] {
        let url = baseURL.appendingPathComponent("api/tv/channels")
        let (data, response) = try await session.data(for: LichessURLSession.request(url))
        guard let http = response as? HTTPURLResponse else { throw LichessError.notHTTP }
        switch http.statusCode {
        case 200: break
        case 429: throw LichessError.rateLimited(retryAfter: http.retryAfterDuration)
        case 404, 410, 501: throw LichessError.unrecoverableStatus(http.statusCode)
        default: throw LichessError.retryableStatus(http.statusCode)
        }
        let summaries = try Self.decodeChannels(data)
        log.debug("Fetched \(summaries.count) TV channels")
        return summaries
    }

    /// Decodes the channels payload. Channel keys we do not model are skipped, never fatal.
    /// The result is ordered by `TVChannel.allCases` so the UI strip is stable.
    static func decodeChannels(_ data: Data) throws -> [TVChannelSummary] {
        let raw = try JSONDecoder().decode([String: ChannelWire].self, from: data)
        let unknown = raw.keys.filter { TVChannel(rawValue: $0) == nil }
        if !unknown.isEmpty {
            log.notice("Skipping unknown TV channels: \(unknown.sorted().joined(separator: ", "), privacy: .public)")
        }
        return TVChannel.allCases.compactMap { channel in
            guard let wire = raw[channel.rawValue] else { return nil }
            return TVChannelSummary(
                channel: channel,
                gameId: wire.gameId,
                userName: wire.user?.name ?? "Anonymous",
                rating: wire.rating
            )
        }
    }

    struct ChannelWire: Decodable {
        struct User: Decodable {
            let name: String?
            let title: String?
        }
        let user: User?
        let rating: Int?
        let gameId: String
    }
}

extension HTTPURLResponse {
    /// `Retry-After` as a `Duration`, accepting the delay-seconds form and the HTTP-date form.
    var retryAfterDuration: Duration? {
        guard let value = (value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces)), !value.isEmpty else { return nil }
        if let seconds = Double(value) { return .seconds(max(0, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return .seconds(max(0, date.timeIntervalSinceNow))
    }
}
