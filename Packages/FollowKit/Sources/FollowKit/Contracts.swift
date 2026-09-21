// FollowKit — frozen contracts (see MOBILE_BUILD_PLAN.md, "Interface contracts").
//
// These types are the wire format between four codebases: the iPhone/iPad app, the watch app, the
// notification extensions and the follow server. They are declared exactly as the plan declares
// them, with two additions the plan implies but does not spell out:
//
//   * every type has a public memberwise initializer with defaults, so a caller can write
//     `FollowAlerts()` or `NotificationPreferences()` and get something sensible; and
//   * the enums with associated values encode explicitly rather than through the synthesised
//     shape, because the synthesised shape for `FollowTarget` is a nested single-key object that
//     is painful to read in a log and impossible to query in SQL.
//
// Dates on the REST API are ISO 8601 (see `FollowJSON`). The one exception is `LiveActivityState`
// when it travels as an ActivityKit content state, which the system decodes with a stock
// `JSONDecoder`; `FollowJSON.activityEncoder` exists for exactly that, and the difference is
// documented on the type.

import Foundation

// MARK: - Devices

/// What the app tells the server about itself on `POST /v1/devices`.
///
/// There is no account and no email. The device is identified from here on by the install token
/// the server mints in reply.
public struct DeviceRegistration: Codable, Sendable, Hashable {
    /// `"ios"` or `"watchos"`. The server keeps it for diagnostics only; the APNs topic is the
    /// same universal-purchase bundle id on both.
    public var platform: String
    /// `"sandbox"` or `"production"` — which APNs host the token belongs to. A development build
    /// and a TestFlight build hand out tokens on different hosts, and sending one to the other is
    /// the classic silent failure.
    public var environment: String
    /// The APNs device token, lowercase hex.
    public var apnsToken: String
    /// `CFBundleShortVersionString`, so the server can tell an old client from a new one.
    public var appVersion: String

    public init(platform: String = "ios", environment: String = "production", apnsToken: String = "", appVersion: String = "0.1") {
        self.platform = platform
        self.environment = environment
        self.apnsToken = apnsToken
        self.appVersion = appVersion
    }

    /// `true` when the registration names a platform and an environment the server supports and
    /// carries a plausible APNs token. Checked on the server; checked here too so the app can
    /// avoid a round trip it knows will fail.
    public var isWellFormed: Bool {
        guard ["ios", "watchos", "ipados", "tvos"].contains(platform) else { return false }
        guard ["sandbox", "production"].contains(environment) else { return false }
        guard (32...200).contains(apnsToken.count) else { return false }
        return apnsToken.allSatisfy(\.isHexDigit)
    }
}

/// The reply to a registration: an opaque device id and the bearer token every later request
/// carries. The app puts the token in the Keychain (`KeychainCredentialStore`) and never logs it.
public struct DeviceCredential: Codable, Sendable, Hashable {
    public var deviceId: String
    public var installToken: String

    public init(deviceId: String = "", installToken: String = "") {
        self.deviceId = deviceId
        self.installToken = installToken
    }
}

// MARK: - Follow targets

/// What a follow points at.
///
/// A player is held by FIDE id rather than by name, because the name in a broadcast PGN is spelled
/// differently from event to event while the FIDE id survives; the server resolves the id to a
/// board each round from the round JSON.
///
/// Encoded as `{"kind": "...", …}` rather than through the synthesised enum shape, so that a row
/// in the server's SQLite and a line in a log are both readable.
public enum FollowTarget: Codable, Sendable, Hashable {
    case player(fideId: Int)
    case game(roundId: String, gameId: String)
    case tournament(tourId: String)

    /// `"player"`, `"game"` or `"tournament"` — the discriminator on the wire and the
    /// `target_kind` column on the server.
    public var kind: String {
        switch self {
        case .player: "player"
        case .game: "game"
        case .tournament: "tournament"
        }
    }

