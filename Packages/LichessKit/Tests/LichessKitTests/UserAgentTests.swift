import Foundation
import Testing
@testable import LichessKit

/// The `User-Agent` the Lichess API policy asks for. The app owns the string and configures the
/// package with it at launch; this suite checks the default and that the configured value is
/// what actually goes out on the wire.
///
/// Serialized, and it restores the default when it is done: the value is process-wide, and
/// other suites only assert that a request head starts with `ChessTV/`.
@Suite("User-Agent", .serialized)
struct UserAgentTests {

    @Test("Unconfigured, the package still sends a valid identity")
    func defaultIdentity() {
        #expect(LichessConfig.defaultUserAgent == "ChessTV/0.1 (zzzlabshq@gmail.com)")
        #expect(LichessConfig.userAgent.hasPrefix("ChessTV/"))
    }

    @Test("The configured value is what a request carries, even on a session built before it")
    func configuredValueReachesTheWire() async throws {
        let server = try LoopbackHTTPServer(steps: [
            .init(chunks: [Data("{}".utf8)], chunkDelay: 0, ending: .graceful)
        ])
        defer { server.stop() }

        // Built first, with the default in its configuration: the per-request header must win.
        let session = LichessURLSession.make(streaming: false)

        let configured = "ChessTV/9.9 (tests@example.invalid)"
        LichessConfig.configure(userAgent: configured)
        defer { LichessConfig.configure(userAgent: LichessConfig.defaultUserAgent) }
        #expect(LichessConfig.userAgent == configured)

        _ = try await session.data(for: LichessURLSession.request(server.baseURL.appendingPathComponent("api/tv/channels")))

        let head = try #require(server.requests.first)
        #expect(head.contains("User-Agent: \(configured)"))
        #expect(!head.contains(LichessConfig.defaultUserAgent))
    }

    @Test("An empty string cannot strip the header")
    func emptyIsIgnored() {
        let before = LichessConfig.userAgent
        LichessConfig.configure(userAgent: "   ")
        #expect(LichessConfig.userAgent == before)
    }
}
