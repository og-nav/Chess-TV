import Foundation
import Testing
import ChessCore
@testable import LichessKit

/// `GameSourceStreamer` as the app uses it: which source it picks, how it switches games, and
/// what it marks as history. Everything runs against the loopback server.
@Suite("GameSourceStreamer gives every source its history")
struct GameSourceStreamerTests {

    // MARK: - Wire fixtures

    private static func featuredLine(id: String, fen: String) -> String {
        """
        {"t":"featured","d":{"id":"\(id)","orientation":"white","players":[\
        {"color":"white","user":{"name":"Alice","title":"GM","id":"alice"},"rating":2700,"seconds":175},\
        {"color":"black","user":{"name":"Bob","id":"bob"},"rating":2500,"seconds":170}],"fen":"\(fen)"}}

        """
    }

    /// A `.fen` line on the *channel* feed. The two-stage stream must drop it: the game stream
    /// carries the same move with its history in front of it.
    private static let strayFeedLine = """
        {"t":"fen","d":{"fen":"8/8/8/8/8/8/8/K6k w - - 0 1","lm":"h1h2","wc":1,"bc":1}}

        """

    private static func gameMetadata(id: String) -> String {
        """
        {"id":"\(id)","players":{"white":{"user":{"name":"Alice"},"rating":2700},\
        "black":{"user":{"name":"Bob"},"rating":2500}}}

        """
    }

    private static func gameMove(fen: String, lastMove: String) -> String {
        """
        {"fen":"\(fen)","lm":"\(lastMove)","wc":180,"bc":178}

        """
    }

    private static func gameOver(id: String, fen: String) -> String {
        """
        {"id":"\(id)","fen":"\(fen)","status":{"id":30,"name":"mate"},"winner":"white",\
        "players":{"white":{"user":{"name":"Alice"},"rating":2700},"black":{"user":{"name":"Bob"},"rating":2500}}}

        """
    }

    private static let afterE4 = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1"
    private static let afterE5 = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2"
    private static let afterD4 = "rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq d3 0 1"
    private static let afterD5 = "rnbqkbnr/ppp1pppp/8/3p4/3P4/8/PPP1PPPP/RNBQKBNR w KQkq d6 0 2"

    // MARK: - TV channel: two stages

    @Test("A TV channel streams the featured game in full, then switches when the channel does")
    func tvChannelTwoStage() async throws {
        let server = try LoopbackHTTPServer { path, _ in
            switch path {
            case "/api/tv/blitz/feed":
                // Featured AAAA, a stray fen the two-stage stream must ignore, then featured BBBB.
                return .init(chunks: [
                    Data(Self.featuredLine(id: "AAAA", fen: Self.afterE5).utf8),
                    Data(Self.strayFeedLine.utf8),
                    Data(Self.featuredLine(id: "BBBB", fen: Self.afterD5).utf8),
                ], chunkDelay: 0.5, ending: .hold)
            case "/api/stream/game/AAAA":
                return .init(chunks: [Data((
                    Self.gameMetadata(id: "AAAA")
                    + Self.gameMove(fen: Self.afterE4, lastMove: "e2e4")
                    + Self.gameMove(fen: Self.afterE5, lastMove: "e7e5")
                ).utf8)], chunkDelay: 0, ending: .hold)
            case "/api/stream/game/BBBB":
                return .init(chunks: [Data((
                    Self.gameMetadata(id: "BBBB")
                    + Self.gameMove(fen: Self.afterD4, lastMove: "d2d4")
                    + Self.gameMove(fen: Self.afterD5, lastMove: "d7d5")
                    + Self.gameOver(id: "BBBB", fen: Self.afterD5)
                ).utf8)], chunkDelay: 0, ending: .graceful)
            default:
                return .init(statusCode: 404, chunks: [], ending: .graceful)
            }
        }
        defer { server.stop() }

        let streamer = GameSourceStreamer(baseURL: server.baseURL, configuration: BroadcastPGNStreamTests.fastConfiguration(),
                                          gameSwitchGrace: .milliseconds(100))
        defer { streamer.finish() }

        let events = await collect(streamer.sourcedEvents(for: .tvChannel(.blitz)), for: .seconds(2)).map(\.item)

        var featuredIds: [String] = []
        var moves: [String] = []
        for item in events {
            switch item.event {
            case .featured(let id, _, _, _): featuredIds.append(id)
            case .fen(_, let lastMove, _, _): moves.append(lastMove ?? "-")
            case nil: continue
            }
        }

        // Stage one picked AAAA; stage two replayed it; the channel then promoted BBBB.
        #expect(featuredIds == ["AAAA", "BBBB"])
        #expect(moves == ["e2e4", "e7e5", "d2d4", "d7d5"])
        // The channel feed's own fen line never reached the consumer.
        #expect(!moves.contains("h1h2"))
        // Both games arrived as a replay burst, so all of it is history.
        let sourced = events.compactMap(\.sourced)
        #expect(sourced.filter { if case .fen = $0.event { true } else { false } }.allSatisfy { $0.isHistorical })
        #expect(sourced.filter { if case .featured = $0.event { true } else { false } }.allSatisfy { !$0.isHistorical })
        // BBBB mated, so the feed said so rather than just going quiet.
        #expect(events.contains { $0 == .gameEnded(gameId: "BBBB", status: GameStatus(id: 30, name: "mate", winner: .white)) })

        #expect(streamer.lastGameTermination?.gameId == "BBBB")
        #expect(streamer.lastGameTermination?.status.name == "mate")

        let paths = server.requests.compactMap { $0.split(separator: " ").dropFirst().first.map(String.init) }
        #expect(paths.contains("/api/tv/blitz/feed"))
        #expect(paths.contains("/api/stream/game/AAAA"))
        #expect(paths.contains("/api/stream/game/BBBB"))
    }

