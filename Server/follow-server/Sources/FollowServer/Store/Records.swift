// The rows, as Swift sees them. Kept apart from the SQL so the policy code can be tested against
// values rather than against a database.

import Foundation
import FollowKit

/// One install. The install token is not here: only its SHA-256 is stored, and only the store
/// ever sees that.
public struct DeviceRecord: Sendable, Equatable {
    public var id: String
    public var platform: String
    public var environment: String
    public var apnsToken: String
    public var appVersion: String
    public var createdAt: Date
    public var lastSeenAt: Date
    /// Set when APNs told us the token is dead (410, `BadDeviceToken`, `Unregistered`). The row
    /// stays so the follows survive a reinstall that re-registers with the same install token;
    /// nothing is delivered to it meanwhile.
    public var disabledAt: Date?

    public init(
        id: String,
        platform: String,
        environment: String,
        apnsToken: String,
        appVersion: String,
        createdAt: Date,
        lastSeenAt: Date,
        disabledAt: Date? = nil
    ) {
        self.id = id
        self.platform = platform
        self.environment = environment
        self.apnsToken = apnsToken
        self.appVersion = appVersion
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.disabledAt = disabledAt
    }

    public var isActive: Bool { disabledAt == nil }
}

/// Everything the alert policy needs to know about one device, gathered once per event rather
/// than queried per follow.
public struct DeviceContext: Sendable, Equatable {
    public var device: DeviceRecord
    public var preferences: NotificationPreferences
    public var follows: [Follow]

    public init(device: DeviceRecord, preferences: NotificationPreferences, follows: [Follow]) {
        self.device = device
        self.preferences = preferences
        self.follows = follows
    }

    /// The FIDE ids this device follows as people, used by the top-boards rule: a board holding
    /// someone you follow is covered even when it is board 40.
    public var followedFideIds: Set<Int> {
        Set(follows.compactMap { follow in
            if case .player(let fideId) = follow.target { return fideId }
            return nil
        })
    }
}

/// What the server knows about a game between updates. This is the baseline rule from the plan:
/// a game is stored at the ply it was first seen at and emits nothing for it, so a restart in the
/// middle of a round is silent.
public struct GameBaseline: Sendable, Equatable {
    public var roundId: String
    public var gameId: String
    public var ply: Int
    public var fen: String
    public var status: String
    public var whiteClock: Int?
    public var blackClock: Int?
    /// When this ply was first observed. Long thinks are measured from here, not by subtracting
    /// clocks: with an increment the clock can go *up* across a move, so clock arithmetic answers
    /// a different question than "how long has this player been sitting there".
    public var observedAt: Date
    /// False for a ply the server did not watch arrive — the first sight of a game, or the ply a
    /// PGN correction left us on. A long think cannot be claimed for such a ply, because the
    /// player may have moved into it an hour before the server started.
    public var longThinkEligible: Bool
    public var updatedAt: Date

    public init(
        roundId: String,
        gameId: String,
        ply: Int,
        fen: String,
        status: String,
        whiteClock: Int? = nil,
        blackClock: Int? = nil,
        observedAt: Date,
        longThinkEligible: Bool,
        updatedAt: Date
    ) {
        self.roundId = roundId
        self.gameId = gameId
        self.ply = ply
        self.fen = fen
        self.status = status
        self.whiteClock = whiteClock
        self.blackClock = blackClock
        self.observedAt = observedAt
        self.longThinkEligible = longThinkEligible
        self.updatedAt = updatedAt
    }

    public var isFinished: Bool { status != "*" && !status.isEmpty }
}

/// What an outbox row is for. The first two are the `aps.category` the device sees; the last two
/// never reach a notification centre.
public enum OutboxCategory: String, Sendable, CaseIterable {
    case gameMove = "GAME_MOVE"
    case tournamentEvent = "TOURNAMENT_EVENT"
    case activityUpdate = "ACTIVITY_UPDATE"
    case activityEnd = "ACTIVITY_END"

    /// Live Activity updates are not alerts. A pinned activity is something the user is looking
    /// at, so mute and quiet hours do not apply to it — see `AlertEngine`.
    public var isAlert: Bool { self == .gameMove || self == .tournamentEvent }
}

