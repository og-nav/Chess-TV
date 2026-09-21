import Foundation

/// A tiny HTTP/1.1 server bound to 127.0.0.1 on an ephemeral port.
///
/// `URLProtocol` stubs cannot exercise a *streaming* body: Foundation buffers a custom
/// protocol's data and hands it to `URLSession.bytes(for:)` only when the task completes,
/// so `.live`, mid-stream reconnects and prompt cancellation cannot be observed through one.
/// This server talks real HTTP over loopback (no internet, no DNS) with chunked transfer
/// encoding, so the feed is tested exactly as it will run in the app.
final class LoopbackHTTPServer: @unchecked Sendable {

    /// How one connection is served. Steps are consumed in order; the last one repeats.
    struct Step: Sendable {
        var statusCode: Int = 200
        var headers: [String: String] = [:]
        /// Body pieces, each written as one HTTP chunk.
        var chunks: [Data] = []
        var chunkDelay: TimeInterval = 0.02
        var ending: Ending = .graceful
    }

    enum Ending: Sendable {
        /// Terminating chunk, then close: a well-behaved server ending the response.
        case graceful
        /// RST mid-body: the connection drop we must recover from.
        case abrupt
        /// Keep the socket open and silent, like the real feed between moves.
        case hold
    }

    /// Picks the response for a request. `index` counts requests for that same path, from 0.
    typealias Router = @Sendable (_ path: String, _ index: Int) -> Step

    private let listenFD: Int32
    let port: UInt16

    private let lock = NSLock()
    private var steps: [Step]
    private let router: Router?
    private var perPathCount: [String: Int] = [:]
    private var served = 0
    private var stopped = false
    private var requestHeads: [String] = []

    convenience init(steps: [Step]) throws {
        precondition(!steps.isEmpty)
        try self.init(steps: steps, router: nil)
    }

    /// A server that answers by request path, for clients that talk to more than one endpoint.
    convenience init(router: @escaping Router) throws {
        try self.init(steps: [Step()], router: router)
    }

    private init(steps: [Step], router: Router?) throws {
        self.steps = steps
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

        var bound_address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound_address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        port = UInt16(bigEndian: bound_address.sin_port)
        listenFD = fd

        Thread.detachNewThread { [self] in acceptLoop() }
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    /// Number of connections served so far.
    var connectionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return served
    }

    /// The request head (request line plus headers) of each connection, in order.
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

            lock.lock()
            // With a router the response depends on the path, so it is chosen after the head is read.
            let step: Step? = router == nil ? steps[min(served, steps.count - 1)] : nil
            served += 1
            lock.unlock()

            Thread.detachNewThread { [self] in serve(fd: fd, preselected: step) }
        }
    }

    private func serve(fd: Int32, preselected: Step?) {
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        let requestHead = readRequestHead(fd: fd)
        let step: Step
        if let preselected {
            step = preselected
        } else if let router {
            let path = requestHead.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            lock.lock()
            let index = perPathCount[path, default: 0]
            perPathCount[path] = index + 1
            lock.unlock()
            step = router(path, index)
        } else {
            step = Step()
        }
        defer { if step.ending != .hold { close(fd) } }

        var head = "HTTP/1.1 \(step.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: step.statusCode))\r\n"
        head += "Content-Type: application/x-ndjson\r\n"
        head += "Transfer-Encoding: chunked\r\n"
        for (key, value) in step.headers { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        guard write(fd, Data(head.utf8)) else { return }

        for chunk in step.chunks {
            var frame = Data(String(format: "%x\r\n", chunk.count).utf8)
            frame.append(chunk)
            frame.append(Data("\r\n".utf8))
            guard write(fd, frame) else { return }
            Thread.sleep(forTimeInterval: step.chunkDelay)
        }

        switch step.ending {
        case .graceful:
            _ = write(fd, Data("0\r\n\r\n".utf8))
        case .abrupt:
            // SO_LINGER with a zero timeout makes close() send RST: a real dropped connection.
            var linger = linger(l_onoff: 1, l_linger: 0)
            setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<linger>.size))
        case .hold:
            Thread.detachNewThread { [self] in
                while true {
                    lock.lock(); let isStopped = stopped; lock.unlock()
                    if isStopped { break }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                close(fd)
            }
        }
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
        let text = String(decoding: head, as: UTF8.self)
        lock.lock(); requestHeads.append(text); lock.unlock()
        return text
    }

    @discardableResult
    private func write(_ fd: Int32, _ data: Data) -> Bool {
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress, raw.count)
            }
            if written <= 0 { return false }
            remaining = remaining.dropFirst(written)
        }
        return true
    }
}