    @Test("The plain events(for:) method still hands back bare TVEvents")
    func plainEventsStillWork() async throws {
        let server = try LoopbackHTTPServer { path, _ in
            switch path {
            case "/api/tv/blitz/feed":
                return .init(chunks: [Data(Self.featuredLine(id: "AAAA", fen: Self.afterE5).utf8)], chunkDelay: 0, ending: .hold)
            case "/api/stream/game/AAAA":
                return .init(chunks: [Data((
                    Self.gameMetadata(id: "AAAA")
                    + Self.gameMove(fen: Self.afterE4, lastMove: "e2e4")
                    + Self.gameMove(fen: Self.afterE5, lastMove: "e7e5")
                    + Self.gameOver(id: "AAAA", fen: Self.afterE5)
                ).utf8)], chunkDelay: 0, ending: .graceful)
            default:
                return .init(statusCode: 404, chunks: [], ending: .graceful)
            }
        }
        defer { server.stop() }

        let streamer = GameSourceStreamer(baseURL: server.baseURL, configuration: BroadcastPGNStreamTests.fastConfiguration())
        defer { streamer.finish() }

        let collector = EventCollector()
        let task = Task {
            for try await event in streamer.events(for: .tvChannel(.blitz)) {
                await collector.append(SourcedEvent(event: event, isHistorical: false))
            }
        }
        try? await Task.sleep(for: .milliseconds(800))
        task.cancel()
        let events = await collector.events.map(\.event)

        #expect(events.count == 3)
        guard case .featured(let id, _, _, _) = events.first else { Issue.record("no featured"); return }
        #expect(id == "AAAA")
    }

    // MARK: - The end of a game

    private static func arenaDetail(featuredId: String, fen: String) -> Data {
        Data("""
        {"id":"A1","fullName":"Test Arena","nbPlayers":12,"minutes":60,"startsAt":1789696800000,
         "variant":{"key":"standard"},"perf":{"key":"blitz"},"secondsToFinish":900,"isStarted":true,
         "featured":{"id":"\(featuredId)","fen":"\(fen)","lastMove":"e7e5",
           "white":{"name":"Alice","rating":2700,"rank":1},
           "black":{"name":"Bob","rating":2500,"rank":2},"c":{"white":180,"black":178}},
         "standing":{"page":1,"players":[{"name":"Alice","rank":1,"rating":2700,"score":10}]}}
        """.utf8)
    }

