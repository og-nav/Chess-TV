// The ActivityKit attributes for a pinned broadcast game.
//
// This file must be a member of both the app target and the Live Activity widget extension: the
// two processes decode the same `ContentState`, and ActivityKit matches activities by the
// attributes type's name.
//
// ## The date problem, stated once
//
// An ActivityKit update push carries `aps["content-state"]`, and the system decodes it with a
// **default `JSONDecoder`**. Default means `.deferredToDate`, which for a `Date` property means a
// JSON **number of seconds since 2001-01-01 UTC** — not ISO 8601, and not a Unix timestamp. Every
// other date on this project's wires is ISO 8601 (see `FollowJSON`), and the gap between the two
// epochs is 978,307,200 seconds, so getting it wrong produces a date in 1970 or 2054 rather than
// an error anyone would notice in review.
//
// Rather than rely on the server remembering, `ContentState` decodes `asOf` from **either** form:
// a number is read as Apple's reference epoch, a string as ISO 8601. It always *encodes* the
// numeric form, so a locally-created activity and a pushed one agree. The server agent is asked in
// the report to send the numeric form; the fixtures under `Fixtures/activity-*.apns` use it.
#if canImport(ActivityKit)
import ActivityKit
#endif
import Foundation

import FollowKit

/// The parts of a pinned game that never change while it is pinned.
public struct ChessGameAttributesPayload: Codable, Sendable, Hashable {
    public var roundId: String
    public var gameId: String
    public var tourName: String
    public var roundName: String
    public var whiteName: String
    public var blackName: String
    public var whiteTitle: String?
    public var blackTitle: String?
    public var whiteRating: Int?
    public var blackRating: Int?
    /// The colour at the bottom of the board, captured when the game was pinned, because a widget
    /// has no sensible moment to re-read the app's settings mid-activity.
    public var orientationIsWhite: Bool

    /// Shared by the Lock Screen and every Dynamic Island presentation.
    public var gameURL: URL? {
        URL(string: "chesstv://game")?
            .appendingPathComponent(roundId)
            .appendingPathComponent(gameId)
    }

    public init(
        roundId: String, gameId: String, tourName: String, roundName: String,
        whiteName: String, blackName: String, whiteTitle: String? = nil, blackTitle: String? = nil,
        whiteRating: Int? = nil, blackRating: Int? = nil, orientationIsWhite: Bool = true
    ) {
        self.roundId = roundId
        self.gameId = gameId
        self.tourName = tourName
        self.roundName = roundName
        self.whiteName = whiteName
        self.blackName = blackName
        self.whiteTitle = whiteTitle
        self.blackTitle = blackTitle
        self.whiteRating = whiteRating
        self.blackRating = blackRating
        self.orientationIsWhite = orientationIsWhite
    }
}

/// The moving part. Mirrors `FollowKit.LiveActivityState` field for field; the only difference is
/// the tolerant `asOf` decoding explained above.
public struct ChessGameActivityState: Codable, Sendable, Hashable {
    public var fen: String
    public var lastMove: String?
    public var san: String?
    public var ply: Int
    public var whiteClock: Int?
    public var blackClock: Int?
    /// "white" | "black" | nil when nothing is running.
    public var clockRunningFor: String?
    public var status: String
    public var asOf: Date

