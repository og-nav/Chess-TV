// Churn: the same controls hammered far harder than anybody would, with a frame-lag reading for
// each run and a check afterwards that the screen is still the screen it should be.
//
// What the hitch readings mean is in TESTING.md: they are the app's own main-thread frame lag while
// the scenario ran, on a simulator, which is a floor rather than a promise about a phone.
//
// Each scenario carries its own budget rather than the 10 ms/s `measureHitches` defaults to. That
// default is the interactive budget — what a person tapping at human speed should see. These
// scenarios tap as fast as XCTest can drive them, and XCTest's own accessibility queries run on
// the app's main thread, so they compete with the frames being measured. The budgets below are set
// from what this simulator actually does (see the figures beside each one), loose enough not to
// fail on noise and tight enough that a real regression in any of these paths breaks the build.
import XCTest

final class StressUITests: UITestCase {

    private let board = ["-open", "board:q7gOEObq:oSiy8ZXF"]

    // MARK: - Tabs

    func testFortyRapidTabSwitches() {
        launch()
        waitFor(app.buttons[UIID.Home.event("q7gOEObq")], timeout: 20)
        let names = ["Following", "Settings", "Watch"]
        measureHitches("40 tab switches", maxMsPerSecond: 60) {   // this simulator: 23 ms/s, worst frame 104 ms
            for index in 0..<40 {
                app.tabBars.buttons[names[index % names.count]].tap()
            }
        }
        selectTab("Watch")
        XCTAssertTrue(waitUntil(15) { self.app.buttons[UIID.Home.event("q7gOEObq")].exists }, "Home lost its shelves")
        selectTab("Following")
        XCTAssertTrue(waitUntil(10) { self.app.buttons[UIID.Following.browse].exists }, "Following lost its empty state")
        selectTab("Settings")
        XCTAssertTrue(waitUntil(10) { self.app.switches[UIID.Settings.engine].exists }, "Settings lost its controls")
    }

    // MARK: - Opening games

    func testTwentyOpenAndBackCyclesAcrossAllThreeSources() {
        launch()
        waitFor(app.buttons[UIID.Home.event("q7gOEObq")], timeout: 20)
        let channel = app.buttons[UIID.Home.channel("blitz")]
        let arena = app.buttons[UIID.Home.arena("FfsuUfQP")]
        let event = app.buttons[UIID.Home.event("q7gOEObq")]
        let boardCard = app.buttons[UIID.Boards.card("oSiy8ZXF")]
        measureHitches("20 open/back cycles", maxMsPerSecond: 150) {   // this simulator: 77 ms/s, worst frame 128 ms
            for index in 0..<7 {
                XCTAssertTrue(reveal(channel))
                channel.tap()
                XCTAssertTrue(gameStatus.waitForExistence(timeout: 20), "the channel game did not open on cycle \(index)")
                back()
                XCTAssertTrue(app.navigationBars["Watch"].waitForExistence(timeout: 15), "channel cycle \(index) did not come home")
            }
            for index in 0..<7 {
                XCTAssertTrue(reveal(arena))
                arena.tap()
                XCTAssertTrue(gameStatus.waitForExistence(timeout: 20), "the arena did not open on cycle \(index)")
                back()
                XCTAssertTrue(app.navigationBars["Watch"].waitForExistence(timeout: 15), "arena cycle \(index) did not come home")
            }
            // The last six are broadcast boards, opened from the wall the event card leads to.
            XCTAssertTrue(reveal(event))
            event.tap()
            XCTAssertTrue(boardCard.waitForExistence(timeout: 20), "the wall did not open")
            for index in 0..<6 {
                boardCard.tap()
                XCTAssertTrue(gameStatus.waitForExistence(timeout: 20), "the board did not open on cycle \(index)")
                back()
                XCTAssertTrue(boardCard.waitForExistence(timeout: 15), "board cycle \(index) did not come back to the wall")
            }
            back()
        }
        XCTAssertTrue(app.buttons[UIID.Home.event("q7gOEObq")].waitForExistence(timeout: 15), "Home is still Home")
    }

    /// The classic race: leave the screen while the feed is still opening. The next open must still
    /// connect — the bug this guards is `onDisappear` closing the feed the new screen just opened.
    func testOpenAndImmediatelyBackFifteenTimes() {
        launch()
        waitFor(app.buttons[UIID.Home.event("q7gOEObq")], timeout: 20)
        let channel = app.buttons[UIID.Home.channel("blitz")]
        XCTAssertTrue(reveal(channel))
        measureHitches("15 open/instant-back", maxMsPerSecond: 160) {   // this simulator: 80 ms/s, worst frame 135 ms
            for index in 0..<15 {
                channel.tap()
                XCTAssertTrue(app.navigationBars.buttons["BackButton"].firstMatch.waitForExistence(timeout: 10), "cycle \(index) never pushed")
                back()
                XCTAssertTrue(app.navigationBars["Watch"].waitForExistence(timeout: 10), "cycle \(index) never popped")
            }
        }
        // And now a normal open: it has to reach Live, not sit on "Connecting".
        channel.tap()
        waitFor(gameStatus, timeout: 20)
        XCTAssertTrue(waitUntil(15) { self.gameStatus.label.contains("Live") },
                      "after fifteen aborted opens the next one stuck on '\(gameStatus.label)'")
    }

