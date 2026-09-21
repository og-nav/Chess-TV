// The schema, as a list of migrations.
//
// Migrations are applied in order and recorded in `schema_migrations`, so a deploy over an
// existing database only runs what is new. There is exactly one writer (the store actor), so no
// migration needs a lock of its own.

enum Schema {

    /// Appended to, never edited. Changing a statement that has already run on the VPS would
    /// leave that box on a schema no version of this file describes.
    static let migrations: [(name: String, statements: [String])] = [
        (
            name: "0001_initial",
            statements: [
                """
                CREATE TABLE devices (
                    device_id     TEXT PRIMARY KEY,
                    token_hash    TEXT NOT NULL UNIQUE,
                    platform      TEXT NOT NULL,
                    environment   TEXT NOT NULL,
                    apns_token    TEXT NOT NULL,
                    app_version   TEXT NOT NULL,
                    created_at    REAL NOT NULL,
                    last_seen_at  REAL NOT NULL,
                    disabled_at   REAL
                )
                """,
                // Routing addresses are indexed for diagnostics, never treated as identity proof.
                "CREATE INDEX devices_apns_token ON devices (apns_token)",
                """
                CREATE TABLE preferences (
                    device_id   TEXT PRIMARY KEY REFERENCES devices (device_id) ON DELETE CASCADE,
                    json        TEXT NOT NULL,
                    updated_at  REAL NOT NULL
                )
                """,
                """
                CREATE TABLE follows (
                    id           TEXT PRIMARY KEY,
                    device_id    TEXT NOT NULL REFERENCES devices (device_id) ON DELETE CASCADE,
                    target_kind  TEXT NOT NULL,
                    target_key   TEXT NOT NULL,
                    alerts_json  TEXT NOT NULL,
                    created_at   REAL NOT NULL,
                    UNIQUE (device_id, target_kind, target_key)
                )
                """,
                "CREATE INDEX follows_target ON follows (target_kind, target_key)",
                """
                CREATE TABLE activities (
                    device_id       TEXT NOT NULL REFERENCES devices (device_id) ON DELETE CASCADE,
                    round_id        TEXT NOT NULL,
                    game_id         TEXT NOT NULL,
                    activity_token  TEXT NOT NULL,
                    created_at      REAL NOT NULL,
                    PRIMARY KEY (device_id)
                )
                """,
                "CREATE INDEX activities_game ON activities (game_id)",
                """
                CREATE TABLE game_baselines (
                    round_id            TEXT NOT NULL,
                    game_id             TEXT NOT NULL,
                    ply                 INTEGER NOT NULL,
                    fen                 TEXT NOT NULL,
                    status              TEXT NOT NULL,
                    white_clock         INTEGER,
                    black_clock         INTEGER,
                    observed_at         REAL NOT NULL,
                    long_think_eligible INTEGER NOT NULL,
                    updated_at          REAL NOT NULL,
                    PRIMARY KEY (round_id, game_id)
                )
                """,
                // The server's own record that it has *seen* a tournament transition, which is
                // what stops a moved `startsAt` re-arming an alert that already fired. Per-device
                // delivery is deduped by the outbox, not by this table.
                """
                CREATE TABLE tournament_events (
                    tour_id     TEXT NOT NULL,
                    round_id    TEXT NOT NULL,
                    kind        TEXT NOT NULL,
                    observed_at REAL NOT NULL,
                    PRIMARY KEY (tour_id, round_id, kind)
                )
                """,
                """
                CREATE TABLE rounds (
                    round_id   TEXT PRIMARY KEY,
                    tour_id    TEXT NOT NULL,
                    name       TEXT NOT NULL,
                    starts_at  REAL,
                    ongoing    INTEGER NOT NULL,
                    finished   INTEGER NOT NULL,
                    updated_at REAL NOT NULL
                )
                """,
                """
                CREATE TABLE outbox (
                    id           INTEGER PRIMARY KEY AUTOINCREMENT,
                    device_id    TEXT NOT NULL,
                    dedupe_key   TEXT NOT NULL,
                    collapse_id  TEXT NOT NULL,
                    category     TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    title        TEXT NOT NULL,
                    body         TEXT NOT NULL,
                    thread_id    TEXT NOT NULL,
                    relevance    REAL NOT NULL,
                    reference    TEXT NOT NULL,
                    state        TEXT NOT NULL,
                    attempts     INTEGER NOT NULL DEFAULT 0,
                    queued_at    REAL NOT NULL,
                    delivered_at REAL,
                    last_error   TEXT,
                    UNIQUE (device_id, dedupe_key)
                )
                """,
                "CREATE INDEX outbox_pending ON outbox (state, queued_at)",
                // One row per follow and game: the cooldown behind `minMinutesBetweenMoveAlerts`.
                """
                CREATE TABLE move_alert_log (
                    follow_id    TEXT NOT NULL,
                    game_id      TEXT NOT NULL,
                    last_sent_at REAL NOT NULL,
                    PRIMARY KEY (follow_id, game_id)
                )
                """,
                "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
            ]
        ),
        (
            name: "0002_outbox_backoff",
            statements: [
                // When a row that failed may be tried again. NULL means now.
                "ALTER TABLE outbox ADD COLUMN next_attempt_at REAL",
            ]
        ),
    ]
}