    @Test("An arena replays the featured game as history and says when it ends")
    func arenaReplaysThenEnds() async throws {
        let server = try LoopbackHTTPServer { path, _ in
            switch path {
            case "/api/tournament/A1":
                return .init(chunks: [Self.arenaDetail(featuredId: "G1", fen: Self.afterE5)], chunkDelay: 0, ending: .graceful)
            case "/api/stream/game/G1":
                return .init(chunks: [Data((
                    Self.gameMetadata(id: "G1")
                    + Self.gameMove(fen: Self.afterE4, lastMove: "e2e4")
                    + Self.gameMove(fen: Self.afterE5, lastMove: "e7e5")
                    + Self.gameOver(id: "G1", fen: Self.afterE5)
                ).utf8)], chunkDelay: 0, ending: .graceful)
            default:
                return .init(statusCode: 404, chunks: [], ending: .graceful)
            }
        }
        defer { server.stop() }

        let streamer = GameSourceStreamer(baseURL: server.baseURL, configuration: BroadcastPGNStreamTests.fastConfiguration())
        defer { streamer.finish() }

        let items = await collect(streamer.sourcedEvents(for: .arena(tournamentId: "A1")), for: .seconds(2)).map(\.item)

        // The two plays already made arrive as history, not as live moves to play out.
        let sourced = items.compactMap(\.sourced)
        #expect(sourced.count == 3)
        let moves = sourced.filter { if case .fen = $0.event { true } else { false } }
        #expect(moves.count == 2)
        #expect(moves.allSatisfy { $0.isHistorical })
        guard case .featured(let gameId, _, _, _) = sourced.first?.event else {
            Issue.record("expected the featured game first"); return
        }
        #expect(gameId == "G1")

        // And the game's end is reported rather than the stream just going quiet.
        #expect(items.last == .gameEnded(gameId: "G1", status: GameStatus(id: 30, name: "mate", winner: .white)))
    }

    @Test("A finished TV-channel game keeps the screen for the hold before the next one starts")
    func gameOverHoldsTheNextGame() async throws {
        let hold = Duration.milliseconds(700)
        let server = try LoopbackHTTPServer { path, _ in
            switch path {
            case "/api/tv/blitz/feed":
                // AAAA, then BBBB a moment later — the channel promoting the next game.
                return .init(chunks: [
                    Data(Self.featuredLine(id: "AAAA", fen: Self.afterE5).utf8),
                    Data(Self.featuredLine(id: "BBBB", fen: Self.afterD5).utf8),
                ], chunkDelay: 0.2, ending: .hold)
            case "/api/stream/game/AAAA":
                return .init(chunks: [Data((
                    Self.gameMetadata(id: "AAAA")
                    + Self.gameMove(fen: Self.afterE4, lastMove: "e2e4")
                    + Self.gameMove(fen: Self.afterE5, lastMove: "e7e5")
                    + Self.gameOver(id: "AAAA", fen: Self.afterE5)
                ).utf8)], chunkDelay: 0, ending: .graceful)
            case "/api/stream/game/BBBB":
                return .init(chunks: [Data((
                    Self.gameMetadata(id: "BBBB")
                    + Self.gameMove(fen: Self.afterD4, lastMove: "d2d4")
                ).utf8)], chunkDelay: 0, ending: .hold)
            default:
                return .init(statusCode: 404, chunks: [], ending: .graceful)
            }
        }
        defer { server.stop() }

        let streamer = GameSourceStreamer(
            baseURL: server.baseURL,
            configuration: BroadcastPGNStreamTests.fastConfiguration(),
            gameOverHold: hold
        )
        defer { streamer.finish() }

        let timed = await collect(streamer.sourcedEvents(for: .tvChannel(.blitz)), for: .seconds(3))

        guard let endIndex = timed.firstIndex(where: { if case .gameEnded = $0.item { true } else { false } }) else {
            Issue.record("the finished game was never reported"); return
        }
        #expect(timed[endIndex].item == .gameEnded(gameId: "AAAA", status: GameStatus(id: 30, name: "mate", winner: .white)))

        // Nothing of the next game reached the screen until the hold was served.
        guard endIndex + 1 < timed.count else { Issue.record("the next game never arrived"); return }
        let next = timed[endIndex + 1]
        let waited = timed[endIndex].at.duration(to: next.at)
        #expect(waited >= hold - .milliseconds(50), "the next game arrived after \(waited.seconds)s")
        guard case .featured(let nextId, _, _, _) = next.item.event else {
            Issue.record("expected the next featured game after the hold"); return
        }
        #expect(nextId == "BBBB")
        // AAAA finished before the hold began, so its own moves were never delayed.
        #expect(timed[..<endIndex].allSatisfy { timed[0].at.duration(to: $0.at) < hold })
    }

    // MARK: - Broadcast board: PGN, then polling

