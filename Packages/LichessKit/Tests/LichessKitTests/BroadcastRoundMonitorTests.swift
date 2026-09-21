import Foundation
import Testing
import ChessCore
@testable import LichessKit

@Suite("Shared round monitor clock anchors and snapshot ordering")
@MainActor
struct BroadcastRoundMonitorTests {
    private let start = ContinuousClock.now
    private let afterE4 = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1"
    private let afterD4 = "rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq d3 0 1"

    @Test("Matching initial PGN keeps the JSON think-time adjustment and original anchor")
    func matchingHistoricalSnapshotPreservesClock() throws {
        let seed = try jsonRound()
        let monitor = BroadcastRoundMonitor(roundId: seed.round.roundId)
        monitor.applyJSON(round: seed.round, boards: seed.boards, startedRevision: 0, now: start)
        monitor.connectionChanged(.live, now: start)
        monitor.accept(BroadcastRoundUpdate(board: pgnBoard(), san: nil, isInitial: true), now: start.advanced(by: .seconds(5)))
        let board = try #require(monitor.boards.first)
        #expect(board.white?.clockMs == 48_000)
        #expect(board.black?.clockMs == 100_000)
        #expect(monitor.clockAnchor(for: "A") == start)
        #expect(monitor.canTick(board: board))
        #expect(board.white?.fideId == 1234)
        #expect(board.white?.title == "GM")
        #expect(board.white?.rating == 2700)
        #expect(board.white?.federation == "USA")
        #expect(board.black?.fideId == 5678)
    }

    @Test("One board's move leaves every other board's clock anchor unchanged")
    func independentBoardAnchors() throws {
        let seed = try jsonRound(ids: ["A", "B"])
        let monitor = BroadcastRoundMonitor(roundId: seed.round.roundId)
        monitor.applyJSON(round: seed.round, boards: seed.boards, startedRevision: 0, now: start)
        monitor.connectionChanged(.live, now: start)
        let beforeA = try #require(monitor.boards.first { $0.gameId == "A" })
        let updateAt = start.advanced(by: .seconds(8))
        monitor.accept(BroadcastRoundUpdate(board: pgnBoard(id: "B", fen: afterD4, whiteMs: 55_000, move: "d2d4"), san: "d4", isInitial: false), now: updateAt)
        let boardA = try #require(monitor.boards.first { $0.gameId == "A" })
        let boardB = try #require(monitor.boards.first { $0.gameId == "B" })
        #expect(boardA == beforeA)
        #expect(monitor.clockAnchor(for: "A") == start)
        #expect(monitor.clockAnchor(for: "B") == updateAt)
        #expect(boardB.fen == afterD4)
        #expect(boardB.white?.fideId == 1234)
        #expect(boardB.black?.fideId == 5678)
        #expect(monitor.canTick(board: boardA) && monitor.canTick(board: boardB))
    }

    @Test("Disconnect freezes elapsed clocks; identical reconnect waits for fresh JSON to resume")
    func disconnectAndIdenticalReconnect() throws {
        let seed = try jsonRound()
        let monitor = BroadcastRoundMonitor(roundId: seed.round.roundId)
        monitor.applyJSON(round: seed.round, boards: seed.boards, startedRevision: 0, now: start)
        monitor.connectionChanged(.live, now: start)
        let disconnectedAt = start.advanced(by: .seconds(8))
        monitor.connectionChanged(.reconnecting(attempt: 1, nextRetryIn: .seconds(2)), now: disconnectedAt)
        var board = try #require(monitor.boards.first)
        #expect(board.white?.clockMs == 40_000)
        #expect(board.black?.clockMs == 100_000)
        #expect(monitor.clockNow == disconnectedAt)
        #expect(!monitor.canTick(board: board))
        monitor.connectionChanged(.live, now: start.advanced(by: .seconds(20)))
        #expect(!monitor.canTick(board: board))
        monitor.accept(BroadcastRoundUpdate(board: pgnBoard(), san: nil, isInitial: true), now: start.advanced(by: .seconds(20)))
        board = try #require(monitor.boards.first)
        #expect(board.white?.clockMs == 40_000)
        #expect(monitor.clockAnchor(for: "A") == disconnectedAt)
        #expect(!monitor.canTick(board: board))
        let fresh = try jsonRound(whiteCentis: 5000, thinkTime: 18)
        let refreshedAt = start.advanced(by: .seconds(30))
        monitor.applyJSON(round: fresh.round, boards: fresh.boards, startedRevision: monitor.revision, now: refreshedAt)
        board = try #require(monitor.boards.first)
        #expect(board.white?.clockMs == 32_000)
        #expect(monitor.clockAnchor(for: "A") == refreshedAt)
        #expect(monitor.canTick(board: board))
    }

