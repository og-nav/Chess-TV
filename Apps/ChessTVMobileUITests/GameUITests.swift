// The game screen: the header, the clocks, the move list, the scrubber, the engine, the follow
// controls, and the parts only an arena or only a broadcast board has.
import XCTest

final class GameUITests: UITestCase {

    private let channel = ["-open", "tv:blitz"]
    private let arena = ["-open", "arena:FfsuUfQP"]
    private let board = ["-open", "board:q7gOEObq:oSiy8ZXF"]

    // MARK: - The header and the clocks

    func testChannelGameGoesLive() {
        launch(channel)
        waitForScreen("Blitz \u{00B7} Lichess TV", timeout: 20)
        waitForLiveGame()
        XCTAssertEqual(gameStatus.label, "Live", "a streaming channel game should say just Live")
        XCTAssertTrue(app.staticTexts[UIID.Game.clock("white")].exists, "no white clock")
        XCTAssertTrue(app.staticTexts[UIID.Game.clock("black")].exists, "no black clock")
    }

    func testClocksTick() {
        launch(channel)
        waitForLiveGame()
        let white = app.staticTexts[UIID.Game.clock("white")]
        let black = app.staticTexts[UIID.Game.clock("black")]
        let before = [white.label, black.label]
        // One of the two is running; two seconds is four ticks of the slowest display.
        let moved = waitUntil(6) { [white.label, black.label] != before }
        XCTAssertTrue(moved, "neither clock moved in six seconds (still \(before))")
    }

    func testMoveListGrowsAsMovesArrive() {
        launch(channel)
        waitForLiveGame()
        XCTAssertTrue(waitUntil(15) { self.moveCount() > 0 }, "the move list never filled")
        let before = moveCount()
        XCTAssertTrue(waitForAnotherMove(from: before, timeout: 15), "the move list stayed at \(before) moves")
    }

    // MARK: - Flipping

    func testFlipTurnsTheBoardAndRelabelsItself() {
        launch(board)
        waitForLiveGame()
        let flip = waitFor(app.buttons[UIID.Game.flip])
        XCTAssertEqual(flip.label, "Watch as Black", "the board starts the right way up")
        let topLeft = topLeftSquare()
        XCTAssertTrue(topLeft.hasPrefix("a8"), "with White at the bottom the top-left square is a8, not \(topLeft)")

        flip.tap()
        XCTAssertTrue(waitUntil(6) { self.app.buttons[UIID.Game.flip].label == "Watch as White" }, "the flip button did not relabel itself")
        XCTAssertTrue(waitUntil(6) { self.topLeftSquare().hasPrefix("h1") }, "the board did not turn round (top-left is \(topLeftSquare()))")

        app.buttons[UIID.Game.flip].tap()
        XCTAssertTrue(waitUntil(6) { self.app.buttons[UIID.Game.flip].label == "Watch as Black" }, "the flip button did not come back")
        XCTAssertTrue(waitUntil(6) { self.topLeftSquare().hasPrefix("a8") }, "the board did not turn back")
    }

    // MARK: - Scrubbing

    func testScrubbingMovesThroughTheHistoryAndComesBackToLive() {
        launch(board)
        waitForLiveGame()
        XCTAssertTrue(waitUntil(15) { self.moveCount() > 2 }, "no history to scrub")

        let label = app.staticTexts[UIID.Game.scrubLabel]
        let previous = app.buttons[UIID.Game.scrubPrevious]
        let next = app.buttons[UIID.Game.scrubNext]
        let live = app.buttons[UIID.Game.scrubLive]

        XCTAssertTrue(label.label.contains("live"), "the label starts at the live position: \(label.label)")
        XCTAssertFalse(next.isEnabled, "Next is meaningless while the board is live")
        XCTAssertFalse(live.isEnabled, "Live is meaningless while the board is live")
        XCTAssertTrue(previous.isEnabled, "Previous should be available with a history")

        previous.tap()
        XCTAssertTrue(waitUntil(6) { !label.label.contains("live") }, "Previous did not leave the live position")
        let firstStop = label.label
        XCTAssertTrue(next.isEnabled, "Next should be available once the board is behind")
        XCTAssertTrue(live.isEnabled, "Live should be available once the board is behind")

        previous.tap()
        XCTAssertTrue(waitUntil(6) { label.label != firstStop }, "a second Previous did not move again")
        let secondStop = label.label

        next.tap()
        XCTAssertTrue(waitUntil(6) { label.label != secondStop }, "Next did not move forward")

        live.tap()
        XCTAssertTrue(waitUntil(6) { label.label.contains("live") }, "Live did not return to the live position")
        XCTAssertFalse(live.isEnabled, "Live is disabled again once the board is live")
    }

    func testTappingAMoveSelectsItAndLiveReturns() {
        launch(board)
        waitForLiveGame()
        XCTAssertTrue(waitUntil(15) { self.moveCount() > 2 }, "no moves to tap")
        let moves = moveButtons()
        guard let move = moves.last(where: { isOnScreen($0) }) ?? moves.last else {
            return XCTFail("no move buttons")
        }
        let name = move.label
        move.tap()
        let label = app.staticTexts[UIID.Game.scrubLabel]
        XCTAssertTrue(waitUntil(6) { !label.label.contains("live") }, "tapping \(name) did not scrub anywhere")
        XCTAssertTrue(app.buttons[UIID.Game.scrubLive].isEnabled)
        app.buttons[UIID.Game.scrubLive].tap()
        XCTAssertTrue(waitUntil(6) { label.label.contains("live") }, "Live did not return after a move was tapped")
    }

    // MARK: - The engine

