import Foundation
import Testing
@testable import LichessKit

@Suite("Broadcast clock wire units")
struct BroadcastClockTests {
    private func board(side: String = "w", status: String = "*", think: Int? = 12, clock: Int = 6000) throws -> BroadcastBoard {
        var json = try #require(JSONSerialization.jsonObject(with: Fixture.JSON.broadcastRound.data) as? [String: Any])
        var game: [String: Any] = ["id": "clock", "fen": "8/8/8/8/8/8/8/8 \(side) - - 0 1", "status": status,
            "players": [["name": "W", "clock": clock], ["name": "B", "clock": 10000]]]
        if let think { game["thinkTime"] = think }
        json["games"] = [game]
        return try #require(BroadcastClient.decodeRound(JSONSerialization.data(withJSONObject: json)).boards.first)
    }
    @Test func centisecondsAndCurrentThinkTime() throws {
        #expect(try board().white?.clockSeconds == 48)
        #expect(try board().black?.clockSeconds == 100)
        #expect(try board(side: "b").white?.clockSeconds == 60)
        #expect(try board(side: "b").black?.clockSeconds == 88)
    }
    @Test func finishedAndUnknownSideDoNotTick() throws {
        #expect(try board(status: "½-½").white?.clockSeconds == 60)
        #expect(try board(side: "invalid").white?.clockSeconds == 60)
        #expect(try board(think: nil).white?.clockSeconds == 60)
    }
    @Test func negativeAndElapsedClamps() throws {
        #expect(try board(think: -30).white?.clockSeconds == 60)
        #expect(try board(think: 200).white?.clockSeconds == 0)
        #expect(try board(clock: -200).white?.clockSeconds == 0)
    }
}