    @Test("A reconnect that missed moves updates the board but does not invent a clock start time")
    func changedHistoricalSnapshotStaysFrozen() throws {
        let seed = try jsonRound()
        let monitor = BroadcastRoundMonitor(roundId: seed.round.roundId)
        monitor.applyJSON(round: seed.round, boards: seed.boards, startedRevision: 0, now: start)
        monitor.connectionChanged(.live, now: start)
        monitor.accept(BroadcastRoundUpdate(board: pgnBoard(fen: afterE4, whiteMs: 55_000, move: "e2e4"), san: "e4", isInitial: true), now: start.advanced(by: .seconds(10)))
        var board = try #require(monitor.boards.first)
        #expect(board.fen == afterE4)
        #expect(board.lastMove == "e2e4")
        #expect(!monitor.canTick(board: board))
        let fresh = try jsonRound(fen: afterE4, whiteCentis: 5500, blackCentis: 10000, thinkTime: 15)
        monitor.applyJSON(round: fresh.round, boards: fresh.boards, startedRevision: monitor.revision, now: start.advanced(by: .seconds(20)))
        board = try #require(monitor.boards.first)
        #expect(board.white?.clockMs == 55_000)
        #expect(board.black?.clockMs == 85_000)
        #expect(monitor.canTick(board: board))
    }

    @Test("A JSON request started before a stream move cannot roll that board back")
    func slowJSONCannotRollbackNewerPosition() throws {
        let seed = try jsonRound(ids: ["A", "B"])
        let monitor = BroadcastRoundMonitor(roundId: seed.round.roundId)
        monitor.applyJSON(round: seed.round, boards: seed.boards, startedRevision: 0, now: start)
        monitor.connectionChanged(.live, now: start)
        let stamp = monitor.revision
        let moveAt = start.advanced(by: .seconds(5))
        monitor.accept(BroadcastRoundUpdate(board: pgnBoard(fen: afterE4, whiteMs: 54_000, move: "e2e4"), san: "e4", isInitial: false), now: moveAt)
        let freshA = try #require(monitor.boards.first { $0.gameId == "A" })
        let oldResponse = try jsonRound(ids: ["A", "B"], whiteCentis: 4500, thinkTime: 10)
        let responseAt = start.advanced(by: .seconds(10))
        monitor.applyJSON(round: oldResponse.round, boards: oldResponse.boards, startedRevision: stamp, now: responseAt)
        #expect(monitor.boards.first { $0.gameId == "A" } == freshA)
        #expect(monitor.clockAnchor(for: "A") == moveAt)
        let boardB = try #require(monitor.boards.first { $0.gameId == "B" })
        #expect(boardB.white?.clockMs == 35_000)
        #expect(monitor.clockAnchor(for: "B") == responseAt)
    }

    @Test("JSON started after a move still cannot replace the streamed position", arguments: [true, false])
    func laggingJSONAfterStreamMove(connected: Bool) throws {
        let seed = try jsonRound()
        let monitor = BroadcastRoundMonitor(roundId: seed.round.roundId)
        monitor.applyJSON(round: seed.round, boards: seed.boards, startedRevision: 0, now: start)
        monitor.connectionChanged(.live, now: start)
        monitor.accept(BroadcastRoundUpdate(board: pgnBoard(fen: afterE4, whiteMs: 55_000, move: "e2e4"), san: "e4", isInitial: false), now: start.advanced(by: .seconds(5)))
        if !connected {
            monitor.connectionChanged(.reconnecting(attempt: 1, nextRetryIn: .seconds(2)), now: start.advanced(by: .seconds(8)))
        }
        let authoritative = try #require(monitor.boards.first)
        let anchor = monitor.clockAnchor(for: "A")
        // This request starts after the stream update, so a revision-only guard cannot help.
        let requestStamp = monitor.revision
        let lagging = try jsonRound(whiteCentis: 4500, thinkTime: 15)
        monitor.applyJSON(round: lagging.round, boards: lagging.boards, startedRevision: requestStamp, now: start.advanced(by: .seconds(12)))
        #expect(monitor.boards.first == authoritative)
        #expect(monitor.boards.first?.fen == afterE4)
        #expect(monitor.clockAnchor(for: "A") == anchor)
        #expect(monitor.canTick(board: authoritative) == connected)
    }

