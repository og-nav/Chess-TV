import Foundation
import Testing
@testable import LichessKit

@Suite("Tournament round list") struct BroadcastTourTests {
    @Test func roundsIncludeFutureAndFinishedWithModernFinishTimestamp() throws {
        let data = Data(#"{"tour":{"id":"tour1","name":"Championship"},"rounds":[{"id":"r1","name":"Round 1","finishedAt":1790000000000},{"id":"r2","name":"Round 2","ongoing":true},{"id":"r3","name":"Round 3","startsAt":1790086400000}]}"#.utf8)
        let tour = try BroadcastClient.decodeTournament(data)
        #expect(tour.id == "tour1")
        #expect(tour.rounds.count == 3)
        #expect(tour.rounds[0].finished)
        #expect(tour.rounds[1].ongoing)
        #expect(!tour.rounds[2].finished)
        #expect(tour.rounds[2].startsAt?.timeIntervalSince1970 == 1790086400)
    }
}
