// The `FollowServerClient` that talks to the follow server over HTTPS.
//
// Deliberately plain: one request per call, no retry and no cache. Retry policy belongs to the
// caller, because the app retries registration on a schedule the user can see ("Not synced,
// retrying") while the Following screen keeps working from its local copy meanwhile.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking      // Linux splits URLSession out of Foundation
#endif

/// The HTTP round trip, behind a protocol so tests do not need a socket or a `URLProtocol`
/// subclass. The server's replay tooling uses it too.
public protocol FollowHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession`, with the async call written over the completion-handler API.
///
/// The completion-handler form is the one that has existed on swift-corelibs-foundation for
/// years; the `async` overloads arrived later and this package has to compile on Linux for the
/// server's sake. One continuation is cheaper than a compatibility surprise.
public struct URLSessionTransport: FollowHTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    /// A session that identifies the app the way Lichess and the server both ask for.
    public static func session(userAgent: String, timeout: TimeInterval = 15) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        #if !canImport(FoundationNetworking)
        configuration.waitsForConnectivity = false
        #endif
        return URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: FollowServerError.unavailable(Self.describe(error)))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: FollowServerError.malformedResponse("not an HTTP response"))
                    return
                }
                continuation.resume(returning: (data ?? Data(), http))
            }
            task.resume()
        }
    }

    /// The error's shape without its `userInfo`, which on some platforms carries the URL and so
    /// could carry a query string into a log.
    private static func describe(_ error: any Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }
}

/// Talks to `https://<host>/v1/…`.
///
/// Holds no credential of its own: it asks the `FollowCredentialStore` on every call, so a token
/// rotated by another part of the app (or cleared after a 401) is picked up without rebuilding
/// the client.
public struct HTTPFollowServerClient: FollowServerClient {

    private let baseURL: URL
    private let credentials: any FollowCredentialStore
    private let transport: any FollowHTTPTransport
    private let userAgent: String

    /// The cap on a response body. The largest legitimate reply is the follow list, and a device
    /// with a thousand follows is already a bug; anything past this is a wrong server, not our
    /// server.
    private let maximumResponseBytes = 1 << 20

    /// - Parameters:
    ///   - baseURL: the server root, with or without a trailing slash. Must be https unless it is
    ///     a loopback address, so that a debug build can point at a laptop.
    ///   - credentials: where the install token lives. `KeychainCredentialStore` in the app.
    ///   - transport: the network. Injected in tests.
    ///   - userAgent: `ChessTV/<version> (<contact>)`, as everything else this project sends.
    /// - Throws: `FollowServerError.insecureBaseURL` rather than letting a bearer token travel in
    ///   the clear.
    public init(
        baseURL: URL,
        credentials: any FollowCredentialStore,
        transport: any FollowHTTPTransport = URLSessionTransport(),
        userAgent: String = "ChessTV/0.1 (zzzlabshq@gmail.com)"
    ) throws {
        guard Self.isSecure(baseURL) else { throw FollowServerError.insecureBaseURL(baseURL.scheme ?? "") }
        self.baseURL = baseURL
        self.credentials = credentials
        self.transport = transport
        self.userAgent = userAgent
    }

