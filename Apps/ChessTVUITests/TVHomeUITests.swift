// The home screen under the remote: every card on every shelf takes focus, Select opens the right
// screen, Back comes home without quitting, and the header's Settings button behaves.
import XCTest

final class TVHomeUITests: TVUITestCase {

    // MARK: - Focus walks

    /// All sixteen channel cards, in the shelf's order, with left/right only.
    func testFocusWalksEveryChannelCard() {
        launch()
        waitFor(channelCard("blitz"), timeout: 20)
        // The shelf opens on the first card, so walking right reaches the rest one press at a time.
        focus(channelCard(TVFixture.channels[0]), pressing: .left, limit: 20)
        for raw in TVFixture.channels {
            focus(channelCard(raw), pressing: .right, limit: 3)
            XCTAssertTrue(channelCard(raw).hasFocus, "\(raw) should have focus")
        }
        // And back again, so the shelf steers both ways.
        for raw in TVFixture.channels.reversed() {
            focus(channelCard(raw), pressing: .left, limit: 3)
        }
        XCTAssertTrue(channelCard(TVFixture.channels[0]).hasFocus)
    }

    /// Down from the channels reaches the arena shelf, and every arena card takes focus; down again
    /// reaches the events, and up walks back to the channels.
    func testFocusWalksArenasAndEventsAndBackUp() {
        launch()
        waitFor(arenaCard(TVFixture.liveArenas[0]), timeout: 20)
        waitFor(eventCard(TVFixture.liveEvent), timeout: 20)

        focus(arenaCard(TVFixture.arenas[0]), pressing: .down, limit: 6)
        for id in TVFixture.arenas {
            focus(arenaCard(id), pressing: .right, limit: 3)
            XCTAssertTrue(arenaCard(id).hasFocus, "arena \(id) should have focus")
        }

        // Down from the far end of a shelf lands on whichever card is nearest, so the walk to the
        // start of the next shelf is steered rather than counted.
        steer(to: eventCard(TVFixture.events[0]), limit: 12)
        for id in TVFixture.events {
            focus(eventCard(id), pressing: .right, limit: 3)
            XCTAssertTrue(eventCard(id).hasFocus, "event \(id) should have focus")
        }

        // Up from the events reaches the arena shelf, and up again the channels.
        press(.up, settle: 0.4)
        XCTAssertTrue(waitUntil(6) { (self.focusedIdentifier() ?? "").hasPrefix("home.arena.") },
                      "up from the events should reach the arenas, reached \(focusedIdentifier() ?? "nothing")")
        press(.up, settle: 0.4)
        XCTAssertTrue(waitUntil(6) { (self.focusedIdentifier() ?? "").hasPrefix("home.channel.") },
                      "up from the arenas should reach the channels, reached \(focusedIdentifier() ?? "nothing")")
    }

    // MARK: - Select opens the right screen

    func testSelectOnAChannelOpensThatChannelsGame() {
        launch()
        waitFor(channelCard("blitz"), timeout: 20)
        select(channelCard("blitz"))
        waitFor(gameSettingsButton)
        XCTAssertTrue(waitUntil(15) { self.gameTitle.label.contains("Blitz") },
                      "the game header should name Blitz, said \(gameTitle.label)")
    }

    func testSelectOnALiveArenaOpensTheArenaGame() {
        launch()
        waitFor(arenaCard(TVFixture.liveArenas[0]), timeout: 20)
        steer(to: arenaCard(TVFixture.liveArenas[0]), limit: 14)
        press(.select)
        waitFor(gameSettingsButton)
        XCTAssertTrue(waitUntil(20) { self.gameTitle.label.contains("Arena") },
                      "the game header should name the arena, said \(gameTitle.label)")
    }

    func testSelectOnAnEventOpensItsBoardList() {
        launch()
        waitFor(eventCard(TVFixture.liveEvent), timeout: 20)
        steer(to: eventCard(TVFixture.liveEvent), limit: 16)
        press(.select)
        waitFor(boardCard(TVFixture.ongoingBoard), timeout: 20)
        XCTAssertFalse(gameSettingsButton.exists, "an event opens the board list, not a game")
    }

