import Foundation

/// Fans `ConnectionState` changes out to any number of `AsyncStream` consumers.
///
/// `TVFeedStreaming.connectionStates` is a synchronous property, so this cannot be an actor;
/// it is a small lock-protected box instead. Each subscriber gets its own stream and receives
/// the most recent state immediately, which means a view that starts observing late still
/// renders the right chip.
final class ConnectionStateBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]
    private var latest: ConnectionState?
    private var finished = false

    /// A new stream carrying the current state (if any) followed by every later change.
    func subscribe() -> AsyncStream<ConnectionState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            let id = UUID()
            lock.lock()
            let replay = latest
            let isFinished = finished
            if !isFinished { continuations[id] = continuation }
            lock.unlock()

            if let replay { continuation.yield(replay) }
            if isFinished {
                continuation.finish()
                return
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                lock.lock()
                continuations[id] = nil
                lock.unlock()
            }
        }
    }

    /// Publishes a state, skipping duplicates.
    func send(_ state: ConnectionState) {
        lock.lock()
        guard !finished, latest != state else { lock.unlock(); return }
        latest = state
        let targets = Array(continuations.values)
        lock.unlock()
        log.info("Connection state: \(String(describing: state), privacy: .public)")
        for continuation in targets { continuation.yield(state) }
    }

    /// Ends every subscriber stream. Used when the client is torn down for good.
    func finish() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in targets { continuation.finish() }
    }

    var current: ConnectionState? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }
}
