// The install token's home on an Apple device.
//
// Guarded by `canImport(Security)` so that the server, which builds this package on Linux, gets a
// package that compiles rather than a package it has to fork. The server never stores a
// credential; it mints them.

#if canImport(Security)

import Foundation
import Security

/// A generic-password item holding the `DeviceCredential`.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: the app has to be able to read the token in
/// the background (the notification extension asks the server for nothing, but the app does resync
/// on a push), and the token must not travel to another device in a backup — the APNs token it is
/// paired with would not be valid there anyway.
///
/// Pass `accessGroup` (`group.com.navin.chesstv`) to share the credential with the extensions and
/// the watch app through the App Group's Keychain group; the default is the app's own group.
public struct KeychainCredentialStore: FollowCredentialStore {

    public enum KeychainError: Error, Sendable, Equatable {
        /// An `OSStatus` the store did not expect. The number is included; the token never is.
        case status(Int32)
        /// The item was there but was not a credential this build can read.
        case malformedItem
    }

    private let service: String
    private let account: String
    private let accessGroup: String?

    public init(service: String = "com.navin.chesstv.follow", account: String = "installToken", accessGroup: String? = nil) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public func load() throws -> DeviceCredential? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.malformedItem }
            guard let credential = try? FollowJSON.decoder.decode(DeviceCredential.self, from: data) else {
                throw KeychainError.malformedItem
            }
            return credential
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    public func save(_ credential: DeviceCredential) throws {
        let data = try FollowJSON.encoder.encode(credential)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError.status(status) }

        var insert = baseQuery
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError.status(added) }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}

#endif
