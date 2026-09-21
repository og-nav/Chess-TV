import Testing
import Foundation
import FollowKit
@testable import ChessTVMobile

@Suite("Collapsing the queue of unsent follow edits")
struct PendingQueueTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func follow(_ id: String, alerts: FollowAlerts = .gameDefaults) -> Follow {
        Follow(id: id, target: .game(roundId: "r1", gameId: "g\(id)"), alerts: alerts, createdAt: now)
    }

    private func edit(_ operation: PendingEdit.Operation) -> PendingEdit {
        PendingEdit(operation: operation)
    }

    /// The shapes, so a test can read a queue without pattern matching five times.
    private func shape(_ queue: [PendingEdit]) -> [String] {
        queue.map { edit in
            switch edit.operation {
            case .add(let follow): "add(\(follow.id))"
            case .alerts(let id, _): "alerts(\(id))"
            case .remove(let id): "remove(\(id))"
            case .preferences: "preferences"
            }
        }
    }

    @Test("A follow added and dropped again while offline sends nothing at all")
    func addThenRemoveCancels() {
        let local = FollowFactory.localID()
        var queue = PendingQueue.appending(edit(.add(follow(local))), to: [])
        queue = PendingQueue.appending(edit(.remove(followID: local)), to: queue)
        #expect(queue.isEmpty)
    }

    @Test("A follow the server already has still gets its delete, and its earlier edits are dropped")
    func removeOfServerFollowSurvives() {
        var queue = PendingQueue.appending(edit(.alerts(followID: "server-7", alerts: .playerDefaults)), to: [])
        queue = PendingQueue.appending(edit(.remove(followID: "server-7")), to: queue)
        #expect(shape(queue) == ["remove(server-7)"])
    }

    @Test("Switches flipped six times while offline become one PATCH")
    func repeatedAlertsCollapse() {
        var queue: [PendingEdit] = []
        for minutes in [1, 2, 5, 10, 15, 30] {
            var alerts = FollowAlerts.gameDefaults
            alerts.minMinutesBetweenMoveAlerts = minutes
            queue = PendingQueue.appending(edit(.alerts(followID: "server-1", alerts: alerts)), to: queue)
        }
        #expect(shape(queue) == ["alerts(server-1)"])
        guard case .alerts(_, let alerts) = queue[0].operation else { Issue.record("wrong shape"); return }
        #expect(alerts.minMinutesBetweenMoveAlerts == 30)
    }

    @Test("Switches changed on a follow that has not been created yet ride along with the POST")
    func alertsFoldIntoPendingAdd() {
        let local = FollowFactory.localID()
        var alerts = FollowAlerts.gameDefaults
        alerts.game.insert(.move)
        var queue = PendingQueue.appending(edit(.add(follow(local))), to: [])
        queue = PendingQueue.appending(edit(.alerts(followID: local, alerts: alerts)), to: queue)

        #expect(shape(queue) == ["add(\(local))"])
        guard case .add(let queued) = queue[0].operation else { Issue.record("wrong shape"); return }
        #expect(queued.alerts.game.contains(.move))
    }

    @Test("Only the newest preferences matter; the server takes the whole object")
    func preferencesCollapse() {
        var first = NotificationPreferences.mobileDefault()
        first.muteAll = true
        var second = NotificationPreferences.mobileDefault()
        second.muteAll = false
        second.quietHoursStart = 60

        var queue = PendingQueue.appending(edit(.preferences(first)), to: [])
        queue = PendingQueue.appending(edit(.add(follow("local-x"))), to: queue)
        queue = PendingQueue.appending(edit(.preferences(second)), to: queue)

        #expect(shape(queue) == ["add(local-x)", "preferences"])
        guard case .preferences(let kept) = queue[1].operation else { Issue.record("wrong shape"); return }
        #expect(kept.quietHoursStart == 60)
        #expect(kept.muteAll == false)
    }

    @Test("Two different follows both keep their place, oldest first")
    func independentFollowsAreNotCollapsed() {
        var queue = PendingQueue.appending(edit(.add(follow("local-a"))), to: [])
        queue = PendingQueue.appending(edit(.alerts(followID: "server-2", alerts: .playerDefaults)), to: queue)
        queue = PendingQueue.appending(edit(.remove(followID: "server-3")), to: queue)
        #expect(shape(queue) == ["add(local-a)", "alerts(server-2)", "remove(server-3)"])
    }

    @Test("When the server mints an id, every queued edit for the local one follows it")
    func idRewriteCoversTheWholeQueue() {
        let local = FollowFactory.localID()
        var queue = PendingQueue.appending(edit(.add(follow(local))), to: [])
        queue.append(edit(.alerts(followID: local, alerts: .playerDefaults)))
        queue.append(edit(.remove(followID: local)))
        queue.append(edit(.alerts(followID: "server-9", alerts: .playerDefaults)))

        let rewritten = PendingQueue.rewriting(localID: local, to: "server-42", in: queue)
        #expect(shape(rewritten) == ["add(server-42)", "alerts(server-42)", "remove(server-42)", "alerts(server-9)"])
    }
}
