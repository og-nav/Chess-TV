// App Store screenshots: walks the phone or iPad to each marketing screen under fixtures and
// writes a native-resolution PNG of the whole screen for each one.
//
// Not part of the hardening suite's assertions; scripts/app-store-screenshots.sh runs this class
// on its own and reads the files back. The directory comes from the CHESSTV_SHOTS environment
// variable (xcodebuild passes it as TEST_RUNNER_CHESSTV_SHOTS); without one the images land in
// the temporary directory under chesstv-shots.
import XCTest
#if canImport(UIKit)
import UIKit
#endif

final class ScreenshotUITests: UITestCase {

    /// The iPad is captured in landscape, the shape its game screen is built for (App Store
    /// Connect takes 2752×2064 for the 13-inch iPad); the phone stays portrait.
    override func setUpWithError() throws {
        try super.setUpWithError()
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
    }

    override func tearDownWithError() throws {
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .portrait
        }
        try super.tearDownWithError()
    }

    private let channel = ["-open", "tv:blitz"]
    private let arena = ["-open", "arena:FfsuUfQP"]
    private let board = ["-open", "board:q7gOEObq:oSiy8ZXF"]

    // MARK: - Writing

    private var outputDirectory: URL {
        let path = ProcessInfo.processInfo.environment["CHESSTV_SHOTS"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("chesstv-shots").path
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Settles, then writes the screen as `<name>.png`.
    private func snap(_ name: String, settle: TimeInterval = 1.0, file: StaticString = #filePath, line: UInt = #line) {
        pause(settle)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let directory = outputDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        do {
            try png.write(to: url)
        } catch {
            XCTFail("could not write \(url.path): \(error)", file: file, line: line)
        }
    }

    private func waitForEvaluation(file: StaticString = #filePath, line: UInt = #line) {
        let shown = waitUntil(40) { self.app.staticTexts[UIID.Game.evaluation].firstMatch.exists }
        XCTAssertTrue(shown, "the engine never put an evaluation on the screen", file: file, line: line)
        XCTAssertTrue(waitUntil(15) { self.moveCount() > 0 }, "the move list never filled", file: file, line: line)
    }

    // MARK: - The screens

    func testHome() {
        launch()
        waitFor(app.buttons[UIID.Home.event("q7gOEObq")], timeout: 25)
        waitFor(app.buttons[UIID.Home.arena("FfsuUfQP")], timeout: 15)
        snap("01-home", settle: 2.5)
    }

    func testBroadcastBoardWithEngine() {
        launch(board, engine: true)
        waitForLiveGame()
        waitForEvaluation()
        snap("02-game-broadcast", settle: 1.5)
    }

    func testChannelGameWithEngine() {
        launch(channel, engine: true)
        waitForLiveGame()
        waitForEvaluation()
        snap("03-game-blitz", settle: 1.5)
    }

    func testArenaStandings() {
        launch(arena, engine: true)
        waitForLiveGame()
        waitForEvaluation()
        let standings = app.staticTexts["Standings"]
        XCTAssertTrue(revealRow(standings), "the standings panel never came into view")
        XCTAssertTrue(waitUntil(15) { self.app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' points'")).count >= 5 })
        snap("04-arena-standings", settle: 1.5)
    }

    func testFollowing() {
        _ = allowSystemAlerts()
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
        back()
        waitFor(app.buttons[UIID.Boards.follow], timeout: 15).tap()
        waitForScreen("Tournament alerts")
        back()

        selectTab("Following")
        waitFor(app.navigationBars["Following"], timeout: 12)
        XCTAssertTrue(app.buttons[UIID.Following.row("game", "q7gOEObq/oSiy8ZXF")].waitForExistence(timeout: 15))
        // The sync footer is a container; its combined label says Synced once the server has it.
        let footer = app.descendants(matching: .any)[UIID.Following.syncLine]
        _ = waitUntil(15) { footer.exists && footer.label.contains("Synced") }
        snap("05-following", settle: 1.5)
    }

    func testSettings() {
        launch(["-open", "settings"])
        waitFor(app.switches[UIID.Settings.engine], timeout: 15)
        snap("06-settings")
    }

    /// Pins the broadcast board, which starts the Live Activity (and tells a paired Watch about
    /// the game), then captures the Dynamic Island on the Home Screen and the Lock Screen. Last in
    /// the alphabet so the locked device is the final state of the run.
    func testZLiveActivity() throws {
        _ = allowSystemAlerts()
        launch(board)
        waitForLiveGame()
        let pin = app.buttons[UIID.Game.pin]
        try XCTSkipUnless(pin.waitForExistence(timeout: 10), "Live Activities are not available here")
        XCTAssertTrue(revealRow(pin))
        pin.tap()
        // ActivityKit refuses with a permissions error when the app carries no entitlements, which
        // is what CODE_SIGNING_ALLOWED=NO produces; the screenshot script signs the build.
        try XCTSkipUnless(waitUntil(15) { self.app.buttons[UIID.Game.pin].label == "Unpin" },
                          "the pin did not take (\(pin.label)); build with code signing on for a Live Activity")
        pause(2)

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCUIDevice.shared.press(.home)
        pause(2.5)
        // A long press on the Dynamic Island opens the expanded view; if the island cannot be
        // found the compact one is what the picture shows.
        let island = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Avalanche' OR label CONTAINS 'Mr_Bob' OR identifier CONTAINS[c] 'island'"))
            .firstMatch
        if island.waitForExistence(timeout: 5), let frame = frame(of: island), frame.minY < 120 {
            island.press(forDuration: 1.0)
            pause(1.5)
        } else {
            // SpringBoard does not always expose the compact island as an accessibility node.
            // Its center is in the status-bar strip on the supported Pro Max capture device.
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.035)).press(forDuration: 1.0)
            pause(1.5)
        }
        snap("07-live-activity-island", settle: 1)
        // Fold it back so the Lock Screen starts clean.
        XCUIDevice.shared.press(.home)
        pause(1)

        // The lock button is not public API; `perform` is how every screenshot tool does it.
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        pause(1.5)
        // Wake the screen so the Lock Screen renders with the activity on it.
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        pause(2.5)
        // The first activity on a Lock Screen raises "Allow Live Activities from Chess TV?".
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 4) {
            allow.tap()
            pause(2)
        }
        snap("08-live-activity-lock", settle: 1)

        // Unlock again (the simulator has no passcode) so the next run starts on the Home Screen.
        springboard.swipeUp()
        pause(1)
        app.activate()
    }
}
