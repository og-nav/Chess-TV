import XCTest

/// Proves the harness: the app launches in fixture mode and the home shelves fill.
final class SmokeUITests: UITestCase {

    func testHomeShelvesFillFromFixtures() {
        let app = launch()
        waitFor(app.buttons[UIID.Home.channel("blitz")])
        waitFor(app.buttons[UIID.Home.event("q7gOEObq")])
        // A tab on the phone, a sidebar row on the iPad: this runs on both.
        XCTAssertTrue(app.tabBars.buttons["Following"].exists || app.cells.staticTexts["Following"].exists,
                      "no way to reach Following")
        XCTAssertNotNil(hitchReport(), "the app should have written a hitch report")
    }
}
