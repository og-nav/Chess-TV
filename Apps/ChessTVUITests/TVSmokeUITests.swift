import XCTest

/// Proves the harness: the app launches in fixture mode, the shelves fill, the remote moves focus.
final class TVSmokeUITests: TVUITestCase {

    func testHomeShelvesFillAndRemoteMovesFocus() {
        let app = launch()
        let blitz = waitFor(app.buttons[UIID.Home.channel("blitz")])
        waitFor(app.buttons[UIID.Home.event("q7gOEObq")])
        focus(blitz, pressing: .right)
        XCTAssertTrue(blitz.hasFocus)
        XCTAssertNotNil(hitchReport(), "the app should have written a hitch report")
    }
}
