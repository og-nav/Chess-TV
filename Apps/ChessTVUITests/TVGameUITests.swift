// The game screen: it goes live, the clocks run, the moves arrive, and every control under the
// board does what its label says.
import XCTest

final class TVGameUITests: TVUITestCase {

    // MARK: - Live feed

    func testChannelGameGoesLiveAndTheClocksRun() {
        launch(["-open", "tv:blitz"])
        waitFor(gameSettingsButton)
        waitForLive()

        // The row label carries the name, the side and the clock, so a changed label is a tick.
        let before = playerRows()
        XCTAssertEqual(before.count, 2, "both player rows should be on screen")
        XCTAssertTrue(before.contains { $0.label.contains("WHITE") }, "a row should say WHITE: \(before.map(\.label))")
        XCTAssertTrue(before.contains { $0.label.contains("BLACK") }, "a row should say BLACK: \(before.map(\.label))")

        let joined = before.map(\.label).joined(separator: " | ")
        let ticked = waitUntil(8) { self.playerRows().map(\.label).joined(separator: " | ") != joined }
        XCTAssertTrue(ticked, "a clock should have ticked within 8 s; the rows still read \(joined)")
    }

    func testTheMoveListGainsMovesAsTheyArrive() {
        launch(["-open", "tv:blitz"])
        waitFor(gameSettingsButton)
        waitForLive()
        XCTAssertTrue(waitUntil(20) { (self.latestMoveNumber() ?? 0) > 1 },
                      "the move list should fill from the history burst, it showed rows \(moveRowNumbers())")
        let rows = moveRowNumbers()
        XCTAssertEqual(rows.count, 8, "the panel keeps the last eight rows, showed \(rows)")
        guard let first = rows.last else { return XCTFail("no numbered rows in the move list") }
        XCTAssertTrue(element(UIID.Game.moveRow(first)).label.contains("\(first)"),
                      "row \(first) should be numbered, read \(element(UIID.Game.moveRow(first)).label)")
        XCTAssertTrue(waitUntil(20) { (self.latestMoveNumber() ?? 0) > first },
                      "a live move should have arrived within 20 s; the list stopped at \(first)")
    }

    // MARK: - Footer controls

    func testSettingsTakesFocusFirstAndDoneGivesItBack() {
        launch(["-open", "tv:blitz"])
        waitFor(gameSettingsButton)
        XCTAssertTrue(waitUntil(10) { self.gameSettingsButton.hasFocus },
                      "Settings under the board is the default focus, focus was on \(focusedIdentifier() ?? "nothing")")
        press(.select)
        waitFor(doneButton)
        focus(doneButton, pressing: .up, limit: 10)
        press(.select)
        XCTAssertTrue(waitUntil(10) { !self.isOnSettings }, "Done should close Settings")
        XCTAssertTrue(waitUntil(6) { self.gameSettingsButton.hasFocus },
                      "focus should come back to Settings, went to \(focusedIdentifier() ?? "nothing")")
    }

    func testMenuClosesSettingsOpenedFromTheGame() {
        launch(["-open", "tv:blitz"])
        waitFor(gameSettingsButton)
        focus(gameSettingsButton, pressing: .down, limit: 8)
        press(.select)
        waitFor(doneButton)
        press(.menu, settle: 0.6)
        XCTAssertTrue(waitUntil(10) { !self.isOnSettings }, "Back should close Settings")
        XCTAssertTrue(isOnGame, "Back from Settings returns to the game, not to the home screen")
    }

    /// The button names the side it would switch to, and pressing it turns the board around, which
    /// swaps which player row is on top.
    func testFlipButtonRenamesItselfAndSwapsTheTopPlayerRow() {
        launch(["-open", "tv:blitz"])
        waitFor(gameSettingsButton)
        waitForLive()
        focus(flipButton, pressing: .right, limit: 8)
        XCTAssertEqual(flipButton.label, "Watch as Black", "White is up first, so the button offers Black")
        let topBefore = playerRows().first
        XCTAssertTrue(topBefore?.label.contains("BLACK") == true,
                      "watching as White puts Black at the top, top row was \(topBefore?.label ?? "nothing")")

        press(.select)
        XCTAssertTrue(waitUntil(6) { self.flipButton.label == "Watch as White" },
                      "after flipping the button should offer White, said \(flipButton.label)")
        XCTAssertTrue(waitUntil(6) { self.playerRows().first?.label.contains("WHITE") == true },
                      "after flipping White should be at the top, top row was \(playerRows().first?.label ?? "nothing")")
        XCTAssertTrue(flipButton.hasFocus, "the flip button keeps focus")

        press(.select)
        XCTAssertTrue(waitUntil(6) { self.flipButton.label == "Watch as Black" }, "flipping back restores the label")
        XCTAssertTrue(waitUntil(6) { self.playerRows().first?.label.contains("BLACK") == true },
                      "flipping back puts Black at the top again")
    }

