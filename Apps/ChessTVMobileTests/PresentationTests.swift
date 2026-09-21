import Testing
import Foundation
import ChessCore
import GameSessionKit
import LichessKit
@testable import ChessTVMobile

@Suite("What VoiceOver reads off the board and the move list")
struct BoardSpeechTests {

    @Test("The grid over the board lines up with the squares under it, both ways up")
    func squareMapping() {
        // White at the bottom: top-left is a8, bottom-right is h1.
        #expect(BoardSpeech.square(row: 0, column: 0, orientation: .white).algebraic == "a8")
        #expect(BoardSpeech.square(row: 7, column: 7, orientation: .white).algebraic == "h1")
        // Black at the bottom: the board is turned around.
        #expect(BoardSpeech.square(row: 0, column: 0, orientation: .black).algebraic == "h1")
        #expect(BoardSpeech.square(row: 7, column: 7, orientation: .black).algebraic == "a8")
    }

    @Test("A square is read as its name and what stands on it")
    func squareLabels() throws {
        let position = try Position(fen: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1")
        #expect(BoardSpeech.label(for: try #require(Square(algebraic: "e4")), in: position) == "e4, white pawn")
        #expect(BoardSpeech.label(for: try #require(Square(algebraic: "e2")), in: position) == "e2, empty")
        #expect(BoardSpeech.label(for: try #require(Square(algebraic: "d8")), in: position) == "d8, black queen")
        #expect(BoardSpeech.label(for: try #require(Square(algebraic: "a1")), in: nil) == "a1, empty")
    }

    @Test("The two squares of the last move say so, and nothing else does")
    func lastMoveValues() throws {
        let from = try #require(Square(algebraic: "e2"))
        let to = try #require(Square(algebraic: "e4"))
        let move = LastMove(from: from, to: to)
        #expect(BoardSpeech.value(for: from, lastMove: move) == "last move from here")
        #expect(BoardSpeech.value(for: to, lastMove: move) == "last move to here")
        #expect(BoardSpeech.value(for: try #require(Square(algebraic: "a1")), lastMove: move).isEmpty)
        #expect(BoardSpeech.value(for: from, lastMove: nil).isEmpty)
    }

    @Test("SAN is spelled out rather than read as a word")
    func spelling() {
        #expect(BoardSpeech.spell("e4") == "e4")
        #expect(BoardSpeech.spell("Nf3") == "knight f3")
        #expect(BoardSpeech.spell("Nbd7") == "knight bd7")
        #expect(BoardSpeech.spell("O-O") == "castles kingside")
        #expect(BoardSpeech.spell("O-O-O") == "castles queenside")
        #expect(BoardSpeech.spell("Qxf7#") == "queen takes f7, checkmate")
        #expect(BoardSpeech.spell("Bb5+") == "bishop b5, check")
        #expect(BoardSpeech.spell("e8=Q") == "e8 promotes to queen")
        #expect(BoardSpeech.spell("exd5") == "e takes d5")
    }

    @Test("A move list row names the side and the number")
    func moveLabels() {
        #expect(BoardSpeech.move(number: 23, color: .white, san: "Nf5") == "White, move 23, knight f5")
        #expect(BoardSpeech.move(number: 23, color: .black, san: "Qe7") == "Black, move 23, queen e7")
    }
}

@Suite("The engine's line, in the move list's notation")
struct PrincipalVariationTests {

