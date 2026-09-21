import Testing
import Foundation
import ChessCore

/// The broadcast PGN parser, driven by a real recording of
/// `GET /api/broadcast/round/q7gOEObq.pgn` (five TCEC games, one of them annotated).
@Suite("PGN parses and replays what a broadcast round publishes")
struct PGNTests {

    private static var roundPGN: String {
        get throws {
            let url = try #require(
                Bundle.module.url(forResource: "broadcast-round", withExtension: "pgn", subdirectory: "Fixtures"),
                "missing fixture broadcast-round.pgn"
            )
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    @Test("A recorded round splits into its five games")
    func splitsRound() throws {
        let games = PGN.parseGames(try Self.roundPGN)
        #expect(games.count == 5)
        #expect(games.allSatisfy { $0.tags["Event"] == "TCEC Season 30 - Category 2 Playoff" })
        #expect(games.map(\.white) == [
            "Raphael 4.3.0-dev-acd050b", "Bagatur.cpp 1.1", "PZChessBot 20260902-88545a9-dev",
            "Wasp 7.16", "Mr_Bob 81deaf4c",
        ])
        #expect(games.compactMap(\.outcome) == ["1-0", "1/2-1/2", "1-0", "1/2-1/2", "1/2-1/2"])
        #expect(games.allSatisfy { ($0.whiteElo ?? 0) > 2000 && ($0.blackElo ?? 0) > 2000 })
        #expect(games.allSatisfy { $0.whiteTitle == "BOT" })
    }

    @Test("Every game replays to its own result without a single unplayable move")
    func replaysEveryGame() throws {
        let games = PGN.parseGames(try Self.roundPGN)
        for game in games {
            let steps = try game.replay(from: game.initialPosition)
            #expect(steps.count == game.moves.count)
            #expect(!steps.isEmpty)

            let final = try Position(fen: try #require(steps.last).fen)
            switch try #require(game.outcome) {
            case "1-0":
                #expect(final.isCheckmate || game.tags["Termination"] != nil)
                #expect(final.sideToMove == .black)
            case "0-1":
                #expect(final.sideToMove == .white)
            case "1/2-1/2":
                #expect(game.tags["Termination"] != nil)
            default:
                Issue.record("unexpected result \(game.outcome ?? "-")")
            }
            #expect(game.isFinished)
            #expect(game.result == game.tags["Result"])
        }
    }

    @Test("The first game mates on move 82 and its clocks and ids survive")
    func firstGameDetail() throws {
        let game = try #require(PGN.parseGames(try Self.roundPGN).first)
        #expect(game.gameId == "ZD7czPL6")
        #expect(game.gameURL?.hasSuffix("/q7gOEObq/ZD7czPL6") == true)
        #expect(game.result == "1-0")

        #expect(game.moves.count == 163)                       // 82 white moves, 81 black
        #expect(game.moves.first?.san == "Nf3")
        #expect(game.moves.first?.clock == .seconds(1800))
        #expect(game.moves.first?.eval == "0.1")
        #expect(game.moves.first?.moveNumber == 1)
        #expect(game.moves.last?.san == "Qg8#")
        #expect(game.moves.last?.clock == .seconds(51))
        #expect(game.moves.allSatisfy { $0.clock != nil })

        // An annotated ply: two evals, a prose comment and a clock, all in separate braces.
        let inaccuracy = try #require(game.moves.first { $0.san == "Rb7?!" })
        #expect(inaccuracy.eval == "26.66")
        #expect(inaccuracy.clock == .seconds(10))
        #expect(inaccuracy.comment == "Inaccuracy. Qd7 was best.")

        let steps = try game.replay()
        #expect(steps.count == 163)
        #expect(steps[0].uci == "g1f3")
        #expect(steps[0].fen == "rnbqkbnr/pppppppp/8/8/8/5N2/PPPPPPPP/RNBQKB1R b KQkq - 1 1")
        #expect(steps.last?.uci == "d8g8")   // the d8 queen; the c8 one is blocked by it
        #expect(try Position(fen: try #require(steps.last).fen).isCheckmate)
        // Both promotions in the finish replay as promotions.
        #expect(steps.contains { $0.uci == "d7d8q" })
        #expect(steps.contains { $0.uci == "c7c8q" })
    }

    @Test("Every GameURL yields the id the stream keys on")
    func gameIds() throws {
        let games = PGN.parseGames(try Self.roundPGN)
        let ids = games.compactMap(\.gameId)
        #expect(ids.count == 5)
        #expect(Set(ids).count == 5)
        #expect(ids.allSatisfy { $0.count == 8 })
    }

    // MARK: - Synthetic awkwardness

    private static let awkward = [
        "[Event \"Synthetic\"]",
        "[Site \"?\"]",
        "[Result \"1/2-1/2\"]",
        "",
        "1. e4 { the king's pawn } 1... e5 $1 (1... c5 { the Sicilian (sharper) } 2. Nf3 d6) 2. Nf3?!",
        "2... Nc6 3. Bb5 { [%clk 0:02:59] } 3... a6!? { [%eval 0.24] [%clk 0:02:58.5] } 1/2-1/2",
        "",
    ].joined(separator: "\r\n")

    @Test("Variations, NAGs, a 1... continuation and CRLF are all tolerated")
    func syntheticGame() throws {
        let games = PGN.parseGames(Self.awkward)
        #expect(games.count == 1)
        let game = try #require(games.first)

        #expect(game.moves.map(\.san) == ["e4", "e5", "Nf3?!", "Nc6", "Bb5", "a6!?"])
        #expect(game.moves.map(\.moveNumber) == [1, 1, 2, 2, 3, 3])
        #expect(game.moves[0].comment == "the king's pawn")
        #expect(game.moves[4].clock == .seconds(179))
        #expect(game.moves[5].eval == "0.24")
        #expect(game.moves[5].clock == .seconds(178.5))
        #expect(game.result == "1/2-1/2")
        #expect(game.isFinished)

        let steps = try game.replay()
        #expect(steps.map(\.uci) == ["e2e4", "e7e5", "g1f3", "b8c6", "f1b5", "a7a6"])
        // The variation's moves are nowhere in the mainline.
        #expect(!steps.contains { $0.uci == "c7c5" })
    }

    @Test("Two games separated only by a blank line and a tag both come out")
    func twoGames() {
        let text = """
        [Event "A"]
        [Result "1-0"]

        1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7# 1-0

        [Event "B"]
        [Result "*"]

        1. d4 d5 *
        """
        let games = PGN.parseGames(text)
        #expect(games.count == 2)
        #expect(games[0].moves.count == 7)
        #expect(games[0].result == "1-0")
        #expect(games[0].isFinished)
        #expect(games[1].moves.map(\.san) == ["d4", "d5"])
        #expect(games[1].result == "*")
        #expect(!games[1].isFinished)
    }

    @Test("A game that starts from a FEN tag replays from it")
    func setUpPosition() throws {
        let text = """
        [Event "Endgame"]
        [SetUp "1"]
        [FEN "8/8/8/8/8/5k2/7p/6K1 b - - 0 1"]
        [Result "*"]

        1... h1=Q+ 2. Kxh1 *
        """
        let game = try #require(PGN.parseGames(text).first)
        #expect(game.initialPosition.fen == "8/8/8/8/8/5k2/7p/6K1 b - - 0 1")
        let steps = try game.replay(from: game.initialPosition)
        #expect(steps.map(\.uci) == ["h2h1q", "g1h1"])
    }

    @Test("An unplayable move names its ply and keeps the prefix")
    func replayError() throws {
        let game = try #require(PGN.parseGames("""
        [Event "Broken"]

        1. e4 e5 2. Nf3 Qxh8 *
        """).first)
        do {
            _ = try game.replay()
            Issue.record("expected a replay error")
        } catch let error as PGNReplayError {
            #expect(error.ply == 4)
            #expect(error.san == "Qxh8")
            #expect(error.replayed.count == 3)
            #expect(error.replayed.map(\.uci) == ["e2e4", "e7e5", "g1f3"])
            #expect(error.description.contains("ply 4"))
            #expect(error.description.contains("Qxh8"))
        }
    }

    @Test("Clock strings in every shape")
    func clockParsing() {
        #expect(PGN.duration(fromClock: "0:30:00") == .seconds(1800))
        #expect(PGN.duration(fromClock: "1:02:03") == .seconds(3723))
        #expect(PGN.duration(fromClock: "12:04") == .seconds(724))
        #expect(PGN.duration(fromClock: "45") == .seconds(45))
        #expect(PGN.duration(fromClock: "0:00:09.5") == .seconds(9.5))
        #expect(PGN.duration(fromClock: "") == nil)
        #expect(PGN.duration(fromClock: "nonsense") == nil)
    }
}