    public init(
        fen: String, lastMove: String? = nil, san: String? = nil, ply: Int,
        whiteClock: Int? = nil, blackClock: Int? = nil, clockRunningFor: String? = nil,
        status: String, asOf: Date
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

    public init(_ state: LiveActivityState) {
        self.init(
            fen: state.fen, lastMove: state.lastMove, san: state.san, ply: state.ply,
            whiteClock: state.whiteClock, blackClock: state.blackClock,
            clockRunningFor: state.clockRunningFor, status: state.status, asOf: state.asOf
        )
    }

    public var asLiveActivityState: LiveActivityState {
        LiveActivityState(
            fen: fen, lastMove: lastMove, san: san, ply: ply,
            whiteClock: whiteClock, blackClock: blackClock,
            clockRunningFor: clockRunningFor, status: status, asOf: asOf
        )
    }

    // MARK: - Derived

    public var isFinished: Bool { ChessFormat.isFinished(status: status) }

    /// Which clock is running, ignoring `clockRunningFor` once the game is over. A finished game
    /// freezes both clocks however the push was worded.
    public var runningColor: String? {
        isFinished ? nil : clockRunningFor
    }

    /// When White's clock hits zero, or nil if it is not the running one.
    public var whiteDeadline: Date? {
        runningColor == "white" ? ChessFormat.deadline(seconds: whiteClock, asOf: asOf) : nil
    }

    public var blackDeadline: Date? {
        runningColor == "black" ? ChessFormat.deadline(seconds: blackClock, asOf: asOf) : nil
    }

    public var moveLabel: String? {
        ChessFormat.moveLabel(ply: ply, san: san, uci: lastMove)
    }

    // MARK: - Codable

    /// Only for the tolerated string form; the numeric form needs no formatter. Built per call
    /// rather than held: `ISO8601DateFormatter` is not `Sendable`, and this runs once per push.
    private static var iso8601: ISO8601DateFormatter { ISO8601DateFormatter() }

    private enum CodingKeys: String, CodingKey {
        case fen, lastMove, san, ply, whiteClock, blackClock, clockRunningFor, status, asOf
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fen = try container.decode(String.self, forKey: .fen)
        lastMove = try container.decodeIfPresent(String.self, forKey: .lastMove)
        san = try container.decodeIfPresent(String.self, forKey: .san)
        ply = try container.decodeIfPresent(Int.self, forKey: .ply) ?? 0
        whiteClock = try container.decodeIfPresent(Int.self, forKey: .whiteClock)
        blackClock = try container.decodeIfPresent(Int.self, forKey: .blackClock)
        clockRunningFor = try container.decodeIfPresent(String.self, forKey: .clockRunningFor)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "*"

        // Either wire form. A number is Apple's reference epoch, which is what the system's own
        // decoder would have produced; a string is the ISO 8601 the rest of the project speaks.
        if let seconds = try? container.decode(Double.self, forKey: .asOf) {
            asOf = Date(timeIntervalSinceReferenceDate: seconds)
        } else if let text = try? container.decode(String.self, forKey: .asOf),
                  let parsed = Self.iso8601.date(from: text) {
            asOf = parsed
        } else {
            // A push with no usable timestamp still has a board and two clock readings worth
            // showing; treating "now" as the reading's age is the least wrong assumption.
            asOf = Date()
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fen, forKey: .fen)
        try container.encodeIfPresent(lastMove, forKey: .lastMove)
        try container.encodeIfPresent(san, forKey: .san)
        try container.encode(ply, forKey: .ply)
        try container.encodeIfPresent(whiteClock, forKey: .whiteClock)
        try container.encodeIfPresent(blackClock, forKey: .blackClock)
        try container.encodeIfPresent(clockRunningFor, forKey: .clockRunningFor)
        try container.encode(status, forKey: .status)
        try container.encode(asOf.timeIntervalSinceReferenceDate, forKey: .asOf)
    }
}

#if canImport(ActivityKit)
public struct ChessGameAttributes: ActivityAttributes {
    public typealias ContentState = ChessGameActivityState

    public var game: ChessGameAttributesPayload

    public init(game: ChessGameAttributesPayload) {
        self.game = game
    }

    // Convenience so the views read as `context.attributes.whiteName`.
    public var roundId: String { game.roundId }
    public var gameId: String { game.gameId }
    public var tourName: String { game.tourName }
    public var roundName: String { game.roundName }
    public var whiteName: String { game.whiteName }
    public var blackName: String { game.blackName }
    public var whiteTitle: String? { game.whiteTitle }
    public var blackTitle: String? { game.blackTitle }
    public var whiteRating: Int? { game.whiteRating }
    public var blackRating: Int? { game.blackRating }
    public var orientationIsWhite: Bool { game.orientationIsWhite }
}
#endif
