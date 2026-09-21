// What the watcher produces and the policy consumes.
//
// All value types: the interesting logic (what changed, who wants to know) is then testable
// without a database, a socket or a clock.

import Foundation
import FollowKit

public struct BoardPlayers: Sendable, Equatable {
    public var white: BroadcastPlayer
    public var black: BroadcastPlayer

    public init(white: BroadcastPlayer, black: BroadcastPlayer) {
        self.white = white
        self.black = black
    }
}

/// Everything about a round that a push needs and a PGN block does not carry: the event's name,
/// the board order (which is what "top boards" means), the banner, and the FIDE ids that resolve
/// a followed player to a board.
public struct RoundContext: Sendable, Equatable {
    public var roundId: String
    public var roundName: String
    public var tourId: String
    public var tourName: String
    public var bannerURL: URL?
    /// Game ids in the round's own order. Board 1 is `boards[0]`.
    public var boards: [String]
    public var boardPlayers: [String: BoardPlayers]

    public init(
        roundId: String,
        roundName: String,
        tourId: String,
        tourName: String,
        bannerURL: URL? = nil,
        boards: [String] = [],
        boardPlayers: [String: BoardPlayers] = [:]
    ) {
        self.roundId = roundId
        self.roundName = roundName
        self.tourId = tourId
        self.tourName = tourName
        self.bannerURL = bannerURL
        self.boards = boards
        self.boardPlayers = boardPlayers
    }

    public init(_ detail: BroadcastRoundDetail) {
        self.init(
            roundId: detail.round.id,
            roundName: detail.round.name,
            tourId: detail.tour.id,
            tourName: detail.tour.name,
            bannerURL: detail.tour.imageURL,
            boards: detail.games.map(\.id),
            boardPlayers: Dictionary(uniqueKeysWithValues: detail.games.map { ($0.id, BoardPlayers(white: $0.white, black: $0.black)) })
        )
    }

    /// 1-based board number, or nil for a game the round JSON has not listed yet.
    public func board(of gameId: String) -> Int? {
        boards.firstIndex(of: gameId).map { $0 + 1 }
    }
}

/// A game as one PGN block describes it, with the round JSON's extra columns folded in.
public struct GameSnapshot: Sendable, Equatable {
    public var roundId: String
    public var gameId: String
    public var ply: Int
    public var fen: String
    /// UCI of the last move, for square highlighting.
    public var lastMove: String?
    public var san: String?
    public var whiteClock: Int?
    public var blackClock: Int?
    public var status: String
    public var white: PushPlayer
    public var black: PushPlayer
    public var whiteFideId: Int?
    public var blackFideId: Int?

    public init(
        roundId: String,
        gameId: String,
        ply: Int = 0,
        fen: String = MovePush.startingFEN,
        lastMove: String? = nil,
        san: String? = nil,
        whiteClock: Int? = nil,
        blackClock: Int? = nil,
        status: String = "*",
        white: PushPlayer = PushPlayer(),
        black: PushPlayer = PushPlayer(),
        whiteFideId: Int? = nil,
        blackFideId: Int? = nil
    ) {
        self.roundId = roundId
        self.gameId = gameId
        self.ply = ply
        self.fen = fen
        self.lastMove = lastMove
        self.san = san
        self.whiteClock = whiteClock
        self.blackClock = blackClock
        self.status = status
        self.white = white
        self.black = black
        self.whiteFideId = whiteFideId
        self.blackFideId = blackFideId
    }

    public var isFinished: Bool { status != "*" && !status.isEmpty }

    /// Who made the move that produced `fen`: the side that is *not* to move.
    ///
    /// Read off the FEN rather than off the ply's parity, because a game set up from a position
    /// with Black to move has an odd ply for a Black move and would name the wrong player for its
    /// whole length.
    public var moverName: String? {
        guard ply > 0 else { return nil }
        let sideToMove = fen.split(separator: " ").dropFirst().first
        return sideToMove == "b" ? white.name : black.name
    }

    /// A baseline describing this snapshot as first seen.
    public func baseline(observedAt: Date, longThinkEligible: Bool) -> GameBaseline {
        GameBaseline(
            roundId: roundId,
            gameId: gameId,
            ply: ply,
            fen: fen,
            status: status,
            whiteClock: whiteClock,
            blackClock: blackClock,
            observedAt: observedAt,
            longThinkEligible: longThinkEligible,
            updatedAt: observedAt
        )
    }
}

/// Something that happened on a board.
public struct MoveEvent: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case gameStart, move, longThink, gameEnd
    }

    public var kind: Kind
    public var snapshot: GameSnapshot
    public var at: Date
    /// How long the player has been on this position, for `longThink`. Measured from when the
    /// server first saw the position, not from the clocks: an increment makes clock subtraction
    /// answer a different question.
    public var thinkSeconds: Int?

    public init(kind: Kind, snapshot: GameSnapshot, at: Date, thinkSeconds: Int? = nil) {
        self.kind = kind
        self.snapshot = snapshot
        self.at = at
        self.thinkSeconds = thinkSeconds
    }

    /// The `GameAlert` switch a player or game follow uses to say yes or no to this.
    public var gameAlert: GameAlert {
        switch kind {
        case .gameStart: .start
        case .move: .move
        case .longThink: .longThink
        case .gameEnd: .end
        }
    }
}

/// Something that happened to an event rather than to a board.
public struct TournamentEvent: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case startingSoon, roundLive, roundFinished, tournamentFinished
    }

    public var kind: Kind
    public var tourId: String
    public var tourName: String
    public var roundId: String?
    public var roundName: String?
    public var startsAt: Date?
    public var boardCount: Int?
    /// `"Carlsen 1–0 Nepomniachtchi"`, board order, at most five.
    public var results: [String]?
    public var bannerURL: URL?
    public var at: Date

    public init(
        kind: Kind,
        tourId: String,
        tourName: String,
        roundId: String? = nil,
        roundName: String? = nil,
        startsAt: Date? = nil,
        boardCount: Int? = nil,
        results: [String]? = nil,
        bannerURL: URL? = nil,
        at: Date
    ) {
        self.kind = kind
        self.tourId = tourId
        self.tourName = tourName
        self.roundId = roundId
        self.roundName = roundName
        self.startsAt = startsAt
        self.boardCount = boardCount
        self.results = results
        self.bannerURL = bannerURL
        self.at = at
    }

    /// The `TournamentAlert` switch this event is governed by.
    public var tournamentAlert: TournamentAlert {
        switch kind {
        case .startingSoon: .startingSoon
        case .roundLive: .roundLive
        case .roundFinished: .roundSummary
        case .tournamentFinished: .finished
        }
    }

    /// The payload kind, which happens to use the same names.
    public var pushKind: TournamentPushKind {
        TournamentPushKind(rawValue: kind.rawValue) ?? .roundLive
    }
}
