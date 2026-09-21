// The parts of the Lichess broadcast API this server reads.
//
// Decoded by hand rather than with synthesised `Codable`, for two reasons: the API's timestamps
// are epoch milliseconds (a `Date` strategy would have to be per-property), and a broadcast JSON
// carries a great deal this server does not care about, all of which would otherwise have to be
// modelled to be ignored.

import Foundation
import FollowKit

public struct BroadcastTourInfo: Sendable, Equatable {
    public var id: String
    public var name: String
    public var tier: Int?
    public var imageURL: URL?

    public init(id: String, name: String, tier: Int? = nil, imageURL: URL? = nil) {
        self.id = id
        self.name = name
        self.tier = tier
        self.imageURL = imageURL
    }
}

/// A round as the tour listing and the round JSON both describe it.
///
/// `ongoing` and `finished` are read, never inferred. Lichess's `startsAt` is a plan; a round that
/// slips by forty minutes is normal, and a server that decided "it must be live by now" would be
/// wrong every evening.
public struct BroadcastRoundInfo: Sendable, Equatable {
    public var id: String
    public var name: String
    public var startsAt: Date?
    public var ongoing: Bool
    public var finished: Bool

    public init(id: String, name: String, startsAt: Date? = nil, ongoing: Bool = false, finished: Bool = false) {
        self.id = id
        self.name = name
        self.startsAt = startsAt
        self.ongoing = ongoing
        self.finished = finished
    }
}

public struct BroadcastPlayer: Sendable, Equatable {
    public var name: String
    public var title: String?
    public var rating: Int?
    /// 0 in the JSON means "no FIDE id" (engines and unrated players), so it is read as nil.
    public var fideId: Int?
    public var federation: String?
    /// Seconds remaining, from the round JSON's `clock` (which is in centiseconds).
    public var clock: Int?

    public init(name: String, title: String? = nil, rating: Int? = nil, fideId: Int? = nil, federation: String? = nil, clock: Int? = nil) {
        self.name = name
        self.title = title
        self.rating = rating
        self.fideId = fideId
        self.federation = federation
        self.clock = clock
    }

    /// The push-payload shape of the same player.
    public var push: PushPlayer { PushPlayer(name: name, title: title, rating: rating, fed: federation) }
}

public struct BroadcastGameInfo: Sendable, Equatable {
    public var id: String
    public var fen: String
    public var lastMove: String?
    /// `"*"` while the game is being played, otherwise the result token.
    public var status: String
    public var white: BroadcastPlayer
    public var black: BroadcastPlayer

    public init(id: String, fen: String = MovePush.startingFEN, lastMove: String? = nil, status: String = "*", white: BroadcastPlayer, black: BroadcastPlayer) {
        self.id = id
        self.fen = fen
        self.lastMove = lastMove
        self.status = status
        self.white = white
        self.black = black
    }

    public var isFinished: Bool { status != "*" && !status.isEmpty }
}

/// `GET /api/broadcast/-/-/{roundId}`.
public struct BroadcastRoundDetail: Sendable, Equatable {
    public var round: BroadcastRoundInfo
    public var tour: BroadcastTourInfo
    public var games: [BroadcastGameInfo]

    public init(round: BroadcastRoundInfo, tour: BroadcastTourInfo, games: [BroadcastGameInfo]) {
        self.round = round
        self.tour = tour
        self.games = games
    }
}

/// `GET /api/broadcast/{tourId}` — the tour and **every** one of its rounds.
///
/// The round list is why this endpoint is fetched at all: "the tournament has finished" is only
/// true when every round in it is finished, and the current round's state cannot say that.
public struct BroadcastTourDetail: Sendable, Equatable {
    public var tour: BroadcastTourInfo
    public var rounds: [BroadcastRoundInfo]

    public init(tour: BroadcastTourInfo, rounds: [BroadcastRoundInfo]) {
        self.tour = tour
        self.rounds = rounds
    }

    /// True when the tour has rounds and all of them are finished.
    public var isFinished: Bool { !rounds.isEmpty && rounds.allSatisfy(\.finished) }
}

/// One entry of `GET /api/broadcast/top`.
public struct BroadcastTopEntry: Sendable, Equatable {
    public var tour: BroadcastTourInfo
    public var round: BroadcastRoundInfo

    public init(tour: BroadcastTourInfo, round: BroadcastRoundInfo) {
        self.tour = tour
        self.round = round
    }
}

public struct BroadcastTop: Sendable, Equatable {
    public var active: [BroadcastTopEntry]
    public var upcoming: [BroadcastTopEntry]

    public init(active: [BroadcastTopEntry] = [], upcoming: [BroadcastTopEntry] = []) {
        self.active = active
        self.upcoming = upcoming
    }

    public var all: [BroadcastTopEntry] { active + upcoming }
}

// MARK: - Decoding

