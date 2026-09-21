// Where the push server lives.
//
// Every install uses the published Chess TV service. There is no screen for this any more: a
// field for a server address is a support burden and an invitation to hand a stranger a bearer
// token, for a feature exactly one person was ever going to use. What is kept is the *model* —
// a URL the app holds, an identity that decides whether a stored install token still belongs to
// the host it was minted by, and the health probe — because the credential scoping in
// `ScopedCredentialStore` is written in terms of it and because a private deployment is still
// one built value away.
//
// `ServerURL.normalize` is likewise kept: it is the rule FollowKit enforces before it will send
// a bearer token, and the unit tests hold it to that rule whether or not a text field calls it.
import Foundation
import FollowKit

enum ServerURLError: Error, Equatable, Sendable, CustomStringConvertible {
    case notAURL
    case missingHost
    case insecure
    case badScheme(String)
    case hasCredentials
    case hasPathExtras

    var description: String {
        switch self {
        case .notAURL: "That isn\u{2019}t a web address."
        case .missingHost: "That address has no host name."
        case .insecure: "http is only allowed to this machine. Use https, so the install token is never sent in the clear."
        case .badScheme(let scheme): "\(scheme):// isn\u{2019}t supported. Use https."
        case .hasCredentials: "Leave the user name and password out of the address."
        case .hasPathExtras: "Leave off the query and the fragment; just the host."
        }
    }
}

/// Turning what the user typed into the base URL the client uses.
enum ServerURL {

    /// - Returns: `.success(nil)` when the field was cleared, which means "no server".
    ///
    /// A bare host gets `https://`, because that is what the deployment behind Caddy is. Plain
    /// `http` is refused unless it points at this machine, which is the same rule
    /// `HTTPFollowServerClient` enforces before it will send a bearer token — better to say so
    /// under the text field than to throw when the first request goes out.
    static func normalize(_ text: String) -> Result<URL?, ServerURLError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success(nil) }

        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard var components = URLComponents(string: withScheme) else { return .failure(.notAURL) }
        guard let scheme = components.scheme?.lowercased() else { return .failure(.notAURL) }
        guard scheme == "https" || scheme == "http" else { return .failure(.badScheme(scheme)) }
        guard components.user == nil, components.password == nil else { return .failure(.hasCredentials) }
        guard let host = components.host, !host.isEmpty, host.contains(".") || isLoopback(host) else {
            return .failure(.missingHost)
        }
        guard components.query == nil, components.fragment == nil else { return .failure(.hasPathExtras) }
        guard scheme == "https" || isLoopback(host) else { return .failure(.insecure) }

        components.scheme = scheme
        // A trailing slash would make every path join double up; the client appends "/v1/…".
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { return .failure(.notAURL) }
        return .success(url)
    }

    /// Exactly the three spellings, as FollowKit's own check has it: `localhost.evil.example` is
    /// not loopback.
    static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// What the Settings row shows for a configured server: the host, not the whole URL.
    static func displayName(for url: URL) -> String {
        guard let host = url.host() else { return url.absoluteString }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }

    /// The identity of a server, for deciding whether the stored install token still belongs to
    /// it. Scheme, host and port: a different one of any of those is a different server.
    static func identity(of url: URL?) -> String {
        guard let url else { return "" }
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host()?.lowercased() ?? ""
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)\(url.path())"
    }
}

/// The server URL, persisted, plus whether it answered the last time we asked.
@MainActor
@Observable
final class ServerConfiguration {

    enum Key {
        static let serverURL = "followServerURL"
    }

    /// What the app knows about the server right now.
    enum Reachability: Equatable, Sendable {
        case unknown
        case checking
        case reachable(roundsWatched: Int, roundsScheduled: Int)
        case unreachable(String)

        var isReachable: Bool { if case .reachable = self { return true }; return false }
    }

    private(set) var url: URL?
    private(set) var reachability: Reachability = .unknown

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var probeTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A stored address wins, so a build that sets one keeps it; anything else — a new
        // install, or the empty string an older build wrote when its Settings field was cleared
        // — is the published service. There is no longer a way to choose "no server", so an
        // empty string is read as "never chosen" rather than as a choice, and a phone upgrading
        // from a build that had the field gets its alerts back instead of silently having none.
        let stored = defaults.string(forKey: Key.serverURL).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        url = stored ?? Self.defaultURL
    }

    /// Where the service the app ships against lives. A public app's user should not have to
    /// stand up a VPS to be told a game started, so every install points here.
    static let defaultURL = PublishedService.url

    var isConfigured: Bool { url != nil }

    /// - Returns: true when the server this app talks to actually changed, which is the caller's
    ///   cue to drop the install token — it belongs to the old host and means nothing to the new.
    @discardableResult
    func set(_ url: URL?) -> Bool {
        let changed = ServerURL.identity(of: url) != ServerURL.identity(of: self.url)
        self.url = url
        defaults.set(url?.absoluteString ?? "", forKey: Key.serverURL)
        if changed {
            reachability = .unknown
            mobileLog.notice("Push server set to \(url.map(ServerURL.displayName(for:)) ?? "none", privacy: .public)")
        }
        return changed
    }

    /// Asks `/v1/health` through the client, so the answer comes back through exactly the code
    /// path every other call uses. A server that is down is then visible in Settings rather than
    /// being a run of alerts that quietly never arrive.
    func probe(using client: (any FollowServerClient)?) {
        probeTask?.cancel()
        guard let client, url != nil else {
            reachability = .unknown
            return
        }
        reachability = .checking
        probeTask = Task { @MainActor [weak self] in
            do {
                let health = try await client.health()
                guard let self, !Task.isCancelled else { return }
                self.reachability = health.ok
                    ? .reachable(roundsWatched: health.roundsWatched, roundsScheduled: health.roundsScheduled)
                    : .unreachable("The server reports a problem")
            } catch {
                guard let self, !Task.isCancelled, !(error is CancellationError) else { return }
                self.reachability = .unreachable(FollowStore.message(for: error))
            }
        }
    }

    /// The line the Settings rows show.
    var reachabilityText: String {
        switch reachability {
        case .unknown: "Not checked"
        case .checking: "Checking\u{2026}"
        case .reachable(let watched, _): watched == 0 ? "Answering" : "Answering \u{00B7} \(watched) rounds watched"
        case .unreachable(let message): message
        }
    }
}
