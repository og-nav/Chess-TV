import Testing
import LichessKit
@testable import ChessTV

@Suite("Round alerts: results and time scrambles on the other boards")
struct RoundAlertsTests {

    private func player(_ name: String, title: String? = "GM", clockMs: Int? = 30 * 60 * 1000) -> BroadcastPlayer {
        BroadcastPlayer(name: name, title: title, rating: 2700, federation: "USA", clockMs: clockMs)
    }

    private func board(_ id: String, _ white: BroadcastPlayer, _ black: BroadcastPlayer, status: String = "*") -> BroadcastBoard {
        BroadcastBoard(gameId: id, name: "\(white.name) - \(black.name)", fen: "", lastMove: nil, status: status, players: [white, black])
    }

    @Test("The first poll is a baseline: nothing that already happened is news")
    func baseline() {
        var detector = RoundAlertDetector()
        let boards = [
            board("a", player("Carlsen, Magnus"), player("Nakamura, Hikaru"), status: "1-0"),
            board("b", player("So, Wesley", clockMs: 60_000), player("Caruana, Fabiano", clockMs: 90_000)),
        ]
        #expect(detector.alerts(for: boards, watching: nil).isEmpty)
        // Same state again: still nothing.
        #expect(detector.alerts(for: boards, watching: nil).isEmpty)
    }

    @Test("A result landing on another board becomes one toast")
    func result() {
        var detector = RoundAlertDetector()
        let white = player("Carlsen, Magnus")
        let black = player("Nakamura, Hikaru")
        _ = detector.alerts(for: [board("x", white, black), board("a", white, black)], watching: "x")

        let alerts = detector.alerts(for: [board("x", white, black, status: "1-0"), board("a", white, black, status: "0-1")], watching: "x")
        #expect(alerts.count == 1)
        #expect(alerts.first?.kind == .result)
        #expect(alerts.first?.headline == "Board 2")
        #expect(alerts.first?.detail == "GM Nakamura beat GM Carlsen")
        // Already reported; a later poll says nothing new.
        #expect(detector.alerts(for: [board("x", white, black, status: "1-0"), board("a", white, black, status: "0-1")], watching: "x").isEmpty)
    }

    @Test("Result wording for each status")
    func wording() {
        let white = player("Carlsen, Magnus")
        let black = player("Praggnanandhaa R", title: nil)
        #expect(RoundAlertDetector.resultText(board("a", white, black, status: "1-0")) == "GM Carlsen beat Praggnanandhaa R")
        #expect(RoundAlertDetector.resultText(board("a", white, black, status: "\u{00BD}-\u{00BD}")) == "GM Carlsen and Praggnanandhaa R drew")
        #expect(RoundAlertDetector.resultText(board("a", white, black, status: "1/2-1/2")) == "GM Carlsen and Praggnanandhaa R drew")
    }

    @Test("Both clocks under five minutes fires once per board, never on the watched one")
    func scramble() {
        var detector = RoundAlertDetector()
        let calm = [board("x", player("A, a"), player("B, b")), board("c", player("C, c"), player("D, d"))]
        _ = detector.alerts(for: calm, watching: "x")

        let tight = [
            board("x", player("A, a", clockMs: 10_000), player("B, b", clockMs: 20_000)),
            board("c", player("C, c", clockMs: 299_000), player("D, d", clockMs: 100_000)),
        ]
        let alerts = detector.alerts(for: tight, watching: "x")
        #expect(alerts.count == 1)
        #expect(alerts.first?.kind == .timeScramble)
        #expect(alerts.first?.detail == "Time scramble: GM C \u{2013} GM D, both under 5:00")
        #expect(detector.alerts(for: tight, watching: "x").isEmpty)

        // One side still has time: not a scramble.
        var fresh = RoundAlertDetector()
        _ = fresh.alerts(for: calm, watching: nil)
        let oneSide = [board("c", player("C, c", clockMs: 100_000), player("D, d"))]
        #expect(fresh.alerts(for: oneSide, watching: nil).isEmpty)
    }

    @Test("Many results in one poll fold into a few lines")
    func condensed() {
        var detector = RoundAlertDetector()
        let live = (1...8).map { board("g\($0)", player("W\($0), w"), player("B\($0), b")) }
        _ = detector.alerts(for: live, watching: nil)
        let done = live.map { board($0.gameId, $0.white!, $0.black!, status: "1-0") }
        let alerts = detector.alerts(for: done, watching: nil)
        #expect(alerts.count == RoundAlertDetector.maxPerPoll)
        #expect(alerts.last?.kind == .more)
        #expect(alerts.last?.detail == "6 more boards finished")
    }

    @Test("Reset takes a fresh baseline")
    func reset() {
        var detector = RoundAlertDetector()
        let white = player("Carlsen, Magnus")
        let black = player("Nakamura, Hikaru")
        _ = detector.alerts(for: [board("a", white, black)], watching: nil)
        detector.reset()
        #expect(detector.alerts(for: [board("a", white, black, status: "1-0")], watching: nil).isEmpty)
    }
}