    @Test("A channel promotion drains the old game's delayed final move and result before switching")
    func promotionBeforeFinalMove() async throws {
        let server = try LoopbackHTTPServer { path, _ in
            switch path {
            case "/api/tv/blitz/feed":
                return .init(chunks: [
                    Data(Self.featuredLine(id: "AAAA", fen: Self.afterE4).utf8),
                    Data(Self.featuredLine(id: "BBBB", fen: Self.afterD4).utf8),
                ], chunkDelay: 0.15, ending: .hold)
            case "/api/stream/game/AAAA":
                return .init(chunks: [
                    Data((Self.gameMetadata(id: "AAAA") + Self.gameMove(fen: Self.afterE4, lastMove: "e2e4")).utf8),
                    Data((Self.gameMove(fen: Self.afterE5, lastMove: "e7e5") + Self.gameOver(id: "AAAA", fen: Self.afterE5)).utf8),
                ], chunkDelay: 0.35, ending: .graceful)
            case "/api/stream/game/BBBB":
                return .init(chunks: [Data((Self.gameMetadata(id: "BBBB")
                    + Self.gameMove(fen: Self.afterD4, lastMove: "d2d4")).utf8)], chunkDelay: 0, ending: .hold)
            default:
                return .init(statusCode: 404, ending: .graceful)
            }
        }
        defer { server.stop() }
        let streamer = GameSourceStreamer(baseURL: server.baseURL,
            configuration: BroadcastPGNStreamTests.fastConfiguration(), gameOverHold: .milliseconds(100))
        defer { streamer.finish() }
        let items = await collect(streamer.sourcedEvents(for: .tvChannel(.blitz)), for: .seconds(1)).map(\.item)
        let lastMove = try #require(items.firstIndex { if case .fen(_, "e7e5", _, _) = $0.event { true } else { false } })
        let result = try #require(items.firstIndex { if case .gameEnded(gameId: "AAAA", status: _) = $0 { true } else { false } })
        let next = try #require(items.firstIndex { if case .featured("BBBB", _, _, _) = $0.event { true } else { false } })
        #expect(lastMove < result && result < next)
        #expect(items[lastMove].sourced?.isHistorical == false)
    }

    @Test("Closing metadata preserves a final position missing from the move lines")
    func closingPosition() async throws {
        let server = try LoopbackHTTPServer(steps: [.init(chunks: [Data((
            Self.gameMetadata(id: "AAAA") + Self.gameMove(fen: Self.afterE4, lastMove: "e2e4")
                + Self.gameOver(id: "AAAA", fen: Self.afterE5)
        ).utf8)], chunkDelay: 0, ending: .graceful)])
        defer { server.stop() }
        let stream = GameStream(baseURL: server.baseURL)
        defer { stream.finish() }
        var events: [SourcedEvent] = []
        for try await event in stream.sourcedEvents(gameId: "AAAA", liveFen: Self.afterE4) { events.append(event) }
        #expect(events.last?.event == .fen(fen: Self.afterE5, lastMove: nil, whiteClock: nil, blackClock: nil))
        #expect(events.last?.isHistorical == false)
        #expect(stream.lastStatus?.name == "mate")
    }

    private static func roundPayload(fen: String, status: String) -> Data {
        Data("""
        {"round":{"id":"R1","name":"Round 1","ongoing":true,"startsAt":1789683722400},
         "tour":{"id":"T1","name":"Test Open","tier":4,"info":{"format":"swiss","location":"Nowhere"}},
         "games":[{"id":"G1","name":"Alice - Bob","fen":"\(fen)","lastMove":"e2e4","status":"\(status)",
                   "players":[{"name":"Alice","title":"GM","rating":2700,"fed":"USA","clock":600000},
                              {"name":"Bob","title":"IM","rating":2500,"fed":"FRA","clock":598000}]}]}
        """.utf8)
    }

    @Test("A broadcast round whose PGN will not replay falls back to polling the board")
    func broadcastFallsBackToPolling() async throws {
        let broken = BroadcastPGNStreamTests.block(gameId: "G1", moves: "1. Ke5 1... Qh9")
        let server = try LoopbackHTTPServer { path, _ in
            switch path {
            case "/api/stream/broadcast/round/R1.pgn":
                return .init(chunks: [broken, broken, broken], chunkDelay: 0.01, ending: .hold)
            case "/api/broadcast/-/-/R1":
                return .init(chunks: [Self.roundPayload(fen: Self.afterE4, status: "1-0")], chunkDelay: 0, ending: .graceful)
            default:
                return .init(statusCode: 404, chunks: [], ending: .graceful)
            }
        }
        defer { server.stop() }

        let streamer = GameSourceStreamer(baseURL: server.baseURL, configuration: BroadcastPGNStreamTests.fastConfiguration())
        defer { streamer.finish() }

        let events = try await withTimeout(.seconds(20), "the fallback to finish") { [streamer] in
            var collected: [SourcedEvent] = []
            for try await item in streamer.sourcedEvents(for: .broadcastBoard(roundId: "R1", gameId: "G1")) {
                if let sourced = item.sourced { collected.append(sourced) }
            }
            return collected
        }

        // The polled board: featured + the one position it reports, and no history to mark.
        #expect(events.count == 2)
        guard case .featured(let gameId, _, let players, let fen) = events[0].event else {
            Issue.record("expected featured from the polling fallback"); return
        }
        #expect(gameId == "G1")
        #expect(fen == Self.afterE4)
        #expect(players.map(\.name) == ["Alice", "Bob"])
        #expect(events.allSatisfy { !$0.isHistorical })

        let paths = server.requests.compactMap { $0.split(separator: " ").dropFirst().first.map(String.init) }
        #expect(paths.contains("/api/stream/broadcast/round/R1.pgn"))   // it tried the PGN first
        #expect(paths.contains("/api/broadcast/-/-/R1"))                // then it polled
    }

