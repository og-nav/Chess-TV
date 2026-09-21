// Racing work against a clock.
//
// Its own file rather than a private helper inside the downloader, because the notification
// service extension needs it for the whole enrichment and the watch's poller needs it for a round
// fetch, and those targets do not all include the downloader.
import Foundation

/// What `withTimeout` hands back, so an operation that legitimately returns nil is not confused
/// with one that ran out of time. Without this the two collapse into the same `nil` and the log
/// line cannot tell you which happened.
enum TimeoutOutcome<T: Sendable>: Sendable {
    case value(T?)
    case timedOut
}

/// Races `operation` against a sleep and returns nil if the sleep wins.
///
/// The losing child is cancelled. For a download that means its cancellation handler fires and the
/// task stops — the point of the exercise, rather than letting it run on inside an extension that
/// is about to have its time taken away.
func withTimeout<T: Sendable>(_ duration: Duration, operation: @escaping @Sendable () async -> T?) async -> T? {
    await withTaskGroup(of: TimeoutOutcome<T>.self) { group in
        group.addTask { .value(await operation()) }
        group.addTask {
            try? await Task.sleep(for: duration)
            return .timedOut
        }
        var result: T?
        if case .value(let value) = await group.next() ?? .timedOut {
            result = value
        } else {
            pushLog.notice("An operation ran out of its \(duration.components.seconds) s budget")
        }
        group.cancelAll()
        return result
    }
}
