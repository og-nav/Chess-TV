// Persistence. One actor, one SQLite connection, every query in this file.
//
// SQLite with one writer is the right size for this: a few hundred devices, a few thousand
// follows, and a write rate bounded by how fast chess is played.
//
// The actor is **not** the write lock. An actor only guarantees that one task runs its
// synchronous work at a time; every `await connection.query(…)` is a suspension point at which
// another call into this store can start. A method that reads, decides and then writes is
// therefore not atomic just because it lives here, and one that opens a SQLite transaction would
// otherwise find unrelated statements from another task inside it.
//
// So: every method that writes goes through `exclusive { }`, a one-at-a-time gate, and anything
// that writes more than one row does it inside `transaction { }`. Reads are not gated — there is
// a single connection either way, so there was never any parallelism to lose, and a read that
// observes a transaction mid-flight is reading advisory state (a health count, a cooldown) where
// a few milliseconds do not change the answer.

import Crypto
import Foundation
import FollowKit
import Logging
import SQLiteNIO

public enum StoreError: Error, Sendable, Equatable {
    case notFound
    case conflict(String)
    case corrupt(String)
    /// The store was closed. A watcher or worker that outlives shutdown gets this instead of a
    /// query against a freed `sqlite3*`, which is undefined behaviour and has crashed the test host.
    case closed
    /// A server-wide ceiling was reached. Not the caller's fault and not permanent, so the API
    /// answers 503 rather than 4xx.
    case full(String)
}

/// Server-wide ceilings on what anonymous installs can make the database hold.
///
/// Registration needs no account, so nothing stops a script from minting installs and filling
/// each with a hundred follows. These caps are what keep that from filling the disk this box
/// shares with other services. At the limit new rows are refused; existing installs keep working.
public struct StoreLimits: Sendable, Equatable {
    public var maximumDevices: Int = 20_000
    public var maximumFollows: Int = 200_000

    public init(maximumDevices: Int = 20_000, maximumFollows: Int = 200_000) {
        self.maximumDevices = maximumDevices
        self.maximumFollows = maximumFollows
    }
}

