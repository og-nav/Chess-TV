// Following: what is on the list, what each row does, and whether a switch survives the trip.
import XCTest

final class FollowingUITests: UITestCase {

    private let board = ["-open", "board:q7gOEObq:oSiy8ZXF"]
    private let gameRow = UIID.Following.row("game", "q7gOEObq/oSiy8ZXF")
    private let gameAlerts = UIID.Following.alerts("game", "q7gOEObq/oSiy8ZXF")
    private let playerRow = UIID.Following.row("player", "1503014")
    private let tournamentRow = UIID.Following.row("tournament", "L2ydImaD")

    // MARK: - Empty

    func testEmptyStateOffersTheWayOut() {
        launch(["-open", "following"])
        let browse = waitFor(app.buttons[UIID.Following.browse], timeout: 20)
        XCTAssertTrue(app.staticTexts["Nothing followed yet"].exists, "the empty state should say so")
        browse.tap()
        XCTAssertTrue(waitUntil(10) { self.app.navigationBars["Watch"].exists }, "Browse events should move to the Watch tab")
    }

    // MARK: - Making the three kinds of follow

    /// Follows the board, its white player and the event, from the one screen each is offered on.
    private func followEverything() {
        allowSystemAlerts()
        launch(board)
        waitForLiveGame()

        waitFor(app.buttons[UIID.Game.follow]).tap()
        dismissPermissionAlert()
        waitForScreen("Game alerts")
        back()

        waitFor(app.buttons[UIID.Game.playerBell("white")]).tap()
        waitForScreen("Player alerts")
        back()

        XCTAssertTrue(waitUntil(10) { self.gameStatus.exists })
        back()   // to the boards wall, which is where the event is followed
        waitFor(app.buttons[UIID.Boards.follow], timeout: 15).tap()
        waitForScreen("Tournament alerts")
        back()
    }

    func testTheThreeKindsLandInTheirOwnSections() {
        followEverything()
        selectTab("Following")
        waitFor(app.navigationBars["Following"], timeout: 12)
        XCTAssertTrue(app.buttons[gameRow].waitForExistence(timeout: 15), "the board follow is not listed")
        XCTAssertTrue(app.buttons[playerRow].exists, "the player follow is not listed")
        XCTAssertTrue(app.buttons[tournamentRow].exists, "the event follow is not listed")
        XCTAssertTrue(app.staticTexts["Players and games"].exists, "the board-shaped section is missing")
        XCTAssertTrue(app.staticTexts["Tournaments"].exists, "the tournament section is missing")
        // A player and a game are board-shaped, so they share the first section, above Tournaments.
        if let players = frame(of: app.staticTexts["Players and games"]), let tournaments = frame(of: app.staticTexts["Tournaments"]) {
            XCTAssertLessThan(players.midY, tournaments.midY, "players and games come first")
        }
        XCTAssertTrue(app.buttons[gameRow].label.contains("Mr_Bob"), "a board row names its players: \(app.buttons[gameRow].label)")
    }

    func testSyncFooterSaysSynced() {
        followEverything()
        selectTab("Following")
        waitFor(app.navigationBars["Following"], timeout: 12)
        let synced = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Synced'"))
        XCTAssertTrue(waitUntil(20) { synced.count > 0 }, "the footer never said it had synced")
        XCTAssertTrue(app.otherElements[UIID.Following.syncLine].exists, "the sync line should be one element")
    }

    // MARK: - What a row does

    func testRowsOpenWhatTheyFollowAndBellsOpenTheAlerts() {
        followEverything()
        // Home is where the shelves load, and the player row needs a live board to open.
        selectTab("Watch")
        waitFor(app.buttons[UIID.Home.event("q7gOEObq")], timeout: 20)
        selectTab("Following")
        waitFor(app.buttons[gameRow], timeout: 15)

        app.buttons[gameRow].tap()
        XCTAssertTrue(waitUntil(20) { self.gameStatus.exists }, "the board row did not open the board")
        selectTab("Following")

        waitFor(app.buttons[tournamentRow], timeout: 12).tap()
        XCTAssertTrue(app.buttons[UIID.Tournament.round("q7gOEObq")].waitForExistence(timeout: 20), "the event row did not open the rounds")
        selectTab("Following")

        waitFor(app.buttons[playerRow], timeout: 12).tap()
        XCTAssertTrue(waitUntil(20) { self.gameStatus.exists }, "the player row did not open the board they are playing")
        selectTab("Following")

        waitFor(app.buttons[gameAlerts], timeout: 12).tap()
        waitForScreen("Game alerts")
        XCTAssertTrue(app.switches[UIID.FollowDetail.toggle("start")].waitForExistence(timeout: 8))
    }

    // MARK: - The switches

