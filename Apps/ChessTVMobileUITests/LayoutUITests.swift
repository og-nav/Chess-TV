// The two layouts the game screen has, and the largest type it has to survive.
import XCTest

final class LayoutUITests: UITestCase {

    private let board = ["-open", "board:q7gOEObq:oSiy8ZXF"]

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        try super.tearDownWithError()
    }

    /// Landscape on a phone is wide enough for the side panel, which is the iPad and TV layout.
    func testLandscapePutsThePanelBesideTheBoard() {
        launch(board)
        waitForLiveGame()
        XCUIDevice.shared.orientation = .landscapeLeft
        pause(2)

        let moves = app.scrollViews[UIID.Game.moveList]
        XCTAssertTrue(moves.waitForExistence(timeout: 12), "the move list should follow the board into landscape")
        if let board = frame(of: app.otherElements[UIID.Game.board].firstMatch), let panel = frame(of: moves) {
            XCTAssertGreaterThan(panel.midX, board.midX, "in landscape the panel sits to the right of the board")
        }
        XCTAssertTrue(app.staticTexts[UIID.Game.clock("white")].exists, "both clocks in landscape")
        XCTAssertTrue(app.staticTexts[UIID.Game.clock("black")].exists, "both clocks in landscape")

        let flip = waitFor(app.buttons[UIID.Game.flip])
        XCTAssertEqual(flip.label, "Watch as Black")
        flip.tap()
        XCTAssertTrue(waitUntil(8) { self.app.buttons[UIID.Game.flip].label == "Watch as White" }, "flipping should work in landscape too")
        XCTAssertTrue(waitUntil(8) { self.topLeftSquare().hasPrefix("h1") }, "the board should turn in landscape (top-left \(topLeftSquare()))")

        XCUIDevice.shared.orientation = .portrait
        pause(2)
        XCTAssertTrue(waitUntil(12) { self.app.buttons[UIID.Game.flip].exists }, "the controls should come back in portrait")
        XCTAssertTrue(app.staticTexts[UIID.Game.clock("white")].exists, "the clocks should come back in portrait")
    }

    /// The whole screen at an accessibility type size: nothing that matters may be dropped.
    func testLargeDynamicTypeKeepsTheClocksAndTheScrubBar() {
        launch(board + ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        waitForLiveGame(timeout: 30)
        XCTAssertTrue(app.staticTexts[UIID.Game.clock("white")].exists, "the white clock is not optional at any type size")
        XCTAssertTrue(app.staticTexts[UIID.Game.clock("black")].exists, "the black clock is not optional at any type size")
        for control in [UIID.Game.scrubPrevious, UIID.Game.scrubLabel, UIID.Game.scrubNext, UIID.Game.scrubLive] {
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: control).count > 0, "\(control) went missing at accessibility L")
        }
        // And the controls under it still work.
        let flip = app.buttons[UIID.Game.flip]
        XCTAssertTrue(revealRow(flip), "the flip button should be reachable by scrolling")
        flip.tap()
        XCTAssertTrue(waitUntil(8) { self.app.buttons[UIID.Game.flip].label == "Watch as White" }, "flip at accessibility L")
    }

    /// Home at an accessibility type size. Only the event shelf is driven: at this size a channel
    /// card is most of the screen, and scrolling a sideways shelf of them costs XCTest more time
    /// than the rest of this file put together. What matters here is that the shelves are still
    /// there and a card still opens what it says it opens.
    func testLargeDynamicTypeKeepsTheHomeShelvesUsable() {
        launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        let event = waitFor(app.buttons[UIID.Home.event("q7gOEObq")], timeout: 30)
        XCTAssertTrue(app.staticTexts["Events"].exists, "the Events shelf should still have its heading")
        XCTAssertTrue(app.buttons[UIID.Home.eventRounds("q7gOEObq")].exists, "the All rounds button should still be there")
        XCTAssertTrue(isOnScreen(event), "the first event card should still fit on screen at accessibility L")
        event.tap()
        XCTAssertTrue(app.buttons[UIID.Boards.card("oSiy8ZXF")].waitForExistence(timeout: 30), "the wall did not open at accessibility L")
        back()
        XCTAssertTrue(waitUntil(15) { self.app.navigationBars["Watch"].exists })
    }
}
