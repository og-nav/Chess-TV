// The boards wall of a round, and the round list of an event.
import XCTest

final class TournamentAndBoardsUITests: UITestCase {

    /// The five boards of the fixture round, ongoing first, with the number each carries.
    private let ongoing = "oSiy8ZXF"
    private let finished = ["ZD7czPL6", "M5p5sGuJ", "0d0Ct9qf", "Nsd4qTwD"]

    private func launchBoards() {
        launch(["-open", "boards:q7gOEObq"])
        waitFor(app.buttons[UIID.Boards.card(ongoing)], timeout: 25)
    }

    private func cards() -> [XCUIElement] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'boards.card.'")).allElementsBoundByIndex
    }

    // MARK: - The wall

    func testFiveBoardsWithTheOngoingOneFirst() {
        launchBoards()
        XCTAssertTrue(waitUntil(15) { self.cards().count == 5 }, "expected five boards, found \(cards().count)")
        XCTAssertEqual(cards().first?.identifier, UIID.Boards.card(ongoing), "the board still being played comes first")
        XCTAssertTrue(cards().first?.label.contains("in progress") == true, "the first board should say it is in progress")
        for id in finished {
            XCTAssertTrue(app.buttons[UIID.Boards.card(id)].exists, "board \(id) is missing")
        }
        XCTAssertTrue(app.staticTexts["5 boards"].exists, "the header should count the boards")
    }

    func testEveryBoardOpensTheGameAndBackReturns() {
        launchBoards()
        XCTAssertTrue(waitUntil(15) { self.cards().count == 5 })
        for id in [ongoing] + finished {
            let card = app.buttons[UIID.Boards.card(id)]
            XCTAssertTrue(revealRow(card), "could not reach board \(id)")
            card.tap()
            XCTAssertTrue(waitUntil(20) { self.screenTitle.contains("Round 21") }, "board \(id) opened as '\(screenTitle)'")
            XCTAssertTrue(waitFor(gameStatus, timeout: 20).exists)
            XCTAssertTrue(app.buttons[UIID.Game.flip].exists, "board \(id) opened without controls")
            back()
            XCTAssertTrue(waitUntil(12) { self.app.buttons[UIID.Boards.card(self.ongoing)].exists }, "Back did not return to the wall from \(id)")
        }
    }

    func testWallToolbarFollowsTheEventAndListsItsRounds() {
        allowSystemAlerts()
        launchBoards()
        let follow = waitFor(app.buttons[UIID.Boards.follow])
        XCTAssertEqual(follow.label, "Follow")
        follow.tap()
        dismissPermissionAlert()
        waitForScreen("Tournament alerts")
        XCTAssertTrue(app.switches[UIID.FollowDetail.toggle("roundLive")].waitForExistence(timeout: 8), "a tournament follow offers the event switches")
        back()
        XCTAssertTrue(waitUntil(10) { self.app.buttons[UIID.Boards.follow].label == "Following" }, "the wall's Follow button should change")

        waitFor(app.buttons[UIID.Boards.allRounds]).tap()
        XCTAssertTrue(app.buttons[UIID.Tournament.round("q7gOEObq")].waitForExistence(timeout: 20), "All rounds listed nothing")
    }

    func testPullToRefreshLeavesTheGridIntact() {
        launchBoards()
        XCTAssertTrue(waitUntil(15) { self.cards().count == 5 })
        app.scrollViews.firstMatch.swipeDown(velocity: .slow)
        pause(2)
        XCTAssertTrue(waitUntil(20) { self.cards().count == 5 }, "the grid lost boards after a refresh: \(cards().count)")
        XCTAssertEqual(cards().first?.identifier, UIID.Boards.card(ongoing), "the ongoing board should still lead after a refresh")
        // And it still opens.
        let card = app.buttons[UIID.Boards.card(ongoing)]
        XCTAssertTrue(revealRow(card))
        card.tap()
        XCTAssertTrue(waitFor(gameStatus, timeout: 20).exists)
    }

    // MARK: - The rounds

    func testRoundsScreenListsEveryRoundWithItsStatus() {
        launch(["-open", "tour:L2ydImaD"])
        let live = waitFor(app.buttons[UIID.Tournament.round("q7gOEObq")], timeout: 25)
        let first = app.buttons[UIID.Tournament.round("fixtureR1")]
        let third = app.buttons[UIID.Tournament.round("fixtureR3")]
        XCTAssertTrue(first.exists, "the finished round is missing")
        XCTAssertTrue(third.exists, "the round that has not started is missing")
        XCTAssertTrue(first.label.contains("Finished"), "round 20 is finished: \(first.label)")
        XCTAssertTrue(live.label.contains("Live"), "round 21 is live: \(live.label)")
        XCTAssertTrue(third.label.contains("Tomorrow"), "round 22 is tomorrow: \(third.label)")
    }

    func testEveryRoundOpensItsBoardsWall() {
        launch(["-open", "tour:L2ydImaD"])
        waitFor(app.buttons[UIID.Tournament.round("q7gOEObq")], timeout: 25)
        for round in ["fixtureR1", "q7gOEObq", "fixtureR3"] {
            let row = app.buttons[UIID.Tournament.round(round)]
            XCTAssertTrue(revealRow(row), "could not reach round \(round)")
            row.tap()
            XCTAssertTrue(app.buttons[UIID.Boards.card(ongoing)].waitForExistence(timeout: 25), "round \(round) opened no boards")
            back()
            XCTAssertTrue(waitUntil(12) { self.app.buttons[UIID.Tournament.round("q7gOEObq")].exists }, "Back did not return to the rounds from \(round)")
        }
    }

    func testRoundsScreenFollowsTheEvent() {
        allowSystemAlerts()
        launch(["-open", "tour:L2ydImaD"])
        let follow = waitFor(app.buttons[UIID.Tournament.follow], timeout: 25)
        follow.tap()
        dismissPermissionAlert()
        waitForScreen("Tournament alerts")
        back()
        XCTAssertTrue(waitUntil(10) { self.app.buttons[UIID.Tournament.follow].label == "Following" })
    }
}
