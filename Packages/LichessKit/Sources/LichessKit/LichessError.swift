import Foundation

/// Errors surfaced by the Lichess clients.
public enum LichessError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The response was not an HTTP response at all.
    case notHTTP
    /// A status code we can retry (5xx, 408, unexpected 3xx, …).
    case retryableStatus(Int)
    /// A status code that will not fix itself by retrying (404, 410, 501).
    case unrecoverableStatus(Int)
    /// HTTP 429. `retryAfter` is the server's `Retry-After` value when it sent one.
    case rateLimited(retryAfter: Duration?)
    /// The server closed a long-lived stream that is supposed to stay open.
    case streamEndedUnexpectedly
    /// A body that could not be decoded at all (only used for one-shot requests).
    case malformedBody

    public var description: String {
        switch self {
        case .notHTTP: "Response was not HTTP"
        case .retryableStatus(let code): "HTTP \(code)"
        case .unrecoverableStatus(let code): "HTTP \(code) (unrecoverable)"
        case .rateLimited(let after): "HTTP 429 (Retry-After: \(after.map(String.init(describing:)) ?? "none"))"
        case .streamEndedUnexpectedly: "Stream ended unexpectedly"
        case .malformedBody: "Malformed response body"
        }
    }

    /// `true` when reconnecting cannot help and the feed must report `.failed`.
    var isUnrecoverable: Bool {
        if case .unrecoverableStatus = self { return true }
        return false
    }
}

/// Errors from turning one NDJSON line into a `TVEvent`.
enum TVEventDecodingError: Error, Equatable {
    case unknownEventType(String)
    case missingPlayer
}
