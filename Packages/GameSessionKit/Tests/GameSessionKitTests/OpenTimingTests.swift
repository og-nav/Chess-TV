import Foundation
import Testing
import ChessCore
import LichessKit
@testable import GameSessionKit

@Suite("Opening timings")
struct OpenTimingTests {

    private final class Lines: @unchecked Sendable {   // @unchecked: lock-guarded
        private let lock = NSLock()
        private var stored: [String] = []
        func append(_ line: String) { lock.withLock { stored.append(line) } }
        var all: [String] { lock.withLock { stored } }
    }

    @Test("Each milestone is recorded once, from the tap, and the summary lists them all")
    func marksOnce() {
        let lines = Lines()
        let start = ContinuousClock.now
        var timing = OpenTiming(source: "tv:blitz", start: start, fromTap: true) { lines.append($0) }

        let screenRecorded = timing.mark(.screen, at: start + .milliseconds(120))
        let boardRecorded = timing.mark(.board, at: start + .milliseconds(130))
        let boardAgain = timing.mark(.board, at: start + .seconds(5))
        #expect(screenRecorded && boardRecorded)
        #expect(!boardAgain, "a second board mark changes nothing")
        #expect(timing.milliseconds(.board) == 130)
        #expect(!timing.isComplete)

        timing.mark(.history, at: start + .milliseconds(400))
        timing.mark(.live, at: start + .milliseconds(900))
        #expect(!timing.isComplete)
        timing.mark(.clocks, at: start + .milliseconds(900))
        #expect(timing.isComplete)

        timing.summarise(reason: "opened", at: start + .milliseconds(901))
        timing.summarise(reason: "closed", at: start + .seconds(30))
        let summaries = lines.all.filter { $0.hasPrefix("opened") || $0.hasPrefix("closed") }
        #expect(summaries.count == 1, "the summary is written once")
        #expect(summaries.first == "opened tv:blitz from=tap after=901ms screen=120 board=130 history=400 live=900 clocks=900 evaluation=-")
        #expect(lines.all.first == "open tv:blitz screen +120ms")
    }

    @Test("Percentile-free millisecond conversion rounds down")
    func millis() {
        #expect(OpenTiming.millis(.milliseconds(1234)) == 1234)
        #expect(OpenTiming.millis(.microseconds(1999)) == 1)
        #expect(OpenTiming.millis(.seconds(2) + .milliseconds(5)) == 2005)
    }
}

@Suite("GameSession writes opening timings")
@MainActor
struct GameSessionTimingTests {

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test("A TV channel marks the board and the first live event, and the tap is the origin")
    func liveChannel() async throws {
        let streamer = FakeStreamer()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "ChessTVTests-\(UUID().uuidString)")!)
        settings.sounds = false
        settings.tournamentAlerts = false
        let model = GameSession(settings: settings, streamer: streamer, arenas: FakeArenas())
        let blitz = GameSource.tvChannel(.blitz)

        model.noteNavigationTap()
        model.open(source: blitz, title: "Blitz")
        model.noteScreenAppeared()
        let timing = try #require(model.openTiming)
        #expect(timing.fromTap)
        #expect(timing.source == blitz.storageKey)
        #expect(timing.milliseconds(.screen) != nil)
        #expect(timing.milliseconds(.board) == nil)

        let events = try FixtureFeed.events(named: "feed-castling")
        streamer.emit(events[0], to: blitz)
        #expect(await eventually { model.openTiming?.milliseconds(.live) != nil })
        #expect(model.openTiming?.milliseconds(.board) != nil)
        // The fake streamer never reports a live connection, so the clocks are never trusted.
        #expect(model.openTiming?.milliseconds(.clocks) == nil)
        #expect(model.openTiming?.isComplete == false)

        model.close()
        #expect(model.openTiming == nil)
        // A second open without a tap starts from the open call.
        model.open(source: blitz, title: "Blitz")
        #expect(model.openTiming?.fromTap == false)
        model.close()
    }
}
