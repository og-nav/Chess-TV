// Stress: churn the remote and the navigation harder than a person would, then check the app is
// still where it should be, still steerable, and still drawing without dropping frames. Each churn
// is wrapped in `measureHitches`, which reads the app's own frame-lag report and fails the test if
// the screen spent more than 10 ms of every second late.
import XCTest

final class TVStressUITests: TVUITestCase {

    /// A fixed seed, so a failure is the same walk every time.
    private func pseudoRandomDirections(_ count: Int, seed: UInt64 = 0x5EED_C0FFEE) -> [XCUIRemote.Button] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return TVFixture.directions[Int((state >> 33) % UInt64(TVFixture.directions.count))]
        }
    }

    /// Two hundred presses in every direction. The home screen has to survive a person who is
    /// looking for the remote's edges, and still have something focused at the end.
    func testTwoHundredRandomPressesOnTheHomeScreen() {
        launch()
        waitFor(channelCard("blitz"), timeout: 20)
        waitFor(eventCard(TVFixture.liveEvent), timeout: 20)

        measureHitches("home-200-random-presses") {
            for button in pseudoRandomDirections(200) {
                remote.press(button)
            }
        }

        XCTAssertEqual(app.state, .runningForeground, "the app should still be running")
        XCTAssertTrue(isOnHome, "random focus moves should never leave the home screen")
        let focused = assertSomethingHasFocus("after 200 random presses")
        XCTAssertTrue(focused?.hasPrefix("home.") == true,
                      "focus should be on a home card or the header, was on \(focused ?? "nothing")")
    }

    /// Fifteen open-and-Back cycles across all three kinds of source. The last one has to reach a
    /// live feed, so nothing has been left broken behind us.
    func testFifteenOpenAndBackCyclesAcrossEverySource() {
        launch()
        waitFor(channelCard("blitz"), timeout: 20)
        waitFor(eventCard(TVFixture.liveEvent), timeout: 20)

        // Channel, arena, board, and round again: five times through.
        let cards: [XCUIElement] = [
            channelCard("blitz"), arenaCard(TVFixture.liveArenas[0]), eventCard(TVFixture.liveEvent),
        ]
        // Pushing and popping a whole screen drops frames on the simulator in a way it does not on
        // the box, so the bar here guards against a regression rather than asserting smoothness.
        measureHitches("open-and-back-15-cycles", maxMsPerSecond: 35) {
            for cycle in 0..<15 {
                let card = cards[cycle % cards.count]
                steer(to: card, limit: 20)
                press(.select)
                // An event opens the board list; a channel or arena opens a game.
                let arrived = waitUntil(15) { self.gameSettingsButton.exists || self.boardCard(TVFixture.ongoingBoard).exists }
                XCTAssertTrue(arrived, "cycle \(cycle) never opened anything from \(card.identifier)")
                backToHome()
            }
        }

        // One more, all the way to a live feed.
        steer(to: channelCard("blitz"), limit: 20)
        press(.select)
        waitFor(gameSettingsButton, timeout: 15)
        waitForLive(10)
    }

    /// Forty flips in a row. The board turns around each time and the button renames itself; an even
    /// number of presses has to leave both exactly as they started.
    func testFortyRapidFlips() {
        launch(["-open", "tv:blitz"])
        waitFor(gameSettingsButton)
        waitForLive()
        focus(flipButton, pressing: .right, limit: 8)
        XCTAssertEqual(flipButton.label, "Watch as Black")

        // Every flip redraws the whole board; on the simulator that costs frames unevenly, so the
        // bar is a regression guard rather than a smoothness claim.
        measureHitches("game-40-flips", maxMsPerSecond: 35) {
            press(.select, times: 40, settle: 0.1)
        }

        XCTAssertTrue(waitUntil(8) { self.flipButton.label == "Watch as Black" },
                      "forty flips is an even number, so the button should read as it did, said \(flipButton.label)")
        XCTAssertTrue(playerRows().first?.label.contains("BLACK") == true,
                      "and the board should be back the way up it started")
        XCTAssertTrue(flipButton.hasFocus, "the button should still have focus")
        XCTAssertTrue(statusChip.exists && statusChip.label == "Live", "the feed should have carried on")
    }

    /// A hundred selects on one toggle. `coordinates` is the one to hammer: it redraws the board
    /// every press without starting or stopping Stockfish.
    func testHundredTogglePressesInSettings() {
        launch(["-showSettings"])
        waitFor(doneButton)
        let toggle = app.buttons[UIID.Settings.coordinates]
        steer(to: toggle, limit: 24)
        let before = toggleValue(UIID.Settings.coordinates)

        measureHitches("settings-100-toggle-presses") {
            press(.select, times: 100, settle: 0.06)
        }

        XCTAssertTrue(waitUntil(8) { self.toggleValue(UIID.Settings.coordinates) == before },
                      "a hundred presses is an even number, so the toggle should read \(before ?? "nothing"), "
                      + "read \(toggleValue(UIID.Settings.coordinates) ?? "nothing")")
        XCTAssertTrue(toggle.hasFocus, "the toggle should still have focus")
        XCTAssertTrue(isOnSettings, "hammering a toggle should not close the screen")
    }

    /// Twenty Settings open/close cycles from the game screen, half with Done and half with Back.
    func testTwentySettingsOpenAndCloseCycles() {
        launch(["-open", "tv:blitz"])
        waitFor(gameSettingsButton)
        waitForLive()

        // Forty presentations of a full-screen cover carrying a 600 pt board preview is the most
        // expensive churn in the suite: the simulator spends around 90 ms of every second late on
        // it. The bar is set to catch a regression, and the reading itself is attached.
        measureHitches("settings-20-open-close", maxMsPerSecond: 130) {
            for cycle in 0..<20 {
                XCTAssertTrue(waitUntil(8) { self.isOnGame }, "cycle \(cycle) did not start on the game")
                steer(to: gameSettingsButton, limit: 12)
                press(.select)
                XCTAssertTrue(waitUntil(10) { self.isOnSettings }, "cycle \(cycle) never opened Settings")
                // A press that lands while the cover is still animating is swallowed, so the close
                // is tried again rather than being read as the screen refusing to go.
                var closed = false
                for attempt in 0..<3 where !closed {
                    if cycle.isMultiple(of: 2) {
                        focus(doneButton, pressing: .up, limit: 12)
                        press(.select, settle: 0.3)
                    } else {
                        press(.menu, settle: 0.3)
                    }
                    closed = waitUntil(attempt == 2 ? 8 : 3) { !self.isOnSettings }
                }
                XCTAssertTrue(closed, "cycle \(cycle) never closed Settings")
            }
        }

        XCTAssertTrue(isOnGame, "twenty cycles should leave us back on the game")
        XCTAssertTrue(statusChip.exists && statusChip.label == "Live", "the feed should have carried on")
        XCTAssertTrue(waitUntil(6) { self.gameSettingsButton.hasFocus }, "and focus should be back on Settings")
    }

    /// What the churn costs in memory and processor time, rather than in frames.
    func testNavigationChurnMemoryAndCPU() {
        launch()
        waitFor(channelCard("blitz"), timeout: 20)
        let options = XCTMeasureOptions()
        options.iterationCount = 2
        measure(metrics: [XCTMemoryMetric(application: app), XCTCPUMetric(application: app)], options: options) {
            for channel in ["blitz", "rapid"] {
                steer(to: channelCard(channel), limit: 20)
                press(.select)
                _ = waitUntil(15) { self.gameSettingsButton.exists }
                backToHome()
            }
        }
        XCTAssertTrue(isOnHome)
        XCTAssertEqual(app.state, .runningForeground)
    }
}
