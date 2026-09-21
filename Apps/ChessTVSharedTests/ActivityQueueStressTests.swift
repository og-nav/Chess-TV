import Foundation
import Testing
import FollowKit
@testable import ChessTVMobile

@Suite("Activity retry queue under repeated lifecycle changes")
struct ActivityQueueStressTests {
    @Test("Thousands of token rotations, late acknowledgements, ends and repins survive JSON round trips")
    func lifecycleStress() throws {
        let host = "https://one.example"
        var queue = ActivityWorkQueue()
        var expected: [String: String] = [:]
        var superseded: [PendingActivityWork] = []
        for step in 0..<2500 {
            let game = "game-\(step % 23)"
            if step % 7 == 0 {
                queue.enqueue(PendingActivityWork(kind: .end, gameId: game, server: host))
                expected.removeValue(forKey: game)
            } else {
                let token = "token-\(step)"
                if let old = queue.items.last(where: { $0.gameId == game && $0.kind == .register }) {
                    superseded.append(old)
                }
                queue.enqueue(PendingActivityWork(kind: .register, roundId: "round", gameId: game, activityToken: token, server: host))
                expected[game] = token
            }
            if step % 11 == 0, let failed = queue.items.last {
                let acceptedFailure = queue.recordFailure(of: failed)
                #expect(acceptedFailure)
            }
            if step % 13 == 0, let old = superseded.popLast() {
                let before = queue
                queue.remove(old)
                #expect(queue == before)
                let staleFailure = queue.recordFailure(of: old)
                #expect(!staleFailure)
            }
            if step % 17 == 0 {
                let beforeIDs = queue.items.map(\.id)
                queue = try FollowJSON.decoder.decode(ActivityWorkQueue.self, from: FollowJSON.encoder.encode(queue))
                #expect(queue.items.map(\.id) == beforeIDs)
            }
            #expect(Set(queue.items.map(\.id)).count == queue.items.count)
            #expect(queue.items.count <= 46) // At most an ordered end + registration per game.
            var replayed: [String: String] = [:]
            for item in queue.items {
                switch item.kind {
                case .end: replayed.removeValue(forKey: item.gameId)
                case .register: replayed[item.gameId] = item.activityToken
                }
            }
            #expect(replayed == expected)
        }
    }

    @Test("Host switches and stale responses cannot acknowledge another host's work")
    func hostGenerationStress() throws {
        var queue = ActivityWorkQueue()
        var obsolete: [PendingActivityWork] = []
        for generation in 0..<100 {
            let host = "https://host-\(generation).example"
            obsolete.append(contentsOf: queue.items)
            queue.keep(server: host)
            for index in 0..<10 {
                queue.enqueue(PendingActivityWork(kind: .register, roundId: "round", gameId: "g\(index)", activityToken: "token\(generation)-\(index)", server: host))
            }
            for stale in obsolete.suffix(25) {
                queue.remove(stale)
                let recorded = queue.recordFailure(of: stale)
                #expect(!recorded)
            }
            queue = try FollowJSON.decoder.decode(ActivityWorkQueue.self, from: FollowJSON.encoder.encode(queue))
            #expect(queue.items.count == 10)
            #expect(queue.items.allSatisfy { $0.server == host && $0.attempts == 0 })
        }
    }
}
