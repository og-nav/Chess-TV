// Logging, and the rule about what may be in a log.
//
// Three kinds of secret pass through this process: the install token a device authenticates with,
// the APNs device token, and the ActivityKit push token. None of them is ever logged in full.
// `Redacted` is the only way any of them is allowed to reach a log line, and it prints a short
// fingerprint that is enough to correlate two lines and useless to anyone who reads them.

import Crypto
import Foundation
import Logging

public enum ServerLog {
    /// The process logger. Hummingbird gets its own child of it.
    public static let subsystem = "follow-server"

    public static func make(_ label: String, level: Logger.Level = .info) -> Logger {
        var logger = Logger(label: "\(subsystem).\(label)")
        logger.logLevel = level
        return logger
    }
}

/// A secret as a log line may name it: the first eight hex characters of its SHA-256.
///
/// Stable across restarts, so two lines about the same device line up, and not reversible, so a
/// log shipped to a bug report does not carry a credential.
public struct Redacted: CustomStringConvertible, Sendable {
    private let fingerprint: String

    public init(_ secret: String) {
        guard !secret.isEmpty else {
            fingerprint = "empty"
            return
        }
        let digest = SHA256.hash(data: Data(secret.utf8))
        fingerprint = digest.compactMap { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    public var description: String { "…\(fingerprint)" }
}

extension Logger.MetadataValue {
    /// `logger.info("registered", metadata: ["device": .redacted(token)])`
    public static func redacted(_ secret: String) -> Logger.MetadataValue {
        .string(Redacted(secret).description)
    }
}
