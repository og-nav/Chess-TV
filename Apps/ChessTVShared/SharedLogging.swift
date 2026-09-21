// Loggers for the shared app sources.
//
// These files are compiled into several targets (the phone app, both notification extensions,
// the Live Activity widget extension, the watch app and the watch widget), so the names are
// prefixed rather than a bare `log`: a target that already has its own global logger must still
// be able to include these sources without a redeclaration.
//
// Nothing here ever logs an install token, an APNs token or an activity push token. The rule is
// simple and absolute: token values are never interpolated into a log line, not even truncated.
import Foundation
import os

import FollowKit

/// Board rendering, payload decoding and wording.
let pushLog = Logger(subsystem: "com.navin.chesstv", category: "push")

/// ActivityKit lifecycle.
let activityLog = Logger(subsystem: "com.navin.chesstv", category: "liveactivity")

/// WatchConnectivity on both sides of the pairing.
let watchLinkLog = Logger(subsystem: "com.navin.chesstv", category: "watchlink")

/// The watch app's own screens and polling.
let watchLog = Logger(subsystem: "com.navin.chesstv", category: "watch")

/// The follow server HTTP client.
let followClientLog = Logger(subsystem: "com.navin.chesstv", category: "followclient")

/// A short, content-free label for an error, for the one place an error reaches a log line.
///
/// `String(describing:)` on an error is a liability in this app and the rule above is why:
/// `URLError` prints the URL it failed on, `DecodingError` prints the body it choked on, and an
/// error thrown by a client that builds its own `URLRequest` can carry that request — including its
/// `Authorization` header, which is the install token. Every case here yields a fixed string or a
/// number, so no server prose and no secret can reach the log through this function.
func logLabel(for error: any Error) -> String {
    switch error {
    case let server as FollowServerError:
        switch server {
        case .insecureBaseURL: return "insecure base URL"
        case .notRegistered: return "not registered"
        case .unauthorized: return "unauthorized"
        case .notFound: return "not found"
        case .rejected: return "rejected by the server"
        case .unavailable: return "server unavailable"
        case .malformedResponse: return "malformed response"
        }
    case let url as URLError:
        return "URLError \(url.code.rawValue)"
    case is DecodingError:
        return "DecodingError"
    case is CancellationError:
        return "cancelled"
    default:
        // Domain and code only. Neither is derived from a response body.
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }
}
