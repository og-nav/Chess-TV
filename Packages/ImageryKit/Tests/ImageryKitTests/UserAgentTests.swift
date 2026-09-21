import Foundation
import Testing
@testable import ImageryKit

/// The identifying `User-Agent` the Wikimedia API and Lichess's image CDN ask for. The app owns
/// the string and configures the package with it at launch.
///
/// Serialized, and it restores the default when it is done: the value is process-wide, and
/// other suites only assert that a request head starts with `ChessTV/`.
@Suite("User-Agent", .serialized)
struct UserAgentTests {

    @Test("Unconfigured, the package still sends a valid identity")
    func defaultIdentity() {
        #expect(ImageryURLSession.defaultUserAgent == "ChessTV/0.1 (zzzlabshq@gmail.com)")
        #expect(ImageryURLSession.userAgent.hasPrefix("ChessTV/"))
    }

    @Test("The configured value is what a request carries, even on a session built before it")
    func configuredValueReachesTheWire() async throws {
        let server = try LoopbackHTTPServer(response: .init(json: "{}"))
        defer { server.stop() }

        // Built first, with the default in its configuration: the per-request header must win.
        let session = ImageryURLSession.make()

        let configured = "ChessTV/9.9 (tests@example.invalid)"
        ImageryURLSession.configure(userAgent: configured)
        defer { ImageryURLSession.configure(userAgent: ImageryURLSession.defaultUserAgent) }
        #expect(ImageryURLSession.userAgent == configured)

        _ = try await session.data(for: ImageryURLSession.request(server.baseURL.appendingPathComponent("api/rest_v1/page/summary/Test")))

        let head = try #require(server.requests.first)
        #expect(head.contains("User-Agent: \(configured)"))
        #expect(!head.contains(ImageryURLSession.defaultUserAgent))
    }

    @Test("An empty string cannot strip the header")
    func emptyIsIgnored() {
        let before = ImageryURLSession.userAgent
        ImageryURLSession.configure(userAgent: "   ")
        #expect(ImageryURLSession.userAgent == before)
    }
}