public actor FollowStore {

    private let connection: SQLiteConnection
    private let logger: Logger
    /// Injected so tests can run a day of a tournament in a few milliseconds.
    private let now: @Sendable () -> Date
    private let limits: StoreLimits

    private init(connection: SQLiteConnection, logger: Logger, limits: StoreLimits, now: @escaping @Sendable () -> Date) {
        self.connection = connection
        self.logger = logger
        self.limits = limits
        self.now = now
    }

    /// Opens (and migrates) the database.
    ///
    /// - Parameter path: a file path, or `":memory:"` for a database that lives as long as the
    ///   process. Note that an in-memory database cannot be shared between connections, which is
    ///   exactly why there is only one.
    public static func open(
        path: String,
        logger: Logger = ServerLog.make("store"),
        limits: StoreLimits = StoreLimits(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> FollowStore {
        let storage: SQLiteConnection.Storage = path == ":memory:" ? .memory : .file(path: path)
        let connection = try await SQLiteConnection.open(storage: storage, logger: logger)
        let store = FollowStore(connection: connection, logger: logger, limits: limits, now: now)
        try await store.prepare()
        return store
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        try? await connection.close()
    }

    /// Set by `close()`. Every statement goes through `query`, which checks it first: SQLite does
    /// not defend a closed handle, so the check has to live here.
    private var closed = false

    /// The one place a statement reaches the connection.
    @discardableResult
    private func query(_ sql: String, _ binds: [SQLiteData] = []) async throws -> [SQLiteRow] {
        guard !closed else { throw StoreError.closed }
        return try await connection.query(sql, binds)
    }

    // MARK: - Serialising writes

    /// True while an `exclusive` body is running.
    private var writing = false
    /// Tasks waiting for the gate, in arrival order.
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Runs `body` with no other write interleaved into it.
    ///
    /// The `while` rather than an `if` is deliberate: a resumed waiter re-checks, so two waiters
    /// released by two consecutive `endWriting` calls cannot both decide the gate is free.
    private func exclusive<T>(_ body: () async throws -> T) async rethrows -> T {
        while writing {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiting.append(continuation)
            }
        }
        writing = true
        defer {
            writing = false
            if !waiting.isEmpty { waiting.removeFirst().resume() }
        }
        return try await body()
    }

    /// One gated statement, for a write that is already atomic on its own.
    ///
    /// The gate is not about that statement — SQLite guarantees it — but about the ones around it:
    /// an ungated write can land inside another call's open transaction and be rolled back with it.
    @discardableResult
    private func write(_ sql: String, _ binds: [SQLiteData] = []) async throws -> [SQLiteRow] {
        try await exclusive { try await query(sql, binds) }
    }

    /// A SQLite transaction. Only ever called from inside `exclusive`, which is what makes
    /// "nothing else is writing on this connection right now" true.
    ///
    /// `IMMEDIATE` takes the write lock at `BEGIN` rather than at the first write, so a busy
    /// database fails here (within `busy_timeout`) instead of halfway through.
    private func transaction<T>(_ body: () async throws -> T) async throws -> T {
        _ = try await query("BEGIN IMMEDIATE")
        do {
            let result = try await body()
            _ = try await query("COMMIT")
            return result
        } catch {
            _ = try? await query("ROLLBACK")
            throw error
        }
    }

    private func prepare() async throws {
        // WAL keeps a reader (the health endpoint) from blocking the writer (the watcher).
        // `foreign_keys` is off by default in SQLite and the cascades on devices depend on it.
        _ = try await query("PRAGMA journal_mode = WAL")
        _ = try await query("PRAGMA foreign_keys = ON")
        _ = try await query("PRAGMA busy_timeout = 5000")
        _ = try await query("CREATE TABLE IF NOT EXISTS schema_migrations (name TEXT PRIMARY KEY, applied_at REAL NOT NULL)")

        let applied = Set(try await query("SELECT name FROM schema_migrations").compactMap { $0.column("name")?.string })
        for migration in Schema.migrations where !applied.contains(migration.name) {
            for statement in migration.statements {
                _ = try await query(statement)
            }
            _ = try await query(
                "INSERT INTO schema_migrations (name, applied_at) VALUES (?, ?)",
                [.text(migration.name), .float(now().timeIntervalSince1970)]
            )
            logger.info("applied migration", metadata: ["name": .string(migration.name)])
        }
    }

    // MARK: - Devices

    /// Registers an install. Always a **new** install, with no follows.
    ///
    /// This endpoint is unauthenticated — it has to be, it is how an install gets its first
    /// credential — so the only thing it can be told is an APNs device token. That token is a
    /// *routing address*, not proof of identity: it is handed to any server the app is configured
    /// to talk to, it travels in push-testing tools, and it is not a secret in the sense a bearer
    /// token is. Looking a device up by it and reissuing that device's install token would mean
    /// anyone who learned a token could take over the install: read its follows, retarget them,
    /// and see the pushes.
    ///
    /// Registration never adopts or disables another row. APNs tokens are not ownership proof,
    /// including when the caller has a credential for some other install. A lost-response retry
    /// creates an empty identity and leaves the original one untouched. If a lost credential is
    /// followed by reconstructing the same follows, duplicate delivery to that phone is possible;
    /// proving token ownership would require a separate device challenge protocol.
    public func register(_ registration: DeviceRegistration) async throws -> (credential: DeviceCredential, device: DeviceRecord) {
        try await exclusive {
            let token = InstallToken.generate()
            let hash = InstallToken.hash(token)
            let timestamp = now().timeIntervalSince1970
            let deviceId = "d_" + InstallToken.identifier()

            try await transaction {
                let count = try await query("SELECT COUNT(*) AS n FROM devices")
                guard (count.first?.column("n")?.integer ?? 0) < limits.maximumDevices else {
                    throw StoreError.full("The server is not taking new installs right now")
                }
                _ = try await query(
                    """
                    INSERT INTO devices (device_id, token_hash, platform, environment, apns_token, app_version, created_at, last_seen_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(deviceId), .text(hash), .text(registration.platform), .text(registration.environment),
                        .text(registration.apnsToken), .text(registration.appVersion), .float(timestamp), .float(timestamp),
                    ]
                )
            }

            guard let device = try await device(id: deviceId) else { throw StoreError.corrupt("device vanished after insert") }
            return (DeviceCredential(deviceId: deviceId, installToken: token), device)
        }
    }

    /// Looks a device up by the bearer token it presented. The token itself is never stored, so
    /// this is a lookup on its hash — constant work, and no comparison of secrets in Swift.
    public func device(installToken: String) async throws -> DeviceRecord? {
        let hash = InstallToken.hash(installToken)
        let rows = try await query("SELECT * FROM devices WHERE token_hash = ? LIMIT 1", [.text(hash)])
        return try rows.first.map(Self.device(from:))
    }

    public func device(id: String) async throws -> DeviceRecord? {
        let rows = try await query("SELECT * FROM devices WHERE device_id = ? LIMIT 1", [.text(id)])
        return try rows.first.map(Self.device(from:))
    }

    public func touch(deviceId: String) async throws {
        try await exclusive {
            _ = try await query(
                "UPDATE devices SET last_seen_at = ? WHERE device_id = ?",
                [.float(now().timeIntervalSince1970), .text(deviceId)]
            )
        }
    }

    /// Rotates only this authenticated install's routing address. Knowing another install's
    /// APNs token cannot disable or mutate that install, even with an unrelated valid bearer.
    public func updateAPNsToken(deviceId: String, apnsToken: String) async throws {
        try await exclusive {
            try await transaction {
                _ = try await query(
                    "UPDATE devices SET apns_token = ?, disabled_at = NULL, last_seen_at = ? WHERE device_id = ?",
                    [.text(apnsToken), .float(now().timeIntervalSince1970), .text(deviceId)]
                )
            }
        }
    }

    /// Called when APNs says the *device* token is gone. The device stops being delivered to; its
    /// queued pushes are dropped rather than retried forever.
    ///
    /// Not for a dead Live Activity token — see `retireActivity(deviceId:gameId:reason:)`.
    public func disableDevice(id: String, reason: String, expectedToken: String? = nil) async throws {
        try await exclusive {
            try await transaction {
                if let expectedToken {
                    let rows = try await query("SELECT 1 FROM devices WHERE device_id = ? AND apns_token = ?", [.text(id), .text(expectedToken)])
                    guard !rows.isEmpty else { return }
                }
                _ = try await query(
                    "UPDATE devices SET disabled_at = ? WHERE device_id = ?",
                    [.float(now().timeIntervalSince1970), .text(id)]
                )
                _ = try await query(
                    "UPDATE outbox SET state = ?, last_error = ? WHERE device_id = ? AND state = ?",
                    [.text(OutboxState.dropped.rawValue), .text(reason), .text(id), .text(OutboxState.queued.rawValue)]
                )
            }
            logger.notice("device disabled", metadata: ["device": .string(id), "reason": .string(reason)])
        }
    }

    private static func device(from row: SQLiteRow) throws -> DeviceRecord {
        guard let id = row.column("device_id")?.string,
              let platform = row.column("platform")?.string,
              let environment = row.column("environment")?.string,
              let apnsToken = row.column("apns_token")?.string,
              let appVersion = row.column("app_version")?.string,
              let createdAt = row.column("created_at")?.double,
              let lastSeenAt = row.column("last_seen_at")?.double
        else { throw StoreError.corrupt("devices row") }
        return DeviceRecord(
            id: id,
            platform: platform,
            environment: environment,
            apnsToken: apnsToken,
            appVersion: appVersion,
            createdAt: Date(timeIntervalSince1970: createdAt),
            lastSeenAt: Date(timeIntervalSince1970: lastSeenAt),
            disabledAt: row.column("disabled_at")?.double.map(Date.init(timeIntervalSince1970:))
        )
    }

    // MARK: - Preferences

    public func preferences(deviceId: String) async throws -> NotificationPreferences {
        let rows = try await query("SELECT json FROM preferences WHERE device_id = ?", [.text(deviceId)])
        guard let text = rows.first?.column("json")?.string,
              let preferences = try? FollowJSON.decoder.decode(NotificationPreferences.self, from: Data(text.utf8))
        else { return NotificationPreferences(timeZoneIdentifier: "UTC") }
        return preferences
    }

    public func setPreferences(_ preferences: NotificationPreferences, deviceId: String) async throws {
        let data = try FollowJSON.encoder.encode(preferences.sanitized())
        try await exclusive {
            _ = try await query(
                """
                INSERT INTO preferences (device_id, json, updated_at) VALUES (?, ?, ?)
                ON CONFLICT (device_id) DO UPDATE SET json = excluded.json, updated_at = excluded.updated_at
                """,
                [.text(deviceId), .text(String(decoding: data, as: UTF8.self)), .float(now().timeIntervalSince1970)]
            )
        }
    }

    // MARK: - Follows

    public static let maximumFollowsPerDevice = 100

    public func follows(deviceId: String) async throws -> [Follow] {
        let rows = try await query(
            "SELECT * FROM follows WHERE device_id = ? ORDER BY created_at",
            [.text(deviceId)]
        )
        return try rows.map(Self.follow(from:))
    }

    /// Adds a follow, or returns the one already there for the same target — a double tap on the
    /// Follow button is not an error and must not make two rows.
    public func addFollow(_ follow: Follow, deviceId: String) async throws -> Follow {
        let alerts = follow.alerts.clamped()
        let data = try FollowJSON.encoder.encode(alerts)
        let id = follow.id.isEmpty ? "f_" + InstallToken.identifier() : follow.id
        let createdAt = now()

        return try await exclusive {
            try await transaction {
                // Count and insert share the write gate/transaction, so concurrent requests
                // cannot all pass a stale count. Updating an existing target remains idempotent.
                let existing = try await query(
                    "SELECT 1 FROM follows WHERE device_id = ? AND target_kind = ? AND target_key = ?",
                    [.text(deviceId), .text(follow.target.kind), .text(follow.target.key)]
                )
                if existing.isEmpty {
                    let count = try await query("SELECT COUNT(*) AS n FROM follows WHERE device_id = ?", [.text(deviceId)])
                    guard (count.first?.column("n")?.integer ?? 0) < Self.maximumFollowsPerDevice else {
                        throw StoreError.conflict("An install can follow at most 100 players, games and tournaments")
                    }
                    let total = try await query("SELECT COUNT(*) AS n FROM follows")
                    guard (total.first?.column("n")?.integer ?? 0) < limits.maximumFollows else {
                        throw StoreError.full("The server is not taking new follows right now")
                    }
                }
                if alerts.evalSwings {
                    try await requireSwingRoom(deviceId: deviceId) { $0.target == follow.target }
                }
                _ = try await query(
                    """
                    INSERT INTO follows (id, device_id, target_kind, target_key, alerts_json, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT (device_id, target_kind, target_key)
                    DO UPDATE SET alerts_json = excluded.alerts_json
                    """,
                    [
                        .text(id), .text(deviceId), .text(follow.target.kind), .text(follow.target.key),
                        .text(String(decoding: data, as: UTF8.self)), .float(createdAt.timeIntervalSince1970),
                    ]
                )

                let rows = try await query(
                    "SELECT * FROM follows WHERE device_id = ? AND target_kind = ? AND target_key = ?",
                    [.text(deviceId), .text(follow.target.kind), .text(follow.target.key)]
                )
                guard let row = rows.first else { throw StoreError.corrupt("follow vanished after insert") }
                return try Self.follow(from: row)
            }
        }
    }

    /// Updates a follow's switches. Scoped to the device, so one install cannot patch another's.
    public func updateFollow(id: String, alerts: FollowAlerts, deviceId: String) async throws -> Follow {
        let data = try FollowJSON.encoder.encode(alerts.clamped())
        return try await exclusive {
            try await transaction {
                if alerts.evalSwings {
                    try await requireSwingRoom(deviceId: deviceId) { $0.id == id }
                }
                _ = try await query(
                    "UPDATE follows SET alerts_json = ? WHERE id = ? AND device_id = ?",
                    [.text(String(decoding: data, as: UTF8.self)), .text(id), .text(deviceId)]
                )
                let rows = try await query(
                    "SELECT * FROM follows WHERE id = ? AND device_id = ?",
                    [.text(id), .text(deviceId)]
                )
                guard let row = rows.first else { throw StoreError.notFound }
                return try Self.follow(from: row)
            }
        }
    }

    /// Throws unless the install has fewer than `AlertEngine.maximumSwingFollowsPerDevice` other
    /// follows with swing alerts on. The alert engine applies the same cap again when it matches;
    /// this is so the app's switch says no instead of silently doing nothing.
    private func requireSwingRoom(deviceId: String, excluding isSame: (Follow) -> Bool) async throws {
        let rows = try await query("SELECT * FROM follows WHERE device_id = ?", [.text(deviceId)])
        let others = try rows.map(Self.follow(from:)).filter { $0.alerts.evalSwings && !isSame($0) }
        guard others.count < AlertEngine.maximumSwingFollowsPerDevice else {
            throw StoreError.conflict("Eval swing alerts can be on for at most \(AlertEngine.maximumSwingFollowsPerDevice) follows")
        }
    }

    @discardableResult
    public func removeFollow(id: String, deviceId: String) async throws -> Bool {
        try await exclusive {
            try await transaction {
                let rows = try await query(
                    "DELETE FROM follows WHERE id = ? AND device_id = ? RETURNING id",
                    [.text(id), .text(deviceId)]
                )
                guard !rows.isEmpty else { return false }
                _ = try await query("DELETE FROM move_alert_log WHERE follow_id = ?", [.text(id)])
                return true
            }
        }
    }

    /// Every follow on the server, with the device it belongs to. The watcher needs the whole set
    /// to decide which rounds are worth a connection.
    public func allFollows() async throws -> [(deviceId: String, follow: Follow)] {
        let rows = try await query(
            "SELECT f.* FROM follows f JOIN devices d ON d.device_id = f.device_id WHERE d.disabled_at IS NULL"
        )
        return try rows.map { row in
            guard let deviceId = row.column("device_id")?.string else { throw StoreError.corrupt("follows row") }
            return (deviceId, try Self.follow(from: row))
        }
    }

    /// The device contexts the alert policy needs: only active devices, only devices that follow
    /// something.
    public func deviceContexts() async throws -> [DeviceContext] {
        let rows = try await query("SELECT * FROM devices WHERE disabled_at IS NULL")
        var contexts: [DeviceContext] = []
        for row in rows {
            let device = try Self.device(from: row)
            let follows = try await follows(deviceId: device.id)
            guard !follows.isEmpty else { continue }
            contexts.append(DeviceContext(device: device, preferences: try await preferences(deviceId: device.id), follows: follows))
        }
        return contexts
    }

    private static func follow(from row: SQLiteRow) throws -> Follow {
        guard let id = row.column("id")?.string,
              let kind = row.column("target_kind")?.string,
              let key = row.column("target_key")?.string,
              let target = FollowTarget(kind: kind, key: key),
              let alertsJSON = row.column("alerts_json")?.string,
              let createdAt = row.column("created_at")?.double
        else { throw StoreError.corrupt("follows row") }
        let alerts = (try? FollowJSON.decoder.decode(FollowAlerts.self, from: Data(alertsJSON.utf8))) ?? .defaults(for: target)
        return Follow(id: id, target: target, alerts: alerts, createdAt: Date(timeIntervalSince1970: createdAt))
    }

    // MARK: - Activities

    public func registerActivity(_ registration: ActivityRegistration, deviceId: String) async throws {
        try await exclusive {
            _ = try await query(
                """
                INSERT INTO activities (device_id, round_id, game_id, activity_token, created_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (device_id) DO UPDATE SET round_id = excluded.round_id, game_id = excluded.game_id,
                                                      activity_token = excluded.activity_token, created_at = excluded.created_at
                """,
                [
                    .text(deviceId), .text(registration.roundId), .text(registration.gameId),
                    .text(registration.activityToken), .float(now().timeIntervalSince1970),
                ]
            )
        }
    }

    @discardableResult
    public func endActivity(gameId: String, deviceId: String, expectedToken: String? = nil) async throws -> Bool {
        try await exclusive {
            try await transaction {
                if let expectedToken {
                    let rows = try await query("SELECT 1 FROM activities WHERE device_id = ? AND game_id = ? AND activity_token = ?", [.text(deviceId), .text(gameId), .text(expectedToken)])
                    guard !rows.isEmpty else { return false }
                }
                let rows = try await query(
                    "DELETE FROM activities WHERE device_id = ? AND game_id = ? RETURNING device_id",
                    [.text(deviceId), .text(gameId)]
                )
                // An activity that is going away should not have a queued update chase it onto the
                // Lock Screen a minute later.
                _ = try await query(
                    "UPDATE outbox SET state = ? WHERE device_id = ? AND reference = ? AND state = ? AND category IN (?, ?)",
                    [
                        .text(OutboxState.dropped.rawValue), .text(deviceId), .text(gameId), .text(OutboxState.queued.rawValue),
                        .text(OutboxCategory.activityUpdate.rawValue), .text(OutboxCategory.activityEnd.rawValue),
                    ]
                )
                return !rows.isEmpty
            }
        }
    }

    /// APNs rejected an activity's push token. Only that registration goes; the install keeps
    /// receiving its alerts.
    ///
    /// An ActivityKit token dies whenever its activity does — the card was swiped away, the
    /// system's lifetime ran out, the app started a different one — so this is an ordinary event,
    /// not a sign that anything is wrong with the device.
    public func retireActivity(deviceId: String, gameId: String, reason: String, expectedToken: String? = nil) async throws {
        _ = try await endActivity(gameId: gameId, deviceId: deviceId, expectedToken: expectedToken)
        logger.info("activity retired", metadata: [
            "device": .string(deviceId), "game": .string(gameId), "reason": .string(reason),
        ])
    }

    /// The rounds that have a Live Activity pinned to one of their games, so the watcher opens a
    /// stream for them even when nobody follows anything.
    ///
    /// Pinning a game is as much a request to be told about it as following one is; a device that
    /// pinned without following used to get no watcher and so no updates at all.
    public func activeActivityRoundIds() async throws -> Set<String> {
        let rows = try await query(
            """
            SELECT DISTINCT a.round_id FROM activities a JOIN devices d ON d.device_id = a.device_id
            WHERE d.disabled_at IS NULL AND a.round_id != ''
            """
        )
        return Set(rows.compactMap { $0.column("round_id")?.string })
    }

    /// Drops registrations older than `maximumAge`.
    ///
    /// A Live Activity cannot live longer than eight hours (ActivityKit's own limit) and the app
    /// does not always get to tell us it ended — the process can be killed with the card still on
    /// screen. Without this, one such registration would hold a PGN stream open against Lichess
    /// for as long as the server ran.
    ///
    /// - Returns: how many were dropped.
    @discardableResult
    public func expireActivities(olderThan maximumAge: TimeInterval) async throws -> Int {
        try await exclusive {
            let cutoff = now().addingTimeInterval(-maximumAge).timeIntervalSince1970
            let rows = try await query(
                "DELETE FROM activities WHERE created_at < ? RETURNING device_id, game_id",
                [.float(cutoff)]
            )
            for row in rows {
                logger.info("activity expired", metadata: [
                    "device": .string(row.column("device_id")?.string ?? "?"),
                    "game": .string(row.column("game_id")?.string ?? "?"),
                ])
            }
            return rows.count
        }
    }

    public func activities(gameId: String) async throws -> [ActivityRecord] {
        let rows = try await query(
            """
            SELECT a.* FROM activities a JOIN devices d ON d.device_id = a.device_id
            WHERE a.game_id = ? AND d.disabled_at IS NULL
            """,
            [.text(gameId)]
        )
        return try rows.map(Self.activity(from:))
    }

    public func activity(deviceId: String) async throws -> ActivityRecord? {
        let rows = try await query("SELECT * FROM activities WHERE device_id = ?", [.text(deviceId)])
        return try rows.first.map(Self.activity(from:))
    }

    private static func activity(from row: SQLiteRow) throws -> ActivityRecord {
        guard let deviceId = row.column("device_id")?.string,
              let roundId = row.column("round_id")?.string,
              let gameId = row.column("game_id")?.string,
              let token = row.column("activity_token")?.string,
              let createdAt = row.column("created_at")?.double
        else { throw StoreError.corrupt("activities row") }
        return ActivityRecord(deviceId: deviceId, roundId: roundId, gameId: gameId, activityToken: token, createdAt: Date(timeIntervalSince1970: createdAt))
    }

    // MARK: - Baselines

    public func baseline(roundId: String, gameId: String) async throws -> GameBaseline? {
        let rows = try await query(
            "SELECT * FROM game_baselines WHERE round_id = ? AND game_id = ?",
            [.text(roundId), .text(gameId)]
        )
        return try rows.first.map(Self.baseline(from:))
    }

    public func baselines(roundId: String) async throws -> [GameBaseline] {
        let rows = try await query("SELECT * FROM game_baselines WHERE round_id = ?", [.text(roundId)])
        return try rows.map(Self.baseline(from:))
    }

    /// Every game the server thinks is still being played, for the long-think tick.
    public func liveBaselines() async throws -> [GameBaseline] {
        let rows = try await query("SELECT * FROM game_baselines WHERE status = '*'")
        return try rows.map(Self.baseline(from:))
    }

    public func save(_ baseline: GameBaseline) async throws {
        try await write(
            """
            INSERT INTO game_baselines (round_id, game_id, ply, fen, status, white_clock, black_clock, observed_at, long_think_eligible, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (round_id, game_id) DO UPDATE SET
                ply = excluded.ply, fen = excluded.fen, status = excluded.status,
                white_clock = excluded.white_clock, black_clock = excluded.black_clock,
                observed_at = excluded.observed_at, long_think_eligible = excluded.long_think_eligible,
                updated_at = excluded.updated_at
            """,
            [
                .text(baseline.roundId), .text(baseline.gameId), .integer(baseline.ply), .text(baseline.fen),
                .text(baseline.status), baseline.whiteClock.map { SQLiteData.integer($0) } ?? .null,
                baseline.blackClock.map { SQLiteData.integer($0) } ?? .null,
                .float(baseline.observedAt.timeIntervalSince1970),
                .integer(baseline.longThinkEligible ? 1 : 0),
                .float(baseline.updatedAt.timeIntervalSince1970),
            ]
        )
    }

    private static func baseline(from row: SQLiteRow) throws -> GameBaseline {
        guard let roundId = row.column("round_id")?.string,
              let gameId = row.column("game_id")?.string,
              let ply = row.column("ply")?.integer,
              let fen = row.column("fen")?.string,
              let status = row.column("status")?.string,
              let observedAt = row.column("observed_at")?.double,
              let eligible = row.column("long_think_eligible")?.integer,
              let updatedAt = row.column("updated_at")?.double
        else { throw StoreError.corrupt("game_baselines row") }
        return GameBaseline(
            roundId: roundId,
            gameId: gameId,
            ply: Int(ply),
            fen: fen,
            status: status,
            whiteClock: row.column("white_clock")?.integer.map { Int($0) },
            blackClock: row.column("black_clock")?.integer.map { Int($0) },
            observedAt: Date(timeIntervalSince1970: observedAt),
            longThinkEligible: eligible != 0,
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    // MARK: - Rounds and tournament transitions

    public func save(_ round: RoundRecord) async throws {
        try await write(
            """
            INSERT INTO rounds (round_id, tour_id, name, starts_at, ongoing, finished, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (round_id) DO UPDATE SET tour_id = excluded.tour_id, name = excluded.name,
                starts_at = excluded.starts_at, ongoing = excluded.ongoing, finished = excluded.finished,
                updated_at = excluded.updated_at
            """,
            [
                .text(round.roundId), .text(round.tourId), .text(round.name),
                round.startsAt.map { SQLiteData.float($0.timeIntervalSince1970) } ?? .null,
                .integer(round.ongoing ? 1 : 0), .integer(round.finished ? 1 : 0),
                .float(round.updatedAt.timeIntervalSince1970),
            ]
        )
    }

    public func round(id: String) async throws -> RoundRecord? {
        let rows = try await query("SELECT * FROM rounds WHERE round_id = ?", [.text(id)])
        return try rows.first.map(Self.round(from:))
    }

    public func scheduledRoundCount() async throws -> Int {
        let rows = try await query("SELECT COUNT(*) AS n FROM rounds WHERE finished = 0")
        return Int(rows.first?.column("n")?.integer ?? 0)
    }

    private static func round(from row: SQLiteRow) throws -> RoundRecord {
        guard let roundId = row.column("round_id")?.string,
              let tourId = row.column("tour_id")?.string,
              let name = row.column("name")?.string,
              let ongoing = row.column("ongoing")?.integer,
              let finished = row.column("finished")?.integer,
              let updatedAt = row.column("updated_at")?.double
        else { throw StoreError.corrupt("rounds row") }
        return RoundRecord(
            roundId: roundId,
            tourId: tourId,
            name: name,
            startsAt: row.column("starts_at")?.double.map(Date.init(timeIntervalSince1970:)),
            ongoing: ongoing != 0,
            finished: finished != 0,
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    /// Records that the server has observed a tournament transition.
    ///
    /// - Returns: `true` the first time, `false` afterwards. This is what makes "a round whose
    ///   `startsAt` moves later re-arms its starting-soon alert only if it was never sent" true
    ///   across a restart.
    public func observeTournamentEvent(tourId: String, roundId: String, kind: String) async throws -> Bool {
        let rows = try await write(
            """
            INSERT INTO tournament_events (tour_id, round_id, kind, observed_at) VALUES (?, ?, ?, ?)
            ON CONFLICT (tour_id, round_id, kind) DO NOTHING
            RETURNING tour_id
            """,
            [.text(tourId), .text(roundId), .text(kind), .float(now().timeIntervalSince1970)]
        )
        return !rows.isEmpty
    }

    public func hasObservedTournamentEvent(tourId: String, roundId: String, kind: String) async throws -> Bool {
        let rows = try await query(
            "SELECT 1 AS n FROM tournament_events WHERE tour_id = ? AND round_id = ? AND kind = ?",
            [.text(tourId), .text(roundId), .text(kind)]
        )
        return !rows.isEmpty
    }

    // MARK: - Move cooldowns

    public func lastMoveAlert(followId: String, gameId: String) async throws -> Date? {
        let rows = try await query(
            "SELECT last_sent_at FROM move_alert_log WHERE follow_id = ? AND game_id = ?",
            [.text(followId), .text(gameId)]
        )
        return rows.first?.column("last_sent_at")?.double.map(Date.init(timeIntervalSince1970:))
    }

    /// Every cooldown in one query, so the policy does not do a round trip per follow.
    public func moveAlertCooldowns() async throws -> [String: Date] {
        let rows = try await query("SELECT follow_id, game_id, last_sent_at FROM move_alert_log")
        var cooldowns: [String: Date] = [:]
        for row in rows {
            guard let followId = row.column("follow_id")?.string,
                  let gameId = row.column("game_id")?.string,
                  let timestamp = row.column("last_sent_at")?.double else { continue }
            cooldowns[AlertEngine.cooldownKey(followId: followId, gameId: gameId)] = Date(timeIntervalSince1970: timestamp)
        }
        return cooldowns
    }

    public func recordMoveAlert(followId: String, gameId: String, at date: Date) async throws {
        try await write(
            """
            INSERT INTO move_alert_log (follow_id, game_id, last_sent_at) VALUES (?, ?, ?)
            ON CONFLICT (follow_id, game_id) DO UPDATE SET last_sent_at = excluded.last_sent_at
            """,
            [.text(followId), .text(gameId), .float(date.timeIntervalSince1970)]
        )
    }

    // MARK: - Outbox

    /// Queues a push, unless this device already has one with the same dedupe key.
    ///
    /// - Returns: `true` when the row was written. `false` means the event was already queued or
    ///   already delivered, which is how two overlapping follows become one push and how a
    ///   restart mid-round stays silent.
    @discardableResult
    public func enqueue(_ entry: OutboxEntry) async throws -> Bool {
        let rows = try await write(
            """
            INSERT INTO outbox (device_id, dedupe_key, collapse_id, category, payload_json, title, body, thread_id, relevance, reference, state, attempts, queued_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
            ON CONFLICT (device_id, dedupe_key) DO NOTHING
            RETURNING id
            """,
            [
                .text(entry.deviceId), .text(entry.dedupeKey), .text(entry.collapseId), .text(entry.category.rawValue),
                .text(entry.payloadJSON), .text(entry.title), .text(entry.body), .text(entry.threadId),
                .float(entry.relevance), .text(entry.reference), .text(OutboxState.queued.rawValue),
                .float(entry.queuedAt.timeIntervalSince1970),
            ]
        )
        return !rows.isEmpty
    }

    /// The rows that are due: queued, and not waiting out a retry delay.
    public func queuedEntries(limit: Int = 100) async throws -> [OutboxEntry] {
        let rows = try await query(
            "SELECT * FROM outbox WHERE state = ? AND (next_attempt_at IS NULL OR next_attempt_at <= ?) ORDER BY queued_at LIMIT ?",
            [.text(OutboxState.queued.rawValue), .float(now().timeIntervalSince1970), .integer(limit)]
        )
        return try rows.map(Self.outbox(from:))
    }

    public func entries(deviceId: String, state: OutboxState? = nil) async throws -> [OutboxEntry] {
        var sql = "SELECT * FROM outbox WHERE device_id = ?"
        var binds: [SQLiteData] = [.text(deviceId)]
        if let state {
            sql += " AND state = ?"
            binds.append(.text(state.rawValue))
        }
        sql += " ORDER BY id"
        return try await query(sql, binds).map(Self.outbox(from:))
    }

    public func markDelivered(id: Int) async throws {
        try await write(
            "UPDATE outbox SET state = ?, delivered_at = ?, attempts = attempts + 1, last_error = NULL WHERE id = ?",
            [.text(OutboxState.delivered.rawValue), .float(now().timeIntervalSince1970), .integer(id)]
        )
    }

    /// Records a failed attempt. Past `maximumAttempts` the row is marked failed and stops being
    /// retried; it stays in the table because "what did the server try to send me" is the first
    /// question when an alert goes missing.
    ///
    /// Until then the row waits: 15 s after the first failure, doubling to a quarter of an hour.
    /// Without the wait, the 15-second timer plus a kick from every queued push would spend the
    /// whole attempt budget inside a one-minute APNs blip.
    public func markAttemptFailed(id: Int, error: String, maximumAttempts: Int) async throws {
        try await exclusive {
            let rows = try await query("SELECT attempts FROM outbox WHERE id = ?", [.integer(id)])
            let attempts = Int(rows.first?.column("attempts")?.integer ?? 0) + 1
            let delay = min(900.0, 15.0 * pow(2.0, Double(attempts - 1)))
            _ = try await query(
                """
                UPDATE outbox SET attempts = ?, last_error = ?, next_attempt_at = ?,
                                  state = CASE WHEN ? >= ? THEN ? ELSE state END
                WHERE id = ?
                """,
                [
                    .integer(attempts), .text(error), .float(now().timeIntervalSince1970 + delay),
                    .integer(attempts), .integer(maximumAttempts), .text(OutboxState.failed.rawValue), .integer(id),
                ]
            )
        }
    }

    // MARK: - Retention

    /// Deletes what nothing will ask for again.
    ///
    /// Delivered, dropped and failed outbox rows after a week — long enough to answer "what did
    /// you try to send me", and the dedupe index only has to outlive the chance of the same event
    /// being observed again. Game baselines a week after their last update, and rounds a month
    /// after they finished.
    ///
    /// Installs go on two rules, follows and all. One APNs has disowned for a week: the token was
    /// invented or the app is gone, and a real phone that rotated its token has long since sent the
    /// new one. And one that has not called in for thirty days and has had nothing delivered in the
    /// outbox's week — the shape of a scripted install, which never opens the app again. Neither
    /// loses a real user anything for good: a live app that finds its token rejected registers
    /// again and re-sends every follow it holds (`DeviceRegistrar.credentialRejected`).
    /// - Returns: how many rows went.
    @discardableResult
    public func sweep(now current: Date) async throws -> Int {
        try await exclusive {
            let day: TimeInterval = 86_400
            let stamp = current.timeIntervalSince1970
            var removed = 0
            try await transaction {
                removed += try await query(
                    "DELETE FROM outbox WHERE state != ? AND queued_at < ? RETURNING id",
                    [.text(OutboxState.queued.rawValue), .float(stamp - 7 * day)]
                ).count
                removed += try await query("DELETE FROM game_baselines WHERE updated_at < ? RETURNING game_id", [.float(stamp - 7 * day)]).count
                removed += try await query("DELETE FROM rounds WHERE finished = 1 AND updated_at < ? RETURNING round_id", [.float(stamp - 30 * day)]).count
                // After the outbox sweep above, so "nothing delivered" means nothing in the week
                // the outbox still remembers.
                let stale = try await query(
                    """
                    SELECT device_id FROM devices
                    WHERE (disabled_at IS NOT NULL AND disabled_at < ?)
                       OR (last_seen_at < ? AND NOT EXISTS (
                               SELECT 1 FROM outbox o WHERE o.device_id = devices.device_id AND o.state = ?))
                    """,
                    [.float(stamp - 7 * day), .float(stamp - 30 * day), .text(OutboxState.delivered.rawValue)]
                ).compactMap { $0.column("device_id")?.string }
                for id in stale {
                    // The same order as `deleteDevice`: the two tables without a cascade first.
                    _ = try await query("DELETE FROM move_alert_log WHERE follow_id IN (SELECT id FROM follows WHERE device_id = ?)", [.text(id)])
                    _ = try await query("DELETE FROM outbox WHERE device_id = ?", [.text(id)])
                    _ = try await query("DELETE FROM devices WHERE device_id = ?", [.text(id)])
                }
                removed += stale.count
            }
            return removed
        }
    }

    /// Removes an install and, through the cascades, its preferences, follows and activities.
    /// Called by the install itself when it resets its identity, so the row it is abandoning
    /// does not keep receiving the same alerts as the row it is about to create.
    public func deleteDevice(id: String) async throws {
        try await exclusive {
            try await transaction {
                _ = try await query("DELETE FROM move_alert_log WHERE follow_id IN (SELECT id FROM follows WHERE device_id = ?)", [.text(id)])
                _ = try await query("DELETE FROM outbox WHERE device_id = ?", [.text(id)])
                _ = try await query("DELETE FROM devices WHERE device_id = ?", [.text(id)])
            }
            logger.notice("device deleted", metadata: ["device": .string(id)])
        }
    }

    public func markDropped(id: Int, reason: String) async throws {
        try await write(
            "UPDATE outbox SET state = ?, last_error = ? WHERE id = ?",
            [.text(OutboxState.dropped.rawValue), .text(reason), .integer(id)]
        )
    }

    /// The count of alerts delivered to a device in the last 24 hours, which is the number the
    /// phone's Settings → Notifications screen shows so an over-eager follow is easy to spot.
    public func deliveredAlertCount(deviceId: String, since: Date) async throws -> Int {
        let rows = try await query(
            """
            SELECT COUNT(*) AS n FROM outbox
            WHERE device_id = ? AND state = ? AND delivered_at >= ? AND category IN (?, ?)
            """,
            [
                .text(deviceId), .text(OutboxState.delivered.rawValue), .float(since.timeIntervalSince1970),
                .text(OutboxCategory.gameMove.rawValue), .text(OutboxCategory.tournamentEvent.rawValue),
            ]
        )
        return Int(rows.first?.column("n")?.integer ?? 0)
    }

    private static func outbox(from row: SQLiteRow) throws -> OutboxEntry {
        guard let id = row.column("id")?.integer,
              let deviceId = row.column("device_id")?.string,
              let dedupeKey = row.column("dedupe_key")?.string,
              let collapseId = row.column("collapse_id")?.string,
              let categoryText = row.column("category")?.string,
              let category = OutboxCategory(rawValue: categoryText),
              let payload = row.column("payload_json")?.string,
              let title = row.column("title")?.string,
              let body = row.column("body")?.string,
              let threadId = row.column("thread_id")?.string,
              let relevance = row.column("relevance")?.double,
              let reference = row.column("reference")?.string,
              let stateText = row.column("state")?.string,
              let state = OutboxState(rawValue: stateText),
              let attempts = row.column("attempts")?.integer,
              let queuedAt = row.column("queued_at")?.double
        else { throw StoreError.corrupt("outbox row") }
        return OutboxEntry(
            id: Int(id),
            deviceId: deviceId,
            dedupeKey: dedupeKey,
            collapseId: collapseId,
            category: category,
            payloadJSON: payload,
            title: title,
            body: body,
            threadId: threadId,
            relevance: relevance,
            reference: reference,
            state: state,
            attempts: Int(attempts),
            queuedAt: Date(timeIntervalSince1970: queuedAt),
            deliveredAt: row.column("delivered_at")?.double.map(Date.init(timeIntervalSince1970:)),
            lastError: row.column("last_error")?.string
        )
    }

    // MARK: - Meta

    public func setMeta(_ key: String, _ value: String) async throws {
        try await write(
            "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
            [.text(key), .text(value)]
        )
    }

    public func meta(_ key: String) async throws -> String? {
        try await query("SELECT value FROM meta WHERE key = ?", [.text(key)]).first?.column("value")?.string
    }
}