    /// A stable string that, with `kind`, identifies the target: the FIDE id, `roundId/gameId`,
    /// or the tour id. The server's uniqueness constraint is `(device, kind, key)`, which is what
    /// stops a double tap on Follow making two rows.
    public var key: String {
        switch self {
        case .player(let fideId): String(fideId)
        case .game(let roundId, let gameId): "\(roundId)/\(gameId)"
        case .tournament(let tourId): tourId
        }
    }

    /// Rebuilds a target from `kind` and `key`, which is how the server reads one back out of
    /// SQLite. Nil when the pair does not describe a target.
    public init?(kind: String, key: String) {
        switch kind {
        case "player":
            guard let fideId = Int(key) else { return nil }
            self = .player(fideId: fideId)
        case "game":
            let parts = key.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            self = .game(roundId: String(parts[0]), gameId: String(parts[1]))
        case "tournament":
            guard !key.isEmpty else { return nil }
            self = .tournament(tourId: key)
        default:
            return nil
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, fideId, roundId, gameId, tourId }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "player":
            self = .player(fideId: try container.decode(Int.self, forKey: .fideId))
        case "game":
            self = .game(
                roundId: try container.decode(String.self, forKey: .roundId),
                gameId: try container.decode(String.self, forKey: .gameId)
            )
        case "tournament":
            self = .tournament(tourId: try container.decode(String.self, forKey: .tourId))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown follow target kind '\(kind)'")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .player(let fideId): try container.encode(fideId, forKey: .fideId)
        case .game(let roundId, let gameId):
            try container.encode(roundId, forKey: .roundId)
            try container.encode(gameId, forKey: .gameId)
        case .tournament(let tourId): try container.encode(tourId, forKey: .tourId)
        }
    }
}

// MARK: - Alerts

/// The alerts a player or game follow can send.
public enum GameAlert: String, Codable, Sendable, CaseIterable, Hashable {
    case start, move, longThink, end
}

/// The alerts a tournament follow can send.
public enum TournamentAlert: String, Codable, Sendable, CaseIterable, Hashable {
    case startingSoon, roundLive, gameResults, roundSummary, finished, topBoardMoves
}

/// The switches on one follow. A follow uses the set its target kind cares about and ignores the
/// other; the numbers apply to whichever it uses.
///
/// This is a set of switches rather than one mode because a single enum cannot express "tell me
/// when the round starts and who won, but not every move", which is the common case for a
/// tournament follow.
public struct FollowAlerts: Codable, Sendable, Hashable {
    /// Used by `player` and `game` follows.
    public var game: Set<GameAlert>
    /// Used by `tournament` follows.
    public var tournament: Set<TournamentAlert>
    /// 0 = every move. Applies to `move` and to `topBoardMoves`; the server holds the clock per
    /// follow and game, so two follows with different intervals do not interfere.
    public var minMinutesBetweenMoveAlerts: Int
    /// How long a player has to sit on one position before `longThink` fires. Measured by the
    /// server from when it first observed the position, not by subtracting clocks — an increment
    /// makes clock subtraction lie.
    public var longThinkMinutes: Int
    /// How far ahead of `startsAt` the `startingSoon` alert fires.
    public var startingSoonMinutes: Int
    /// 1…5. `gameResults` and `topBoardMoves` cover these boards in round order, plus any board
    /// holding a player the same device follows. Everything else is covered by `roundSummary`.
    public var topBoards: Int

    public init(
        game: Set<GameAlert> = [],
        tournament: Set<TournamentAlert> = [],
        minMinutesBetweenMoveAlerts: Int = 0,
        longThinkMinutes: Int = 10,
        startingSoonMinutes: Int = 15,
        topBoards: Int = 1
    ) {
        self.game = game
        self.tournament = tournament
        self.minMinutesBetweenMoveAlerts = minMinutesBetweenMoveAlerts
        self.longThinkMinutes = longThinkMinutes
        self.startingSoonMinutes = startingSoonMinutes
        self.topBoards = topBoards
    }

