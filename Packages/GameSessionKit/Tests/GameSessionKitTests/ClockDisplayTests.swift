import Testing
import Foundation
import ChessCore
@testable import GameSessionKit

@Suite("Local clock countdown")
struct ClockDisplayTests {

    private func reading(sideToMove: PieceColor, at instant: ContinuousClock.Instant) -> ClockReading {
        ClockReading(whiteSeconds: 137, blackSeconds: 240, receivedAt: instant, sideToMove: sideToMove)
    }

    @Test("The side to move counts down from the received value")
    func countdown() {
        let received = ContinuousClock.now
        let clocks = reading(sideToMove: .white, at: received)
        let seconds = ClockDisplay.remainingSeconds(for: .white, clocks: clocks, isLive: true, now: received + .seconds(5))
        #expect(seconds == 132)
        #expect(ClockDisplay.text(seconds!) == "2:12")
    }

    @Test("The idle side's clock is frozen at the received value")
    func idleSideDoesNotTick() {
        let received = ContinuousClock.now
        let clocks = reading(sideToMove: .white, at: received)
        let seconds = ClockDisplay.remainingSeconds(for: .black, clocks: clocks, isLive: true, now: received + .seconds(30))
        #expect(seconds == 240)
        #expect(ClockDisplay.text(seconds!) == "4:00")
    }

    @Test("While reconnecting, even the side to move is frozen")
    func reconnectingFreezes() {
        let received = ContinuousClock.now
        let clocks = reading(sideToMove: .white, at: received)
        let seconds = ClockDisplay.remainingSeconds(for: .white, clocks: clocks, isLive: false, now: received + .seconds(42))
        #expect(seconds == 137)
        #expect(ClockDisplay.text(seconds!) == "2:17")
    }

    @Test("The clock never goes below zero")
    func neverNegative() {
        let received = ContinuousClock.now
        let clocks = reading(sideToMove: .white, at: received)
        let seconds = ClockDisplay.remainingSeconds(for: .white, clocks: clocks, isLive: true, now: received + .seconds(500))
        #expect(seconds == 0)
        #expect(ClockDisplay.text(seconds!) == "0:00")
    }

    @Test("Formatting covers seconds, minutes and hours")
    func formatting() {
        #expect(ClockDisplay.text(0) == "0:00")
        #expect(ClockDisplay.text(9) == "0:09")
        #expect(ClockDisplay.text(60) == "1:00")
        #expect(ClockDisplay.text(132) == "2:12")
        #expect(ClockDisplay.text(3723) == "1:02:03")
        #expect(ClockDisplay.text(-5) == "0:00")
    }

    @Test("A clock the feed never sent shows nothing")
    func missingClock() {
        let clocks = ClockReading(whiteSeconds: nil, blackSeconds: 30, receivedAt: .now, sideToMove: .white)
        #expect(ClockDisplay.remainingSeconds(for: .white, clocks: clocks, isLive: true, now: .now) == nil)
        #expect(ClockDisplay.remainingSeconds(for: .black, clocks: nil, isLive: true, now: .now) == nil)
    }
}
