import Foundation

/// One arena tournament as it appears in `GET /api/tournament`.
///
/// `secondsToFinish` is only sent by the *detail* endpoint; the list endpoint sends
/// `finishesAt` instead, so it is `nil` for summaries coming out of ``ArenaClient/list()``.
public struct ArenaSummary: Sendable, Equatable, Identifiable {
    public let id: String
    public let fullName: String
    /// `perf.key`, e.g. `"bullet"`, `"rapid"`.
    public let perfKey: String
    /// `variant.key`, e.g. `"standard"`, `"crazyhouse"`.
    public let variantKey: String
    public let nbPlayers: Int
    public let startsAt: Date
    /// Scheduled duration in minutes.
    public let minutes: Int
    public let secondsToFinish: Int?
    public let isStarted: Bool
    public let isFinished: Bool

    public init(
        id: String,
        fullName: String,
        perfKey: String,
        variantKey: String,
        nbPlayers: Int,
        startsAt: Date,
        minutes: Int,
        secondsToFinish: Int?,
        isStarted: Bool,
        isFinished: Bool
    ) {
        self.id = id
        self.fullName = fullName
        self.perfKey = perfKey
        self.variantKey = variantKey
        self.nbPlayers = nbPlayers
        self.startsAt = startsAt
        self.minutes = minutes
        self.secondsToFinish = secondsToFinish
        self.isStarted = isStarted
        self.isFinished = isFinished
    }
}

/// The game an arena is currently showing on its own page (`featured` in the detail payload).
public struct ArenaFeaturedGame: Sendable, Equatable {
    /// One side of the featured game. `rank` is the player's place in the arena standing.
    public struct Player: Sendable, Equatable {
        public let name: String
        public let rating: Int?
        public let rank: Int?
        /// Clock in whole seconds (`c.white` / `c.black`); absent before the first move.
        public let secondsRemaining: Int?

        public init(name: String, rating: Int?, rank: Int?, secondsRemaining: Int?) {
            self.name = name
            self.rating = rating
            self.rank = rank
            self.secondsRemaining = secondsRemaining
        }
    }

    public let gameId: String
    /// May be the two-field form (`"… w"`) rather than a full six-field FEN.
    public let fen: String
    public let lastMove: String?
    public let white: Player
    public let black: Player

    public init(gameId: String, fen: String, lastMove: String?, white: Player, black: Player) {
        self.gameId = gameId
        self.fen = fen
        self.lastMove = lastMove
        self.white = white
        self.black = black
    }
}

/// One row of the arena leaderboard.
public struct ArenaStanding: Sendable, Equatable, Identifiable {
    public let name: String
    public let title: String?
    public let score: Int
    public let rank: Int
    public let rating: Int?
    /// `sheet.fire`: this player is on a streak, so the next wins are worth double.
    public let onStreak: Bool
    /// `withdraw`: the player paused, and is not being paired any more.
    public let withdrawn: Bool

    /// Ranks are unique inside one standing page, and the page is the whole model.
    public var id: Int { rank }

    public init(
        name: String,
        title: String?,
        score: Int,
        rank: Int,
        rating: Int? = nil,
        onStreak: Bool = false,
        withdrawn: Bool = false
    ) {
        self.name = name
        self.title = title
        self.score = score
        self.rank = rank
        self.rating = rating
        self.onStreak = onStreak
        self.withdrawn = withdrawn
    }
}

/// `GET /api/tournament/{id}`: the summary plus the featured game and the top of the standing.
public struct ArenaDetail: Sendable, Equatable {
    public let summary: ArenaSummary
    /// `nil` before the arena starts, and briefly between featured games.
    public let featured: ArenaFeaturedGame?
    /// `standing.players`: the first page of the leaderboard, which Lichess sends ten rows deep.
    public let standings: [ArenaStanding]

    public init(summary: ArenaSummary, featured: ArenaFeaturedGame?, standings: [ArenaStanding]) {
        self.summary = summary
        self.featured = featured
        self.standings = standings
    }
}