    /// The bounds the server enforces and the UI should not offer past. A hostile or buggy client
    /// cannot turn one follow into a thousand pushes an hour by sending a negative interval.
    public static let topBoardsRange = 1...5
    public static let minutesBetweenMoveAlertsRange = 0...240
    public static let longThinkRange = 1...120
    public static let startingSoonRange = 1...720

    /// The same value with every number pulled inside its range. The server calls this on the way
    /// in; the app may call it too so the UI shows what will actually happen.
    public func clamped() -> FollowAlerts {
        var copy = self
        copy.topBoards = min(max(topBoards, Self.topBoardsRange.lowerBound), Self.topBoardsRange.upperBound)
        copy.minMinutesBetweenMoveAlerts = min(max(minMinutesBetweenMoveAlerts, Self.minutesBetweenMoveAlertsRange.lowerBound), Self.minutesBetweenMoveAlertsRange.upperBound)
        copy.longThinkMinutes = min(max(longThinkMinutes, Self.longThinkRange.lowerBound), Self.longThinkRange.upperBound)
        copy.startingSoonMinutes = min(max(startingSoonMinutes, Self.startingSoonRange.lowerBound), Self.startingSoonRange.upperBound)
        return copy
    }

    /// Following a person: you want to know when they sit down and how it went, not every move of
    /// a six-hour classical game.
    public static let playerDefaults = FollowAlerts(game: [.start, .end])
    /// Following one board: you asked for that game in particular, so a long think is interesting.
    public static let gameDefaults = FollowAlerts(game: [.start, .longThink, .end])
    /// Following an event: the shape of the day, not the moves. `topBoardMoves` stays off.
    public static let tournamentDefaults = FollowAlerts(
        tournament: [.startingSoon, .roundLive, .gameResults, .roundSummary, .finished]
    )

    /// The defaults for a target kind, used when the app has no stored preference to fall back on.
    public static func defaults(for target: FollowTarget) -> FollowAlerts {
        switch target {
        case .player: .playerDefaults
        case .game: .gameDefaults
        case .tournament: .tournamentDefaults
        }
    }

    // Written by hand so an older client, or a field added later, decodes into the defaults
    // instead of failing the whole request.
    private enum CodingKeys: String, CodingKey {
        case game, tournament, minMinutesBetweenMoveAlerts, longThinkMinutes, startingSoonMinutes, topBoards
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        game = try container.decodeIfPresent(Set<GameAlert>.self, forKey: .game) ?? []
        tournament = try container.decodeIfPresent(Set<TournamentAlert>.self, forKey: .tournament) ?? []
        minMinutesBetweenMoveAlerts = try container.decodeIfPresent(Int.self, forKey: .minMinutesBetweenMoveAlerts) ?? 0
        longThinkMinutes = try container.decodeIfPresent(Int.self, forKey: .longThinkMinutes) ?? 10
        startingSoonMinutes = try container.decodeIfPresent(Int.self, forKey: .startingSoonMinutes) ?? 15
        topBoards = try container.decodeIfPresent(Int.self, forKey: .topBoards) ?? 1
    }
}

/// One follow. `id` is minted by the server; a client creating a follow may send anything (the
/// plan says the id is ignored on `POST`), and the reply carries the real one.
public struct Follow: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var target: FollowTarget
    public var alerts: FollowAlerts
    public var createdAt: Date

    public init(id: String = "", target: FollowTarget, alerts: FollowAlerts? = nil, createdAt: Date = Date()) {
        self.id = id
        self.target = target
        self.alerts = alerts ?? .defaults(for: target)
        self.createdAt = createdAt
    }
}

// MARK: - Preferences