    func testEngineOnShowsAnEvaluationAndTheButtonSaysSo() {
        launch(board, engine: true)
        waitForLiveGame()
        let engine = waitFor(app.buttons[UIID.Game.engine])
        XCTAssertEqual(engine.label, "Engine on")
        XCTAssertTrue(app.staticTexts[UIID.Game.evaluation].firstMatch.waitForExistence(timeout: 20), "Stockfish never published an evaluation")
        engine.tap()
        XCTAssertTrue(waitUntil(8) { self.app.buttons[UIID.Game.engine].label == "Engine off" }, "the engine button did not relabel")
        XCTAssertTrue(waitUntil(8) { !self.app.staticTexts[UIID.Game.evaluation].firstMatch.exists }, "the evaluation stayed after the engine was turned off")
        app.buttons[UIID.Game.engine].tap()
        XCTAssertTrue(waitUntil(8) { self.app.buttons[UIID.Game.engine].label == "Engine on" }, "the engine button did not come back on")
    }

    func testEngineOffLeavesNoEvaluation() {
        launch(board)
        waitForLiveGame()
        XCTAssertEqual(waitFor(app.buttons[UIID.Game.engine]).label, "Engine off")
        XCTAssertFalse(app.staticTexts[UIID.Game.evaluation].firstMatch.exists, "there should be no evaluation with the engine off")
    }

    // MARK: - Links and follows

    func testBroadcastBoardOffersTheLichessLinkAndThePin() {
        launch(board)
        waitForLiveGame()
        XCTAssertTrue(waitFor(app.buttons[UIID.Game.lichess]).isEnabled, "no Open on lichess.org link")
        XCTAssertEqual(app.buttons[UIID.Game.lichess].label, "Open on lichess.org")
        // Pinning is only offered for a broadcast board, and only while Live Activities are on.
        // It is not tapped here: the Lock Screen is not this suite's business.
        XCTAssertTrue(app.buttons[UIID.Game.pin].exists, "a broadcast board can be pinned")
    }

    func testChannelGameOffersTheLichessLink() {
        launch(channel)
        waitForLiveGame()
        XCTAssertTrue(app.buttons[UIID.Game.lichess].waitForExistence(timeout: 15), "a channel game names a Lichess game, so the link belongs")
    }

    func testBothPlayerBellsOpenTheFollowDetail() {
        allowSystemAlerts()
        launch(board)
        waitForLiveGame()
        for colour in ["white", "black"] {
            let bell = app.buttons[UIID.Game.playerBell(colour)]
            XCTAssertTrue(bell.waitForExistence(timeout: 15), "the \(colour) player has no bell")
            bell.tap()
            dismissPermissionAlert()
            waitForScreen("Player alerts")
            XCTAssertTrue(app.switches[UIID.FollowDetail.toggle("start")].waitForExistence(timeout: 8), "no alert switches on the player follow")
            XCTAssertTrue(app.buttons[UIID.FollowDetail.unfollow].exists, "no Unfollow on the player follow")
            back()
            XCTAssertTrue(waitUntil(10) { self.gameStatus.exists }, "Back did not return to the board")
        }
    }

    func testFollowButtonCreatesAFollowAndOpensIt() {
        allowSystemAlerts()
        launch(board)
        waitForLiveGame()
        let follow = waitFor(app.buttons[UIID.Game.follow])
        XCTAssertEqual(follow.label, "Follow")
        follow.tap()
        dismissPermissionAlert()
        waitForScreen("Game alerts")
        XCTAssertTrue(app.switches[UIID.FollowDetail.toggle("end")].waitForExistence(timeout: 8))
        back()
        XCTAssertTrue(waitUntil(10) { self.app.buttons[UIID.Game.follow].label == "Following" }, "the toolbar button should say Following afterwards")
        // A second tap opens the same follow rather than making another.
        app.buttons[UIID.Game.follow].tap()
        waitForScreen("Game alerts")
    }

    func testChannelFollowExplainsItselfAndTheAlertDismisses() {
        launch(channel)
        waitForLiveGame()
        let follow = waitFor(app.buttons[UIID.Game.follow])
        follow.tap()
        let alert = app.alerts["Can\u{2019}t follow this"]
        XCTAssertTrue(alert.waitForExistence(timeout: 8), "a channel is not followable, so it owes an explanation")
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'different game'")).count > 0,
                      "the alert should say why: \(alert.staticTexts.allElementsBoundByIndex.map { $0.label })")
        alert.buttons["OK"].tap()
        XCTAssertTrue(waitUntil(6) { !alert.exists }, "OK did not dismiss the alert")
        XCTAssertTrue(gameStatus.exists, "the game screen should still be there")
    }

    func testArenaFollowExplainsItself() {
        launch(arena)
        waitForLiveGame()
        waitFor(app.buttons[UIID.Game.follow]).tap()
        let alert = app.alerts["Can\u{2019}t follow this"]
        XCTAssertTrue(alert.waitForExistence(timeout: 8), "an arena is not followable either")
        alert.buttons["OK"].tap()
        XCTAssertTrue(waitUntil(6) { !alert.exists })
    }

    // MARK: - Arena extras

    func testArenaShowsStandingsAndACountdown() {
        launch(arena)
        waitForLiveGame()
        XCTAssertTrue(gameStatus.label.contains("Ends in"), "an arena's header carries the countdown: \(gameStatus.label)")
        let standings = app.staticTexts["Standings"]
        XCTAssertTrue(revealRow(standings), "the standings panel never came into view")
        let rows = app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' points'")).count
        XCTAssertGreaterThanOrEqual(rows, 5, "the arena standings should list the leaders")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'players'")).count > 0, "the standings say how many are playing")
    }
}
