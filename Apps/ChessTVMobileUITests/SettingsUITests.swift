// Settings, Notifications, the follow defaults and Credits: every control.
//
// The push-server screen is gone: the address is built in, so there is nothing to type and
// nothing to press. What replaced those tests is the one button that is left for a phone that
// has stopped getting alerts, and the credits the Apple TV and the phone now share.
import XCTest

final class SettingsUITests: UITestCase {

    private let settings = ["-open", "settings"]

    private func launchSettings(engine: Bool = true, keepState: Bool = false) {
        launch(settings, engine: engine, keepState: keepState)
        waitFor(app.switches[UIID.Settings.engine], timeout: 20)
    }

    // MARK: - Board and engine

    func testEveryBoardChoiceCanBePickedAndSticks() {
        launchSettings()
        for theme in ["Brown", "Green", "Slate", "Sage"] {
            choose(theme, in: UIID.Settings.boardTheme)
        }
        for pieces in ["Merida", "Chessnut", "Classic"] {
            choose(pieces, in: UIID.Settings.pieces)
        }
        // Leave something other than the defaults behind, and check the app reads it back.
        choose("Slate", in: UIID.Settings.boardTheme)
        choose("Merida", in: UIID.Settings.pieces)
        app.terminate()

        launchSettings(keepState: true)
        XCTAssertEqual(pickerValue(UIID.Settings.boardTheme), "Slate", "the board colours did not survive a relaunch")
        XCTAssertEqual(pickerValue(UIID.Settings.pieces), "Merida", "the piece set did not survive a relaunch")
    }

    func testEveryDepthCanBePickedAndSticks() {
        launchSettings()
        for depth in ["Standard \u{00B7} 24", "Deep \u{00B7} 32", "Maximum \u{00B7} 40", "Light \u{00B7} 18"] {
            choose(depth, in: UIID.Settings.depth)
        }
        choose("Deep \u{00B7} 32", in: UIID.Settings.depth)
        app.terminate()
        launchSettings(keepState: true)
        XCTAssertEqual(pickerValue(UIID.Settings.depth), "Deep \u{00B7} 32", "the search depth did not survive a relaunch")
    }

    func testDepthIsDisabledWhileStockfishIsOff() {
        launch(settings)   // -engineEnabled NO
        waitFor(app.switches[UIID.Settings.engine], timeout: 20)
        XCTAssertFalse(isOn(UIID.Settings.engine), "this launch turns the engine off")
        XCTAssertFalse(app.buttons[UIID.Settings.depth].isEnabled, "a depth for an engine that is off is a control with no effect")
        flip(UIID.Settings.engine)
        XCTAssertTrue(waitUntil(6) { self.app.buttons[UIID.Settings.depth].isEnabled }, "the depth row should wake up with the engine")
        flip(UIID.Settings.engine)
        XCTAssertTrue(waitUntil(6) { !self.app.buttons[UIID.Settings.depth].isEnabled }, "and go back to sleep")
    }

    func testEveryBoardToggleFlipsAndSticks() {
        launchSettings()
        let toggles = [UIID.Settings.coordinates, UIID.Settings.sounds, UIID.Settings.followFeatured]
        var wanted: [String: Bool] = [:]
        for toggle in toggles {
            wanted[toggle] = flip(toggle)
        }
        for toggle in toggles {
            XCTAssertEqual(isOn(toggle), wanted[toggle], "\(toggle) did not hold its new value")
        }
        app.terminate()
        launchSettings(keepState: true)
        for toggle in toggles {
            XCTAssertEqual(isOn(toggle), wanted[toggle], "\(toggle) did not survive a relaunch")
        }
    }

    func testSettingsReachesEverySubScreen() {
        launchSettings()
        waitFor(app.buttons[UIID.Settings.notifications]).tap()
        waitForScreen("Notifications")
        back()
        XCTAssertTrue(revealRow(app.buttons[UIID.Settings.credits]))
        app.buttons[UIID.Settings.credits].tap()
        waitForScreen("Credits")
    }