/// The per-device settings the server enforces, so that a muted device costs no push at all and
/// the watch and the phone cannot disagree about the rules.
public struct NotificationPreferences: Codable, Sendable, Hashable {
    public var muteAll: Bool
    /// Minutes from local midnight. Both nil means no quiet hours. `start > end` is an overnight
    /// window (22:00 → 07:00), which is the usual one.
    public var quietHoursStart: Int?
    public var quietHoursEnd: Int?
    /// The device's time zone, so the server can work out "is it night there" without the device.
    public var timeZoneIdentifier: String
    /// When on, a game-end alert is delivered during quiet hours anyway.
    public var gameEndIgnoresQuietHours: Bool
    public var newPlayerFollowDefaults: FollowAlerts
    public var newGameFollowDefaults: FollowAlerts
    public var newTournamentFollowDefaults: FollowAlerts

    public init(
        muteAll: Bool = false,
        quietHoursStart: Int? = nil,
        quietHoursEnd: Int? = nil,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        gameEndIgnoresQuietHours: Bool = false,
        newPlayerFollowDefaults: FollowAlerts = .playerDefaults,
        newGameFollowDefaults: FollowAlerts = .gameDefaults,
        newTournamentFollowDefaults: FollowAlerts = .tournamentDefaults
    ) {
        self.muteAll = muteAll
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
        self.timeZoneIdentifier = timeZoneIdentifier
        self.gameEndIgnoresQuietHours = gameEndIgnoresQuietHours
        self.newPlayerFollowDefaults = newPlayerFollowDefaults
        self.newGameFollowDefaults = newGameFollowDefaults
        self.newTournamentFollowDefaults = newTournamentFollowDefaults
    }

    /// The defaults a new follow of this kind should start from.
    public func defaults(for target: FollowTarget) -> FollowAlerts {
        switch target {
        case .player: newPlayerFollowDefaults
        case .game: newGameFollowDefaults
        case .tournament: newTournamentFollowDefaults
        }
    }

    /// `true` when `date` falls inside the quiet window in this device's time zone.
    ///
    /// Lives here rather than on the server so that the phone's Settings screen can say "quiet
    /// now" with the same arithmetic the server uses to drop the push.
    public func isQuiet(at date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Bool {
        guard let start = quietHoursStart, let end = quietHoursEnd, start != end else { return false }
        var calendar = calendar
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if start < end { return minutes >= start && minutes < end }
        return minutes >= start || minutes < end     // the window crosses midnight
    }

    /// Whether a device in this state should be sent an alert of this kind right now.
    ///
    /// Note what this does *not* cover: Live Activity updates. A pinned activity is a thing the
    /// user is looking at, not an interruption, so the server updates it whatever the mute switch
    /// says — see `PushDecision` on the server for where that is enforced.
    public func allowsAlert(kind: MovePushKind, at date: Date) -> Bool {
        if muteAll { return false }
        guard isQuiet(at: date) else { return true }
        let isEnding = kind == .gameEnd || kind == .gameResult
        return isEnding && gameEndIgnoresQuietHours
    }

    /// The same question for an event-shaped alert. Nothing about a tournament is exempt from
    /// quiet hours: a round going live at 3am is exactly what quiet hours are for.
    public func allowsAlert(kind: TournamentPushKind, at date: Date) -> Bool {
        if muteAll { return false }
        return !isQuiet(at: date)
    }

    private enum CodingKeys: String, CodingKey {
        case muteAll, quietHoursStart, quietHoursEnd, timeZoneIdentifier, gameEndIgnoresQuietHours
        case newPlayerFollowDefaults, newGameFollowDefaults, newTournamentFollowDefaults
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        muteAll = try container.decodeIfPresent(Bool.self, forKey: .muteAll) ?? false
        quietHoursStart = try container.decodeIfPresent(Int.self, forKey: .quietHoursStart)
        quietHoursEnd = try container.decodeIfPresent(Int.self, forKey: .quietHoursEnd)
        timeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .timeZoneIdentifier) ?? TimeZone.current.identifier
        gameEndIgnoresQuietHours = try container.decodeIfPresent(Bool.self, forKey: .gameEndIgnoresQuietHours) ?? false
        newPlayerFollowDefaults = try container.decodeIfPresent(FollowAlerts.self, forKey: .newPlayerFollowDefaults) ?? .playerDefaults
        newGameFollowDefaults = try container.decodeIfPresent(FollowAlerts.self, forKey: .newGameFollowDefaults) ?? .gameDefaults
        newTournamentFollowDefaults = try container.decodeIfPresent(FollowAlerts.self, forKey: .newTournamentFollowDefaults) ?? .tournamentDefaults
    }

