import Testing
import Foundation
import ChessCore
import LichessKit
import EngineKit
@testable import GameSessionKit

@Suite("GameReducer drives the board from feed events")
struct GameReducerTests {

    private func castlingEvents() throws -> [TVEvent] {
        let events = try FixtureFeed.events(named: "feed-castling")
        #expect(events.count == 5)
        return events
    }

    @Test("The featured event seats the players and the position")
    func featuredEvent() throws {
        let events = try castlingEvents()
        var reducer = GameReducer()
        reducer.apply(events[0])

        #expect(reducer.gameId == "castle01")
        #expect(reducer.revision == 1)
        #expect(reducer.position?.sideToMove == .white)
        #expect(reducer.white?.name == "WhiteTester")
        #expect(reducer.black?.name == "BlackTester")
        #expect(reducer.black?.title == "IM")
        #expect(reducer.white?.rating == 2000)
        #expect(reducer.lastMove == nil)
        #expect(reducer.moveHistory.isEmpty)
        #expect(reducer.clocks?.whiteSeconds == 180)
        #expect(reducer.clocks?.sideToMove == .white)
    }

    @Test("Lichess king-to-rook castling lands the king on g1 and c8")
    func castlingSquares() throws {
        let events = try castlingEvents()
        var reducer = GameReducer()
        reducer.apply(events[0])

        reducer.apply(events[1])                       // white castles kingside, "e1h1"
        #expect(reducer.revision == 2)
        #expect(reducer.lastMove?.from == Square(algebraic: "e1"))
        #expect(reducer.lastMove?.to == Square(algebraic: "g1"))
        #expect(reducer.position?.piece(at: Square(file: 6, rank: 0)) == Piece(kind: .king, color: .white))
        #expect(reducer.position?.sideToMove == .black)

        reducer.apply(events[2])                       // black castles queenside, "e8a8"
        #expect(reducer.revision == 3)
        #expect(reducer.lastMove?.from == Square(algebraic: "e8"))
        #expect(reducer.lastMove?.to == Square(algebraic: "c8"))
        #expect(reducer.position?.piece(at: Square(file: 2, rank: 7)) == Piece(kind: .king, color: .black))
    }

    @Test("The move list numbers plies from the FEN that follows them")
    func moveHistoryNumbering() throws {
        let events = try castlingEvents()
        var reducer = GameReducer()
        reducer.apply(events[0])
        reducer.apply(events[1])
        reducer.apply(events[2])

        #expect(reducer.moveHistory.map(\.uci) == ["e1h1", "e8a8"])
        #expect(reducer.moveHistory.map(\.san) == ["O-O", "O-O-O"])
        #expect(reducer.moveHistory.map(\.moveNumber) == [8, 8])
        #expect(reducer.moveHistory.map(\.color) == [.white, .black])
        #expect(reducer.rows.count == 1)
        #expect(reducer.rows[0].white?.uci == "e1h1")
        #expect(reducer.rows[0].black?.uci == "e8a8")
    }

    @Test("A new featured event resets the history and the players")
    func featuredResets() throws {
        let events = try castlingEvents()
        var reducer = GameReducer()
        for event in events.prefix(3) { reducer.apply(event) }
        #expect(reducer.moveHistory.count == 2)

        reducer.apply(events[3])                       // the next featured game
        #expect(reducer.revision == 4)
        #expect(reducer.gameId == "next0002")
        #expect(reducer.moveHistory.isEmpty)
        #expect(reducer.lastMove == nil)
        #expect(reducer.white?.name == "Alpha")
        #expect(reducer.black?.name == "Beta")
        #expect(reducer.orientation == .black)
        #expect(reducer.position == Position.standard)

        reducer.apply(events[4])
        #expect(reducer.revision == 5)
        #expect(reducer.moveHistory.map(\.uci) == ["e2e4"])
        #expect(reducer.moveHistory.map(\.san) == ["e4"])
        #expect(reducer.moveHistory[0].moveNumber == 1)
    }

