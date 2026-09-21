import Foundation
import Testing
import ChessCore
@testable import LichessKit

/// Streaming behaviour, driven by a loopback HTTP server (see `LoopbackHTTPServer` for why
/// a `URLProtocol` stub cannot cover these).
@Suite("TV feed streaming")
struct TVFeedStreamTests {

    static let featuredLine = #"{"t":"featured","d":{"id":"castle01","orientation":"white","players":[{"color":"white","user":{"name":"WhiteTester","id":"whitetester"},"rating":2000,"seconds":180},{"color":"black","user":{"name":"BlackTester","title":"IM","id":"blacktester"},"rating":2100,"seconds":180}],"fen":"r3k2r/pppq1ppp/2npbn2/4p3/4P3/2NPBN2/PPPQ1PPP/R3K2R w KQkq - 4 8"}}"#
    static let fenLine = #"{"t":"fen","d":{"fen":"r3k2r/pppq1ppp/2npbn2/4p3/4P3/2NPBN2/PPPQ1PPP/R4RK1 b kq - 5 8","lm":"e1h1","wc":176,"bc":180}}"#

    private func feed(_ server: LoopbackHTTPServer) -> TVFeedStream {
        var configuration = TVFeedStream.Configuration()
        configuration.jitterFraction = { 0 }
        configuration.baseDelay = .milliseconds(20)
        configuration.maxDelay = .milliseconds(100)
        configuration.healthyConnectionThreshold = .milliseconds(200)
        return TVFeedStream(
            session: LichessURLSession.make(streaming: true),
            baseURL: server.baseURL,
            configuration: configuration
        )
    }

    private func firstState(
        _ states: AsyncStream<ConnectionState>,
        timeout: Duration = .seconds(10),
        where predicate: @escaping @Sendable (ConnectionState) -> Bool
    ) async throws -> ConnectionState {
        try await withTimeout(timeout, "connection state") {
            for await state in states where predicate(state) { return state }
            throw TimedOut(what: "connection state (stream ended)")
        }
    }

    @Test("Requests hit the right path and carry the User-Agent")
    func requestShape() async throws {
        let server = try LoopbackHTTPServer(steps: [
            .init(chunks: [Data((Self.featuredLine + "\n").utf8)], ending: .hold)
        ])
        defer { server.stop() }
        let stream = feed(server)

        let event = try await withTimeout(.seconds(10), "first event") { [stream] in
            for try await event in stream.events(for: .rapid) { return event }
            throw TimedOut(what: "first event")
        }
        guard case .featured(let gameId, _, _, _) = event else { Issue.record("expected featured"); return }
        #expect(gameId == "castle01")

        let head = try #require(server.requests.first)
        #expect(head.hasPrefix("GET /api/tv/rapid/feed HTTP/1.1"))
        // A broad check: UserAgentTests changes the configured value, so the exact string
        // belongs there rather than in every test that happens to see a request head.
        #expect(head.contains("User-Agent: ChessTV/"))
    }