    /// Play/Pause runs the music, which nothing has connected in fixture mode. It must not disturb
    /// the game or the focus.
    func testPlayPauseLeavesTheGameAlone() {
        launch(["-open", "tv:blitz"])
        waitFor(gameSettingsButton)
        waitForLive()
        focus(flipButton, pressing: .right, limit: 8)
        press(.playPause, times: 6, settle: 0.3)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(isOnGame, "Play/Pause should not leave the game")
        XCTAssertTrue(statusChip.exists && statusChip.label == "Live", "the feed should still be live")
        XCTAssertTrue(flipButton.hasFocus, "Play/Pause should not move focus")
    }

    // MARK: - Arenas

    func testArenaShowsTheStandingsPanelAndTheEndsInChip() {
        launch(["-open", "arena:FfsuUfQP"])
        waitFor(gameSettingsButton)
        waitForLive()
        let standings = element(UIID.Game.standings)
        XCTAssertTrue(standings.waitForExistence(timeout: 20), "an arena should bring its leaderboard")
        XCTAssertTrue(standings.label.contains("Standings"), "the panel should be labelled, said \(standings.label)")
        // Lichess sends ten rows on page one, ranked 1 to 10.
        for rank in 1...10 {
            let row = element(UIID.Game.standingsRow(rank))
            XCTAssertTrue(row.waitForExistence(timeout: 10), "standings row \(rank) should be on screen")
        }
        XCTAssertTrue(element(UIID.Game.standingsRow(1)).label.contains("Matanzas67"),
                      "the leader should be first, row 1 read \(element(UIID.Game.standingsRow(1)).label)")
        XCTAssertTrue(element(UIID.Game.standingsRow(10)).label.contains("Porrio08"),
                      "row 10 read \(element(UIID.Game.standingsRow(10)).label)")
        XCTAssertFalse(element(UIID.Game.standingsRow(11)).exists, "page one is ten rows, not eleven")

        let endsIn = element(UIID.Game.endsIn)
        XCTAssertTrue(endsIn.waitForExistence(timeout: 20), "an arena header should say how long it has left")
        XCTAssertTrue(endsIn.label.hasPrefix("Arena ends in"), "said \(endsIn.label)")
    }

    func testAChannelGameHasNoStandingsPanel() {
        launch(["-open", "tv:blitz"])
        waitFor(gameSettingsButton)
        waitForLive()
        XCTAssertFalse(element(UIID.Game.standings).exists, "only arenas have a leaderboard")
        XCTAssertFalse(element(UIID.Game.endsIn).exists, "only arenas end at a time")
    }

    // MARK: - Broadcast boards

    func testBoardOpenedFromTheListIsTitledAndLive() {
        launch(["-open", "boards:\(TVFixture.roundId)"])
        let card = boardCard(TVFixture.ongoingBoard)
        waitFor(card, timeout: 20)
        XCTAssertTrue(waitUntil(10) { card.hasFocus }, "the ongoing board takes focus first")
        press(.select)
        waitFor(gameSettingsButton)
        XCTAssertTrue(waitUntil(20) { self.gameTitle.label.contains("Board 5") },
                      "the header should name the board, said \(gameTitle.label)")
        waitForLive()
        XCTAssertTrue(playerRows().contains { $0.label.contains("Mr_Bob") },
                      "the players should be the board's, rows read \(playerRows().map(\.label))")
    }

    // MARK: - Toasts

    /// `-demoAlert` enqueues two sample alerts four seconds after the game opens. Each holds the
    /// header for seven seconds, and the connection chip comes back once they are done.
    func testDemoAlertShowsTheToastChipAndThenGivesTheHeaderBack() {
        launch(["-open", "tv:blitz", "-demoAlert"])
        waitFor(gameSettingsButton)
        let toast = element(UIID.Game.toast)
        XCTAssertTrue(toast.waitForExistence(timeout: 12), "the demo alert should reach the header")
        XCTAssertTrue(toast.label.contains("Board 3"), "the first alert names board 3, said \(toast.label)")
        XCTAssertFalse(statusChip.exists, "the toast takes the chips' place while it shows")

        // The second alert replaces the first, and then the header goes back to the chips.
        XCTAssertTrue(waitUntil(14) { self.element(UIID.Game.toast).label.contains("Board 7")
                                      || !self.element(UIID.Game.toast).exists },
                      "the second alert should follow the first, header said \(toast.exists ? toast.label : "no toast")")
        XCTAssertTrue(waitUntil(22) { !self.element(UIID.Game.toast).exists },
                      "the toasts should clear out of the header")
        XCTAssertTrue(waitUntil(6) { self.statusChip.exists }, "the connection chip should come back")
    }
}
