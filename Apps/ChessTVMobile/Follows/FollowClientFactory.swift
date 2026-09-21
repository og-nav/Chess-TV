// Building the follow-server client.
//
// One function, so FollowKit's HTTP client is constructed in exactly one place. The client reads
// the credential store on every call, so it is usable before `POST /v1/devices` has minted a
// token and picks a rotated one up without being rebuilt.
import Foundation
import FollowKit

enum FollowClientFactory {

    /// - Returns: nil when no server is configured, which is the app's honest offline mode, and
    ///   nil when the address is one FollowKit refuses to send a bearer token to. The Settings
    ///   field rejects those before they are ever stored, so this is the belt to that's braces.
    static func make(baseURL: URL?, credentials: any FollowCredentialStore) -> (any FollowServerClient)? {
        guard let baseURL else { return nil }
        #if DEBUG
        // `-uiFixtures`: the in-memory server, so the follow screens work with nothing deployed.
        if FixtureMode.isActive { return FixtureFollowServer.shared }
        #endif
        do {
            return try HTTPFollowServerClient(
                baseURL: baseURL,
                credentials: credentials,
                userAgent: MobileIdentity.userAgent
            )
        } catch {
            mobileLog.error("Refusing to talk to \(ServerURL.displayName(for: baseURL), privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
