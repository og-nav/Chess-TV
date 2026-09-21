// Shared vocabulary for the Apple TV suite: the fixture ids and shelf order the tests walk, and
// the remote moves that are the same on every screen.
//
// The ids are spelled out here rather than imported because a UI test bundle does not link the
// app's packages: `TVChannel`, `BoardTheme` and friends live on the other side of the process
// boundary. `Apps/ChessTVTests` keeps the app honest about these orders; this file keeps the
// walk honest about the app.
import XCTest

enum TVFixture {

    /// `ChannelOrder.all`: the seven headline channels, then the rest in `TVChannel.allCases` order.
    static let channels = [
        "best", "bullet", "blitz", "rapid", "classical", "ultraBullet", "chess960",
        "crazyhouse", "antichess", "atomic", "horde", "kingOfTheHill", "racingKings",
        "threeCheck", "bot", "computer",
    ]

    /// Live arenas, most players first, which is the order the shelf uses.
    static let liveArenas = ["FfsuUfQP", "VA9GFK0R", "NGqVKrW0"]
    /// Upcoming arenas, soonest first. Select on one of these only shows when it begins.
    static let upcomingArenas = ["xvA6OzRD", "rNZDFgiM", "cBK5Bfks"]
    static var arenas: [String] { liveArenas + upcomingArenas }

    /// The round being played, first on the Events shelf, then the one that has not started.
    static let liveEvent = "q7gOEObq"
    static let upcomingEvent = "bmI956uk"
    static var events: [String] { [liveEvent, upcomingEvent] }

    static let roundId = "q7gOEObq"
    static let ongoingBoard = "oSiy8ZXF"
    /// The five boards of the round as the list shows them (the ongoing one first) with the
    /// number each card carries, which is its place in the round's own order.
    static let boards: [(id: String, number: Int)] = [
        ("oSiy8ZXF", 5), ("ZD7czPL6", 1), ("M5p5sGuJ", 2), ("0d0Ct9qf", 3), ("Nsd4qTwD", 4),
    ]

    static let themes = ["Sage", "Brown", "Green", "Slate"]
    static let pieceSets: [(raw: String, name: String)] = [
        ("cburnett", "Classic"), ("merida", "Merida"), ("chessnut", "Chessnut"),
    ]
    static let depths: [(raw: String, name: String)] = [
        ("light", "Light"), ("standard", "Standard"), ("deep", "Deep"), ("maximum", "Maximum"),
    ]

    /// Toggles in the order the two-column grid lays them out, left column then right.
    static let toggleRows: [[String]] = [
        [UIID.Settings.keepTVOn, UIID.Settings.engine],
        [UIID.Settings.coordinates, UIID.Settings.sounds],
        [UIID.Settings.followFeatured, UIID.Settings.tournamentAlerts],
    ]
    static var toggles: [String] { toggleRows.flatMap { $0 } }
    /// Toggles no launch argument overrides, so their value survives a relaunch. (`engineEnabled`
    /// is set by `-engineEnabled NO`, which the argument domain applies ahead of what we saved.)
    static var persistentToggles: [String] {
        toggles.filter { $0 != UIID.Settings.engine }
    }

    static let directions: [XCUIRemote.Button] = [.up, .down, .left, .right]
}

extension TVUITestCase {

    // MARK: - Elements

    /// Any element with this identifier, whatever type it surfaced as. Combined accessibility
    /// elements (a player row, the move list, the standings) are not reliably buttons or
    /// static texts on tvOS, so the suite asks for them by identifier alone.
    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func channelCard(_ raw: String) -> XCUIElement { app.buttons[UIID.Home.channel(raw)] }
    func arenaCard(_ id: String) -> XCUIElement { app.buttons[UIID.Home.arena(id)] }
    func eventCard(_ id: String) -> XCUIElement { app.buttons[UIID.Home.event(id)] }
    func boardCard(_ id: String) -> XCUIElement { app.buttons[UIID.Boards.card(id)] }
    var homeSettingsButton: XCUIElement { app.buttons[UIID.Home.settings] }
    var resumeCard: XCUIElement { app.buttons[UIID.Home.resume] }
    var gameSettingsButton: XCUIElement { app.buttons[UIID.Game.settings] }
    var flipButton: XCUIElement { app.buttons[UIID.Game.flip] }
    var doneButton: XCUIElement { app.buttons[UIID.Settings.done] }
    var statusChip: XCUIElement { element(UIID.Game.status) }
    var moveList: XCUIElement { element(UIID.Game.moveList) }
    var gameTitle: XCUIElement { element(UIID.Game.title) }

    /// Which screen we are on. The home screen always has its Settings button; a game always has
    /// the footer's; the Settings screen always has Done.
    var isOnHome: Bool { homeSettingsButton.exists && !doneButton.exists }
    var isOnGame: Bool { gameSettingsButton.exists && !doneButton.exists }
    var isOnSettings: Bool { doneButton.exists }

    // MARK: - Focus

    /// The focused leaf. tvOS reports `hasFocus` on the focused element and on the ancestors that
    /// contain it, so the smallest match is the one the remote is actually on.
    func focusedElement() -> XCUIElement? {
        let focusedButtons = app.buttons.matching(NSPredicate(format: "hasFocus == YES")).allElementsBoundByIndex
        let candidates = focusedButtons.isEmpty
            ? app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == YES")).allElementsBoundByIndex
            : focusedButtons
        return candidates.min { lhs, rhs in
            let l = lhs.frame, r = rhs.frame
            return l.width * l.height < r.width * r.height
        }
    }

