// Which Keychain the install token lives in.
//
// FollowKit owns the Keychain code; this file owns the one decision the app has to make about
// it, and says why, because getting it wrong is silent.
//
// **No access group.** An access group would let the notification extensions and the watch read
// the token, and neither needs to: the extensions render a push that has already been delivered
// and never call the server, and the watch is handed its own copy of the credential over
// WatchConnectivity, into its own Keychain. A `keychain-access-groups` entitlement is also not
// the app group — it is prefixed with the signing team — so borrowing the app group identifier
// for it produces an entitlement that silently matches nothing.
import Foundation
import FollowKit

enum AppCredentialStore {

    /// The service and account the token is filed under. Stable across builds: changing either
    /// would orphan the token and register this phone a second time.
    static let service = "com.navin.chesstv.follow"
    static let account = "installToken"

    static func make() -> any FollowCredentialStore {
        KeychainCredentialStore(service: service, account: account)
    }
}

/// A credential store that knows *which server* minted what it holds.
///
/// `HTTPFollowServerClient` reads the store on every call, which is what lets a rotated token be
/// picked up without rebuilding the client — and is also why clearing the Keychain after a server
/// change is not enough on its own. The clear is asynchronous; a request made in the window
/// between pointing the app at a new host and that clear landing would carry the *previous*
/// host's bearer token to an address the user has only just typed in. Handing a stranger a
/// credential is the one failure here that is not merely inconvenient.
///
/// So the scope is changed synchronously, on the main actor, before any client for the new host
/// exists, and a credential filed under a different scope is not handed out at all. The lock is
/// what makes "synchronously" possible: an actor's setter would be another await, and the window
/// would still be open.
final class ScopedCredentialStore: FollowCredentialStore, @unchecked Sendable {   // @unchecked: every field is behind `lock`

    /// Which server the token in the Keychain belongs to, as `ServerURL.identity(of:)` spells it.
    /// In defaults rather than the Keychain because it is not a secret and because the Keychain
    /// survives an app delete, which would otherwise resurrect a scope with no token.
    static let scopeKey = "installTokenServerIdentity"

    private let lock = NSLock()
    private let inner: any FollowCredentialStore
    private let defaults: UserDefaults
    private var scope: String
    private var epoch = UUID()

    init(wrapping inner: any FollowCredentialStore, scope: String, defaults: UserDefaults = .standard) {
        self.inner = inner
        self.defaults = defaults
        self.scope = scope
    }

    /// A client retains this immutable epoch, so an old request can never read a new identity.
    /// Registration returns the identity to DeviceRegistrar; only that owner persists it after
    /// checking its generation. HTTPFollowServerClient's automatic save is deliberately a no-op.
    func clientStore() -> any FollowCredentialStore {
        BoundReader(owner: self, epoch: lock.withLock { epoch })
    }

    func setScope(_ scope: String) {
        lock.withLock {
            self.scope = scope
            epoch = UUID()
            defaults.removeObject(forKey: Self.scopeKey)
        }
    }

    func invalidateIdentity() {
        lock.withLock {
            epoch = UUID()
            defaults.removeObject(forKey: Self.scopeKey)
        }
    }

    func load() async throws -> DeviceCredential? {
        try await load(epoch: lock.withLock { epoch })
    }

    private func load(epoch expected: UUID) async throws -> DeviceCredential? {
        guard lock.withLock({ expected == epoch && defaults.string(forKey: Self.scopeKey) == scope }) else { return nil }
        let credential = try await inner.load()
        guard lock.withLock({ expected == epoch && defaults.string(forKey: Self.scopeKey) == scope }) else { return nil }
        return credential
    }

    /// Registrar serializes writes and resets; a scope change during an await never labels an
    /// old credential as belonging to the new host.
    func save(_ credential: DeviceCredential) async throws {
        let stamp = lock.withLock { epoch }
        try await inner.save(credential)
        lock.withLock {
            if stamp == epoch { defaults.set(scope, forKey: Self.scopeKey) }
        }
    }

    func clear() async throws {
        lock.withLock { defaults.removeObject(forKey: Self.scopeKey) }
        try await inner.clear()
    }

    private struct BoundReader: FollowCredentialStore {
        let owner: ScopedCredentialStore
        let epoch: UUID
        func load() async throws -> DeviceCredential? { try await owner.load(epoch: epoch) }
        func save(_ credential: DeviceCredential) async throws {}
        func clear() async throws {}
    }
}
