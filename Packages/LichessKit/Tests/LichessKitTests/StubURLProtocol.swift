import Foundation
@testable import LichessKit

/// A `URLProtocol` that replays scripted responses so no unit test touches the network.
///
/// Steps are consumed one per request; the last step repeats for any further requests,
/// which is what a reconnecting client needs.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {

    struct Step: Sendable {
        var statusCode: Int = 200
        var headers: [String: String] = [:]
        /// Body pieces delivered in order. Split a JSON line across two chunks to exercise
        /// the line decoder over a real `URLSession`.
        var chunks: [Data] = []
        /// Pause between chunks so the consumer really sees them separately.
        var chunkDelay: Duration = .milliseconds(5)
        /// Fail the request after the chunks, simulating a dropped connection.
        var failWith: URLError.Code?
        /// Keep the body open forever after the chunks (the real feed idles like this).
        var holdOpen: Bool = false
    }

    private static let state = State()

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var steps: [Step] = []
        private var requests: [URLRequest] = []

        func install(_ steps: [Step]) {
            lock.lock(); defer { lock.unlock() }
            self.steps = steps
            requests = []
        }

        func next(for request: URLRequest) -> Step {
            lock.lock(); defer { lock.unlock() }
            requests.append(request)
            let index = min(requests.count - 1, max(0, steps.count - 1))
            return steps.isEmpty ? Step() : steps[index]
        }

        var recorded: [URLRequest] {
            lock.lock(); defer { lock.unlock() }
            return requests
        }
    }

    /// Installs the script and clears the request log.
    static func install(_ steps: [Step]) { state.install(steps) }
    /// Every request the stub has served, in order.
    static var requests: [URLRequest] { state.recorded }
    static var requestCount: Int { state.recorded.count }

    /// A session wired to this stub, with the package's real headers and timeouts.
    static func session(streaming: Bool = true) -> URLSession {
        LichessURLSession.make(streaming: streaming, protocolClasses: [StubURLProtocol.self])
    }

    private nonisolated(unsafe) var worker: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// `URLProtocol` and its client are not `Sendable`; the stub only ever touches them
    /// from its own serial task, so it hands them to that task inside an unchecked box.
    private struct Channel: @unchecked Sendable {
        let owner: StubURLProtocol
        let client: any URLProtocolClient
    }

    override func startLoading() {
        let step = Self.state.next(for: request)
        let request = request
        guard let client else { return }
        let channel = Channel(owner: self, client: client)
        worker = Task {
            let owner = channel.owner
            let client = channel.client
            guard let response = HTTPURLResponse(
                url: request.url!,
                statusCode: step.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: step.headers
            ) else { return }
            client.urlProtocol(owner, didReceive: response, cacheStoragePolicy: .notAllowed)

            for chunk in step.chunks {
                if Task.isCancelled { return }
                client.urlProtocol(owner, didLoad: chunk)
                try? await Task.sleep(for: step.chunkDelay)
            }
            if Task.isCancelled { return }

            if let code = step.failWith {
                client.urlProtocol(owner, didFailWithError: URLError(code))
                return
            }
            if step.holdOpen {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
                return
            }
            client.urlProtocolDidFinishLoading(owner)
        }
    }

    override func stopLoading() {
        worker?.cancel()
        worker = nil
    }
}

// MARK: - Async helpers

struct TimedOut: Error, CustomStringConvertible {
    let what: String
    var description: String { "timed out waiting for \(what)" }
}

/// Races `work` against a deadline so a broken stream fails the test instead of hanging it.
func withTimeout<T: Sendable>(
    _ timeout: Duration,
    _ what: String = "operation",
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TimedOut(what: what)
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