public enum BroadcastDecoder {

    public enum DecodeError: Error, Sendable, Equatable {
        case notAnObject
        case missing(String)
    }

    public static func top(from data: Data) throws -> BroadcastTop {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DecodeError.notAnObject }
        func entries(_ key: String) -> [BroadcastTopEntry] {
            guard let list = object[key] as? [[String: Any]] else { return [] }
            return list.compactMap(entry(from:))
        }
        return BroadcastTop(active: entries("active"), upcoming: entries("upcoming"))
    }

    private static func entry(from object: [String: Any]) -> BroadcastTopEntry? {
        guard let tourObject = object["tour"] as? [String: Any], let tour = tourInfo(from: tourObject),
              let roundObject = object["round"] as? [String: Any], let round = roundInfo(from: roundObject)
        else { return nil }
        return BroadcastTopEntry(tour: tour, round: round)
    }

    public static func tourDetail(from data: Data) throws -> BroadcastTourDetail {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DecodeError.notAnObject }
        guard let tourObject = object["tour"] as? [String: Any], let tour = tourInfo(from: tourObject) else {
            throw DecodeError.missing("tour")
        }
        let rounds = (object["rounds"] as? [[String: Any]] ?? []).compactMap(roundInfo(from:))
        return BroadcastTourDetail(tour: tour, rounds: rounds)
    }

    public static func roundDetail(from data: Data) throws -> BroadcastRoundDetail {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DecodeError.notAnObject }
        guard let roundObject = object["round"] as? [String: Any], let round = roundInfo(from: roundObject) else {
            throw DecodeError.missing("round")
        }
        guard let tourObject = object["tour"] as? [String: Any], let tour = tourInfo(from: tourObject) else {
            throw DecodeError.missing("tour")
        }
        let games = (object["games"] as? [[String: Any]] ?? []).compactMap(game(from:))
        return BroadcastRoundDetail(round: round, tour: tour, games: games)
    }

    static func tourInfo(from object: [String: Any]) -> BroadcastTourInfo? {
        guard let id = string(object["id"]), let name = string(object["name"]) else { return nil }
        return BroadcastTourInfo(
            id: id,
            name: name,
            tier: integer(object["tier"]),
            imageURL: string(object["image"]).flatMap(URL.init(string:))
        )
    }

    static func roundInfo(from object: [String: Any]) -> BroadcastRoundInfo? {
        guard let id = string(object["id"]), let name = string(object["name"]) else { return nil }
        return BroadcastRoundInfo(
            id: id,
            name: name,
            startsAt: milliseconds(object["startsAt"]),
            ongoing: boolean(object["ongoing"]) ?? false,
            // `finishedAt` without `finished` happens in the top listing's `roundToLink`.
            finished: boolean(object["finished"]) ?? (object["finishedAt"] != nil)
        )
    }

    static func game(from object: [String: Any]) -> BroadcastGameInfo? {
        guard let id = string(object["id"]) else { return nil }
        let players = (object["players"] as? [[String: Any]] ?? []).map(player(from:))
        guard players.count >= 2 else { return nil }
        return BroadcastGameInfo(
            id: id,
            fen: string(object["fen"]) ?? MovePush.startingFEN,
            lastMove: string(object["lastMove"]),
            status: normalizeResult(string(object["status"])),
            white: players[0],
            black: players[1]
        )
    }

    static func player(from object: [String: Any]) -> BroadcastPlayer {
        let fideId = integer(object["fideId"])
        // The round JSON's `clock` is centiseconds; every clock in this project is seconds.
        let clock = integer(object["clock"]).map { $0 / 100 }
        return BroadcastPlayer(
            name: string(object["name"]) ?? "",
            title: string(object["title"]),
            rating: integer(object["rating"]),
            fideId: (fideId ?? 0) > 0 ? fideId : nil,
            federation: string(object["fed"]),
            clock: clock
        )
    }

    /// Lichess writes a draw as `½-½`; PGN and every other part of this project write `1/2-1/2`.
    /// One spelling, decided here, or the "has this game finished" comparison quietly fails.
    public static func normalizeResult(_ status: String?) -> String {
        guard let status, !status.isEmpty else { return "*" }
        switch status {
        case "½-½", "0.5-0.5": return "1/2-1/2"
        default: return status
        }
    }

    private static func milliseconds(_ value: Any?) -> Date? {
        guard let value = number(value) else { return nil }
        return Date(timeIntervalSince1970: value / 1000)
    }

    // `JSONSerialization` hands back `NSNumber` on Apple platforms and, depending on the version,
    // either `NSNumber` or a native Swift value on Linux. These four read both, so the decoding
    // does not depend on which Foundation the binary was built against.

    static func string(_ value: Any?) -> String? { value as? String }

    static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        guard let value = number(value) else { return nil }
        return Int(value)
    }

    static func boolean(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }
}
