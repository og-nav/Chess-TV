import Testing
@testable import EngineKit

@Suite("UCI parsing")
struct UCIParserTests {

    @Test func sideToMove() {
        #expect(UCIParser.blackToMove(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1") == false)
        #expect(UCIParser.blackToMove(fen: "r5k1/5ppp/8/8/8/8/5PPP/6K1 b - - 0 1") == true)
        #expect(UCIParser.blackToMove(fen: "8/8/8/8/8/8/8/8") == nil)
    }

    @Test func centipawnsAreNormalisedToWhite() {
        let line = "info depth 12 seldepth 18 multipv 1 score cp 34 nodes 1000 pv e2e4 e7e5"
        let white = UCIParser.evaluation(from: line, fen: "f", revision: 3, negate: false)
        #expect(white?.score == .centipawns(34))
        #expect(white?.depth == 12)
        #expect(white?.principalVariation == ["e2e4", "e7e5"])
        #expect(white?.revision == 3)
        #expect(white?.positionFEN == "f")

        let black = UCIParser.evaluation(from: line, fen: "f", revision: 3, negate: true)
        #expect(black?.score == .centipawns(-34))
    }

    @Test func mateIsNormalisedToWhite() {
        let line = "info depth 4 score mate 1 pv a1a8"
        #expect(UCIParser.evaluation(from: line, fen: "f", revision: 0, negate: false)?.score == .mate(1))
        #expect(UCIParser.evaluation(from: line, fen: "f", revision: 0, negate: true)?.score == .mate(-1))
    }

    @Test func noisyLinesAreIgnored() {
        #expect(UCIParser.evaluation(from: "info string NNUE evaluation using nn.nnue", fen: "f", revision: 0, negate: false) == nil)
        #expect(UCIParser.evaluation(from: "info depth 3 multipv 2 score cp 5 pv d2d4", fen: "f", revision: 0, negate: false) == nil)
        #expect(UCIParser.evaluation(from: "info depth 3 score cp 500 upperbound pv d2d4", fen: "f", revision: 0, negate: false) == nil)
        #expect(UCIParser.evaluation(from: "info depth 5 nodes 900 nps 4000 time 20", fen: "f", revision: 0, negate: false) == nil)
        #expect(UCIParser.evaluation(from: "bestmove e2e4", fen: "f", revision: 0, negate: false) == nil)
    }

    @Test func durationMilliseconds() {
        #expect(Duration.milliseconds(1500).milliseconds == 1500)
        #expect(Duration.seconds(2).milliseconds == 2000)
        #expect(Duration.milliseconds(-5).milliseconds == 0)
    }
}
