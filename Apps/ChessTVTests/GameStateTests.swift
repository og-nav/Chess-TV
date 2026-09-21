import Testing
import Foundation
import ChessCore
import LichessKit
import EngineKit
@testable import ChessTV

@Suite("GameState accepts only evaluations that match what is on screen")
@MainActor
struct GameStateTests {

    private func seeded() throws -> GameState {
        let state = GameState()
        let events = try FixtureFeed.events(named: "feed-castling")
        state.apply(events[0])
        state.apply(events[1])
        return state
    }

    private func evaluation(fen: String, revision: Int) -> Evaluation {
        Evaluation(score: .centipawns(40), depth: 20, principalVariation: ["d2d4", "d7d5", "c2c4"], positionFEN: fen, revision: revision)
    }

    @Test("A matching FEN and revision is stored")
    func accepted() throws {
        let state = try seeded()
        let fen = try #require(state.position?.fen)
        #expect(state.applyEvaluation(evaluation(fen: fen, revision: state.revision)))
        #expect(state.evaluation?.depth == 20)
        #expect(state.evaluationText == "+0.4")
        #expect((state.whiteShare ?? 0) > 0.5)
    }

    @Test("The wrong FEN is rejected")
    func wrongFEN() throws {
        let state = try seeded()
        #expect(!state.applyEvaluation(evaluation(fen: Position.standard.fen, revision: state.revision)))
        #expect(state.evaluation == nil)
    }

    @Test("The wrong revision is rejected")
    func wrongRevision() throws {
        let state = try seeded()
        let fen = try #require(state.position?.fen)
        #expect(!state.applyEvaluation(evaluation(fen: fen, revision: state.revision + 1)))
        #expect(!state.applyEvaluation(evaluation(fen: fen, revision: state.revision - 1)))
        #expect(state.evaluation == nil)
    }

    @Test("The next move drops the evaluation that belonged to the previous one")
    func nextMoveClears() throws {
        let state = try seeded()
        let fen = try #require(state.position?.fen)
        #expect(state.applyEvaluation(evaluation(fen: fen, revision: state.revision)))
        let events = try FixtureFeed.events(named: "feed-castling")
        state.apply(events[2])
        #expect(state.evaluation == nil)
    }

    @Test("Mate scores map to the ends of the bar")
    func mateScores() throws {
        let state = try seeded()
        let fen = try #require(state.position?.fen)
        state.applyEvaluation(Evaluation(score: .mate(3), depth: 30, principalVariation: [], positionFEN: fen, revision: state.revision))
        #expect(state.evaluationText == "M3")
        #expect(state.whiteShare == 1.0)
    }

    @Test("Clearing the game forgets the position, the history and the evaluation")
    func clearing() throws {
        let state = try seeded()
        state.connection = .live
        state.clearGame()
        #expect(state.position == nil)
        #expect(state.revision == 0)
        #expect(state.moveHistory.isEmpty)
        #expect(state.evaluation == nil)
        #expect(state.connection == .live)
    }
}

@Suite("The home shelf order and the model's view of a source")
@MainActor
struct SourcePresentationTests {

    @Test("The Lichess TV shelf starts with the seven headline channels")
    func order() {
        #expect(Array(HomeShelves.channelOrder.prefix(7)) == [.best, .bullet, .blitz, .rapid, .classical, .ultraBullet, .chess960])
        #expect(HomeShelves.channelOrder.count == TVChannel.allCases.count)
        #expect(Set(HomeShelves.channelOrder).count == TVChannel.allCases.count)
    }

    @Test("The eval bar hides on variants and when the engine is off")
    func evalBarVisibility() {
        let model = makeModel()
        model.settings.engineEnabled = true
        model.game.source = .tvChannel(.blitz)
        #expect(model.showsEvalBar)
        model.game.source = .tvChannel(.atomic)
        #expect(!model.showsEvalBar)
        model.game.source = .tvChannel(.chess960)
        #expect(!model.showsEvalBar)          // Stockfish is only asked about standard chess now
        model.game.source = .arena(tournamentId: "abc")
        model.settings.engineEnabled = false
        #expect(!model.showsEvalBar)
    }

    @Test("Following the featured player flips the board")
    func orientation() throws {
        let model = makeModel()
        let events = try FixtureFeed.events(named: "feed-castling")
        model.game.apply(events[3])                 // orientation: black
        model.settings.followFeaturedPlayer = false
        #expect(model.boardOrientation == .white)
        #expect(model.topColor == .black)
        model.settings.followFeaturedPlayer = true
        #expect(model.boardOrientation == .black)
        #expect(model.topColor == .white)
    }

    @Test("Sources round-trip through the storage key the settings and -open use")
    func storageKeys() {
        let sources: [GameSource] = [
            .tvChannel(.blitz),
            .arena(tournamentId: "j7Qd8Kz2"),
            .broadcastBoard(roundId: "q7gOEObq", gameId: "abcd1234"),
        ]
        for source in sources {
            #expect(GameSource(storageKey: source.storageKey) == source)
        }
        #expect(GameSource(storageKey: "tv:nosuchchannel") == nil)
        #expect(GameSource(storageKey: "board:onlyround") == nil)
    }

    @Test("-open pushes the matching screens")
    func launchArguments() {
        #expect(LaunchArguments.routes(["app"]).isEmpty)
        #expect(LaunchArguments.routes(["app", "-open", "tv:blitz"])
            == [.game(GameDestination(source: .tvChannel(.blitz)))])
        #expect(LaunchArguments.routes(["app", "-open", "boards:q7gOEObq"])
            == [.boards(roundId: "q7gOEObq", tournamentName: nil)])
        #expect(LaunchArguments.routes(["app", "-open", "board:q7gOEObq:xyz"]).count == 2)
        #expect(LaunchArguments.routes(["app", "-open", "nonsense"]).isEmpty)
    }

    private func makeModel() -> AppModel {
        AppModel(
            settings: AppSettings(defaults: UserDefaults(suiteName: "ChessTVTests-\(UUID().uuidString)")!),
            streamer: FakeStreamer(),
            arenas: FakeArenas()
        )
    }
}
