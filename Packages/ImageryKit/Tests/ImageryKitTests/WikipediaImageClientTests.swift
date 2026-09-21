import Foundation
import Testing
@testable import ImageryKit

/// `WikipediaImageClient`, driven by the loopback server with bodies shaped like the ones
/// `en.wikipedia.org/api/rest_v1/page/summary/…` returned on 2026-09-18. No test touches
/// the internet.
@Suite("Wikipedia lead images")
struct WikipediaImageClientTests {

    private static func summary(
        title: String,
        type: String = "standard",
        original: String? = "https://upload.wikimedia.org/wikipedia/commons/8/8c/Registan.jpg",
        thumbnail: String? = "https://thumb.wikimedia.org/wikipedia/commons/thumb/8/8c/Registan.jpg/330px-Registan.jpg"
    ) -> String {
        var fields = ["\"type\":\"\(type)\"", "\"title\":\"\(title)\""]
        if let original { fields.append("\"originalimage\":{\"source\":\"\(original)\",\"width\":3840,\"height\":2160}") }
        if let thumbnail { fields.append("\"thumbnail\":{\"source\":\"\(thumbnail)\",\"width\":330,\"height\":186}") }
        fields.append("\"content_urls\":{\"desktop\":{\"page\":\"https://en.wikipedia.org/wiki/\(title)\"}}")
        return "{" + fields.joined(separator: ",") + "}"
    }

    private static func client(_ server: LoopbackHTTPServer) -> WikipediaImageClient {
        WikipediaImageClient(session: ImageryURLSession.make(), baseURL: server.baseURL)
    }

    // MARK: - Candidate titles

    @Test(
        "A location string is reduced to the city and the country",
        arguments: [
            ("Samarkand, Uzbekistan", ["Samarkand", "Uzbekistan"]),
            ("Rosario, Santa Fe - Argentina", ["Rosario", "Argentina"]),
            ("Netherlands", ["Netherlands"]),
            ("  Wijk aan Zee , Netherlands ", ["Wijk aan Zee", "Netherlands"]),
            ("Saint-Quentin, France", ["Saint-Quentin", "France"]),     // a bare hyphen is part of the name
            ("Guinea-Bissau", ["Guinea-Bissau"]),
            ("", []),
        ]
    )
    func splitsLocations(place: String, expected: [String]) {
        #expect(WikipediaImageClient.candidateTitles(for: place) == expected)
    }

    @Test("Titles are encoded the way MediaWiki writes them")
    func encodesTitles() {
        #expect(WikipediaImageClient.encodedTitle("Wijk aan Zee") == "Wijk_aan_Zee")
        #expect(WikipediaImageClient.encodedTitle("Zürich") == "Z%C3%BCrich")
        // A slash in a title must not become a path separator.
        #expect(WikipediaImageClient.encodedTitle("AC/DC") == "AC%2FDC")
    }

    // MARK: - Lookups

    @Test("The city's summary supplies the image and the attribution")
    func findsTheCity() async throws {
        let server = try LoopbackHTTPServer(response: .init(json: Self.summary(title: "Samarkand")))
        defer { server.stop() }
        let client = Self.client(server)

        let found = try await withTimeout(.seconds(10), "lookup") { await client.image(forPlace: "Samarkand, Uzbekistan") }
        let image = try #require(found)
        #expect(image.pageTitle == "Samarkand")
        #expect(image.imageURL.absoluteString.hasSuffix("Registan.jpg"))
        #expect(image.thumbnailURL?.absoluteString.contains("330px") == true)
        #expect(image.attribution == "Image: Wikipedia — Samarkand")
        #expect(image.pageURL?.absoluteString == "https://en.wikipedia.org/wiki/Samarkand")

        // The city was asked for, and once it answered the country was never asked.
        let head = try #require(server.requests.first)
        #expect(head.hasPrefix("GET /api/rest_v1/page/summary/Samarkand HTTP/1.1"))
        #expect(head.contains("User-Agent: ChessTV/"))   // the exact value is UserAgentTests' business
        #expect(server.requestCount == 1)
    }

    @Test("With no original, the thumbnail is used")
    func fallsBackToTheThumbnail() async throws {
        let server = try LoopbackHTTPServer(response: .init(json: Self.summary(title: "Praia", original: nil)))
        defer { server.stop() }
        let image = try #require(await Self.client(server).image(forPlace: "Praia, Cape Verde"))
        #expect(image.imageURL.absoluteString.contains("330px"))
        #expect(image.imageURL == image.thumbnailURL)
    }