    /// The build facts used to live on an About screen of their own. They are rows in Settings now.
    func testSettingsNamesTheBuild() {
        launchSettings()
        XCTAssertTrue(revealRow(app.staticTexts["Version"]), "Settings should name the version")
        XCTAssertTrue(findLabel("Identifies as"), "Settings should name the user agent")
        XCTAssertTrue(findLabel("No accounts, no ads, no analytics."), "the privacy line should still be there")
    }

    // MARK: - Notifications

    private func openNotifications() {
        launchSettings()
        waitFor(app.buttons[UIID.Settings.notifications]).tap()
        waitForScreen("Notifications")
    }

    func testMuteAndQuietHours() {
        openNotifications()
        XCTAssertFalse(isOn(UIID.Notifications.muteAll))
        flip(UIID.Notifications.muteAll)
        XCTAssertTrue(isOn(UIID.Notifications.muteAll), "Mute everything did not take")

        XCTAssertFalse(exists(UIID.Notifications.quietFrom), "the times only appear with quiet hours on")
        flip(UIID.Notifications.quietHours)
        XCTAssertTrue(waitUntil(6) { self.exists(UIID.Notifications.quietFrom) }, "From did not appear")
        XCTAssertTrue(exists(UIID.Notifications.quietTo), "To did not appear")
        XCTAssertTrue(app.switches[UIID.Notifications.resultsThrough].waitForExistence(timeout: 6), "the results exemption belongs with quiet hours")
        flip(UIID.Notifications.resultsThrough)

        flip(UIID.Notifications.quietHours)
        XCTAssertTrue(waitUntil(6) { !self.exists(UIID.Notifications.quietFrom) }, "the times should go with the switch")

        // Mute survives the trip out and back.
        back()
        waitFor(app.buttons[UIID.Settings.notifications]).tap()
        waitForScreen("Notifications")
        XCTAssertTrue(isOn(UIID.Notifications.muteAll), "Mute everything did not stick")
    }

    /// Whether anything at all publishes this identifier — a DatePicker row is not a button, a
    /// switch or a static text.
    private func exists(_ identifier: String) -> Bool {
        app.descendants(matching: .any).matching(identifier: identifier).count > 0
    }

    func testEveryFollowDefaultsScreenOffersItsSwitches() {
        openNotifications()
        for (kind, title, alerts) in [
            ("player", "Players", ["start", "move", "longThink", "end"]),
            ("game", "Games", ["start", "move", "longThink", "end"]),
            ("tournament", "Tournaments", ["startingSoon", "roundLive", "gameResults", "roundSummary", "finished", "topBoardMoves"]),
        ] {
            let row = app.buttons[UIID.Notifications.defaults(kind)]
            XCTAssertTrue(revealRow(row), "no defaults row for \(kind)")
            row.tap()
            waitForScreen(title)
            for alert in alerts {
                XCTAssertTrue(revealRow(app.switches[UIID.FollowDetail.toggle(alert)]), "the \(kind) defaults have no \(alert) switch")
            }
            flip(UIID.FollowDetail.toggle(alerts[1]))
            XCTAssertFalse(app.buttons[UIID.FollowDetail.applyToExisting].exists, "with nothing followed there is nothing to apply to")
            back()
            waitForScreen("Notifications")
        }
    }

    func testApplyToExistingAppearsOnceSomethingIsFollowedAndAnEditIsMade() {
        allowSystemAlerts()
        launch(["-open", "board:q7gOEObq:oSiy8ZXF"])
        waitForLiveGame()
        waitFor(app.buttons[UIID.Game.follow]).tap()
        dismissPermissionAlert()
        waitForScreen("Game alerts")

        selectTab("Settings")
        waitFor(app.buttons[UIID.Settings.notifications], timeout: 12).tap()
        waitForScreen("Notifications")
        let row = app.buttons[UIID.Notifications.defaults("game")]
        XCTAssertTrue(revealRow(row))
        row.tap()
        waitForScreen("Games")
        XCTAssertFalse(app.buttons[UIID.FollowDetail.applyToExisting].exists, "the offer waits for an edit")
        flip(UIID.FollowDetail.toggle("move"))
        let apply = app.buttons[UIID.FollowDetail.applyToExisting]
        XCTAssertTrue(apply.waitForExistence(timeout: 8), "the offer should appear once a default changed and a follow exists")
        XCTAssertTrue(apply.label.contains("1 existing game follow"), "the offer should count what it would rewrite: \(apply.label)")
        apply.tap()
        XCTAssertTrue(waitUntil(10) { self.app.staticTexts["Updated 1 follow"].exists }, "applying the defaults said nothing")
    }