    /// Minutes outside 0..<1440, or a time zone the system does not know, are corrected rather
    /// than rejected: a wrong quiet window is a bad night's sleep, not a protocol error.
    public func sanitized() -> NotificationPreferences {
        var copy = self
        func inDay(_ value: Int?) -> Int? {
            guard let value else { return nil }
            return (value % 1440 + 1440) % 1440
        }
        copy.quietHoursStart = inDay(quietHoursStart)
        copy.quietHoursEnd = inDay(quietHoursEnd)
        if copy.quietHoursStart == nil || copy.quietHoursEnd == nil {
            copy.quietHoursStart = nil
            copy.quietHoursEnd = nil
        }
        if TimeZone(identifier: timeZoneIdentifier) == nil { copy.timeZoneIdentifier = "UTC" }
        copy.newPlayerFollowDefaults = newPlayerFollowDefaults.clamped()
        copy.newGameFollowDefaults = newGameFollowDefaults.clamped()
        copy.newTournamentFollowDefaults = newTournamentFollowDefaults.clamped()
        return copy
    }
}

// MARK: - Push payloads

/// A player as a push payload carries them: enough to draw the row, nothing more.
public struct PushPlayer: Codable, Sendable, Hashable {
    public var name: String
    public var title: String?
    public var rating: Int?
    /// Three-letter federation code, when the round JSON gave one.
    public var fed: String?

    public init(name: String = "", title: String? = nil, rating: Int? = nil, fed: String? = nil) {
        self.name = name
        self.title = title
        self.rating = rating
        self.fed = fed
    }
}

/// The kinds a board-shaped alert comes in. `MovePush.kind` is a `String` in the contract; this is
/// the closed set it holds, so neither side has to spell a literal.
public enum MovePushKind: String, Codable, Sendable, CaseIterable, Hashable {
    case gameStart, move, longThink, gameEnd, gameResult
}

/// The `d` key of a board-shaped alert (`aps.category == PushCategory.gameMove`).
///
/// Everything the notification service extension needs to draw the board and write the title is
/// here; nothing is fetched. That keeps the payload under APNs' 4 KB and means a notification
/// renders with the network off.
public struct MovePush: Codable, Sendable, Hashable {
    public var kind: String
    public var roundId: String
    public var gameId: String
    public var tourName: String
    public var roundName: String
    public var white: PushPlayer
    public var black: PushPlayer
    public var fen: String
    /// UCI, for highlighting the squares.
    public var lastMove: String?
    /// SAN, for the wording.
    public var san: String?
    public var ply: Int
    /// Seconds remaining, when the PGN carried a `%clk`.
    public var whiteClock: Int?
    public var blackClock: Int?
    /// The PGN result token: `"*"`, `"1-0"`, `"0-1"`, `"1/2-1/2"`.
    public var status: String
    public var sentAt: Date

