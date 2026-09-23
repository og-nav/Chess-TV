// Everything the process needs to know, read once from the environment.
//
// Secrets (the APNs key, the optional Lichess token) are read from the environment or from a file
// path and are never echoed. `description` exists so the log line at startup can say what the
// server is configured to do without saying any of it.

import Foundation
import Logging

public struct ServerConfig: Sendable {

    // MARK: HTTP

    public var host: String = "127.0.0.1"
    public var port: Int = 8099
    /// The largest request body the API will read. The biggest legitimate body is a
    /// `NotificationPreferences` with three alert sets in it, well under a kilobyte.
    public var maximumRequestBytes: Int = 32 * 1024
    /// Refuse a request that did not arrive over TLS. Caddy terminates TLS and sets
    /// `X-Forwarded-Proto`, so this is on in production and off when running on a laptop.
    public var requireHTTPS: Bool = true

    // MARK: Storage

    /// Absolute path to the SQLite file. `:memory:` is accepted for tests and `--replay`.
    public var databasePath: String = "/var/lib/follow-server/follow.sqlite"
    /// Server-wide row ceilings; see `StoreLimits`.
    public var storeLimits = StoreLimits()

    // MARK: APNs

    /// Team id from the developer portal.
    public var apnsTeamId: String = ""
    /// Key id of the `.p8`.
    public var apnsKeyId: String = ""
    /// Path to the `.p8` on disk, readable only by the service user.
    public var apnsKeyPath: String = ""
    /// The universal-purchase bundle id; both topics are derived from it.
    public var apnsTopic: String = PushTopicDefaults.app
    /// Which APNs host to use when a device did not say. Devices say, so this is a fallback.
    public var apnsDefaultEnvironment: String = "production"
    /// With no key configured the server still runs, watches rounds and records what it *would*
    /// send. That is what `--replay` uses and what a first deploy looks like before the key
    /// arrives.
    public var apnsEnabled: Bool { !apnsTeamId.isEmpty && !apnsKeyId.isEmpty && !apnsKeyPath.isEmpty }

    // MARK: Lichess

    public var lichessBaseURL: String = "https://lichess.org"
    /// Optional personal token with `study:read`. Anonymous until Lichess rate-limits us; see
    /// MOBILE_BUILD_PLAN.md "Facts verified on September 18".
    public var lichessToken: String?
    /// `ChessTV-follow-server/<version> (<contact>)`. Lichess asks to be able to reach whoever is
    /// holding the streams open all day.
    public var userAgent: String = "ChessTV-follow-server/0.1 (zzzlabshq@gmail.com)"
    /// How often the top-broadcast poll runs.
    public var pollInterval: Duration = .seconds(300)
    /// The most rounds to hold a PGN stream for at once. A hard cap, because one runaway follow
    /// list should not turn into fifty connections to Lichess.
    public var maximumWatchedRounds: Int = 12
    /// The least time to wait after a 429 before asking Lichess for anything again.
    public var rateLimitBackoff: Duration = .seconds(60)

    /// How long a Live Activity registration is believed without being renewed.
    ///
    /// ActivityKit ends an activity after eight hours whatever the app wants, and the app does not
    /// always survive to say so — a registration can outlive the thing it describes. Twelve hours
    /// leaves room for a long classical game and still stops an orphan from holding a stream open
    /// against Lichess for days.
    public var activityLifetime: TimeInterval = 12 * 3600

    // MARK: Eval swings

    /// Whether to run Stockfish at all. The runtime image turns it on; `FOLLOW_EVAL_ENABLED=0` in
    /// the compose file is the switch that turns it off again without a rebuild.
    public var evalEnabled: Bool = false
    public var stockfishPath: String = "/usr/local/bin/stockfish"
    public var stockfishHashMegabytes: Int = 32
    public var swings = SwingConfiguration()
    /// The share of winning chances a move must give away, on Lichess's [-1, 1] scale. 0.3 is
    /// Lichess's blunder; checked against 92 Olympiad games it fires about 1.7 times in a decisive
    /// game and 0.2 times in a draw.
    public var swingThreshold: Double = 0.3

    // MARK: Delivery

    /// How often the outbox worker looks for queued pushes. Delivery is also kicked immediately
    /// when something is enqueued; this is the safety net for a push that failed and is waiting.
    public var outboxInterval: Duration = .seconds(15)
    /// Attempts before a queued push is abandoned.
    public var maximumDeliveryAttempts: Int = 8

    public var logLevel: Logger.Level = .info

    public init() {}