    func focusedIdentifier() -> String? { focusedElement()?.identifier }

    /// True once anything on screen has focus. A screen the remote cannot steer is a bug of its
    /// own, so several tests end on this.
    @discardableResult
    func assertSomethingHasFocus(_ what: String, file: StaticString = #filePath, line: UInt = #line) -> String? {
        let identifier = waitUntil(6) { self.focusedElement() != nil } ? focusedIdentifier() : nil
        XCTAssertNotNil(identifier, "nothing has focus \(what)", file: file, line: line)
        return identifier
    }

    /// Walks focus onto `target` from wherever it is now, choosing each press from the geometry:
    /// down/up when the target's row is below/above the focused element, otherwise right/left.
    /// Used where the layout is a grid rather than a single row.
    @discardableResult
    func steer(to target: XCUIElement, limit: Int = 40, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        if !target.exists {
            // A lazy grid only builds the rows near the viewport, so walking down brings the rest
            // into being before there is anything to steer towards.
            _ = target.waitForExistence(timeout: 5)
            var scrolls = 0
            while !target.exists, scrolls < 12 { press(.down, settle: 0.25); scrolls += 1 }
        }
        guard target.exists else {
            XCTFail("\(target) never appeared, so focus cannot reach it", file: file, line: line)
            return false
        }
        var previous: String?
        for _ in 0..<limit {
            if target.hasFocus { return true }
            guard let current = focusedElement(), current.identifier != target.identifier else {
                press(.down, settle: 0.2)
                continue
            }
            let didNotMove = current.identifier == previous
            previous = current.identifier
            let from = current.frame, to = target.frame
            let vertical: XCUIRemote.Button? = to.midY > from.maxY ? .down : (to.midY < from.minY ? .up : nil)
            let horizontal: XCUIRemote.Button? = to.midX > from.midX + 4 ? .right : (to.midX < from.midX - 4 ? .left : nil)
            // The far axis first; when the last press left focus where it was — the grid's last row
            // is short, say, so there is nothing straight down — take the other axis instead.
            var order = abs(to.midY - from.midY) >= abs(to.midX - from.midX)
                ? [vertical, horizontal]
                : [horizontal, vertical]
            if didNotMove { order.reverse() }
            guard let button = order.compactMap({ $0 }).first else { break }
            press(button, settle: 0.2)
        }
        XCTAssertTrue(target.hasFocus, "focus never reached \(target.identifier)", file: file, line: line)
        return target.hasFocus
    }

    // MARK: - Navigation

    /// Opens a card: brings it into focus with `direction`, then Select.
    func select(_ element: XCUIElement, arrivingWith direction: XCUIRemote.Button = .right, limit: Int = 24,
                file: StaticString = #filePath, line: UInt = #line) {
        focus(element, pressing: direction, limit: limit, file: file, line: line)
        press(.select)
    }

    /// Back until the home screen is the top of the stack. Menu on the home screen is swallowed,
    /// so the extra presses this may make are harmless.
    func backToHome(file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<6 {
            if isOnHome { return }
            press(.menu, settle: 0.5)
        }
        XCTAssertTrue(isOnHome, "Back never returned to the home screen", file: file, line: line)
    }

    /// Waits for a game screen that is streaming.
    @discardableResult
    func waitForLive(_ timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let live = waitUntil(timeout) { self.statusChip.exists && self.statusChip.label == "Live" }
        XCTAssertTrue(live, "the status chip never said Live (it said \(statusChip.exists ? statusChip.label : "nothing"))",
                      file: file, line: line)
        return live
    }

    // MARK: - Reading the screen

    /// The two player rows, topmost first. The row label carries WHITE or BLACK and the clock.
    func playerRows() -> [(color: String, label: String, top: Double)] {
        ["white", "black"].compactMap { color in
            let row = element(UIID.Game.clock(color))
            guard row.exists else { return nil }
            return (color, row.label, row.frame.minY)
        }
        .sorted { $0.top < $1.top }
    }

    /// The numbered rows the move list is showing right now.
    func moveRowNumbers() -> [Int] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "game.moves.row."))
            .allElementsBoundByIndex
            .compactMap { Int($0.identifier.dropFirst("game.moves.row.".count)) }
            .sorted()
    }

    /// The latest move number on screen. The panel keeps the last eight rows, so this grows as the
    /// feed delivers moves.
    func latestMoveNumber() -> Int? { moveRowNumbers().last }

    func toggleValue(_ identifier: String) -> String? {
        let button = app.buttons[identifier]
        guard button.exists else { return nil }
        return button.value as? String
    }

    /// The toggle grid at the foot of the Settings column is lazy: it is only built once focus
    /// walks down to it. Bring the whole grid into being before reading any of it.
    @discardableResult
    func revealToggles(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let last = app.buttons[UIID.Settings.tournamentAlerts]
        var presses = 0
        while !last.exists, presses < 14 { press(.down, settle: 0.25); presses += 1 }
        XCTAssertTrue(last.exists, "the toggle grid never appeared after \(presses) presses of down", file: file, line: line)
        return last.exists
    }
}
