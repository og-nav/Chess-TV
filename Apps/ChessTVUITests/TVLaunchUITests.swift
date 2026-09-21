// Every `-open` form lands on the screen it names, and a value the app cannot parse lands on home
// rather than on nothing.
import XCTest

final class TVLaunchUITests: TVUITestCase {

    func testOpenChannelLandsOnTheGame() {
        launch(["-open", "tv:rapid"])
        waitFor(gameSettingsButton)
        XCTAssertTrue(waitUntil(15) { self.gameTitle.exists && self.gameTitle.label.contains("Rapid") },
                      "the header should name the channel, said \(gameTitle.exists ? gameTitle.label : "nothing")")
        XCTAssertFalse(homeSettingsButton.exists, "the home screen should be underneath, not on top")
    }

    func testOpenArenaLandsOnTheArenaGame() {
        launch(["-open", "arena:FfsuUfQP"])
        waitFor(gameSettingsButton)
        XCTAssertTrue(waitUntil(20) { self.gameTitle.label.contains("Arena") },
                      "the header should name the arena, said \(gameTitle.label)")
        waitForLive()
    }

    func testOpenBoardLandsOnTheBoardWithTheListBehindIt() {
        launch(["-open", "board:\(TVFixture.roundId):\(TVFixture.ongoingBoard)"])
        waitFor(gameSettingsButton)
        XCTAssertTrue(waitUntil(20) { self.gameTitle.label.contains("Board 5") },
                      "the header should name the board, said \(gameTitle.label)")
        // The stack was built as list-then-board, so one Back lands on the list.
        press(.menu, settle: 1.0)
        waitFor(boardCard(TVFixture.ongoingBoard))
    }

    func testOpenBoardsLandsOnTheBoardList() {
        launch(["-open", "boards:\(TVFixture.roundId)"])
        for board in TVFixture.boards {
            waitFor(boardCard(board.id), timeout: 20)
        }
        XCTAssertFalse(gameSettingsButton.exists, "the list should be on top, not a game")
    }

    func testShowSettingsLandsOnSettings() {
        launch(["-showSettings"])
        waitFor(doneButton)
        XCTAssertTrue(app.buttons[UIID.Settings.theme("Sage")].exists)
    }

    func testAnUnparseableOpenLandsOnHome() {
        launch(["-open", "nonsense:not-a-thing"])
        waitFor(channelCard("blitz"))
        XCTAssertTrue(isOnHome, "a bad -open should leave the app on the home screen")
        XCTAssertFalse(gameSettingsButton.exists)
        assertSomethingHasFocus("on the home screen after a bad -open")
    }

    func testAnEmptyBoardsOpenLandsOnHome() {
        launch(["-open", "boards:"])
        waitFor(channelCard("blitz"))
        XCTAssertTrue(isOnHome, "-open boards: with no round should leave the app on the home screen")
    }
}
