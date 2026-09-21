// Who this app says it is on the network. Lichess and the Wikimedia API both ask requests to
// identify the app and give a way to reach whoever runs it, so the string is built once here
// and handed to the packages at launch.
import Foundation
import ImageryKit
import LichessKit

enum AppIdentity {

    /// The project mailbox. It is the single place either package's `User-Agent` gets a
    /// contact from.
    static let contact = "zzzlabshq@gmail.com"

    /// `CFBundleShortVersionString`, so a released build says what it is without a second place
    /// to bump. The fallback only matters in a context with no Info.plist.
    static var version: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return "0.1" }
        return value
    }

    /// `ChessTV/<version> (<contact>)` — the one identity every outgoing request sends.
    static var userAgent: String { "ChessTV/\(version) (\(contact))" }

    /// Called once from `ChessTVApp.init`, before `AppModel` exists and so before any client or
    /// `URLSession` in either package has been built. Both packages read the value at request
    /// time anyway, so a later session still sends this.
    static func configurePackages() {
        let agent = userAgent
        LichessConfig.configure(userAgent: agent)
        ImageryURLSession.configure(userAgent: agent)
        appLog.notice("Identifying as \(agent, privacy: .public)")
    }
}