    @Test("A line split across TCP chunks, blank keep-alives and a malformed line are handled")
    func chunkedAndMalformedWire() async throws {
        let featured = Data((Self.featuredLine + "\n").utf8)
        let server = try LoopbackHTTPServer(steps: [
            .init(chunks: [
                Data("\n".utf8),                       // keep-alive before anything
                featured.prefix(37),                   // JSON line split across two writes
                featured.dropFirst(37),
                Data("{ not json\n".utf8),             // malformed: logged and skipped
                Data("\n".utf8),                       // keep-alive
                Data((Self.fenLine + "\n").utf8),
            ], ending: .hold)
        ])
        defer { server.stop() }
        let stream = feed(server)

        let events = try await withTimeout(.seconds(10), "two events") { [stream] in
            var collected: [TVEvent] = []
            for try await event in stream.events(for: .blitz) {
                collected.append(event)
                if collected.count == 2 { break }
            }
            return collected
        }
        #expect(events.count == 2)
        if case .featured(let gameId, let orientation, let players, _) = events[0] {
            #expect(gameId == "castle01")
            #expect(orientation == .white)
            #expect(players.map(\.name) == ["WhiteTester", "BlackTester"])
            #expect(players[1].title == "IM")
        } else {
            Issue.record("expected a featured event first")
        }
        #expect(events[1] == .fen(
            fen: "r3k2r/pppq1ppp/2npbn2/4p3/4P3/2NPBN2/PPPQ1PPP/R4RK1 b kq - 5 8",
            lastMove: "e1h1", whiteClock: 176, blackClock: 180
        ))
        #expect(server.connectionCount == 1)   // the malformed line did not end the stream
    }

    @Test("A dropped connection reconnects and resumes emitting")
    func reconnectsAfterDrop() async throws {
        let server = try LoopbackHTTPServer(steps: [
            .init(chunks: [Data((Self.featuredLine + "\n").utf8)], ending: .abrupt),
            .init(chunks: [Data((Self.fenLine + "\n").utf8)], ending: .hold),
        ])
        defer { server.stop() }
        let stream = feed(server)

        let events = try await withTimeout(.seconds(15), "two events across a reconnect") { [stream] in
            var collected: [TVEvent] = []
            for try await event in stream.events(for: .blitz) {
                collected.append(event)
                if collected.count == 2 { break }
            }
            return collected
        }
        #expect(events.count == 2)
        #expect(events[1] == .fen(
            fen: "r3k2r/pppq1ppp/2npbn2/4p3/4P3/2NPBN2/PPPQ1PPP/R4RK1 b kq - 5 8",
            lastMove: "e1h1", whiteClock: 176, blackClock: 180
        ))
        #expect(server.connectionCount == 2)
    }

    @Test("A server that closes the response cleanly is also treated as a drop")
    func serverCloseReconnects() async throws {
        let server = try LoopbackHTTPServer(steps: [
            .init(chunks: [Data((Self.featuredLine + "\n").utf8)], ending: .graceful),
            .init(chunks: [Data((Self.fenLine + "\n").utf8)], ending: .hold),
        ])
        defer { server.stop() }
        let stream = feed(server)

        let events = try await withTimeout(.seconds(15), "two events") { [stream] in
            var collected: [TVEvent] = []
            for try await event in stream.events(for: .blitz) {
                collected.append(event)
                if collected.count == 2 { break }
            }
            return collected
        }
        #expect(events.count == 2)
        #expect(server.connectionCount == 2)
    }

    @Test("States report connecting, live, then reconnecting with a backoff")
    func stateTransitions() async throws {
        let server = try LoopbackHTTPServer(steps: [
            .init(chunks: [Data((Self.featuredLine + "\n").utf8)], ending: .abrupt),
            .init(chunks: [Data((Self.fenLine + "\n").utf8)], ending: .hold),
        ])
        defer { server.stop() }
        let stream = feed(server)
        let states = stream.connectionStates
        let consumer = Task {
            var count = 0
            for try await _ in stream.events(for: .blitz) {
                count += 1
                if count == 2 { break }
            }
        }

        let collected = try await withTimeout(.seconds(15), "state transitions") {
            var seen: [ConnectionState] = []
            for await state in states {
                seen.append(state)
                if seen.count >= 5 { break }
            }
            return seen
        }
        #expect(collected[0] == .connecting)
        #expect(collected[1] == .live)
        guard case .reconnecting(let attempt, let nextRetryIn) = collected[2] else {
            Issue.record("expected .reconnecting, got \(collected[2])"); return
        }
        #expect(attempt == 1)
        #expect(nextRetryIn >= .milliseconds(20))
        #expect(collected[3] == .connecting)
        #expect(collected[4] == .live)
        consumer.cancel()
        _ = await consumer.result
    }

    @Test("Cancelling the consumer finishes the stream within one second")
    func cancellationFinishesPromptly() async throws {
        let server = try LoopbackHTTPServer(steps: [
            .init(chunks: [Data((Self.featuredLine + "\n").utf8)], ending: .hold)
        ])
        defer { server.stop() }
        let stream = feed(server)

        let consumer = Task { () -> Int in
            var count = 0
            // Finishing, not throwing, is the contract for cancellation.
            for try await _ in stream.events(for: .blitz) { count += 1 }
            return count
        }
        _ = try await firstState(stream.connectionStates) { $0 == .live }

        let started = ContinuousClock.now
        consumer.cancel()
        let count = try await withTimeout(.seconds(1), "stream to finish") { try await consumer.value }
        let elapsed = started.duration(to: .now)
        #expect(count == 1)
        #expect(elapsed < .seconds(1))
    }

    @Test("Cancelling while still connecting also finishes the stream")
    func cancellationWhileConnecting() async throws {
        let server = try LoopbackHTTPServer(steps: [
            .init(chunks: [], ending: .hold)   // headers only, then silence
        ])
        defer { server.stop() }
        let stream = feed(server)

        let consumer = Task { for try await _ in stream.events(for: .blitz) {} }
        _ = try await firstState(stream.connectionStates) { $0 == .connecting }
        try await Task.sleep(for: .milliseconds(100))
        consumer.cancel()
        try await withTimeout(.seconds(1), "stream to finish") { _ = await consumer.result }
    }
}

/// Status-code handling, driven by a stubbed `URLProtocol` (no body streaming needed).
@Suite("TV feed HTTP policy", .serialized)
struct TVFeedPolicyTests {

