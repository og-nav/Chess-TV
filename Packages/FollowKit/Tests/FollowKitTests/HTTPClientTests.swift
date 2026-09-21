import Foundation
import Testing
@testable import FollowKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Records what the client sent and answers with what the test told it to. No socket, so these
/// run in any sandbox.
actor StubTransport: FollowHTTPTransport {
    struct Exchange: Sendable {
        var status: Int
        var body: Data
    }

    private var queue: [Exchange]
    private(set) var sent: [URLRequest] = []

    init(_ queue: [Exchange]) { self.queue = queue }

    static func json(_ value: some Encodable, status: Int = 200) -> Exchange {
        Exchange(status: status, body: (try? FollowJSON.encoder.encode(value)) ?? Data())
    }

    static func empty(_ status: Int = 204) -> Exchange { Exchange(status: status, body: Data()) }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        sent.append(request)
        guard !queue.isEmpty else { throw FollowServerError.unavailable("stub ran dry") }
        let exchange = queue.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: exchange.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (exchange.body, response)
    }

    func lastRequest() -> URLRequest? { sent.last }
    func requestCount() -> Int { sent.count }
}

@Suite("HTTP follow client")
struct HTTPClientTests {

    private let base = URL(string: "https://follow.example.com")!

    @Test("A base URL that is not https is refused before any request")
    func insecureBase() {
        let store = InMemoryCredentialStore()
        #expect(throws: FollowServerError.insecureBaseURL("http")) {
            try HTTPFollowServerClient(baseURL: URL(string: "http://follow.example.com")!, credentials: store)
        }
        // A laptop during development is allowed; a host that merely looks like one is not.
        #expect(HTTPFollowServerClient.isSecure(URL(string: "http://localhost:8080")!))
        #expect(HTTPFollowServerClient.isSecure(URL(string: "http://127.0.0.1:8080")!))
        #expect(HTTPFollowServerClient.isSecure(URL(string: "http://localhost.evil.example")!) == false)
        #expect(HTTPFollowServerClient.isSecure(URL(string: "ftp://follow.example.com")!) == false)
    }

    @Test("Registering stores the credential and sends no bearer token")
    func registration() async throws {
        let credential = DeviceCredential(deviceId: "dev_1", installToken: "tok_secret")
        let transport = StubTransport([StubTransport.json(credential)])
        let store = InMemoryCredentialStore()
        let client = try HTTPFollowServerClient(baseURL: base, credentials: store, transport: transport)

        let result = try await client.register(DeviceRegistration(apnsToken: String(repeating: "a", count: 64), appVersion: "1.0"))
        #expect(result == credential)
        #expect(try await store.load() == credential)

        let request = try #require(await transport.lastRequest())
        #expect(request.url?.absoluteString == "https://follow.example.com/v1/devices")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("ChessTV/") == true)
    }

    @Test("A credential with an empty token is a malformed response, not a registration")
    func emptyCredential() async throws {
        let transport = StubTransport([StubTransport.json(DeviceCredential(deviceId: "dev_1", installToken: ""))])
        let store = InMemoryCredentialStore()
        let client = try HTTPFollowServerClient(baseURL: base, credentials: store, transport: transport)
        await #expect(throws: FollowServerError.malformedResponse("empty credential")) {
            try await client.register(DeviceRegistration())
        }
        #expect(try await store.load() == nil)
    }

    @Test("Every other call carries the bearer token")
    func bearer() async throws {
        let store = InMemoryCredentialStore(DeviceCredential(deviceId: "dev_1", installToken: "tok_secret"))
        let follow = Follow(id: "f_1", target: .tournament(tourId: "L2ydImaD"))
        let transport = StubTransport([StubTransport.json([follow])])
        let client = try HTTPFollowServerClient(baseURL: base, credentials: store, transport: transport)

        let follows = try await client.follows()
        #expect(follows.count == 1)
        #expect(follows[0].target == .tournament(tourId: "L2ydImaD"))

        let request = try #require(await transport.lastRequest())
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok_secret")
    }

    @Test("A call before registration fails locally rather than over the network")
    func notRegistered() async throws {
        let transport = StubTransport([])
        let client = try HTTPFollowServerClient(baseURL: base, credentials: InMemoryCredentialStore(), transport: transport)
        await #expect(throws: FollowServerError.notRegistered) { try await client.follows() }
        #expect(await transport.requestCount() == 0)
    }

    @Test("Status codes map to the cases the UI knows how to show")
    func statusMapping() async throws {
        let store = InMemoryCredentialStore(DeviceCredential(deviceId: "d", installToken: "t"))
        func client(_ status: Int, body: Data = Data()) throws -> (HTTPFollowServerClient, StubTransport) {
            let transport = StubTransport([StubTransport.Exchange(status: status, body: body)])
            return (try HTTPFollowServerClient(baseURL: base, credentials: store, transport: transport), transport)
        }

        var (subject, _) = try client(401)
        await #expect(throws: FollowServerError.unauthorized) { try await subject.follows() }

        (subject, _) = try client(404)
        await #expect(throws: FollowServerError.notFound) { try await subject.remove(id: "f_1") }

        (subject, _) = try client(422, body: Data(#"{"error":"unknown target"}"#.utf8))
        await #expect(throws: FollowServerError.rejected("unknown target")) { try await subject.add(Follow(target: .player(fideId: 1))) }

        (subject, _) = try client(503)
        await #expect(throws: FollowServerError.unavailable("HTTP 503")) { try await subject.preferences() }
    }

    @Test("A patch sends only the alerts, to the follow's own path")
    func patchShape() async throws {
        var follow = Follow(id: "f_1", target: .player(fideId: 1503014))
        follow.alerts.game = [.start, .move, .end]
        let transport = StubTransport([StubTransport.json(follow)])
        let store = InMemoryCredentialStore(DeviceCredential(deviceId: "d", installToken: "t"))
        let client = try HTTPFollowServerClient(baseURL: base, credentials: store, transport: transport)

        _ = try await client.update(follow)
        let request = try #require(await transport.lastRequest())
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path == "/v1/follows/f_1")
        let body = try #require(request.httpBody)
        let alerts = try FollowJSON.decoder.decode(FollowAlerts.self, from: body)
        #expect(alerts.game == [.start, .move, .end])
        #expect(String(decoding: body, as: UTF8.self).contains("\"id\"") == false)
    }

    @Test("An id with a slash in it cannot walk out of its path")
    func pathEscaping() async throws {
        let transport = StubTransport([StubTransport.empty()])
        let store = InMemoryCredentialStore(DeviceCredential(deviceId: "d", installToken: "t"))
        let client = try HTTPFollowServerClient(baseURL: base, credentials: store, transport: transport)
        try await client.remove(id: "../devices/me")
        let request = try #require(await transport.lastRequest())
        #expect(request.url?.absoluteString.contains("/v1/follows/") == true)
        #expect(request.url?.absoluteString.contains("../") == false)
    }

    @Test("Health needs no token")
    func health() async throws {
        let transport = StubTransport([StubTransport.json(ServerHealth(ok: true, roundsWatched: 3, roundsScheduled: 2))])
        let client = try HTTPFollowServerClient(baseURL: base, credentials: InMemoryCredentialStore(), transport: transport)
        let health = try await client.health()
        #expect(health.roundsWatched == 3)
        #expect(await transport.lastRequest()?.value(forHTTPHeaderField: "Authorization") == nil)
    }
}