    public init(
        kind: MovePushKind = .move,
        roundId: String = "",
        gameId: String = "",
        tourName: String = "",
        roundName: String = "",
        white: PushPlayer = PushPlayer(),
        black: PushPlayer = PushPlayer(),
        fen: String = MovePush.startingFEN,
        lastMove: String? = nil,
        san: String? = nil,
        ply: Int = 0,
        whiteClock: Int? = nil,
        blackClock: Int? = nil,
        status: String = "*",
        sentAt: Date = Date()
    ) {
        self.kind = kind.rawValue
        self.roundId = roundId
        self.gameId = gameId
        self.tourName = tourName
        self.roundName = roundName
        self.white = white
        self.black = black
        self.fen = fen
        self.lastMove = lastMove
        self.san = san
        self.ply = ply
        self.whiteClock = whiteClock
        self.blackClock = blackClock
        self.status = status
        self.sentAt = sentAt
    }

    public static let startingFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

    /// The kind as the enum, or nil if a newer server sent one this build does not know. An
    /// extension that gets nil should still render the board and fall back to a plain title.
    public var pushKind: MovePushKind? { MovePushKind(rawValue: kind) }

    /// `true` once the game has a result.
    public var isFinished: Bool { status != "*" && !status.isEmpty }

    /// Whose move it is in `fen`, as `"white"` or `"black"`; nil when the FEN is unreadable.
    /// The extension and the Live Activity use it to decide which clock is ticking.
    public var sideToMove: String? {
        let fields = fen.split(separator: " ")
        guard fields.count >= 2 else { return nil }
        return fields[1] == "w" ? "white" : (fields[1] == "b" ? "black" : nil)
    }

    /// `"23. Nf5"` or `"23... Nf5"` — the move as a person writes it, so the extension does not
    /// have to count.
    ///
    /// Read from the FEN's side-to-move and fullmove number where it can be, because a game
    /// broadcast from a setup position (an adjournment, a study, a `[FEN]` tag with Black to
    /// move) has no fixed relationship between the ply count and the move number: ply 1 can be
    /// `41... Kg7`. The ply's parity is the fallback for a FEN too short to answer, which is the
    /// standard-opening case where the two agree anyway.
    public var numberedSAN: String? {
        guard let san, ply > 0 else { return nil }
        let fields = fen.split(separator: " ")
        if fields.count >= 6, let fullmove = Int(fields[5]), fullmove > 0 {
            // The FEN describes the position *after* the move: Black to move means White just
            // played and the counter has not advanced; White to move means Black just played and
            // it has.
            return fields[1] == "b" ? "\(fullmove). \(san)" : "\(max(1, fullmove - 1))... \(san)"
        }
        let moveNumber = (ply + 1) / 2
        return ply % 2 == 1 ? "\(moveNumber). \(san)" : "\(moveNumber)... \(san)"
    }
}

/// The kinds an event-shaped alert comes in.
public enum TournamentPushKind: String, Codable, Sendable, CaseIterable, Hashable {
    case startingSoon, roundLive, roundFinished, tournamentFinished
}

/// The `d` key of an event-shaped alert (`aps.category == PushCategory.tournamentEvent`).
/// There is no board to draw; the extension attaches the tour banner instead, if it can.
public struct TournamentPush: Codable, Sendable, Hashable {
    public var kind: String
    public var tourId: String
    public var tourName: String
    public var roundId: String?
    public var roundName: String?
    public var startsAt: Date?
    public var boardCount: Int?
    /// `"Carlsen 1–0 Nepomniachtchi"`, top boards first, at most five.
    public var results: [String]?
    /// Only when the round JSON gave enough to say it.
    public var leaders: [String]?
    /// The tour image from the broadcast JSON. The server never downloads it; the extension does,
    /// on the device, and skips it if it is slow or large.
    public var bannerURL: URL?
    public var sentAt: Date