    private func feed(_ steps: [StubURLProtocol.Step], realTiming: Bool = true) -> TVFeedStream {
        StubURLProtocol.install(steps)
        var configuration = TVFeedStream.Configuration()
        configuration.jitterFraction = { 0 }
        if !realTiming {
            configuration.baseDelay = .milliseconds(10)
            configuration.maxDelay = .milliseconds(50)
        }
        return TVFeedStream(
            session: StubURLProtocol.session(),
            baseURL: URL(string: "https://stub.lichess.test")!,
            configuration: configuration
        )
    }

    private func firstReconnect(_ stream: TVFeedStream) async throws -> (Int, Duration) {
        let states = stream.connectionStates
        let state = try await withTimeout(.seconds(5), "reconnecting state") {
            for await state in states {
                if case .reconnecting = state { return state }
            }
            throw TimedOut(what: "reconnecting state")
        }
        guard case .reconnecting(let attempt, let nextRetryIn) = state else {
            throw TimedOut(what: "reconnecting state")
        }
        return (attempt, nextRetryIn)
    }

    @Test("HTTP 429 with Retry-After: 5 still waits at least sixty seconds")
    func rateLimitHonoursSixtySecondFloor() async throws {
        let stream = feed([.init(statusCode: 429, headers: ["Retry-After": "5"])])
        let consumer = Task { for try await _ in stream.events(for: .blitz) {} }
        let (attempt, nextRetryIn) = try await firstReconnect(stream)
        #expect(attempt == 1)
        #expect(nextRetryIn >= .seconds(60))
        consumer.cancel()
    }

    @Test("HTTP 429 with Retry-After: 900 honours the longer server value")
    func rateLimitHonoursLongRetryAfter() async throws {
        let stream = feed([.init(statusCode: 429, headers: ["Retry-After": "900"])])
        let consumer = Task { for try await _ in stream.events(for: .blitz) {} }
        let (_, nextRetryIn) = try await firstReconnect(stream)
        #expect(nextRetryIn >= .seconds(900))
        consumer.cancel()
    }

    @Test("HTTP 429 without Retry-After still waits at least sixty seconds")
    func rateLimitWithoutHeader() async throws {
        let stream = feed([.init(statusCode: 429)])
        let consumer = Task { for try await _ in stream.events(for: .blitz) {} }
        let (_, nextRetryIn) = try await firstReconnect(stream)
        #expect(nextRetryIn >= .seconds(60))
        consumer.cancel()
    }

    @Test("HTTP 503 retries with the ordinary backoff, not the rate-limit floor")
    func serverErrorUsesOrdinaryBackoff() async throws {
        let stream = feed([.init(statusCode: 503)], realTiming: false)
        let consumer = Task { for try await _ in stream.events(for: .blitz) {} }
        let (attempt, nextRetryIn) = try await firstReconnect(stream)
        #expect(attempt == 1)
        #expect(nextRetryIn < .seconds(60))
        consumer.cancel()
    }

    @Test("HTTP 404 fails the stream instead of reconnecting forever")
    func notFoundIsUnrecoverable() async throws {
        let stream = feed([.init(statusCode: 404)])
        let states = stream.connectionStates

        await #expect(throws: LichessError.unrecoverableStatus(404)) {
            try await withTimeout(.seconds(5), "failure") {
                for try await _ in stream.events(for: .blitz) {}
            }
        }
        let state = try await withTimeout(.seconds(5), "failed state") {
            for await state in states {
                if case .failed = state { return state }
            }
            throw TimedOut(what: "failed state")
        }
        if case .failed(let message) = state { #expect(message.contains("404")) }
        #expect(StubURLProtocol.requestCount == 1)
    }

    @Test("The channels client decodes over a stubbed session and sends the User-Agent")
    func channelsOverStub() async throws {
        StubURLProtocol.install([.init(chunks: [try Fixture.channelsData])])
        let client = TVChannelsClient(
            session: StubURLProtocol.session(streaming: false),
            baseURL: URL(string: "https://stub.lichess.test")!
        )
        let summaries = try await withTimeout(.seconds(5), "channels") { try await client.currentGames() }
        #expect(summaries.count == 16)
        #expect(StubURLProtocol.requests.first?.url?.path == "/api/tv/channels")
        #expect(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("ChessTV/") == true)
    }

    @Test("The channels client reports a rate limit rather than pretending")
    func channelsRateLimited() async throws {
        StubURLProtocol.install([.init(statusCode: 429, headers: ["Retry-After": "61"])])
        let client = TVChannelsClient(
            session: StubURLProtocol.session(streaming: false),
            baseURL: URL(string: "https://stub.lichess.test")!
        )
        await #expect(throws: LichessError.rateLimited(retryAfter: .seconds(61))) {
            try await withTimeout(.seconds(5), "channels") { try await client.currentGames() }
        }
    }
}
