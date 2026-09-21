// The board list of one broadcast round: five boards, the one still being played first and
// focused, every card opens its own game, and Back walks the stack down to the home screen.
import XCTest

final class TVBoardListUITests: TVUITestCase {

    func testTheEventCardOpensTheRoundWithFiveBoardsTheOngoingOneFirst() {
        launch()
        waitFor(eventCard(TVFixture.liveEvent), timeout: 20)
        steer(to: eventCard(TVFixture.liveEvent), limit: 16)
        press(.select)

        for board in TVFixture.boards {
            waitFor(boardCard(board.id), timeout: 20)
        }
        XCTAssertTrue(element(UIID.Boards.title).label.contains("TCEC"),
                      "the header should name the tournament, said \(element(UIID.Boards.title).label)")

        let ongoing = boardCard(TVFixture.ongoingBoard)
        XCTAssertTrue(waitUntil(10) { ongoing.hasFocus },
                      "the board still being played takes focus, focus was on \(focusedIdentifier() ?? "nothing")")
        // First means first in reading order: no other card sits above it or to its left on its row.
        let others = TVFixture.boards.dropFirst().map { boardCard($0.id).frame }
        for frame in others {
            let isAfter = frame.minY > ongoing.frame.minY - 1
                && (frame.minY > ongoing.frame.maxY - 1 || frame.minX > ongoing.frame.minX - 1)
            XCTAssertTrue(isAfter, "the ongoing board should be the first card; \(frame) came before \(ongoing.frame)")
        }
    }

    /// Every card opens the game it names. The board number a card shows is its place in the
    /// round, which is what the game header spells out.
    func testEveryBoardCardOpensAGameTitledWithItsNumber() {
        launch(["-open", "boards:\(TVFixture.roundId)"])
        waitFor(boardCard(TVFixture.ongoingBoard), timeout: 20)
        for board in TVFixture.boards {
            let card = boardCard(board.id)
            steer(to: card, limit: 20)
            press(.select)
            waitFor(gameSettingsButton, timeout: 15)
            XCTAssertTrue(waitUntil(20) { self.gameTitle.label.contains("Board \(board.number)") },
                          "opening \(board.id) should title the game Board \(board.number), said \(gameTitle.label)")
            press(.menu, settle: 0.8)
            XCTAssertTrue(waitUntil(10) { self.boardCard(board.id).exists && !self.gameSettingsButton.exists },
                          "Back should return to the board list")
        }
    }

    func testBackWalksFromAGameToTheListAndThenHome() {
        launch()
        waitFor(eventCard(TVFixture.liveEvent), timeout: 20)
        steer(to: eventCard(TVFixture.liveEvent), limit: 16)
        press(.select)
        let card = boardCard(TVFixture.ongoingBoard)
        waitFor(card, timeout: 20)
        steer(to: card, limit: 20)
        press(.select)
        waitFor(gameSettingsButton, timeout: 15)

        press(.menu, settle: 0.8)
        XCTAssertTrue(waitUntil(10) { self.boardCard(TVFixture.ongoingBoard).exists && !self.gameSettingsButton.exists },
                      "the first Back lands on the board list")
        assertSomethingHasFocus("on the board list after Back")

        press(.menu, settle: 0.8)
        XCTAssertTrue(waitUntil(10) { self.isOnHome }, "the second Back lands on the home screen")
        assertSomethingHasFocus("on the home screen after Back")
    }

    /// The round that has not started yet answers with the same five boards under its own id, so
    /// the upcoming event card opens a usable list too.
    func testTheUpcomingEventCardOpensAListAsWell() {
        launch()
        waitFor(eventCard(TVFixture.upcomingEvent), timeout: 20)
        steer(to: eventCard(TVFixture.upcomingEvent), limit: 16)
        press(.select)
        waitFor(boardCard(TVFixture.ongoingBoard), timeout: 20)
        XCTAssertFalse(gameSettingsButton.exists, "an event card opens the list, not a game")
    }
}