    /// An upcoming arena has no game yet, so Select only notes when it begins, and Select again
    /// puts the countdown back.
    func testSelectOnAnUpcomingArenaTogglesTheStartsAtNote() {
        launch()
        let card = arenaCard(TVFixture.upcomingArenas[0])
        waitFor(card, timeout: 20)
        steer(to: card, limit: 16)
        let before = card.value as? String ?? ""
        XCTAssertFalse(before.hasPrefix("Starts at"), "the card should open on the countdown, said \(before)")

        press(.select)
        XCTAssertTrue(waitUntil(5) { (card.value as? String ?? "").hasPrefix("Starts at") },
                      "Select should show when the arena begins, said \(card.value as? String ?? "nothing")")
        XCTAssertFalse(gameSettingsButton.exists, "an upcoming arena has no game to open")

        press(.select)
        XCTAssertTrue(waitUntil(5) { !((card.value as? String ?? "").hasPrefix("Starts at")) },
                      "Select again should put the countdown back, said \(card.value as? String ?? "nothing")")
        XCTAssertTrue(card.hasFocus, "the card should keep focus across both presses")
    }

    // MARK: - Back

    func testMenuOnTheHomeScreenDoesNotQuitTheApp() {
        launch()
        waitFor(channelCard("blitz"), timeout: 20)
        press(.menu, times: 4, settle: 0.5)
        XCTAssertEqual(app.state, .runningForeground, "Back on the home screen must not quit the app")
        XCTAssertTrue(isOnHome)
        assertSomethingHasFocus("after Back on the home screen")
    }

    func testMenuFromAGameReturnsHomeWithFocusRestored() {
        launch()
        waitFor(channelCard("blitz"), timeout: 20)
        select(channelCard("blitz"))
        waitFor(gameSettingsButton)
        waitForLive()

        press(.menu, settle: 1.0)
        XCTAssertTrue(waitUntil(10) { self.isOnHome }, "Back from a game should come home")
        let focused = assertSomethingHasFocus("after Back from a game")
        // Either the card that opened the game or the "Continue watching" card it has just earned.
        XCTAssertTrue(focused == UIID.Home.channel("blitz") || focused == UIID.Home.resume,
                      "focus should land on the channel or the resume card, landed on \(focused ?? "nothing")")
    }

    // MARK: - Settings from the header

    func testHeaderSettingsButtonOpensSettingsAndDoneReturnsFocusToIt() {
        launch()
        waitFor(channelCard("blitz"), timeout: 20)
        focus(homeSettingsButton, pressing: .up, limit: 8)
        press(.select)
        waitFor(doneButton)

        focus(doneButton, pressing: .up, limit: 10)
        press(.select)
        XCTAssertTrue(waitUntil(10) { !self.isOnSettings }, "Done should close Settings")
        XCTAssertTrue(waitUntil(6) { self.homeSettingsButton.hasFocus },
                      "focus should come back to the Settings button, went to \(focusedIdentifier() ?? "nothing")")
    }

    func testMenuClosesSettingsOpenedFromTheHeader() {
        launch()
        waitFor(channelCard("blitz"), timeout: 20)
        focus(homeSettingsButton, pressing: .up, limit: 8)
        press(.select)
        waitFor(doneButton)
        press(.menu, settle: 0.6)
        XCTAssertTrue(waitUntil(10) { !self.isOnSettings }, "Back should close Settings")
        XCTAssertTrue(isOnHome)
        XCTAssertTrue(waitUntil(6) { self.homeSettingsButton.hasFocus },
                      "focus should come back to the Settings button, went to \(focusedIdentifier() ?? "nothing")")
    }

    // MARK: - Continue watching

    /// The shelf only exists once something has been watched, so this takes two launches: one that
    /// opens a channel, and one that keeps what the first one saved.
    func testContinueWatchingAppearsAfterAGameAndOpensIt() {
        launch()
        waitFor(channelCard("classical"), timeout: 20)
        XCTAssertFalse(resumeCard.exists, "a fresh install has nothing to continue")
        select(channelCard("classical"))
        waitFor(gameSettingsButton)
        waitForLive()
        app.terminate()

        launch(keepState: true)
        waitFor(resumeCard, timeout: 20)
        XCTAssertTrue(resumeCard.label.contains("Classical"),
                      "the resume card should name the channel, said \(resumeCard.label)")
        XCTAssertTrue(waitUntil(6) { self.resumeCard.hasFocus },
                      "the resume card is the default focus, focus was on \(focusedIdentifier() ?? "nothing")")
        press(.select)
        waitFor(gameSettingsButton)
        XCTAssertTrue(waitUntil(15) { self.gameTitle.label.contains("Classical") },
                      "the resume card should reopen the channel, header said \(gameTitle.label)")
    }
}