    @Test("JSON started after a streamed result cannot make the game ongoing again", arguments: [true, false])
    func laggingJSONAfterStreamResult(connected: Bool) throws {
        let seed = try jsonRound()
        let monitor = BroadcastRoundMonitor(roundId: seed.round.roundId)
        monitor.applyJSON(round: seed.round, boards: seed.boards, startedRevision: 0, now: start)
        monitor.connectionChanged(.live, now: start)
        monitor.accept(BroadcastRoundUpdate(board: pgnBoard(status: "1-0"), san: nil, isInitial: false), now: start.advanced(by: .seconds(9)))
        if !connected {
            monitor.connectionChanged(.connecting, now: start.advanced(by: .seconds(12)))
        }
        let authoritative = try #require(monitor.boards.first)
        let anchor = monitor.clockAnchor(for: "A")
        let requestStamp = monitor.revision
        let lagging = try jsonRound(whiteCentis: 6000, thinkTime: 20, status: "*")
        monitor.applyJSON(round: lagging.round, boards: lagging.boards, startedRevision: requestStamp, now: start.advanced(by: .seconds(15)))
        let board = try #require(monitor.boards.first)
        #expect(board == authoritative)
        #expect(board.status == "1-0")
        #expect(board.white?.clockMs == 39_000)
        #expect(monitor.clockAnchor(for: "A") == anchor)
        #expect(!monitor.canTick(board: board))
    }

    @Test("Result-only PGN freezes the elapsed clock without restoring its historical reading")
    func resultOnlyFreezesElapsedClock() throws {
        let seed = try jsonRound()
        let monitor = BroadcastRoundMonitor(roundId: seed.round.roundId)
        monitor.applyJSON(round: seed.round, boards: seed.boards, startedRevision: 0, now: start)
        monitor.connectionChanged(.live, now: start)
        let endedAt = start.advanced(by: .seconds(9))
        monitor.accept(BroadcastRoundUpdate(board: pgnBoard(status: "1-0"), san: nil, isInitial: false), now: endedAt)
        let board = try #require(monitor.boards.first)
        #expect(board.status == "1-0")
        #expect(board.white?.clockMs == 39_000)
        #expect(board.black?.clockMs == 100_000)
        #expect(!monitor.canTick(board: board))
        #expect(monitor.clockAnchor(for: "A") == endedAt)
    }

    @Test("Repeated connection failures do not subtract elapsed time twice")
    func repeatedDisconnectDoesNotDoubleAge() throws {
        let seed = try jsonRound()
        let monitor = BroadcastRoundMonitor(roundId: seed.round.roundId)
        monitor.applyJSON(round: seed.round, boards: seed.boards, startedRevision: 0, now: start)
        monitor.connectionChanged(.live, now: start)
        monitor.connectionChanged(.connecting, now: start.advanced(by: .seconds(8)))
        monitor.connectionChanged(.failed("unavailable"), now: start.advanced(by: .seconds(30)))
        let board = try #require(monitor.boards.first)
        #expect(board.white?.clockMs == 40_000)
        #expect(board.black?.clockMs == 100_000)
        #expect(!monitor.canTick(board: board))
    }

    @Test("A historical board received without any JSON seed remains untimed")
    func unseededHistoricalBoardWaitsForClockAuthority() throws {
        let monitor = BroadcastRoundMonitor(roundId: "round")
        monitor.connectionChanged(.live, now: start)
        monitor.accept(BroadcastRoundUpdate(board: pgnBoard(), san: nil, isInitial: true), now: start)
        let board = try #require(monitor.boards.first)
        #expect(monitor.hasLoaded)
        #expect(!monitor.canTick(board: board))
    }

    private func jsonRound(
        ids: [String] = ["A"], fen: String = Position.standard.fen,
        whiteCentis: Int = 6000, blackCentis: Int = 10000, thinkTime: Int = 12,
        status: String = "*"
    ) throws -> (round: BroadcastTournament, boards: [BroadcastBoard]) {
        var root = try #require(JSONSerialization.jsonObject(with: Fixture.JSON.broadcastRound.data) as? [String: Any])
        root["games"] = ids.map { id in
            ["id": id, "name": "Alice - Bob", "fen": fen, "status": status,
             "thinkTime": thinkTime,
             "players": [
                ["name": "Alice", "title": "GM", "rating": 2700, "fideId": 1234, "fed": "USA", "clock": whiteCentis],
                ["name": "Bob", "title": "IM", "rating": 2500, "fideId": 5678, "fed": "CAN", "clock": blackCentis]
             ]] as [String: Any]
        }
        return try BroadcastClient.decodeRound(JSONSerialization.data(withJSONObject: root))
    }

    private func pgnBoard(
        id: String = "A", fen: String = Position.standard.fen,
        whiteMs: Int = 60_000, blackMs: Int = 100_000, status: String = "*", move: String? = nil
    ) -> BroadcastBoard {
        BroadcastBoard(gameId: id, name: "Alice - Bob", fen: fen, lastMove: move, status: status,
            players: [
                BroadcastPlayer(name: "Alice", title: nil, rating: nil, federation: nil, clockMs: whiteMs),
                BroadcastPlayer(name: "Bob", title: nil, rating: nil, federation: nil, clockMs: blackMs)
            ])
    }
}