    func testOpenFollowingLeavesTheSettingsTab() {
        openNotifications()
        let button = app.buttons[UIID.Notifications.openFollowing]
        XCTAssertTrue(revealRow(button), "no Open Following button")
        button.tap()
        XCTAssertTrue(waitUntil(10) { self.app.navigationBars["Following"].exists }, "Open Following should switch tabs")
    }

    // MARK: - Starting push over

    /// The one button a phone that has stopped getting alerts is meant to press. It asks for
    /// permission, throws the install's identity away, asks iOS for a token again and re-queues
    /// the follows; the simulator may or may not hand out a token, so what is asserted is that
    /// the button runs to completion and says something honest rather than spinning for ever.
    func testResetPushNotificationsRunsAndReportsWhatHappened() {
        allowSystemAlerts()
        openNotifications()
        let button = app.buttons[UIID.Notifications.resetPush]
        XCTAssertTrue(revealRow(button), "Notifications should offer Reset push notifications")
        XCTAssertTrue(findLabel("Use this if alerts stop arriving."), "the button should say when to use it")
        button.tap()
        dismissPermissionAlert()

        let result = app.staticTexts[UIID.Notifications.resetPushResult]
        XCTAssertTrue(waitUntil(40) { result.exists }, "the reset never said what happened")
        XCTAssertFalse(result.label.isEmpty, "the result line should say something")
        // Whatever it said, the screen has to be usable again.
        XCTAssertTrue(waitUntil(10) { self.app.buttons[UIID.Notifications.resetPush].isEnabled },
                      "the button should come back after the reset finished")
    }

    // MARK: - Credits

    private func openCredits() {
        launchSettings()
        XCTAssertTrue(revealRow(app.buttons[UIID.Settings.credits]))
        app.buttons[UIID.Settings.credits].tap()
        waitForScreen("Credits")
    }

    func testCreditsNameEverySourceAndTheLicences() {
        openCredits()
        for heading in ["Lichess", "FIDE", "Stockfish 19", "Piece sets", "Sounds", "Thank you"] {
            XCTAssertTrue(findLabel(heading), "Credits should have a \(heading) section")
            if heading == "Stockfish 19" {
                let source = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Its source is available at'")).firstMatch
                XCTAssertTrue(revealRow(source), "Credits should explain where to find the corresponding source")
            }
        }
        XCTAssertTrue(findLabel("Sounds made for Chess TV."), "the sounds line should say who made them")
    }

    func testEveryBundledLicenceOpensAndScrolls() {
        openCredits()
        for (identifier, title, opening) in [
            ("gpl3", "GPLv3", "GNU GENERAL PUBLIC LICENSE"),
            ("gpl2", "GPLv2", "GNU GENERAL PUBLIC LICENSE"),
            ("apache2", "Apache 2.0", "Apache License"),
        ] {
            let row = app.buttons[UIID.Credits.licence(identifier)]
            XCTAssertTrue(revealRow(row), "Credits should offer the \(title) text")
            row.tap()
            waitForScreen(title)
            let text = app.staticTexts[UIID.Credits.licenceText]
            XCTAssertTrue(text.waitForExistence(timeout: 10), "\(title) should show its text")
            XCTAssertTrue(text.label.contains(opening), "\(title) does not start with its own title: \(text.label.prefix(80))")
            back()
            waitForScreen("Credits")
        }
    }
}