    /// https anywhere, or http to this machine. `localhost.evil.example` does not count as
    /// loopback: the host has to be exactly one of the three spellings.
    public static func isSecure(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http":
            guard let host = url.host?.lowercased() else { return false }
            return host == "localhost" || host == "127.0.0.1" || host == "::1"
        default: return false
        }
    }

    // MARK: Requests

    /// Joins an **already escaped** path onto the base URL.
    ///
    /// Built by string rather than by `appending(path:)` because that method treats its argument
    /// as literal text and percent-encodes it again, which turns an escaped `%5F` into `%255F`.
    /// A base with a path of its own (`https://host/api`) survives either way.
    private func url(_ path: String) -> URL {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + "/" + path) ?? baseURL
    }

    private func credential() async throws -> DeviceCredential {
        guard let credential = try? await credentials.load(), !credential.installToken.isEmpty else {
            throw FollowServerError.notRegistered
        }
        return credential
    }

    private func request(_ method: String, _ path: String, body: Data? = nil, authorized: Bool) async throws -> URLRequest {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authorized {
            request.setValue("Bearer \(try await credential().installToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    @discardableResult
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.send(request)
        guard data.count <= maximumResponseBytes else {
            throw FollowServerError.malformedResponse("response body over \(maximumResponseBytes) bytes")
        }
        switch response.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw FollowServerError.unauthorized
        case 404:
            throw FollowServerError.notFound
        case 400, 409, 422:
            throw FollowServerError.rejected(Self.reason(from: data))
        default:
            throw FollowServerError.unavailable("HTTP \(response.statusCode)")
        }
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let data = try await send(request)
        do {
            return try FollowJSON.decoder.decode(T.self, from: data)
        } catch {
            throw FollowServerError.malformedResponse(String(describing: type))
        }
    }

    /// The server's error message, or an empty string. Hummingbird writes
    /// `{"error": {"message": "..."}}`; a plain `{"error": "..."}` is accepted too. Never the raw
    /// body: it could be an HTML error page from a proxy and there is no reason to put that in a
    /// log.
    private static func reason(from data: Data) -> String {
        struct Nested: Decodable { var message: String? }
        struct Envelope: Decodable {
            var error: String?
            var nested: Nested?
            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let text = try? container.decode(String.self, forKey: .error) {
                    error = text
                } else {
                    nested = try? container.decode(Nested.self, forKey: .error)
                }
            }
            enum CodingKeys: String, CodingKey { case error }
        }
        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        return envelope?.error ?? envelope?.nested?.message ?? ""
    }

    // MARK: FollowServerClient

    public func register(_ device: DeviceRegistration) async throws -> DeviceCredential {
        let body = try FollowJSON.encoder.encode(device)
        let request = try await request("POST", "v1/devices", body: body, authorized: false)
        let credential = try await send(request, as: DeviceCredential.self)
        guard !credential.deviceId.isEmpty, !credential.installToken.isEmpty else {
            throw FollowServerError.malformedResponse("empty credential")
        }
        try await credentials.save(credential)
        return credential
    }

    public func updateToken(_ apnsToken: String) async throws {
        struct Body: Encodable { var apnsToken: String }
        let body = try FollowJSON.encoder.encode(Body(apnsToken: apnsToken))
        try await send(request("PUT", "v1/devices/me/token", body: body, authorized: true))
    }

    public func follows() async throws -> [Follow] {
        try await send(request("GET", "v1/follows", authorized: true), as: [Follow].self)
    }

    public func add(_ follow: Follow) async throws -> Follow {
        let body = try FollowJSON.encoder.encode(follow)
        return try await send(request("POST", "v1/follows", body: body, authorized: true), as: Follow.self)
    }

    public func update(_ follow: Follow) async throws -> Follow {
        guard !follow.id.isEmpty else { throw FollowServerError.rejected("follow has no id") }
        let body = try FollowJSON.encoder.encode(follow.alerts)
        let path = "v1/follows/\(Self.escape(follow.id))"
        return try await send(request("PATCH", path, body: body, authorized: true), as: Follow.self)
    }

    public func remove(id: String) async throws {
        guard !id.isEmpty else { throw FollowServerError.rejected("follow has no id") }
        try await send(request("DELETE", "v1/follows/\(Self.escape(id))", authorized: true))
    }

    public func unregister(_ credential: DeviceCredential) async throws {
        guard !credential.installToken.isEmpty else { throw FollowServerError.notRegistered }
        var request = try await request("DELETE", "v1/devices/me", authorized: false)
        request.setValue("Bearer \(credential.installToken)", forHTTPHeaderField: "Authorization")
        try await send(request)
    }

    public func preferences() async throws -> NotificationPreferences {
        try await send(request("GET", "v1/preferences", authorized: true), as: NotificationPreferences.self)
    }

    public func setPreferences(_ preferences: NotificationPreferences) async throws {
        let body = try FollowJSON.encoder.encode(preferences)
        try await send(request("PUT", "v1/preferences", body: body, authorized: true))
    }

    public func registerActivity(_ activity: ActivityRegistration) async throws {
        let body = try FollowJSON.encoder.encode(activity)
        try await send(request("POST", "v1/activities", body: body, authorized: true))
    }

    public func endActivity(gameId: String) async throws {
        guard !gameId.isEmpty else { throw FollowServerError.rejected("activity has no game id") }
        try await send(request("DELETE", "v1/activities/\(Self.escape(gameId))", authorized: true))
    }

    public func health() async throws -> ServerHealth {
        try await send(request("GET", "v1/health", authorized: false), as: ServerHealth.self)
    }

    public func alertCount() async throws -> AlertCount? {
        try await send(request("GET", "v1/alerts/count", authorized: true), as: AlertCount.self)
    }

    /// Path-component escaping: the RFC 3986 unreserved set, so a `/` or a `..` becomes `%2F` or
    /// `%2E%2E` instead of another path segment. Lichess ids are `[A-Za-z0-9]{8}` and the
    /// server's follow ids are `f_<base32>`, so nothing here is escaped in practice; the point is
    /// that an id from somewhere else cannot walk the path.
    private static let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    private static func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: unreserved) ?? component
    }
}