    @Test("preferPollingForBroadcasts skips the PGN stream entirely")
    func preferPollingSkipsPGN() async throws {
        let server = try LoopbackHTTPServer { path, _ in
            switch path {
            case "/api/broadcast/-/-/R1":
                return .init(chunks: [Self.roundPayload(fen: Self.afterE4, status: "1-0")], chunkDelay: 0, ending: .graceful)
            default:
                return .init(statusCode: 404, chunks: [], ending: .graceful)
            }
        }
        defer { server.stop() }

        let streamer = GameSourceStreamer(
            baseURL: server.baseURL,
            configuration: BroadcastPGNStreamTests.fastConfiguration(),
            preferPollingForBroadcasts: true
        )
        defer { streamer.finish() }
        #expect(streamer.preferPollingForBroadcasts)

        let events = try await withTimeout(.seconds(20), "the polled board") { [streamer] in
            var collected: [SourcedEvent] = []
            for try await item in streamer.sourcedEvents(for: .broadcastBoard(roundId: "R1", gameId: "G1")) {
                if let sourced = item.sourced { collected.append(sourced) }
            }
            return collected
        }
        #expect(events.count == 2)
        let paths = server.requests.compactMap { $0.split(separator: " ").dropFirst().first.map(String.init) }
        #expect(!paths.contains { $0.hasSuffix(".pgn") })
    }
}

// MARK: - The boundary detector itself

@Suite("The history boundary")
struct HistoryBoundaryDetectorTests {

    private func fen(_ text: String) -> TVEvent { .fen(fen: text, lastMove: nil, whiteClock: nil, blackClock: nil) }

    @Test("The burst ends at the first long gap")
    func gapEndsTheBurst() {
        let start = ContinuousClock.now
        var detector = HistoryBoundaryDetector(gap: .milliseconds(100), startedAt: start)
        let a = detector.classify(fen("a"), at: start + .milliseconds(5))
        let b = detector.classify(fen("b"), at: start + .milliseconds(10))
        let c = detector.classify(fen("c"), at: start + .milliseconds(500))     // the gap
        let d = detector.classify(fen("d"), at: start + .milliseconds(505))     // and it stays live
        #expect(a)
        #expect(b)
        #expect(!c)
        #expect(!d)
        #expect(detector.isLive)
        #expect(detector.historicalCount == 2)
    }

    @Test("Reaching the announced live position ends the burst, whatever the timing")
    func liveFenEndsTheBurst() {
        let live = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2"
        // The channel feed announces two fields; the game stream sends six.
        var detector = HistoryBoundaryDetector(liveFen: "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w")
        let now = ContinuousClock.now
        let first = detector.classify(fen("rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1"), at: now)
        let caughtUp = detector.classify(fen(live), at: now)                    // still history
        let after = detector.classify(fen("anything after"), at: now)
        #expect(first)
        #expect(caughtUp)
        #expect(!after)
        #expect(detector.historicalCount == 2)
    }

    @Test("A featured event is never history and never ends the burst")
    func featuredIsNeutral() {
        var detector = HistoryBoundaryDetector()
        let now = ContinuousClock.now
        let featured = detector.classify(.featured(gameId: "A", orientation: .white, players: [], fen: "x"), at: now)
        let ply = detector.classify(fen("a"), at: now)
        #expect(!featured)
        #expect(ply)
        #expect(!detector.isLive)
    }

    @Test("Featuring move zero makes a fast opening live immediately")
    func startingPositionBoundary() {
        var detector = HistoryBoundaryDetector(liveFen: Position.standard.fen)
        let now = ContinuousClock.now
        let featured = detector.classify(.featured(gameId: "A", orientation: .white, players: [], fen: Position.standard.fen), at: now)
        #expect(!featured)
        #expect(detector.isLive)
        let move = detector.classify(fen("next position"), at: now)
        #expect(!move)
    }
}
