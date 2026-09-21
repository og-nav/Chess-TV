// The Settings screen: every swatch, piece set and depth selects and shows up in the block's value
// and in the line under the preview; every toggle flips, and the choice outlives Done and a
// relaunch. The Music row is checked but never pressed: connecting raises a system prompt the
// remote cannot dismiss.
import XCTest

final class TVSettingsUITests: TVUITestCase {

    /// The screen opens on the first swatch, so each block is reached by walking down from there.
    private func openSettings() {
        launch(["-showSettings"])
        waitFor(doneButton)
        XCTAssertTrue(waitUntil(10) { self.app.buttons[UIID.Settings.theme(TVFixture.themes[0])].hasFocus },
                      "Settings opens on the first board swatch, focus was on \(focusedIdentifier() ?? "nothing")")
    }

    private func summary() -> String { element(UIID.Settings.summary).label }

    // MARK: - Board colors

    func testEveryBoardSwatchSelects() {
        openSettings()
        for theme in TVFixture.themes {
            let swatch = app.buttons[UIID.Settings.theme(theme)]
            focus(swatch, pressing: .right, limit: 6)
            press(.select)
            XCTAssertTrue(waitUntil(6) { self.element(UIID.Settings.boardTheme).label == theme },
                          "the block should read \(theme), read \(element(UIID.Settings.boardTheme).label)")
            XCTAssertTrue(waitUntil(6) { self.summary().contains("\(theme) board") },
                          "the summary should name the \(theme) board, said \(summary())")
            XCTAssertTrue(swatch.isSelected, "\(theme) should be marked as the chosen swatch")
        }
        // Walking left again reaches each of them, so the row steers both ways.
        for theme in TVFixture.themes.reversed() {
            focus(app.buttons[UIID.Settings.theme(theme)], pressing: .left, limit: 6)
        }
    }

    // MARK: - Pieces

    func testEveryPieceSetSelects() {
        openSettings()
        let first = app.buttons[UIID.Settings.pieceSet(TVFixture.pieceSets[0].raw)]
        focus(first, pressing: .down, limit: 6)
        for set in TVFixture.pieceSets {
            let button = app.buttons[UIID.Settings.pieceSet(set.raw)]
            focus(button, pressing: .right, limit: 6)
            press(.select)
            XCTAssertTrue(waitUntil(6) { self.element(UIID.Settings.pieces).label == set.name },
                          "the block should read \(set.name), read \(element(UIID.Settings.pieces).label)")
            XCTAssertTrue(waitUntil(6) { self.summary().contains("\(set.name) pieces") },
                          "the summary should name the \(set.name) pieces, said \(summary())")
            XCTAssertTrue(button.isSelected, "\(set.raw) should be marked as the chosen set")
        }
    }

    // MARK: - Engine depth

    func testEveryDepthButtonSelects() {
        openSettings()
        let first = app.buttons[UIID.Settings.depth(TVFixture.depths[0].raw)]
        focus(first, pressing: .down, limit: 8)
        for depth in TVFixture.depths {
            let button = app.buttons[UIID.Settings.depth(depth.raw)]
            focus(button, pressing: .right, limit: 6)
            press(.select)
            XCTAssertTrue(waitUntil(6) { self.element(UIID.Settings.depth).label == depth.name },
                          "the block should read \(depth.name), read \(element(UIID.Settings.depth).label)")
            XCTAssertTrue(button.isSelected, "\(depth.raw) should be marked as the chosen depth")
        }
    }

    // MARK: - Toggles

    func testEveryToggleFlipsItsValue() {
        openSettings()
        let grid = app.buttons[TVFixture.toggleRows[0][0]]
        steer(to: grid, limit: 24)
        for identifier in TVFixture.toggles {
            let toggle = app.buttons[identifier]
            steer(to: toggle, limit: 16)
            let before = toggleValue(identifier)
            XCTAssertTrue(before == "On" || before == "Off", "\(identifier) should report On or Off, said \(before ?? "nothing")")
            press(.select)
            XCTAssertTrue(waitUntil(6) { self.toggleValue(identifier) != before },
                          "\(identifier) should have flipped from \(before ?? "nothing"), still \(toggleValue(identifier) ?? "nothing")")
            // And back, so the screen is left as it was found for the next assertion.
            press(.select)
            XCTAssertTrue(waitUntil(6) { self.toggleValue(identifier) == before },
                          "\(identifier) should flip back to \(before ?? "nothing")")
        }
    }

    /// The engine toggle also drives the summary line and the eval bar, so it gets its own check.
    func testTheEngineToggleReachesTheSummaryLine() {
        openSettings()
        let engine = app.buttons[UIID.Settings.engine]
        steer(to: engine, limit: 24)
        XCTAssertEqual(toggleValue(UIID.Settings.engine), "Off", "-engineEnabled NO starts it off")
        XCTAssertTrue(summary().contains("Stockfish off"), "the summary should say the engine is off, said \(summary())")
        press(.select)
        XCTAssertTrue(waitUntil(8) { self.summary().contains("Stockfish on") },
                      "turning the engine on should reach the summary, said \(summary())")
        press(.select)
        XCTAssertTrue(waitUntil(8) { self.summary().contains("Stockfish off") },
                      "turning it off again should reach the summary, said \(summary())")
    }