    @Test("A line from White's move is numbered from the position's own move number")
    func fromWhite() throws {
        let position = try Position(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
        let text = PrincipalVariation.text(["e2e4", "e7e5", "g1f3"], from: position)
        #expect(text == "1. e4 e5 2. Nf3")
    }

    @Test("A line from Black's move opens with the ellipsis form")
    func fromBlack() throws {
        let position = try Position(fen: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1")
        let text = PrincipalVariation.text(["e7e5", "g1f3"], from: position)
        #expect(text == "1\u{2026} e5 2. Nf3")
    }

    @Test("A move the position rejects ends the line instead of printing nonsense")
    func truncatesOnIllegalMove() throws {
        let position = try Position(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
        let text = PrincipalVariation.text(["e2e4", "h8h1", "g1f3"], from: position)
        #expect(text == "1. e4")
    }

    @Test("No position and no line produce nothing at all")
    func empty() throws {
        #expect(PrincipalVariation.text([], from: try Position(fen: "8/8/8/8/8/8/8/K6k w - - 0 1")).isEmpty)
        #expect(PrincipalVariation.text(["e2e4"], from: nil).isEmpty)
    }

    @Test("Only the first few plies are shown; a phone has one line for them")
    func limit() throws {
        let position = try Position(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
        let text = PrincipalVariation.text(["e2e4", "e7e5", "g1f3", "b8c6", "f1b5", "a7a6"], from: position, limit: 2)
        #expect(text == "1. e4 e5")
    }
}

@Suite("Clocks on the boards wall")
struct WallClockTests {

    private func board(status: String, whiteMs: Int?, blackMs: Int?, fen: String) -> BroadcastBoard {
        BroadcastBoard(
            gameId: "g1",
            name: "White - Black",
            fen: fen,
            lastMove: nil,
            status: status,
            players: [
                BroadcastPlayer(name: "White", title: "GM", rating: 2800, federation: "NOR", clockMs: whiteMs, fideId: 1_503_014),
                BroadcastPlayer(name: "Black", title: "GM", rating: 2790, federation: "USA", clockMs: blackMs, fideId: 2_016_192),
            ]
        )
    }

    /// Black to move in this FEN, so Black's clock is the one running.
    private let blackToMove = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1"

    @Test("The side to move counts down from the poll; the other side is frozen")
    func countsDown() {
        let received = ContinuousClock.Instant.now
        let board = board(status: "*", whiteMs: 600_000, blackMs: 300_000, fen: blackToMove)

        let white = WallClock.text(for: .white, board: board, receivedAt: received, now: received + .seconds(30))
        let black = WallClock.text(for: .black, board: board, receivedAt: received, now: received + .seconds(30))

        #expect(white == "10:00")
        #expect(black == "4:30")
    }

    @Test("A finished board shows the clocks exactly as they stood")
    func finishedBoardIsFrozen() {
        let received = ContinuousClock.Instant.now
        let board = board(status: "1-0", whiteMs: 600_000, blackMs: 300_000, fen: blackToMove)
        let black = WallClock.text(for: .black, board: board, receivedAt: received, now: received + .seconds(120))
        #expect(black == "5:00")
    }

    @Test("A board with no clocks shows none rather than zero")
    func missingClocks() {
        let received = ContinuousClock.Instant.now
        let board = board(status: "*", whiteMs: nil, blackMs: nil, fen: blackToMove)
        #expect(WallClock.text(for: .white, board: board, receivedAt: received, now: received) == nil)
    }

    @Test("A FEN that will not parse freezes the clocks rather than counting the wrong one down")
    func unparseableFEN() {
        let board = board(status: "*", whiteMs: 600_000, blackMs: 300_000, fen: "not a fen")
        #expect(WallClock.sideToMove(of: board) == .white)
    }
}

@Suite("Opening the right screen from a push")
struct PushRoutingTests {

    @Test("A board alert opens the board it is about")
    func boardPush() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["category": "GAME_MOVE"],
            "d": ["roundId": "r1", "gameId": "g1", "tourName": "Tata Steel"],
        ]
        #expect(PushRouting.target(from: userInfo) == .board(roundId: "r1", gameId: "g1", tourName: "Tata Steel"))
        #expect(PushRouting.identifier(from: userInfo) == "r1:g1")
    }

    @Test("An event alert opens the event")
    func tournamentPush() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["category": "TOURNAMENT_EVENT"],
            "d": ["tourId": "t1", "tourName": "Tata Steel", "roundId": "r5"],
        ]
        #expect(PushRouting.target(from: userInfo) == .tournament(tourId: "t1", name: "Tata Steel"))
        #expect(PushRouting.identifier(from: userInfo) == "t1")
    }

    @Test("A payload this build does not understand opens nothing rather than the wrong thing")
    func unknownPayload() {
        #expect(PushRouting.target(from: ["aps": ["alert": "hello"]]) == nil)
        #expect(PushRouting.target(from: ["d": ["something": "else"]]) == nil)
    }
}

@Suite("Cold launch and landscape layout")
@MainActor
struct MobileLifecyclePresentationTests {
    @Test("A notification tapped before navigation exists opens after attachment")
    func coldTap() {
        AppDelegate.navigator = nil
        AppDelegate.receive(.board(roundId: "round", gameId: "game", tourName: "Event"))
        let navigator = Navigator()
        AppDelegate.attach(navigator: navigator)
        #expect(navigator.tab == .home)
        #expect(navigator.homePath.contains {
            if case .game(let destination) = $0 {
                return destination.source == .broadcastBoard(roundId: "round", gameId: "game")
            }
            return false
        })
        let replacement = Navigator()
        AppDelegate.attach(navigator: replacement)
        #expect(replacement.homePath.isEmpty)
        AppDelegate.navigator = nil
    }

    @Test("Short landscape leaves room for controls instead of using the entire width")
    func landscapeWidth() {
        #expect(GameLayout.boardColumnWidth(availableWidth: 460, availableHeight: 360) == 160)
        #expect(GameLayout.boardColumnWidth(availableWidth: 520, availableHeight: 900) == 520)
    }
}

@Suite("Widget links open only chess boards")
struct WidgetRoutingTests {
    @Test @MainActor func activityLinkOpensItsGameFromAnotherTab() throws {
        let attributes = ChessGameAttributesPayload(
            roundId: "round123", gameId: "game456", tourName: "Event", roundName: "Round 4",
            whiteName: "White", blackName: "Black"
        )
        let url = try #require(attributes.gameURL)
        let target = try #require(PushRouting.target(from: url))
        let navigator = Navigator()
        navigator.tab = .settings
        AppDelegate.attach(navigator: navigator)
        defer { AppDelegate.navigator = nil }
        AppDelegate.receive(target)
        #expect(navigator.tab == .home)
        guard case .game(let destination) = navigator.homePath.last else {
            Issue.record("The Live Activity must land directly on the game")
            return
        }
        #expect(destination.source == .broadcastBoard(roundId: "round123", gameId: "game456"))
    }

    @Test func boardLink() throws {
        let url = try #require(URL(string: "chesstv://game/round123/game456"))
        #expect(PushRouting.target(from: url) == .board(roundId: "round123", gameId: "game456", tourName: nil))
    }
    @Test(arguments: ["https://game/r/g", "chesstv://unknown/r/g", "chesstv://game/r/g/extra", "chesstv://game/r/g?token=anything"])
    func invalidLinks(_ input: String) throws {
        #expect(PushRouting.target(from: try #require(URL(string: input))) == nil)
    }
}
