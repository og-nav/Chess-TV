// Collapsing the queue of unsent edits.
//
// A week on a train is a week of edits, and replaying every one of them when the signal comes
// back would mean a follow that was added and dropped again costing two requests, or a switch
// flipped six times costing six. The rules below keep the queue the size of the *difference*
// between what the server has and what the phone shows, not the size of the user's fidgeting.
//
// Pure functions on arrays, so ChessTVMobileTests can drive them directly.
import Foundation
import FollowKit

enum PendingQueue {

    /// Adds one edit, folding it into what is already queued.
    ///
    /// * A `remove` erases obsolete edits, but retains an uncertain add so its server id can be
    ///   recovered before deletion. Only an add that was never attempted cancels out entirely.
    /// * `alerts` on a follow still queued as an `add` is folded into the `add`, so the follow
    ///   arrives with its final switches in one `POST`.
    /// * A second `alerts` for the same follow replaces the first.
    /// * Only the newest `preferences` matters; the server takes the whole object.
    ///
    /// - Parameter inFlight: the id of the edit currently on the wire, if any. **An edit that has
    ///   already left cannot be cancelled by deleting it from the queue**: the server is going to
    ///   act on it whatever happens here. So a follow whose `add` is in flight gets a real
    ///   `remove` queued behind it (`rewriting` repoints it at the id the server mints), and a
    ///   switch flip is not folded into an `add` the server has already been sent.
    static func appending(_ edit: PendingEdit, to queue: [PendingEdit], inFlight: UUID? = nil) -> [PendingEdit] {
        switch edit.operation {

        case .remove(let followID):
            let unsentAdd = queue.first {
                if case .add(let follow) = $0.operation { return follow.id == followID }
                return false
            }
            var trimmed = queue.filter { $0.followID != followID || $0.id == inFlight }
            if let unsentAdd, unsentAdd.id != inFlight, !unsentAdd.wasSubmitted,
               FollowFactory.isLocal(followID) { return trimmed }
            // An earlier attempt may already exist remotely even though its id is still local.
            // Replay it to recover the server id, then delete that exact follow.
            if let unsentAdd, unsentAdd.wasSubmitted, unsentAdd.id != inFlight {
                trimmed = queue.filter { $0.followID != followID || $0.id == unsentAdd.id }
            }
            trimmed.append(edit)
            return trimmed

        case .alerts(let followID, let alerts):
            if let index = queue.firstIndex(where: {
                if case .add(let follow) = $0.operation { return follow.id == followID }
                return false
            }), queue[index].id != inFlight, !queue[index].wasSubmitted {
                var folded = queue
                if case .add(let follow) = folded[index].operation {
                    folded[index].operation = .add(FollowFactory.replacingAlerts(follow, with: alerts))
                }
                return folded
            }
            var replaced = queue.filter {
                if case .alerts(let id, _) = $0.operation { return id != followID || $0.id == inFlight }
                return true
            }
            replaced.append(edit)
            return replaced

        case .preferences:
            var replaced = queue.filter {
                if case .preferences = $0.operation { return $0.id == inFlight }
                return true
            }
            replaced.append(edit)
            return replaced

        case .add:
            var appended = queue
            appended.append(edit)
            return appended
        }
    }

    /// Rewrites a follow's local id to the id the server gave it, everywhere in the queue.
    ///
    /// Called the moment a queued `add` succeeds, so the `alerts` and `remove` edits made while
    /// the phone was offline address the follow the server actually created.
    static func rewriting(localID: String, to serverID: String, in queue: [PendingEdit]) -> [PendingEdit] {
        queue.map { edit in
            var edit = edit
            switch edit.operation {
            case .add(let follow) where follow.id == localID:
                edit.operation = .add(FollowFactory.replacingID(follow, with: serverID))
            case .alerts(let id, let alerts) where id == localID:
                edit.operation = .alerts(followID: serverID, alerts: alerts)
            case .remove(let id) where id == localID:
                edit.operation = .remove(followID: serverID)
            default:
                break
            }
            return edit
        }
    }
}
