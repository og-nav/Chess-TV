import Foundation

/// A tiny HTTP/1.1 server bound to 127.0.0.1 on an ephemeral port.
///
/// A deliberately minimal cousin of LichessKit's server, copied rather than shared: ImageryKit has
/// no dependency on LichessKit and is not about to grow one for a test helper. This one only has
/// to answer whole bodies with a `Content-Length`, so none of the chunked-streaming machinery is
/// here — but it is a real socket, so `URLSession`, its connection reuse and the `User-Agent`
/// header are exercised exactly as they will be in the app. No test touches the internet.
final class LoopbackHTTPServer: @unchecked Sendable {

    /// One response. `delay` is applied before the body is written, which is how the coalescing
    /// test guarantees a second caller arrives while the first request is still open.
    struct Response: Sendable {
        var statusCode: Int = 200
        var contentType: String = "application/json"
        var body: Data = Data()
        var delay: TimeInterval = 0

        init(statusCode: Int = 200, contentType: String = "application/json", body: Data = Data(), delay: TimeInterval = 0) {
            self.statusCode = statusCode
            self.contentType = contentType
            self.body = body
            self.delay = delay
        }

        init(json: String, statusCode: Int = 200, delay: TimeInterval = 0) {
            self.init(statusCode: statusCode, contentType: "application/json", body: Data(json.utf8), delay: delay)
        }
    }

    /// Picks the response for a request. `index` counts requests for that same path, from 0.
    typealias Router = @Sendable (_ path: String, _ index: Int) -> Response

    private let listenFD: Int32
    let port: UInt16

    private let lock = NSLock()
    private let router: Router
    private var perPathCount: [String: Int] = [:]
    private var served = 0
    private var stopped = false
    private var requestHeads: [String] = []

    init(router: @escaping Router) throws {
        self.router = router

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EADDRNOTAVAIL) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0                                   // ephemeral
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: boundAddress.sin_port)
        listenFD = fd

        Thread.detachNewThread { [self] in acceptLoop() }
    }

    /// A server that always answers the same way.
    convenience init(response: Response) throws {
        try self.init(router: { _, _ in response })
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    /// Requests served so far. The cache tests assert on this: it is what "did not re-download" means.
    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return served
    }

    /// The request head (request line plus headers) of each request, in order.
    var requests: [String] {
        lock.lock(); defer { lock.unlock() }
        return requestHeads
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        lock.unlock()
        shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
    }

    deinit { stop() }

    // MARK: - Serving

    private func acceptLoop() {
        while true {
            var address = sockaddr()
            var length = socklen_t(MemoryLayout<sockaddr>.size)
            let fd = accept(listenFD, &address, &length)
            lock.lock()
            let isStopped = stopped
            lock.unlock()
            if isStopped { if fd >= 0 { close(fd) }; return }
            guard fd >= 0 else { return }
            Thread.detachNewThread { [self] in serve(fd: fd) }
        }
    }

    private func serve(fd: Int32) {
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        defer { close(fd) }

        let head = readRequestHead(fd: fd)
        let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"

        lock.lock()
        let index = perPathCount[path, default: 0]
        perPathCount[path] = index + 1
        served += 1
        requestHeads.append(head)
        lock.unlock()

        let response = router(path, index)
        if response.delay > 0 { Thread.sleep(forTimeInterval: response.delay) }

        var text = "HTTP/1.1 \(response.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode))\r\n"
        text += "Content-Type: \(response.contentType)\r\n"
        text += "Content-Length: \(response.body.count)\r\n"
        text += "Connection: close\r\n\r\n"
        guard write(fd, Data(text.utf8)) else { return }
        _ = write(fd, response.body)
    }

    @discardableResult
    private func readRequestHead(fd: Int32) -> String {
        var head = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        while !head.contains(Data("\r\n\r\n".utf8)) {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            head.append(contentsOf: buffer[0..<n])
            if head.count > 16_384 { break }
        }
        return String(decoding: head, as: UTF8.self)
    }

    @discardableResult
    private func write(_ fd: Int32, _ data: Data) -> Bool {
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { raw in Darwin.write(fd, raw.baseAddress, raw.count) }
            if written <= 0 { return false }
            remaining = remaining.dropFirst(written)
        }
        return true
    }
}

// MARK: - Async helpers

struct TimedOut: Error, CustomStringConvertible {
    let what: String
    var description: String { "timed out waiting for \(what)" }
}

/// Races `work` against a deadline so a broken load fails the test instead of hanging it.
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