    // MARK: - The board's own controls

    func testFortyRapidFlips() {
        launch(board)
        waitForLiveGame()
        let flip = waitFor(app.buttons[UIID.Game.flip])
        measureHitches("40 flips", maxMsPerSecond: 220) {   // this simulator: 117 ms/s, worst frame 52 ms
            for _ in 0..<40 { flip.tap() }
        }
        // Forty is even, so the board is back where it started.
        XCTAssertTrue(waitUntil(10) { self.app.buttons[UIID.Game.flip].label == "Watch as Black" },
                      "after forty flips the button reads \(app.buttons[UIID.Game.flip].label)")
        XCTAssertTrue(waitUntil(10) { self.topLeftSquare().hasPrefix("a8") },
                      "after forty flips the board is facing \(topLeftSquare())")
        XCTAssertTrue(gameStatus.label.contains("Live") || gameStatus.label.contains("Finished"),
                      "the feed should have survived: \(gameStatus.label)")
    }

    func testSixtyRapidScrubTaps() {
        launch(board)
        waitForLiveGame()
        XCTAssertTrue(waitUntil(20) { self.moveCount() > 4 }, "no history to scrub")
        let previous = app.buttons[UIID.Game.scrubPrevious]
        let next = app.buttons[UIID.Game.scrubNext]
        measureHitches("60 scrub taps", maxMsPerSecond: 260) {   // this simulator: 141 ms/s, worst frame 51 ms
            for index in 0..<60 {
                // Walk back twenty and forward one, over and over, so both ends get used and the
                // disabled states are hit too.
                if index % 3 == 2, next.isEnabled { next.tap() } else if previous.isEnabled { previous.tap() }
            }
        }
        let label = app.staticTexts[UIID.Game.scrubLabel]
        XCTAssertTrue(label.exists, "the scrub bar is still there")
        app.buttons[UIID.Game.scrubLive].tap()
        XCTAssertTrue(waitUntil(10) { label.label.contains("live") }, "Live did not recover the live position: \(label.label)")
        XCTAssertTrue(app.buttons[UIID.Game.flip].exists, "the controls are still there")
    }

    func testFiftyToggleFlipsInSettings() {
        launch(["-open", "settings"], engine: true)
        waitFor(app.switches[UIID.Settings.engine], timeout: 20)
        let toggles = [UIID.Settings.coordinates, UIID.Settings.sounds, UIID.Settings.followFeatured]
        let controls = toggles.map { app.switches[$0].switches.firstMatch }
        measureHitches("50 toggle flips", maxMsPerSecond: 90) {   // this simulator: 38 ms/s, worst frame 66 ms
            for index in 0..<50 { controls[index % controls.count].tap() }
        }
        for toggle in toggles {
            XCTAssertTrue(app.switches[toggle].exists, "\(toggle) survived the churn")
            XCTAssertTrue(["0", "1"].contains((app.switches[toggle].value as? String) ?? ""), "\(toggle) has a sane value")
        }
        // The engine switch and the picker under it still work afterwards.
        XCTAssertTrue(app.buttons[UIID.Settings.depth].isEnabled)
        choose("Deep \u{00B7} 32", in: UIID.Settings.depth)
    }

    // MARK: - System metrics

    /// Memory and CPU across a navigation churn. The numbers are the simulator's, so they are a
    /// trend line for this machine rather than a phone budget.
    func testNavigationChurnMemoryAndCPU() {
        launch()
        waitFor(app.buttons[UIID.Home.event("q7gOEObq")], timeout: 20)
        let options = XCTMeasureOptions()
        options.iterationCount = 2
        let channel = app.buttons[UIID.Home.channel("blitz")]
        XCTAssertTrue(reveal(channel))
        measure(metrics: [XCTMemoryMetric(application: app), XCTCPUMetric(application: app)], options: options) {
            for _ in 0..<4 {
                channel.tap()
                _ = gameStatus.waitForExistence(timeout: 15)
                back()
                _ = app.navigationBars["Watch"].waitForExistence(timeout: 15)
            }
        }
        XCTAssertTrue(app.buttons[UIID.Home.event("q7gOEObq")].exists)
    }

    /// Navigation transitions as the system measures them.
    ///
    /// The iOS 26 simulator does emit UIKit's `NavigationTransition` signposts, so this collects
    /// real data: one push and pop of the game screen measured 0.504 s of transition on this
    /// machine. There is no baseline stored, so the measurement records rather than judges; what
    /// it is here for is the day a transition doubles.
    func testNavigationTransitionSignposts() {
        launch()
        waitFor(app.buttons[UIID.Home.event("q7gOEObq")], timeout: 20)
        let channel = app.buttons[UIID.Home.channel("blitz")]
        XCTAssertTrue(reveal(channel))
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        measure(metrics: [XCTOSSignpostMetric.navigationTransitionMetric], options: options) {
            channel.tap()
            _ = gameStatus.waitForExistence(timeout: 15)
            back()
            _ = app.navigationBars["Watch"].waitForExistence(timeout: 15)
        }
        XCTAssertTrue(app.buttons[UIID.Home.event("q7gOEObq")].exists, "the churn left Home intact")
    }
}
