// Home: every card on every shelf opens the screen it promises, and Back comes home.
import XCTest

final class HomeUITests: UITestCase {

    /// The Lichess TV shelf, in the order `ChannelOrder.all` lists it, with the title each card's
    /// game screen must end up wearing.
    private static let channels: [(raw: String, title: String)] = [
        ("best", "Top rated"), ("bullet", "Bullet"), ("blitz", "Blitz"), ("rapid", "Rapid"),
        ("classical", "Classical"), ("ultraBullet", "UltraBullet"), ("chess960", "Chess960"),
        ("crazyhouse", "Crazyhouse"), ("antichess", "Antichess"), ("atomic", "Atomic"),
        ("horde", "Horde"), ("kingOfTheHill", "King of the Hill"), ("racingKings", "Racing Kings"),
        ("threeCheck", "Three-check"), ("bot", "Bots"), ("computer", "Computer"),
    ]

    private func waitForHome() {
        waitFor(app.buttons[UIID.Home.event("q7gOEObq")], timeout: 20)
    }

    // MARK: - Lichess TV

    private func openEveryChannel(_ slice: ArraySlice<(raw: String, title: String)>) {
        launch()
        waitForHome()
        for channel in slice {
            let card = app.buttons[UIID.Home.channel(channel.raw)]
            XCTAssertTrue(reveal(card, siblingPrefix: "home.channel."), "could not reach the \(channel.title) card")
            card.tap()
            waitForScreen("\(channel.title) \u{00B7} Lichess TV")
            XCTAssertTrue(app.buttons[UIID.Game.flip].waitForExistence(timeout: 12), "\(channel.title) opened without controls")
            back()
            XCTAssertTrue(waitUntil(10) { self.app.navigationBars["Watch"].exists }, "Back did not return Home from \(channel.title)")
        }
    }

    func testFirstEightChannelCardsOpenAndComeBack() {
        openEveryChannel(Self.channels.prefix(8))
    }

    func testRemainingChannelCardsOpenAndComeBack() {
        openEveryChannel(Self.channels.suffix(8))
    }

    // MARK: - Arenas

    func testEveryArenaCardOpensIncludingAnUpcomingOne() {
        launch()
        waitForHome()
        // Three started and three created, so the last of the six is an arena that has not begun.
        let ids = ["FfsuUfQP", "VA9GFK0R", "NGqVKrW0", "xvA6OzRD", "rNZDFgiM", "cBK5Bfks"]
        for id in ids {
            let card = app.buttons[UIID.Home.arena(id)]
            XCTAssertTrue(reveal(card, siblingPrefix: "home.arena."), "could not reach the arena card \(id)")
            let label = card.label
            card.tap()
            waitFor(gameStatus, timeout: 20)
            XCTAssertTrue(app.buttons[UIID.Game.flip].waitForExistence(timeout: 12), "arena \(id) opened without controls")
            XCTAssertTrue(screenTitle.contains("Lichess"), "arena \(id) (\(label)) opened as '\(screenTitle)'")
            back()
            XCTAssertTrue(waitUntil(10) { self.app.navigationBars["Watch"].exists }, "Back did not return Home from arena \(id)")
        }
    }

    func testUpcomingArenaOpensAWaitingBoard() {
        launch()
        waitForHome()
        let card = app.buttons[UIID.Home.arena("cBK5Bfks")]
        XCTAssertTrue(reveal(card, siblingPrefix: "home.arena."), "could not reach the upcoming arena card")
        XCTAssertTrue(card.label.contains("players"), "an arena card should say how many players: \(card.label)")
        card.tap()
        waitFor(gameStatus, timeout: 20)
        XCTAssertTrue(app.buttons[UIID.Game.scrubLive].exists, "the scrub bar should be there even before an arena starts")
        back()
        XCTAssertTrue(waitUntil(10) { self.app.navigationBars["Watch"].exists })
    }

    // MARK: - Events

    func testEveryEventCardOpensItsBoardsAndItsRounds() {
        launch()
        waitForHome()
        for round in ["q7gOEObq", "bmI956uk"] {
            let card = app.buttons[UIID.Home.event(round)]
            XCTAssertTrue(reveal(card, siblingPrefix: "home.event."), "could not reach the event card \(round)")
            card.tap()
            // Both fixture rounds serve the same five boards, and the ongoing one comes first.
            XCTAssertTrue(app.buttons[UIID.Boards.card("oSiy8ZXF")].waitForExistence(timeout: 20), "event \(round) opened no boards")
            XCTAssertTrue(app.buttons[UIID.Boards.allRounds].exists, "no All rounds button on the boards wall")
            back()
            XCTAssertTrue(waitUntil(10) { self.app.navigationBars["Watch"].exists }, "Back did not return Home from event \(round)")

            let rounds = app.buttons[UIID.Home.eventRounds(round)]
            XCTAssertTrue(reveal(rounds), "could not reach All rounds for \(round)")
            rounds.tap()
            XCTAssertTrue(app.buttons[UIID.Tournament.round("q7gOEObq")].waitForExistence(timeout: 20), "All rounds for \(round) listed nothing")
            XCTAssertTrue(app.buttons[UIID.Tournament.follow].exists, "the rounds screen has no Follow button")
            back()
            XCTAssertTrue(waitUntil(10) { self.app.navigationBars["Watch"].exists }, "Back did not return Home from the rounds of \(round)")
        }
    }

    // MARK: - Continue watching

    func testContinueWatchingAppearsAfterAGameAndOpensIt() {
        launch()
        waitForHome()
        let card = app.buttons[UIID.Home.channel("blitz")]
        XCTAssertTrue(reveal(card, siblingPrefix: "home.channel."))
        card.tap()
        waitForScreen("Blitz \u{00B7} Lichess TV")
        waitForLiveGame()
        app.terminate()

        launch(keepState: true)
        let resume = app.buttons[UIID.Home.resume]
        XCTAssertTrue(resume.waitForExistence(timeout: 20), "Continue watching did not come back after a game was watched")
        XCTAssertTrue(resume.label.contains("Blitz"), "Continue watching should name the last board: \(resume.label)")
        resume.tap()
        waitForScreen("Blitz \u{00B7} Lichess TV")
        waitForLiveGame()
    }

    func testContinueWatchingIsAbsentOnAFreshInstall() {
        launch()
        waitForHome()
        XCTAssertFalse(app.buttons[UIID.Home.resume].exists, "a fresh install has nothing to continue")
    }

    // MARK: - Settings from Home

    func testTabBarReachesEveryTab() {
        launch()
        waitForHome()
        selectTab("Following")
        XCTAssertTrue(app.navigationBars["Following"].waitForExistence(timeout: 10))
        selectTab("Settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        selectTab("Watch")
        XCTAssertTrue(app.navigationBars["Watch"].waitForExistence(timeout: 10))
    }
}