    /// Reads the configuration from the process environment. Every key is optional; the defaults
    /// above are what a laptop wants, except `FOLLOW_DB` which a laptop must set.
    ///
    /// - Parameter environment: injected in tests.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> ServerConfig {
        var config = ServerConfig()
        func string(_ key: String) -> String? {
            guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        func int(_ key: String) -> Int? { string(key).flatMap(Int.init) }
        func bool(_ key: String) -> Bool? {
            guard let value = string(key)?.lowercased() else { return nil }
            return ["1", "true", "yes", "on"].contains(value)
        }

        config.host = string("FOLLOW_HOST") ?? config.host
        config.port = int("FOLLOW_PORT") ?? config.port
        config.requireHTTPS = bool("FOLLOW_REQUIRE_HTTPS") ?? config.requireHTTPS
        config.maximumRequestBytes = int("FOLLOW_MAX_REQUEST_BYTES") ?? config.maximumRequestBytes
        config.databasePath = string("FOLLOW_DB") ?? config.databasePath
        config.storeLimits.maximumDevices = int("FOLLOW_MAX_DEVICES") ?? config.storeLimits.maximumDevices
        config.storeLimits.maximumFollows = int("FOLLOW_MAX_FOLLOWS") ?? config.storeLimits.maximumFollows

        config.apnsTeamId = string("APNS_TEAM_ID") ?? ""
        config.apnsKeyId = string("APNS_KEY_ID") ?? ""
        config.apnsKeyPath = string("APNS_KEY_PATH") ?? ""
        config.apnsTopic = string("APNS_TOPIC") ?? config.apnsTopic
        config.apnsDefaultEnvironment = string("APNS_ENVIRONMENT") ?? config.apnsDefaultEnvironment

        config.lichessBaseURL = string("LICHESS_BASE_URL") ?? config.lichessBaseURL
        config.lichessToken = string("LICHESS_TOKEN")
        config.userAgent = string("FOLLOW_USER_AGENT") ?? config.userAgent
        if let seconds = int("FOLLOW_POLL_SECONDS") { config.pollInterval = .seconds(max(30, seconds)) }
        config.maximumWatchedRounds = int("FOLLOW_MAX_ROUNDS") ?? config.maximumWatchedRounds
        if let hours = int("FOLLOW_ACTIVITY_HOURS") { config.activityLifetime = TimeInterval(max(1, hours) * 3600) }
        if let seconds = int("FOLLOW_OUTBOX_SECONDS") { config.outboxInterval = .seconds(max(1, seconds)) }
        config.maximumDeliveryAttempts = int("FOLLOW_MAX_ATTEMPTS") ?? config.maximumDeliveryAttempts
        config.evalEnabled = bool("FOLLOW_EVAL_ENABLED") ?? config.evalEnabled
        config.stockfishPath = string("FOLLOW_STOCKFISH_PATH") ?? config.stockfishPath
        if let megabytes = int("FOLLOW_EVAL_HASH_MB") { config.stockfishHashMegabytes = min(max(megabytes, 1), 256) }
        if let ms = int("FOLLOW_EVAL_MOVETIME_MS") { config.swings.movetimeMs = min(max(ms, 100), 10_000) }
        if let ms = int("FOLLOW_EVAL_CONFIRM_MS") { config.swings.confirmMovetimeMs = min(max(ms, 100), 30_000) }
        if let boards = int("FOLLOW_EVAL_MAX_BOARDS") { config.swings.maximumBoards = min(max(boards, 1), 200) }
        if let threshold = string("FOLLOW_EVAL_THRESHOLD").flatMap(Double.init) { config.swingThreshold = min(max(threshold, 0.1), 2) }
        if let level = string("LOG_LEVEL").flatMap({ Logger.Level(rawValue: $0.lowercased()) }) { config.logLevel = level }
        return config
    }

    /// The APNs Live Activity topic, which is the app topic with a fixed suffix.
    public var liveActivityTopic: String { apnsTopic + ".push-type.liveactivity" }

    /// What the startup log line says. Deliberately free of the key path's contents, the Lichess
    /// token, and anything else a support log should not carry.
    public var summary: String {
        """
        listening \(host):\(port) · db \(databasePath) · apns \(apnsEnabled ? "on (topic \(apnsTopic))" : "off, recording only") \
        · lichess \(lichessToken == nil ? "anonymous" : "with token") · poll \(pollInterval) · max rounds \(maximumWatchedRounds) \
        · swings \(evalEnabled ? "on (\(swings.movetimeMs) ms, \(swings.maximumBoards) boards)" : "off")
        """
    }

    /// What the server refuses to start with. Returned as a list so an operator fixes everything
    /// in one go rather than one restart at a time.
    public func problems() -> [String] {
        var problems: [String] = []
        if port <= 0 || port > 65_535 { problems.append("FOLLOW_PORT is not a port") }
        if databasePath.isEmpty { problems.append("FOLLOW_DB is empty") }
        if evalEnabled, !FileManager.default.isExecutableFile(atPath: stockfishPath) {
            problems.append("FOLLOW_EVAL_ENABLED is on but FOLLOW_STOCKFISH_PATH is not an executable")
        }
        if storeLimits.maximumDevices < 1 || storeLimits.maximumFollows < 1 {
            problems.append("FOLLOW_MAX_DEVICES and FOLLOW_MAX_FOLLOWS must be positive")
        }
        if apnsTeamId.isEmpty != apnsKeyId.isEmpty || apnsKeyId.isEmpty != apnsKeyPath.isEmpty {
            problems.append("APNS_TEAM_ID, APNS_KEY_ID and APNS_KEY_PATH must be set together or not at all")
        }
        if apnsEnabled, !FileManager.default.isReadableFile(atPath: apnsKeyPath) {
            problems.append("APNS_KEY_PATH is not readable")
        }
        if !["sandbox", "production"].contains(apnsDefaultEnvironment) {
            problems.append("APNS_ENVIRONMENT must be sandbox or production")
        }
        return problems
    }
}

/// The bundle id, repeated here so `ServerConfig` has a default without importing FollowKit into
/// its own header. `PushTopic` in FollowKit is the one the apps read.
enum PushTopicDefaults {
    static let app = "com.navin.chesstv"
}
