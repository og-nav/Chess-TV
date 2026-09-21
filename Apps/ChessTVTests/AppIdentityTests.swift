import Testing
import Foundation
import ImageryKit
import LichessKit
@testable import ChessTV

/// The one `User-Agent` the app sends. Lichess and the Wikimedia API both want the app, its
/// version and a way to reach whoever runs it, so the shape matters as much as the value: when
/// the contact changes, only `AppIdentity.contact` should have to.
@Suite("The app's network identity")
struct AppIdentityTests {

    @Test("The User-Agent is ChessTV/<version> (<contact>)")
    func shape() throws {
        let agent = AppIdentity.userAgent
        #expect(agent == "ChessTV/\(AppIdentity.version) (\(AppIdentity.contact))")

        let pattern = try Regex(#"^ChessTV/[0-9]+(\.[0-9]+)* \([^()]+@[^()]+\)$"#)
        #expect(agent.wholeMatch(of: pattern) != nil, "\(agent) does not identify the app and a contact")
    }

    @Test("The version comes from the bundle, not from a second hard-coded copy")
    func versionFromTheBundle() {
        let bundled = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        // Hosted by the app, so this is the app's Info.plist; the fallback only covers a
        // context that has none.
        #expect(AppIdentity.version == (bundled ?? "0.1"))
        #expect(!AppIdentity.version.isEmpty)
    }

    @Test("Configuring the packages gives both of them that exact string")
    func configuresBothPackages() {
        AppIdentity.configurePackages()
        #expect(LichessConfig.userAgent == AppIdentity.userAgent)
        #expect(ImageryURLSession.userAgent == AppIdentity.userAgent)
    }
}