    @Test("The move list is written in SAN, from the position before each move")
    func moveListIsSAN() throws {
        let events = try castlingEvents()
        var reducer = GameReducer()
        for event in events { reducer.apply(event) }
        // The last featured event resets the history, so only 1. e4 survives it.
        #expect(reducer.moveHistory.map(\.san) == ["e4"])

        var whole = GameReducer()
        for event in events.prefix(3) { whole.apply(event) }
        #expect(whole.moveHistory.map(\.san) == ["O-O", "O-O-O"])
        #expect(whole.rows[0].white?.san == "O-O")
        #expect(whole.rows[0].black?.san == "O-O-O")
    }

    @Test("A move with no position before it keeps the feed's own spelling")
    func sanFallsBackToUCI() throws {
        // A stream joined mid-game: a fen event arrives before any featured event, so there is
        // no previous position to write SAN against.
        var reducer = GameReducer()
        reducer.apply(.fen(
            fen: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1",
            lastMove: "e2e4",
            whiteClock: 60,
            blackClock: 60
        ))
        #expect(reducer.moveHistory.map(\.san) == ["e2e4"])

        // And once the next move has a predecessor, SAN resumes.
        reducer.apply(.fen(
            fen: "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2",
            lastMove: "e7e5",
            whiteClock: 60,
            blackClock: 59
        ))
        #expect(reducer.moveHistory.map(\.san) == ["e2e4", "e5"])
    }

    @Test("Revision advances once per accepted event and not at all for junk")
    func revisionCounting() throws {
        var reducer = GameReducer()
        reducer.apply(.featured(gameId: "x", orientation: .white, players: [], fen: Position.standard.fen))
        #expect(reducer.revision == 1)
        reducer.apply(.fen(fen: "not a fen", lastMove: "e2e4", whiteClock: 1, blackClock: 1))
        #expect(reducer.revision == 1)
        #expect(reducer.position == Position.standard)
    }

    @Test("The history keeps the whole game, so a viewer who joined late can see all of it")
    func historyIsComplete() throws {
        var reducer = GameReducer()
        reducer.apply(.featured(gameId: "x", orientation: .white, players: [], fen: Position.standard.fen))
        // Shuffle a knight back and forth; the FENs do not have to be a legal game for this.
        let fens = [
            "rnbqkbnr/pppppppp/8/8/8/5N2/PPPPPPPP/RNBQKB1R b KQkq - 1 1",
            "rnbqkb1r/pppppppp/5n2/8/8/5N2/PPPPPPPP/RNBQKB1R w KQkq - 2 2",
        ]
        for index in 0..<20 {
            reducer.apply(.fen(fen: fens[index % 2], lastMove: index % 2 == 0 ? "g1f3" : "g8f6", whiteClock: 60, blackClock: 60))
        }
        #expect(reducer.moveHistory.count == 20)
        #expect(reducer.moveHistory.first?.uci == "g1f3")
        #expect(reducer.revision == 21)
    }

    @Test("Sounds: a plain move, a capture and a check")
    func moveOutcomes() throws {
        var reducer = GameReducer()
        reducer.apply(.featured(gameId: "x", orientation: .white, players: [], fen: Position.standard.fen))
        let plain = reducer.apply(.fen(fen: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1", lastMove: "e2e4", whiteClock: 60, blackClock: 60))
        #expect(plain == .move)
        #expect(reducer.moveHistory.last?.san == "e4")

        // Scholar's-mate finish: Qxf7 is both a capture and check; check wins.
        var mate = GameReducer()
        mate.apply(.featured(gameId: "y", orientation: .white, players: [], fen: "r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5Q2/PPPP1PPP/RNB1K1NR w KQkq - 4 4"))
        let checkmate = mate.apply(.fen(fen: "r1bqkbnr/pppp1Qpp/2n5/4p3/2B1P3/8/PPPP1PPP/RNB1K1NR b KQkq - 0 4", lastMove: "f3f7", whiteClock: 60, blackClock: 60))
        #expect(checkmate == .check)
        #expect(mate.moveHistory.last?.san == "Qxf7#")

        // A capture that gives no check.
        var capture = GameReducer()
        capture.apply(.featured(gameId: "z", orientation: .white, players: [], fen: "rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 2"))
        let outcome = capture.apply(.fen(fen: "rnbqkbnr/ppp1pppp/8/3P4/8/8/PPPP1PPP/RNBQKBNR b KQkq - 0 2", lastMove: "e4d5", whiteClock: 60, blackClock: 60))
        #expect(outcome == .capture)
        #expect(capture.moveHistory.last?.san == "exd5")
    }
}
