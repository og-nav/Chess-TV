// The bearer credential a device authenticates with.
//
// There are no accounts, so this token *is* the identity: anything holding it can read and change
// that device's follows. Two properties matter and are both here.
//
//   1. It is unguessable. 32 bytes from the system CSPRNG, base64url — 256 bits, which is not
//      enumerable by anyone, ever. Nothing about it is derived from the device, the APNs token or
//      the time, so knowing one token says nothing about another.
//   2. The server does not keep it. Only SHA-256 of it is stored, so a stolen database backup
//      does not let anyone act as a device. SHA-256 rather than a password hash on purpose: the
//      input is 256 random bits, not a password, so there is nothing for a slow hash to defend
//      against, and the lookup is on the hot path of every request.

import Crypto
import Foundation

public enum InstallToken {

    /// A fresh install token: 32 random bytes, base64url, no padding.
    public static func generate() -> String {
        base64URL(randomBytes(32))
    }

    /// A short opaque id for a row (`d_…`, `f_…`): 10 random bytes, base64url. Not a secret —
    /// the device id appears in logs — but random so it carries no ordering or count.
    public static func identifier() -> String {
        base64URL(randomBytes(10))
    }

    /// Lowercase hex SHA-256. The only form of a token the database ever holds.
    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    private static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