    @Test("A disambiguation page is rejected and the country is tried instead")
    func skipsDisambiguationAndFallsBackToTheCountry() async throws {
        let server = try LoopbackHTTPServer(router: { path, _ in
            path.hasSuffix("/Rosario")
                ? .init(json: Self.summary(title: "Rosario", type: "disambiguation"))
                : .init(json: Self.summary(title: "Argentina"))
        })
        defer { server.stop() }

        let image = try #require(await Self.client(server).image(forPlace: "Rosario, Santa Fe - Argentina"))
        #expect(image.pageTitle == "Argentina")
        #expect(server.requestCount == 2)
        #expect(server.requests.contains { $0.contains("summary/Rosario ") })
        #expect(server.requests.contains { $0.contains("summary/Argentina ") })
    }

    @Test("A page with no image at all falls through to the country")
    func skipsImagelessPages() async throws {
        let server = try LoopbackHTTPServer(router: { path, _ in
            path.hasSuffix("/Nowhereville")
                ? .init(json: Self.summary(title: "Nowhereville", original: nil, thumbnail: nil))
                : .init(json: Self.summary(title: "Norway"))
        })
        defer { server.stop() }
        let image = try #require(await Self.client(server).image(forPlace: "Nowhereville, Norway"))
        #expect(image.pageTitle == "Norway")
    }

    @Test("A place with no article anywhere is nil, and remembered as nil")
    func memoizesNegatives() async throws {
        let server = try LoopbackHTTPServer(response: .init(json: "{\"title\":\"Not found\"}", statusCode: 404))
        defer { server.stop() }
        let client = Self.client(server)

        #expect(await client.image(forPlace: "Qqqq, Zzzz") == nil)
        #expect(await client.isCached(place: "Qqqq, Zzzz"))
        #expect(await client.image(forPlace: "Qqqq, Zzzz") == nil)
        // Two candidates on the first call, nothing on the second.
        #expect(server.requestCount == 2)
    }

    @Test("A hit is remembered, so a shelf refresh does not re-query")
    func memoizesHits() async throws {
        let server = try LoopbackHTTPServer(response: .init(json: Self.summary(title: "Samarkand")))
        defer { server.stop() }
        let client = Self.client(server)

        let first = await client.image(forPlace: "Samarkand, Uzbekistan")
        let second = await client.image(forPlace: "Samarkand, Uzbekistan")
        #expect(first == second)
        #expect(first != nil)
        #expect(server.requestCount == 1)
    }

    @Test("A throttle is not remembered: it says nothing about the place")
    func doesNotMemoizeTransientFailures() async throws {
        let body = Self.summary(title: "Samarkand")
        let server = try LoopbackHTTPServer(router: { _, index in
            index == 0 ? .init(json: "{}", statusCode: 429) : .init(json: body)
        })
        defer { server.stop() }
        let client = Self.client(server)

        // The city throttles, the country (second request) throttles too on this router's first
        // index per path — so the whole lookup is inconclusive and nothing is cached.
        #expect(await client.image(forPlace: "Samarkand, Uzbekistan") == nil)
        #expect(await client.isCached(place: "Samarkand, Uzbekistan") == false)

        let retried = try #require(await client.image(forPlace: "Samarkand, Uzbekistan"))
        #expect(retried.pageTitle == "Samarkand")
    }

    @Test("Concurrent lookups of one place share a single pair of requests")
    func coalescesConcurrentLookups() async throws {
        let server = try LoopbackHTTPServer(response: .init(json: Self.summary(title: "Samarkand"), delay: 0.3))
        defer { server.stop() }
        let client = Self.client(server)

        let titles = try await withTimeout(.seconds(20), "concurrent lookups") {
            await withTaskGroup(of: String?.self) { group in
                for _ in 0..<5 { group.addTask { await client.image(forPlace: "Samarkand, Uzbekistan")?.pageTitle } }
                var collected: [String?] = []
                for await title in group { collected.append(title) }
                return collected
            }
        }
        #expect(titles == Array(repeating: "Samarkand", count: 5))
        #expect(server.requestCount == 1)
    }

    @Test("An empty location asks for nothing")
    func ignoresEmptyPlaces() async throws {
        let server = try LoopbackHTTPServer(response: .init(json: Self.summary(title: "Anything")))
        defer { server.stop() }
        let client = Self.client(server)
        #expect(await client.image(forPlace: "") == nil)
        #expect(await client.image(forPlace: "   ") == nil)
        #expect(server.requestCount == 0)
    }
}
