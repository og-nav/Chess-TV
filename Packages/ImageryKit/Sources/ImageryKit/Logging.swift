import Foundation
import Synchronization
import os

/// Single logger for the whole package. No `print` anywhere in the library.
let log = Logger(subsystem: "com.navin.chesstv", category: "ImageryKit")

/// Shared `URLSession` configuration for every image or Wikipedia request.
///
/// Both Lichess's image CDN and the Wikimedia REST API ask for an identifying `User-Agent`
/// and will throttle or block requests without one, so the header is on the session
/// configuration *and* on every request in case a caller supplies their own session.
public enum ImageryURLSession {
    /// The identity sent until the app configures one, so tests still send a valid header.
    public static let defaultUserAgent = "ChessTV/0.1 (zzzlabshq@gmail.com)"

    /// Guarded because this is process-wide state a request may read from any thread; a plain
    /// `static var` is not Sendable under Swift 6.
    private static let userAgentStorage = Mutex<String>(defaultUserAgent)

    /// `ChessTV/<version> (<contact>)`, the same identity the Lichess clients send. Read at
    /// request time, so configuring it after `standard` exists still counts.
    public static var userAgent: String { userAgentStorage.withLock { $0 } }

    /// Set once at launch, from the app, before any request goes out. An empty string is
    /// ignored so a misconfiguration cannot strip the header.
    public static func configure(userAgent: String) {
        let trimmed = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        userAgentStorage.withLock { $0 = trimmed }
    }

    /// The session used by `ImageCache` and `WikipediaImageClient` unless one is injected.
    public static let standard: URLSession = make()

    /// - Parameter protocolClasses: injected `URLProtocol` subclasses, used by tests to stub the network.
    public static func make(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        // This package runs its own two-level cache; URLSession's would only duplicate it on disk.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        // A board list asks for up to eighty portraits at once; more than a handful of parallel
        // connections to one CDN host earns a throttle rather than a speed-up.
        configuration.httpMaximumConnectionsPerHost = 4
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return URLSession(configuration: configuration)
    }

    /// A request with the required header already set. Every request in this package goes
    /// through here, so the header is whatever the app configured, not what `standard` was
    /// built with.
    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }
}
