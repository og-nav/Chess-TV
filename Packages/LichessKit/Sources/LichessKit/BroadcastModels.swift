import Foundation

/// The complete round list, needed to distinguish a finished round from a finished event.
public struct BroadcastTour: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let rounds: [BroadcastRound]
    public let imageURL: URL?
    public init(id: String, name: String, rounds: [BroadcastRound], imageURL: URL? = nil) {
        self.id = id; self.name = name; self.rounds = rounds; self.imageURL = imageURL
    }
}

public struct BroadcastRound: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let ongoing: Bool
    public let finished: Bool
    public let startsAt: Date?
    public init(id: String, name: String, ongoing: Bool = false, finished: Bool = false, startsAt: Date? = nil) {
        self.id = id; self.name = name; self.ongoing = ongoing; self.finished = finished; self.startsAt = startsAt
    }
}

/// One broadcast (`tour`) paired with the round the list endpoint pointed at.
///
/// Lichess models a broadcast as a tournament with many rounds; every list entry names exactly
/// one round, so the two are flattened into a single value the UI can render as a row.
public struct BroadcastTournament: Sendable, Equatable, Identifiable {
    public var id: String { roundId }

    public let tourId: String
    public let name: String
    /// 3 = regional, 4 = national leagues / strong opens, 5 = Olympiad class. Absent on some tours.
    public let tier: Int?
    public let roundId: String
    public let roundName: String
    public let roundOngoing: Bool
    public let roundStartsAt: Date?
    /// `tour.info.format`, e.g. `"11-round swiss for teams"`.
    public let format: String?
    /// `tour.info.location`.
    public let location: String?
    /// `true` when the entry came from the `active` bucket (or the round reports `ongoing`).
    public let isActive: Bool
    /// `tour.image`: the organiser's banner, an 800×400 WebP on Lichess's image CDN. Nearly
    /// every tour has one; `nil` for the few that do not.
    public let imageURL: URL?

    public init(
        tourId: String,
        name: String,
        tier: Int?,
        roundId: String,
        roundName: String,
        roundOngoing: Bool,
        roundStartsAt: Date?,
        format: String?,
        location: String?,
        isActive: Bool,
        imageURL: URL? = nil
    ) {
        self.tourId = tourId
        self.name = name
        self.tier = tier
        self.roundId = roundId
        self.roundName = roundName
        self.roundOngoing = roundOngoing
        self.roundStartsAt = roundStartsAt
        self.format = format
        self.location = location
        self.isActive = isActive
        self.imageURL = imageURL
    }
}

/// A player's portrait on Lichess's image CDN, in the two sizes it publishes plus the credit.
///
/// The same three values the FIDE player endpoint returns under `photo`, and the reason this type
/// exists separately: a broadcast round carries them for every player of the round under `photos`,
/// keyed by FIDE id, so opening a board already has the picture in hand and needs no second
/// request. `/api/fide/player/{id}` remains the source for a board we were sent straight to.
public struct PlayerPhoto: Sendable, Hashable {
    /// 100×100 WebP, for a board list.
    public let smallURL: URL?
    /// 500×500 WebP, for the game side panel.
    public let mediumURL: URL?
    /// The photographer Lichess credits. Showing it is a condition of using the picture.
    public let credit: String?

    public init(smallURL: URL? = nil, mediumURL: URL? = nil, credit: String? = nil) {
        self.smallURL = smallURL
        self.mediumURL = mediumURL
        self.credit = credit
    }

    /// A credit with no picture is nothing to show; treat that as no photo at all.
    public var hasPicture: Bool { smallURL != nil || mediumURL != nil }
}

/// One side of a broadcast board. Order in `BroadcastBoard.players` is white then black.
public struct BroadcastPlayer: Sendable, Hashable {
    public let name: String
    public let title: String?
    public let rating: Int?
    /// `fed`, a three-letter federation code such as `"USA"`. Absent for engine events.
    public let federation: String?
    /// Remaining clock in **milliseconds**, normalized from API centiseconds at receipt time.
    public let clockMs: Int?
    /// The player's FIDE id, the key to `FIDEPlayerClient` and its portraits. Lichess sends `0`
    /// for players without one (engines, most amateurs); that is normalised to `nil` here.
    public let fideId: Int?
    /// The portrait Lichess published with the round, when it has one for this player. Present
    /// only on boards that came from the round JSON: the PGN stream carries no pictures, and
    /// `BroadcastRoundMonitor` keeps the one it already had when a streamed update lands.
    public let photo: PlayerPhoto?

    public init(
        name: String,
        title: String?,
        rating: Int?,
        federation: String?,
        clockMs: Int?,
        fideId: Int? = nil,
        photo: PlayerPhoto? = nil
    ) {
        self.name = name
        self.title = title
        self.rating = rating
        self.federation = federation
        self.clockMs = clockMs
        self.fideId = (fideId ?? 0) > 0 ? fideId : nil
        self.photo = (photo?.hasPicture ?? false) ? photo : nil
    }

    /// The clock rounded down to whole seconds, which is what `TVEvent.fen` carries.
    public var clockSeconds: Int? { clockMs.map { $0 / 1000 } }
}

/// One board of a broadcast round (`games[]` of `GET /api/broadcast/-/-/{roundId}`).
public struct BroadcastBoard: Sendable, Hashable, Identifiable {
    public var id: String { gameId }

    public let gameId: String
    /// `"White Player - Black Player"` as Lichess formats it.
    public let name: String
    public let fen: String
    public let lastMove: String?
    /// `"*"` while the game is in progress; `"1-0"`, `"0-1"` or `"½-½"` once it is over.
    public let status: String
    public let players: [BroadcastPlayer]

    public init(gameId: String, name: String, fen: String, lastMove: String?, status: String, players: [BroadcastPlayer]) {
        self.gameId = gameId
        self.name = name
        self.fen = fen
        self.lastMove = lastMove
        self.status = status
        self.players = players
    }

    /// `true` while the game is still being played.
    public var isOngoing: Bool { status == "*" || status.isEmpty }

    public var white: BroadcastPlayer? { players.first }
    public var black: BroadcastPlayer? { players.count > 1 ? players[1] : nil }
}
