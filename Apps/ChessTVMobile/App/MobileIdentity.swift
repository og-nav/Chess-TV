// Who the phone app says it is on the network, and which APNs environment it was built for.
//
// The same shape as Apps/ChessTV/App/AppIdentity.swift: one contact, one version, configured
// into the packages before any client exists.
import Foundation
import ImageryKit
import LichessKit

enum MobileIdentity {

    /// The project mailbox. Lichess and the Wikimedia API both ask for a way to reach whoever
    /// runs the client.
    static let contact = "zzzlabshq@gmail.com"

    static var version: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return "0.1" }
        return value
    }

    static var build: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
    }

    /// `ChessTV/<version> (<contact>)`, the one identity every outgoing request sends.
    static var userAgent: String { "ChessTV/\(version) (\(contact))" }

    /// What `DeviceRegistration.appVersion` carries: enough to tell two TestFlight builds apart.
    static var appVersion: String { "\(version) (\(build))" }

    /// `"ios"`. The watch app sends `"watchos"` through the same endpoint.
    static let platform = "ios"

    /// Which APNs environment this build's push token belongs to. A Debug build is signed with
    /// the development entitlement and its tokens only work against the sandbox; getting this
    /// wrong is a silent `BadDeviceToken` on every push, so it is decided at compile time
    /// rather than guessed on the server.
    static var apnsEnvironment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    /// Called once from the app's `init`, before any client or `URLSession` exists.
    static func configurePackages() {
        let agent = userAgent
        LichessConfig.configure(userAgent: agent)
        ImageryURLSession.configure(userAgent: agent)
        mobileLog.notice("Identifying as \(agent, privacy: .public)")
    }
}