public enum OutboxState: String, Sendable {
    /// Written, not yet handed to APNs. A restart picks these up.
    case queued
    /// APNs accepted it.
    case delivered
    /// Gave up after `maximumDeliveryAttempts`.
    case failed
    /// Not worth sending any more: the device is gone, or the activity was unregistered.
    case dropped
}

/// One push, durably queued.
///
/// The row exists *before* anything is handed to APNs and is marked delivered *after*. The plan's
/// text says to mark an alert sent before delivering it; that loses a push whenever delivery
/// fails, so the state is split in two instead. The `UNIQUE(device_id, dedupe_key)` index gives
/// a unique queued event. Delivery is at least once: a crash after APNs accepts a request but
/// before the delivered marker may repeat it. APNs collapse identifiers reduce visible repeats.
public struct OutboxEntry: Sendable, Equatable {
    public var id: Int
    public var deviceId: String
    /// `g:<gameId>:<ply>:<kind>:<fen>` for board alerts, `t:<tourId>:<roundId>:<kind>` for event
    /// alerts, `a:<gameId>:<ply>:<event>` for activity updates. Unique per device.
    public var dedupeKey: String
    public var collapseId: String
    public var category: OutboxCategory
    /// The `d` payload, already encoded: a `MovePush`, a `TournamentPush`, or a
    /// `LiveActivityState`.
    public var payloadJSON: String
    public var title: String
    public var body: String
    public var threadId: String
    public var relevance: Double
    /// The game id, for an activity row: the token to push to is looked up at delivery time, not
    /// at enqueue time, because an ActivityKit token can be replaced while a push is queued.
    public var reference: String
    public var state: OutboxState
    public var attempts: Int
    public var queuedAt: Date
    public var deliveredAt: Date?
    public var lastError: String?

    public init(
        id: Int = 0,
        deviceId: String,
        dedupeKey: String,
        collapseId: String,
        category: OutboxCategory,
        payloadJSON: String,
        title: String = "",
        body: String = "",
        threadId: String = "",
        relevance: Double = 0.5,
        reference: String = "",
        state: OutboxState = .queued,
        attempts: Int = 0,
        queuedAt: Date = Date(),
        deliveredAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.deviceId = deviceId
        self.dedupeKey = dedupeKey
        self.collapseId = collapseId
        self.category = category
        self.payloadJSON = payloadJSON
        self.title = title
        self.body = body
        self.threadId = threadId
        self.relevance = relevance
        self.reference = reference
        self.state = state
        self.attempts = attempts
        self.queuedAt = queuedAt
        self.deliveredAt = deliveredAt
        self.lastError = lastError
    }
}

/// A round of a followed tournament, as the last poll saw it.
///
/// `ongoing` and `finished` come from Lichess and are never guessed from the clock: a round that
/// was due at 14:00 and starts at 14:40 must produce one early heads-up and one accurate "live
/// now", not a wrong one at 14:00.
public struct RoundRecord: Sendable, Equatable {
    public var roundId: String
    public var tourId: String
    public var name: String
    public var startsAt: Date?
    public var ongoing: Bool
    public var finished: Bool
    public var updatedAt: Date

    public init(roundId: String, tourId: String, name: String, startsAt: Date?, ongoing: Bool, finished: Bool, updatedAt: Date = Date()) {
        self.roundId = roundId
        self.tourId = tourId
        self.name = name
        self.startsAt = startsAt
        self.ongoing = ongoing
        self.finished = finished
        self.updatedAt = updatedAt
    }
}

/// A registered Live Activity. One per device: `POST /v1/activities` replaces whatever was there.
public struct ActivityRecord: Sendable, Equatable {
    public var deviceId: String
    public var roundId: String
    public var gameId: String
    public var activityToken: String
    public var createdAt: Date

    public init(deviceId: String, roundId: String, gameId: String, activityToken: String, createdAt: Date = Date()) {
        self.deviceId = deviceId
        self.roundId = roundId
        self.gameId = gameId
        self.activityToken = activityToken
        self.createdAt = createdAt
    }
}
