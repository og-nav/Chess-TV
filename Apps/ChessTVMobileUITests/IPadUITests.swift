// The iPad shape: a sidebar and a detail pane instead of a tab bar, and a game screen wide enough
// for the side panel.
//
// Run with IOS_SIM_ID pointing at an iPad (scripts/test-ui-ios.sh reads it). On a phone these
// skip themselves rather than assert about a layout that is not there.
import XCTest
#if canImport(UIKit)
import UIKit
#endif

final class IPadUITests: UITestCase {

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        try super.tearDownWithError()
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the split-view layout only exists on iPad")
    }

    func testSidebarListsTheThreeSectionsAndOpensThem() {
        launch()
        waitFor(app.buttons[UIID.Home.event("q7gOEObq")], timeout: 25)
        XCTAssertTrue(app.tabBars.buttons["Watch"].exists == false, "the iPad uses a sidebar, not a tab bar")
        for row in ["Watch", "Following", "Settings"] {
            XCTAssertTrue(app.cells.staticTexts[row].exists || app.staticTexts[row].exists, "the sidebar should list \(row)")
        }
        selectTab("Following")
        XCTAssertTrue(waitUntil(15) { self.app.buttons[UIID.Following.browse].exists }, "Following did not open in the detail pane")
        selectTab("Settings")
        XCTAssertTrue(waitUntil(15) { self.app.switches[UIID.Settings.engine].exists }, "Settings did not open in the detail pane")
        selectTab("Watch")
        XCTAssertTrue(waitUntil(15) { self.app.buttons[UIID.Home.event("q7gOEObq")].exists }, "Watch did not come back")
    }

    /// Portrait on an 11-inch iPad leaves the detail pane under the 700-point threshold, so the
    /// game is a column there and only landscape gets the side panel. Both shapes are checked.
    func testAGameOnTheIPadIsAColumnInPortraitAndAPanelInLandscape() {
        launch(["-open", "board:q7gOEObq:oSiy8ZXF"])
        waitForLiveGame(timeout: 30)
        let board = app.otherElements[UIID.Game.board].firstMatch
        let moves = app.scrollViews[UIID.Game.moveList]
        XCTAssertTrue(moves.waitForExistence(timeout: 15), "no move list")
        if let boardFrame = frame(of: board), let panel = frame(of: moves) {
            XCTAssertGreaterThan(panel.midY, boardFrame.midY, "in portrait the move list sits under the board")
        }
        XCTAssertTrue(app.staticTexts[UIID.Game.clock("white")].exists)
        XCTAssertTrue(app.staticTexts[UIID.Game.clock("black")].exists)

        XCUIDevice.shared.orientation = .landscapeLeft
        pause(3)
        XCTAssertTrue(moves.waitForExistence(timeout: 15), "the move list should follow into landscape")
        if let boardFrame = frame(of: board), let panel = frame(of: moves) {
            XCTAssertGreaterThan(panel.midX, boardFrame.maxX, "landscape is wide enough for the panel to sit beside the board")
        }
        let flip = waitFor(app.buttons[UIID.Game.flip])
        flip.tap()
        XCTAssertTrue(waitUntil(8) { self.app.buttons[UIID.Game.flip].label == "Watch as White" }, "flipping works on the iPad")
        XCTAssertTrue(waitUntil(8) { self.topLeftSquare().hasPrefix("h1") }, "the board turns on the iPad")
    }

    func testBoardsWallFitsMoreColumnsOnTheIPad() {
        launch(["-open", "boards:q7gOEObq"])
        waitFor(app.buttons[UIID.Boards.card("oSiy8ZXF")], timeout: 30)
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'boards.card.'")).allElementsBoundByIndex
        XCTAssertEqual(cards.count, 5, "all five boards")
        // The adaptive grid should give an iPad more than the phone's two columns.
        let rows = Set(cards.compactMap { frame(of: $0).map { Int($0.midY / 50) } })
        XCTAssertLessThanOrEqual(rows.count, 2, "five boards should need at most two rows on an iPad")
    }
}