    public init(
        kind: TournamentPushKind = .roundLive,
        tourId: String = "",
        tourName: String = "",
        roundId: String? = nil,
        roundName: String? = nil,
        startsAt: Date? = nil,
        boardCount: Int? = nil,
        results: [String]? = nil,
        leaders: [String]? = nil,
        bannerURL: URL? = nil,
        sentAt: Date = Date()
    ) {
        self.kind = kind.rawValue
        self.tourId = tourId
        self.tourName = tourName
        self.roundId = roundId
        self.roundName = roundName
        self.startsAt = startsAt
        self.boardCount = boardCount
        self.results = results
        self.leaders = leaders
        self.bannerURL = bannerURL
        self.sentAt = sentAt
    }

    public var pushKind: TournamentPushKind? { TournamentPushKind(rawValue: kind) }
}

// MARK: - Live Activity

/// The ActivityKit content state for the one pinned broadcast game.
///
/// **Date encoding.** ActivityKit decodes the `content-state` from the push with a stock
/// `JSONDecoder`, whose date strategy is `.deferredToDate` — a `Double` of seconds since the 2001
/// reference date, *not* ISO 8601. The server therefore encodes this type (and only this type)
/// with `FollowJSON.activityEncoder`. Everything on the REST API keeps ISO 8601.
public struct LiveActivityState: Codable, Sendable, Hashable {
    public var fen: String
    public var lastMove: String?
    public var san: String?
    public var ply: Int
    public var whiteClock: Int?
    public var blackClock: Int?
    /// `"white"` or `"black"` — whose clock the widget should count down locally. Nil when the
    /// game is over and both clocks are frozen.
    public var clockRunningFor: String?
    public var status: String
    /// When the clocks above were true. The widget counts down from here.
    public var asOf: Date

    public init(
        fen: String = MovePush.startingFEN,
        lastMove: String? = nil,
        san: String? = nil,
        ply: Int = 0,
        whiteClock: Int? = nil,
        blackClock: Int? = nil,
        clockRunningFor: String? = nil,
        status: String = "*",
        asOf: Date = Date()
    ) {
        self.fen = fen
        self.lastMove = lastMove
        self.san = san
        self.ply = ply
        self.whiteClock = whiteClock
        self.blackClock = blackClock
        self.clockRunningFor = clockRunningFor
        self.status = status
        self.asOf = asOf
    }

    /// The state a board-shaped push describes, so the server and the app build the same thing
    /// from the same event.
    public init(_ push: MovePush) {
        self.init(
            fen: push.fen,
            lastMove: push.lastMove,
            san: push.san,
            ply: push.ply,
            whiteClock: push.whiteClock,
            blackClock: push.blackClock,
            clockRunningFor: push.isFinished ? nil : push.sideToMove,
            status: push.status,
            asOf: push.sentAt
        )
    }

    public var isFinished: Bool { status != "*" && !status.isEmpty }
}

/// What the app sends on `POST /v1/activities` to have the server push updates to a Live Activity.
/// One per device: registering a second replaces the first, which is how "pin this game instead"
/// works without an extra call.
public struct ActivityRegistration: Codable, Sendable, Hashable {
    public var roundId: String
    public var gameId: String
    /// The ActivityKit push token, lowercase hex. Distinct from the device's APNs token and much
    /// shorter-lived.
    public var activityToken: String

    public init(roundId: String = "", gameId: String = "", activityToken: String = "") {
        self.roundId = roundId
        self.gameId = gameId
        self.activityToken = activityToken
    }
}

// MARK: - Health

/// The body of `GET /v1/health`, the one endpoint that needs no token. The Settings → About row
/// shows the server's reachability from this.
public struct ServerHealth: Codable, Sendable, Hashable {
    public var ok: Bool
    public var roundsWatched: Int
    public var roundsScheduled: Int
    public var lastLichessEventAt: Date?

    public init(ok: Bool = true, roundsWatched: Int = 0, roundsScheduled: Int = 0, lastLichessEventAt: Date? = nil) {
        self.ok = ok
        self.roundsWatched = roundsWatched
        self.roundsScheduled = roundsScheduled
        self.lastLichessEventAt = lastLichessEventAt
    }
}
