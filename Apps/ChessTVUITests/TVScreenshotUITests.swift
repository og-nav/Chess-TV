// App Store screenshots for the Apple TV: lands on each marketing screen under fixtures and writes
// a native-resolution PNG of the screen. Run by scripts/app-store-screenshots.sh; the directory
// comes from CHESSTV_SHOTS (TEST_RUNNER_CHESSTV_SHOTS on the xcodebuild line).
import XCTest

final class TVScreenshotUITests: TVUITestCase {

    private var outputDirectory: URL {
        let path = ProcessInfo.processInfo.environment["CHESSTV_SHOTS"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("chesstv-shots").path
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func snap(_ name: String, settle: TimeInterval = 1.0, file: StaticString = #filePath, line: UInt = #line) {
        RunLoop.current.run(until: Date().addingTimeInterval(settle))
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

    private func waitForEvaluationAndMoves(file: StaticString = #filePath, line: UInt = #line) {
        // The TV's evaluation row carries no identifier; "Stockfish 19 · depth N" under it is the
        // sign the engine has spoken.
        let depth = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'depth'")).firstMatch
        XCTAssertTrue(waitUntil(60) { depth.exists }, "no evaluation appeared", file: file, line: line)
        XCTAssertTrue(waitUntil(15) { self.latestMoveNumber() != nil }, "the move list never filled", file: file, line: line)
    }

    func testHome() {
        launch()
        waitFor(channelCard(TVFixture.channels[0]), timeout: 25)
        waitFor(eventCard(TVFixture.liveEvent), timeout: 20)
        snap("01-home", settle: 3)
    }

    func testChannelGameWithEngine() {
        launch(["-open", "tv:blitz"], engine: true)
        waitForLive()
        waitForEvaluationAndMoves()
        snap("02-game-blitz", settle: 1.5)
    }

    func testBoardList() {
        launch(["-open", "boards:\(TVFixture.roundId)"])
        waitFor(boardCard(TVFixture.ongoingBoard), timeout: 25)
        snap("03-boards", settle: 2.5)
    }

    func testArenaStandings() {
        launch(["-open", "arena:FfsuUfQP"], engine: true)
        waitForLive()
        waitForEvaluationAndMoves()
        XCTAssertTrue(waitUntil(15) { self.element(UIID.Game.standingsRow(1)).exists }, "the standings never filled")
        snap("04-arena-standings", settle: 1.5)
    }

    func testSettings() {
        launch(["-showSettings"])
        waitFor(doneButton)
        snap("05-settings", settle: 2)
    }
}
