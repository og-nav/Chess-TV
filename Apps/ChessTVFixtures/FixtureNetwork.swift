// The network in fixture mode: a `URLProtocol` that answers every request from the bundle.
//
// Every client in the suite builds its own `URLSession` from `.default` or `.ephemeral`, and a
// `URLProtocol` registered globally only reaches `URLSession.shared`. So the two class getters
// are swapped for ones that put the fixture protocol first in `protocolClasses`. Nothing else
// about the sessions changes: headers, timeouts and the streaming configuration are still what
// the packages asked for, and every decoder runs on real bytes.
import Foundation
import ObjectiveC

enum FixtureNetwork {

    static func install() {
        URLProtocol.registerClass(FixtureURLProtocol.self)
        swap(#selector(getter: URLSessionConfiguration.default), #selector(getter: URLSessionConfiguration.fixture_default))
        swap(#selector(getter: URLSessionConfiguration.ephemeral), #selector(getter: URLSessionConfiguration.fixture_ephemeral))
    }

    private static func swap(_ original: Selector, _ replacement: Selector) {
        guard let first = class_getClassMethod(URLSessionConfiguration.self, original),
              let second = class_getClassMethod(URLSessionConfiguration.self, replacement) else { return }
        method_exchangeImplementations(first, second)
    }
}

extension URLSessionConfiguration {
    // After the swap these bodies call the *original* getters, then add the protocol.
    @objc dynamic class var fixture_default: URLSessionConfiguration {
        fixture_default.addingFixtureProtocol()
    }

    @objc dynamic class var fixture_ephemeral: URLSessionConfiguration {
        fixture_ephemeral.addingFixtureProtocol()
    }

    private func addingFixtureProtocol() -> URLSessionConfiguration {
        protocolClasses = [FixtureURLProtocol.self] + (protocolClasses ?? [])
        return self
    }
}

/// One request, answered by `FixtureRouter`. A streaming answer keeps delivering chunks until
/// the request is cancelled, exactly as an NDJSON or PGN feed does.
final class FixtureURLProtocol: URLProtocol {

    private var serving: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canInit(with task: URLSessionTask) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let box = Box(self)
        serving = Task { await Self.serve(request, through: box) }
    }

    /// The protocol object, handed to the serving task. `URLProtocol` is not Sendable; the
    /// client calls below are the documented way to answer from any thread.
    private final class Box: @unchecked Sendable {
        let owner: FixtureURLProtocol
        init(_ owner: FixtureURLProtocol) { self.owner = owner }
    }

    private static func serve(_ request: URLRequest, through box: Box) async {
        let owner = box.owner
        let answer = FixtureRouter.answer(for: request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://lichess.org")!,
            statusCode: answer.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": answer.contentType]
        )!
        owner.client?.urlProtocol(owner, didReceive: response, cacheStoragePolicy: .notAllowed)
        switch answer.body {
        case .whole(let data):
            if !data.isEmpty { owner.client?.urlProtocol(owner, didLoad: data) }
            owner.client?.urlProtocolDidFinishLoading(owner)
        case .stream(let chunks):
            for await chunk in chunks {
                if Task.isCancelled { return }
                owner.client?.urlProtocol(owner, didLoad: chunk)
            }
            if !Task.isCancelled { owner.client?.urlProtocolDidFinishLoading(owner) }
        }
    }

    override func stopLoading() {
        serving?.cancel()
        serving = nil
    }
}

/// What a request gets back.
struct FixtureAnswer: Sendable {
    enum Body: Sendable {
        case whole(Data)
        /// Chunks in order, paced by the producer. The stream ending finishes the request; a
        /// live feed never ends it.
        case stream(AsyncStream<Data>)
    }
    var status: Int
    var contentType: String
    var body: Body

    static func json(_ data: Data?) -> FixtureAnswer {
        guard let data else { return .notFound }
        return FixtureAnswer(status: 200, contentType: "application/json", body: .whole(data))
    }

    static let notFound = FixtureAnswer(status: 404, contentType: "text/plain", body: .whole(Data("not in the fixtures".utf8)))

    /// Chunks delivered on a schedule. `pace` is called with the index of the chunk about to go
    /// out and answers how long to wait before it; `holdOpen` keeps the request alive after the
    /// last chunk, which is what a live feed looks like from the client's side.
    static func stream(
        contentType: String,
        chunks: [Data],
        holdOpen: Bool,
        pace: @escaping @Sendable (Int) -> TimeInterval
    ) -> FixtureAnswer {
        let stream = AsyncStream<Data> { continuation in
            let task = Task {
                for (index, chunk) in chunks.enumerated() {
                    let delay = pace(index)
                    if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                    if Task.isCancelled { return }
                    continuation.yield(chunk)
                }
                if holdOpen {
                    while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)) }
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return FixtureAnswer(status: 200, contentType: contentType, body: .stream(stream))
    }
}