    /// A choice has to outlive the screen and the app. `engineEnabled` is left out because
    /// `-engineEnabled NO` is applied from the argument domain on every launch, ahead of what
    /// the app saved.
    func testToggleValuesSurviveDoneAndAReopenAndARelaunch() {
        openSettings()
        var flipped: [String: String] = [:]
        for identifier in TVFixture.persistentToggles {
            let toggle = app.buttons[identifier]
            steer(to: toggle, limit: 20)
            let before = toggleValue(identifier)
            press(.select)
            XCTAssertTrue(waitUntil(6) { self.toggleValue(identifier) != before }, "\(identifier) should flip")
            flipped[identifier] = toggleValue(identifier)
        }

        focus(doneButton, pressing: .up, limit: 14)
        press(.select)
        XCTAssertTrue(waitUntil(10) { !self.isOnSettings }, "Done should close Settings")

        // Reopened from the home screen's header.
        focus(homeSettingsButton, pressing: .up, limit: 8)
        press(.select)
        waitFor(doneButton)
        revealToggles()
        for (identifier, expected) in flipped {
            XCTAssertEqual(toggleValue(identifier), expected, "\(identifier) should still be \(expected) after reopening")
        }

        app.terminate()
        launch(["-showSettings"], keepState: true)
        waitFor(doneButton)
        revealToggles()
        for (identifier, expected) in flipped {
            XCTAssertEqual(toggleValue(identifier), expected, "\(identifier) should still be \(expected) after a relaunch")
        }
    }

    // MARK: - Music

    func testTheMusicRowOffersAConnectButtonAndIsNotPressed() {
        openSettings()
        let connect = app.buttons[UIID.Settings.musicConnect]
        XCTAssertTrue(connect.waitForExistence(timeout: 10), "the Music row should offer Connect Apple Music")
        XCTAssertEqual(connect.label, "Connect Apple Music")
        // Nothing has been authorised, so there is no playlist row or transport yet.
        XCTAssertFalse(app.buttons[UIID.Settings.musicPlay].exists)
        XCTAssertFalse(app.buttons[UIID.Settings.musicNext].exists)
        // Focus reaches it, but Select is never sent: it raises a system prompt the remote cannot
        // get out of.
        steer(to: connect, limit: 20)
        XCTAssertTrue(connect.hasFocus, "the remote should be able to reach Connect Apple Music")
    }

    // MARK: - Credits

    /// Credits take the Settings screen's place rather than opening a second cover, so this walks
    /// in, reads the blocks, opens a licence, walks down it with the remote — the only way
    /// anything scrolls on tvOS — and steps back out through both screens with Back.
    func testCreditsListEverySourceAndALicenceOpensAndScrolls() {
        openSettings()
        let credits = app.buttons[UIID.Settings.credits]
        steer(to: credits, limit: 30)
        press(.select)
        waitFor(app.buttons[UIID.Credits.done], timeout: 10)

        for entry in ["lichess", "fide", "stockfish", "pieces", "sounds", "thanks"] {
            XCTAssertTrue(waitUntil(8) { self.element(UIID.Credits.entry(entry)).exists },
                          "the credits should have a \(entry) block")
        }

        let licence = app.buttons[UIID.Credits.licence("gpl3")]
        steer(to: licence, limit: 30)
        press(.select)
        XCTAssertTrue(waitUntil(12) { self.element(UIID.Credits.licenceText).exists },
                      "selecting the GPLv3 row should show its text")
        assertSomethingHasFocus("on the licence text, which is the only way it scrolls")
        press(.down, times: 3, settle: 0.3)
        assertSomethingHasFocus("after walking down the licence")

        press(.menu, settle: 0.6)
        XCTAssertTrue(waitUntil(8) { self.element(UIID.Credits.entry("lichess")).exists },
                      "Back from a licence should land on the credits list")
        press(.menu, settle: 0.6)
        XCTAssertTrue(waitUntil(8) { self.doneButton.exists }, "Back from the credits should land on Settings")
    }

    // MARK: - Closing

    func testMenuClosesSettings() {
        openSettings()
        press(.menu, settle: 0.6)
        XCTAssertTrue(waitUntil(10) { !self.isOnSettings }, "Back should close Settings")
        XCTAssertTrue(isOnHome, "-showSettings opens over the home screen, so Back lands there")
    }

    /// Settings reached from under the board, which is the way the screen describes itself.
    func testSettingsOpenedFromTheGameChangesTheBoardAndComesBack() {
        launch(["-open", "tv:blitz"])
        waitFor(gameSettingsButton)
        waitForLive()
        focus(gameSettingsButton, pressing: .down, limit: 8)
        press(.select)
        waitFor(doneButton)

        let slate = app.buttons[UIID.Settings.theme("Slate")]
        focus(slate, pressing: .right, limit: 8)
        press(.select)
        XCTAssertTrue(waitUntil(6) { self.summary().contains("Slate board") }, "the preview should follow the swatch")

        focus(doneButton, pressing: .up, limit: 12)
        press(.select)
        XCTAssertTrue(waitUntil(10) { self.isOnGame }, "Done returns to the game")
        XCTAssertTrue(waitUntil(6) { self.gameSettingsButton.hasFocus },
                      "focus should come back to the Settings button, went to \(focusedIdentifier() ?? "nothing")")
        XCTAssertTrue(statusChip.exists && statusChip.label == "Live", "the feed should have carried on")
    }
}