    func testEveryAlertControlFlipsAndSurvivesTheTrip() {
        followEverything()
        selectTab("Following")
        waitFor(app.buttons[gameAlerts], timeout: 15).tap()
        waitForScreen("Game alerts")

        // Every switch flips, and the pickers only exist while their switch is on.
        set(UIID.FollowDetail.toggle("move"), to: true)
        XCTAssertTrue(app.buttons[UIID.FollowDetail.moveInterval].waitForExistence(timeout: 6), "the move-interval picker belongs with the move switch")
        set(UIID.FollowDetail.toggle("longThink"), to: true)
        XCTAssertTrue(app.buttons[UIID.FollowDetail.longThink].waitForExistence(timeout: 6), "the long-think picker belongs with its switch")
        set(UIID.FollowDetail.toggle("start"), to: false)
        set(UIID.FollowDetail.toggle("end"), to: false)

        choose("At most every 5 min", in: UIID.FollowDetail.moveInterval)
        choose("20 min", in: UIID.FollowDetail.longThink)

        set(UIID.FollowDetail.toggle("move"), to: false)
        XCTAssertTrue(waitUntil(6) { !self.app.buttons[UIID.FollowDetail.moveInterval].exists }, "the interval picker should go with the switch")
        set(UIID.FollowDetail.toggle("move"), to: true)

        // Back and in again: the store is the only copy, so this is not a re-read of local state.
        back()
        waitFor(app.buttons[gameAlerts], timeout: 12).tap()
        waitForScreen("Game alerts")
        assertAlertsAsEdited("after Back")

        // And again after the app has been restarted with its files kept.
        app.terminate()
        launch(["-open", "following"], keepState: true)
        waitFor(app.buttons[gameAlerts], timeout: 20).tap()
        waitForScreen("Game alerts")
        assertAlertsAsEdited("after a relaunch")
    }

    private func assertAlertsAsEdited(_ when: String) {
        XCTAssertFalse(isOn(UIID.FollowDetail.toggle("start")), "Game starts should still be off \(when)")
        XCTAssertTrue(isOn(UIID.FollowDetail.toggle("move")), "Every move should still be on \(when)")
        XCTAssertTrue(isOn(UIID.FollowDetail.toggle("longThink")), "Long think should still be on \(when)")
        XCTAssertFalse(isOn(UIID.FollowDetail.toggle("end")), "Game ends should still be off \(when)")
        XCTAssertEqual(pickerValue(UIID.FollowDetail.moveInterval), "At most every 5 min", "the interval should have stuck \(when)")
        XCTAssertEqual(pickerValue(UIID.FollowDetail.longThink), "20 min", "the long-think threshold should have stuck \(when)")
    }

    func testTournamentAlertsOfferTheEventSwitchesAndTheirPickers() {
        followEverything()
        selectTab("Following")
        let bell = UIID.Following.alerts("tournament", "L2ydImaD")
        waitFor(app.buttons[bell], timeout: 15).tap()
        waitForScreen("Tournament alerts")
        for alert in ["startingSoon", "roundLive", "gameResults", "roundSummary", "finished", "topBoardMoves"] {
            XCTAssertTrue(revealRow(app.switches[UIID.FollowDetail.toggle(alert)]), "no switch for \(alert)")
        }
        set(UIID.FollowDetail.toggle("startingSoon"), to: true)
        XCTAssertTrue(app.buttons[UIID.FollowDetail.startingSoon].waitForExistence(timeout: 6), "the heads-up picker belongs with Round starting soon")
        choose("30 min before", in: UIID.FollowDetail.startingSoon)
        set(UIID.FollowDetail.toggle("gameResults"), to: true)
        XCTAssertTrue(revealRow(app.buttons[UIID.FollowDetail.topBoards]), "the boards-watched picker belongs with Results")
        choose("Top 3 boards", in: UIID.FollowDetail.topBoards)
        set(UIID.FollowDetail.toggle("topBoardMoves"), to: true)
        XCTAssertTrue(revealRow(app.buttons[UIID.FollowDetail.moveInterval]), "the move-interval picker belongs with the noisy switch")
    }

    // MARK: - Unfollowing

    func testUnfollowFromTheDetailRemovesTheRow() {
        followEverything()
        selectTab("Following")
        waitFor(app.buttons[gameAlerts], timeout: 15).tap()
        waitForScreen("Game alerts")
        XCTAssertTrue(revealRow(app.buttons[UIID.FollowDetail.unfollow]))
        app.buttons[UIID.FollowDetail.unfollow].tap()
        XCTAssertTrue(waitUntil(12) { !self.app.buttons[self.gameRow].exists }, "the row stayed after Unfollow")
        XCTAssertTrue(app.buttons[playerRow].exists, "unfollowing the board should leave the player alone")
    }

    func testSwipeActionsOpenAlertsAndUnfollow() {
        followEverything()
        selectTab("Following")
        let row = waitFor(app.buttons[playerRow], timeout: 15)

        row.swipeRight()
        let alerts = app.buttons["Alerts"]
        XCTAssertTrue(alerts.waitForExistence(timeout: 6), "swiping right offers Alerts")
        alerts.tap()
        waitForScreen("Player alerts")
        back()

        let target = waitFor(app.buttons[playerRow], timeout: 12)
        target.swipeLeft()
        let unfollow = app.buttons["Unfollow"]
        XCTAssertTrue(unfollow.waitForExistence(timeout: 6), "swiping left offers Unfollow")
        unfollow.tap()
        XCTAssertTrue(waitUntil(12) { !self.app.buttons[self.playerRow].exists }, "the row stayed after the swipe unfollowed it")
    }
}
