import Foundation
import Testing
@testable import LichessKit

/// `FIDEPlayerClient` decoding and caching, driven by recordings taken from the live API on
/// 2026-09-18 and served over the loopback HTTP server. No test touches the network.
@Suite("FIDE players")
struct FIDEPlayerTests {

    /// Fixtures live alongside the other recordings but are loaded here rather than added to the
    /// shared `Fixture` enum, which is another agent's file this work must not touch.
    private static func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "missing fixture \(name).json"
        )
        return try Data(contentsOf: url)
    }

    private static func client(_ server: LoopbackHTTPServer) -> FIDEPlayerClient {
        FIDEPlayerClient(session: LichessURLSession.make(streaming: false), baseURL: server.baseURL)
    }

    // MARK: - Decoding

    @Test("A player with a portrait decodes every field")
    func decodesPlayerWithPhoto() throws {
        let player = try FIDEPlayerClient.decode(Self.fixture("fide-player"))
        #expect(player.id == 1_503_014)
        #expect(player.name == "Carlsen, Magnus")
        #expect(player.federation == "NOR")
        #expect(player.title == "GM")
        #expect(player.year == 1990)
        #expect(player.standard == 2823)
        #expect(player.rapid == 2803)
        #expect(player.blitz == 2860)
        #expect(player.photoCredit == "Brigham Aldrich")

        // The CDN serves WebP, at the exact pixel size asked for in the query.
        let medium = try #require(player.photoMediumURL)
        #expect(medium.host() == "image.lichess1.org")
        #expect(medium.query()?.contains("fmt=webp") == true)
        #expect(medium.query()?.contains("w=500") == true)
        #expect(try #require(player.photoSmallURL).query()?.contains("w=100") == true)
    }

    @Test("A player with no portrait, title or ratings decodes with those fields nil")
    func decodesPlayerWithoutPhoto() throws {
        let player = try FIDEPlayerClient.decode(Self.fixture("fide-player-no-photo"))
        #expect(player.id == 2_020_106)
        #expect(player.name == "Lynch, Mark O")
        #expect(player.federation == "USA")
        #expect(player.year == 1957)
        #expect(player.title == nil)
        #expect(player.standard == nil)
        #expect(player.rapid == nil)
        #expect(player.blitz == nil)
        #expect(player.photoSmallURL == nil)
        #expect(player.photoMediumURL == nil)
        #expect(player.photoCredit == nil)
    }

    // MARK: - Caching

    @Test("A second lookup of the same id is answered from memory")
    func memoizesHits() async throws {
        let body = try Self.fixture("fide-player")
        let server = try LoopbackHTTPServer(steps: [.init(chunks: [body], chunkDelay: 0, ending: .graceful)])
        defer { server.stop() }
        let client = Self.client(server)

        let first = try await withTimeout(.seconds(10), "first lookup") { try await client.player(fideId: 1_503_014) }
        let second = try await withTimeout(.seconds(10), "second lookup") { try await client.player(fideId: 1_503_014) }
        #expect(first == second)
        #expect(try #require(first).name == "Carlsen, Magnus")
        #expect(server.connectionCount == 1)
        #expect(await client.isCached(fideId: 1_503_014))

        let head = try #require(server.requests.first)
        #expect(head.hasPrefix("GET /api/fide/player/1503014 HTTP/1.1"))
        #expect(head.contains("User-Agent: ChessTV/"))   // the exact value is UserAgentTests' business
    }

    @Test("A 404 becomes nil and is remembered, so the id is not looked up again")
    func memoizesMisses() async throws {
        let server = try LoopbackHTTPServer(steps: [
            .init(statusCode: 404, chunks: [Data("not found".utf8)], chunkDelay: 0, ending: .graceful)
        ])
        defer { server.stop() }
        let client = Self.client(server)

        let first = try await withTimeout(.seconds(10), "missing player") { try await client.player(fideId: 42) }
        let second = try await withTimeout(.seconds(10), "missing player again") { try await client.player(fideId: 42) }
        #expect(first == nil)
        #expect(second == nil)
        #expect(await client.isCached(fideId: 42))
        #expect(server.connectionCount == 1)
    }

    @Test("A rate limit is raised to the caller and not cached")
    func doesNotCacheRateLimits() async throws {
        let body = try Self.fixture("fide-player")
        let server = try LoopbackHTTPServer(router: { _, index in
            index == 0
                ? .init(statusCode: 429, headers: ["Retry-After": "7"], chunks: [Data()], chunkDelay: 0)
                : .init(chunks: [body], chunkDelay: 0)
        })
        defer { server.stop() }
        let client = Self.client(server)

        await #expect(throws: LichessError.rateLimited(retryAfter: .seconds(7))) {
            _ = try await client.player(fideId: 1_503_014)
        }
        #expect(await client.isCached(fideId: 1_503_014) == false)

        let retried = try await withTimeout(.seconds(10), "retry") { try await client.player(fideId: 1_503_014) }
        #expect(try #require(retried).name == "Carlsen, Magnus")
        #expect(server.connectionCount == 2)
    }

    @Test("Concurrent lookups of one id share a single request")
    func coalescesConcurrentLookups() async throws {
        let body = try Self.fixture("fide-player")
        // The chunk delay holds the response open past the terminating chunk, so the second
        // caller is guaranteed to arrive while the first request is still in flight.
        let server = try LoopbackHTTPServer(steps: [.init(chunks: [body], chunkDelay: 0.4, ending: .graceful)])
        defer { server.stop() }
        let client = Self.client(server)

        let results = try await withTimeout(.seconds(20), "concurrent lookups") {
            try await withThrowingTaskGroup(of: FIDEPlayer?.self) { group in
                for _ in 0..<2 { group.addTask { try await client.player(fideId: 1_503_014) } }
                var collected: [FIDEPlayer?] = []
                for try await result in group { collected.append(result) }
                return collected
            }
        }
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0?.name == "Carlsen, Magnus" })
        #expect(server.connectionCount == 1)
    }

    @Test("fideId 0 means the player has no FIDE id, so nothing is requested")
    func zeroIsNotLookedUp() async throws {
        let server = try LoopbackHTTPServer(steps: [.init(chunks: [Data("{}".utf8)], chunkDelay: 0)])
        defer { server.stop() }
        let client = Self.client(server)

        #expect(try await client.player(fideId: 0) == nil)
        #expect(try await client.player(fideId: -1) == nil)
        #expect(await client.isCached(fideId: 0))
        #expect(server.connectionCount == 0)
    }
}
