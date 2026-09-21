import Foundation

/// Shared `URLSession` configuration for every Lichess request.
///
/// Both flavours always send `LichessConfig.userAgent` (`ChessTV/<version> (<contact>)`, set by
/// the app at launch) as required by the Lichess API policy. The session configuration carries
/// whatever the value was when the session was built; `request(_:)` sets it again per request,
/// which is what every client here goes through, so the value is read at request time.
public enum LichessURLSession {
    /// Short-timeout session for one-shot requests such as `/api/tv/channels`.
    public static let standard: URLSession = make(streaming: false)

    /// Session for the NDJSON feeds. The TV feed idles for minutes between moves,
    /// so the request timeout is effectively disabled (24 h) and the resource
    /// timeout is unlimited; without this URLSession would kill an idle stream.
    public static let streaming: URLSession = make(streaming: true)

    /// Builds a session with the package's headers and timeouts.
    /// - Parameters:
    ///   - streaming: `true` for long-lived NDJSON connections.
    ///   - protocolClasses: injected `URLProtocol` subclasses, used by tests to stub the network.
    public static func make(streaming: Bool, protocolClasses: [AnyClass]? = nil) -> URLSession {
        URLSession(configuration: configuration(streaming: streaming, protocolClasses: protocolClasses))
    }

    /// The shared configuration, exposed so callers can tweak one field and rebuild.
    public static func configuration(streaming: Bool, protocolClasses: [AnyClass]? = nil) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [
            "User-Agent": LichessConfig.userAgent,
            "Accept": streaming ? "application/x-ndjson" : "application/json",
        ]
        // 24 hours for the feed: the connection legitimately idles between moves.
        configuration.timeoutIntervalForRequest = streaming ? 86_400 : 15
        // `.greatestFiniteMagnitude` is how you say "no resource timeout".
        configuration.timeoutIntervalForResource = streaming ? .greatestFiniteMagnitude : 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        // We run our own backoff; waiting for connectivity would hide the reconnecting state.
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 2
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return configuration
    }

    /// A request with the required headers already set.
    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        // Not just belt and braces: this read is what makes the app's launch-time
        // configuration reach a session that was already built with the default.
        request.setValue(LichessConfig.userAgent, forHTTPHeaderField: "User-Agent")
        // Never attach the Lichess credential to a test host or an image/CDN URL.
        if url.scheme == "https", url.host == LichessConfig.baseURL.host,
           let token = LichessConfig.bearerToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
