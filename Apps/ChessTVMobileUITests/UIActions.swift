// The gestures this suite repeats, written once.
//
// Three of them are not what you would guess from the view code, and every test depends on the
// difference:
//
//   * A SwiftUI `Toggle` in a Form publishes the whole row under the identifier, and a tap in the
//     middle of that row lands on the label and does nothing. The switch inside it is what has to
//     be tapped.
//   * A `Picker` in a Form on iOS 26 is a pop-up menu button, not a pushed list: tapping it opens
//     a menu whose choices are plain buttons titled with the option, in the app's own hierarchy.
//   * The first follow made while a push server is configured raises the system notification
//     alert, which belongs to SpringBoard and blocks taps on the app until it is dismissed.
import XCTest

extension UITestCase {

    // MARK: - Controls

    /// The row published under `identifier`, whose value is "0" or "1".
    func switchRow(_ identifier: String) -> XCUIElement { app.switches[identifier] }

    func isOn(_ identifier: String) -> Bool { (app.switches[identifier].value as? String) == "1" }

    /// Flips the switch inside the row, which is the only part of it that responds to a tap.
    @discardableResult
    func flip(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let row = waitFor(app.switches[identifier], file: file, line: line)
        let before = (row.value as? String) == "1"
        let control = row.switches.firstMatch.exists ? row.switches.firstMatch : row
        control.tap()
        let flipped = waitUntil(4) { ((row.value as? String) == "1") != before }
        XCTAssertTrue(flipped, "\(identifier) did not change from \(before)", file: file, line: line)
        return !before
    }

    func set(_ identifier: String, to wanted: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let row = waitFor(app.switches[identifier], file: file, line: line)
        guard ((row.value as? String) == "1") != wanted else { return }
        flip(identifier, file: file, line: line)
    }

    /// Picks `option` out of the pop-up menu a Form picker opens.
    func choose(_ option: String, in picker: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = waitFor(app.buttons[picker], file: file, line: line)
        button.tap()
        let choice = app.buttons[option]
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "the \(picker) menu never offered \(option)", file: file, line: line)
        choice.tap()
        let landed = waitUntil(5) { self.app.buttons[picker].label.contains(option) }
        XCTAssertTrue(landed, "\(picker) still reads \(app.buttons[picker].label) after choosing \(option)", file: file, line: line)
    }

    /// The value half of a picker row's label ("Board colours, Sage" -> "Sage").
    func pickerValue(_ picker: String) -> String {
        let label = app.buttons[picker].label
        guard let comma = label.range(of: ", ", options: .backwards) else { return label }
        return String(label[comma.upperBound...])
    }

    // MARK: - Navigation

    @discardableResult
    func back(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let button = app.navigationBars.buttons["BackButton"].firstMatch
        guard button.waitForExistence(timeout: 8) else {
            XCTFail("no Back button on \(app.navigationBars.firstMatch.identifier)", file: file, line: line)
            return false
        }
        button.tap()
        return true
    }

    /// The title of the screen on top, which is the identifier UIKit gives the navigation bar.
    var screenTitle: String {
        app.navigationBars.allElementsBoundByIndex.last?.identifier ?? ""
    }

    func waitForScreen(_ title: String, timeout: TimeInterval = 12, file: StaticString = #filePath, line: UInt = #line) {
        let arrived = waitUntil(timeout) { self.app.navigationBars[title].exists }
        XCTAssertTrue(arrived, "expected the \(title) screen, got \(screenTitle)", file: file, line: line)
    }

    /// The phone's tab bar, or the iPad's sidebar rows, by the name both shapes use.
    ///
    /// The iPad half takes some care: the sidebar is a `List` with a selection binding, and a tap
    /// on the label inside a row does not always move that selection, so the row itself is tried
    /// first and each attempt is checked against the title the detail pane ends up showing.
    func selectTab(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        if app.tabBars.buttons[name].exists {
            app.tabBars.buttons[name].tap()
            return
        }
        let candidates = [
            app.cells.containing(NSPredicate(format: "label == %@", name)).firstMatch,
            app.cells.staticTexts[name],
            app.buttons[name],
        ]
        var tried = false
        for candidate in candidates where candidate.exists {
            tried = true
            candidate.tap()
            if waitUntil(4, { self.app.navigationBars[name].exists }) { return }
        }
        XCTAssertTrue(tried, "no way to reach the \(name) tab", file: file, line: line)
        XCTAssertTrue(waitUntil(6) { self.app.navigationBars[name].exists },
                      "tapping \(name) did not open it", file: file, line: line)
    }

    func isSelectedTab(_ name: String) -> Bool {
        if app.tabBars.buttons[name].exists { return app.tabBars.buttons[name].isSelected }
        return app.navigationBars[name].exists
    }

    // MARK: - Scrolling

    /// The part of the window a tap actually lands in: inside the navigation bar above and the
    /// tab bar below, both of which float over the content.
    private var contentArea: CGRect {
        let window = frame(of: app.windows.firstMatch) ?? CGRect(x: 0, y: 0, width: 402, height: 874)
        // The navigation bar ends at 116 on a phone and the tab bar starts 83 points from the
        // bottom; a point inside this rectangle is a point a tap reaches the content at.
        let top = 116.0
        let bottom = 84.0
        guard window.height > top + bottom else { return window }
        return CGRect(x: window.minX, y: window.minY + top, width: window.width, height: window.height - top - bottom)
    }

    /// An element's frame, or nil when it is not there.
    ///
    /// `XCUIElement.frame` fails the whole test for an element that has gone — which happens all
    /// the time while a lazy stack is being scrolled — and `isHittable` fails it for one whose
    /// frame lies off the side of the window, which is exactly the case a scroll helper needs to
    /// ask about. `snapshot()` throws instead, so it is the only safe way to read geometry.
    func frame(of element: XCUIElement) -> CGRect? {
        // `exists` first: asking an absent element for a snapshot records a failure of its own
        // ("failed to get matching snapshot"), which `try?` does not swallow.
        guard element.exists else { return nil }
        // `snapshot()` is main-actor isolated and its result is not Sendable; a test method runs on
        // the main thread, so the frame is read there and only the rectangle comes back out.
        return MainActor.assumeIsolated { (try? element.snapshot())?.frame }
    }

    /// Whether an element sits in the area a tap can reach.
    func isOnScreen(_ element: XCUIElement) -> Bool {
        guard let frame = frame(of: element), frame.width > 1, frame.height > 1 else { return false }
        return contentArea.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    /// Scrolls until `element` sits in the content area: the page vertically, and the shelf the
    /// element belongs to sideways.
    ///
    /// The sideways half is the fiddly one. A swipe that starts on a card moves the shelf about
    /// twenty points and springs back, because the button's own gesture wins; a swipe on the shelf
    /// itself travels two screen widths and overshoots for ever. So the shelf is found by the band
    /// of the screen the element sits in, and dragged card-to-card by the distance needed.
    /// - Parameter siblingPrefix: the identifier prefix the element's shelf-mates share. A card
    ///   further along a lazy shelf is not in the tree at all until the shelf has been dragged
    ///   near it, and an element with no frame gives a scroll helper nothing to aim at; a sibling
    ///   that is on screen says which band to drag.
    @discardableResult
    func reveal(_ element: XCUIElement, siblingPrefix: String? = nil, attempts: Int = 24) -> Bool {
        let page = app.scrollViews.firstMatch
        var shelf: XCUIElement?
        var sideways = 1
        for attempt in 0..<attempts {
            if isOnScreen(element) { return true }
            let area = contentArea
            guard let frame = frame(of: element) else {
                if let sibling = onScreenCard(prefix: siblingPrefix), let band = shelfScrollView(atY: sibling.midY) {
                    // The shelf is on screen; the card is simply past the end of what it has built.
                    if !dragShelf(band, by: Double(sideways) * area.width * 0.8) {
                        if sideways > 0 { band.swipeLeft() } else { band.swipeRight() }
                    }
                } else if let shelf {
                    if sideways > 0 { shelf.swipeLeft() } else { shelf.swipeRight() }
                } else if attempt < attempts / 2 {
                    page.swipeUp()
                } else {
                    page.swipeDown()
                }
                pause(0.4)
                continue
            }
            if frame.midY > area.maxY {
                page.swipeUp()
            } else if frame.midY < area.minY {
                page.swipeDown()
            } else if frame.midX > area.maxX || frame.midX < area.minX {
                guard let band = shelfScrollView(atY: frame.midY) else { return false }
                shelf = band
                sideways = frame.midX > area.maxX ? 1 : -1
                // A swipe on the shelf travels about seven hundred points, which is two screens
                // wide: it would jump the target from off the right to off the left and back for
                // ever. A drag between two cards moves the shelf by exactly the gap between them,
                // so the pair whose gap is closest to what is needed lands the card on screen.
                if !dragShelf(band, by: frame.midX - area.midX) {
                    if sideways > 0 { band.swipeLeft() } else { band.swipeRight() }
                }
            } else {
                page.swipeUp()
            }
            pause(0.4)
        }
        return isOnScreen(element)
    }

    /// The frame of any card of the same shelf that is currently on screen.
    private func onScreenCard(prefix: String?) -> CGRect? {
        guard let prefix else { return nil }
        return app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .allElementsBoundByIndex
            .lazy
            .compactMap { self.isOnScreen($0) ? self.frame(of: $0) : nil }
            .first
    }

    /// Drags a shelf so its contents move `delta` points to the left (a negative delta moves them
    /// right), by pressing one card and dragging to another the right distance away.
    ///
    /// The shelf's cards are read from a single snapshot rather than by querying each button:
    /// at an accessibility type size a shelf holds enough elements that one query per card takes
    /// long enough for XCTest to give up on the app ("timed out while evaluating UI query").
    /// - Returns: false when fewer than two of the shelf's cards are on screen to drag between.
    private func dragShelf(_ shelf: XCUIElement, by delta: CGFloat) -> Bool {
        guard shelf.exists else { return false }
        let cards: [(String, CGFloat)] = MainActor.assumeIsolated {
            guard let snapshot = try? shelf.snapshot() else { return [] }
            var found: [(String, CGFloat)] = []
            func walk(_ element: XCUIElementSnapshot) {
                if element.elementType == .button, !element.identifier.isEmpty,
                   element.frame.width > 1, element.frame.midX > snapshot.frame.minX, element.frame.midX < snapshot.frame.maxX {
                    found.append((element.identifier, element.frame.midX))
                }
                for child in element.children { walk(child) }
            }
            walk(snapshot)
            return found
        }
        guard cards.count >= 2 else { return false }
        var best: (from: String, to: String, error: CGFloat)?
        for from in cards {
            for to in cards where to.1 != from.1 {
                let error = abs((from.1 - to.1) - delta)
                if best == nil || error < best!.error { best = (from.0, to.0, error) }
            }
        }
        guard let best else { return false }
        app.buttons[best.from].press(forDuration: 0.1, thenDragTo: app.buttons[best.to])
        return true
    }

    /// The sideways shelf whose viewport covers this line of the screen.
    private func shelfScrollView(atY y: CGFloat) -> XCUIElement? {
        app.scrollViews.allElementsBoundByIndex.first { view in
            guard let frame = frame(of: view), frame.height < 300 else { return false }
            return frame.minY <= y && y <= frame.maxY
        }
    }

    /// Scrolls a Form until a row is reachable. A screen with nothing to scroll is not a failure:
    /// the answer is then simply whether the row is there.
    @discardableResult
    func revealRow(_ element: XCUIElement, attempts: Int = 12) -> Bool {
        for _ in 0..<attempts {
            if isOnScreen(element) { return true }
            guard let scroll = scrollContainer else { return element.exists }
            if let frame = frame(of: element), frame.midY < contentArea.minY {
                scroll.swipeDown()
            } else {
                scroll.swipeUp()
            }
            pause(0.4)
        }
        return isOnScreen(element)
    }

    /// Whether anything on this screen carries exactly this label, scrolling the screen to look for
    /// it: a Form only realises the rows near the viewport, so a row further down does not exist yet.
    func findLabel(_ text: String, attempts: Int = 10) -> Bool {
        let query = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text))
        for _ in 0..<attempts {
            if query.count > 0 { return true }
            guard let scroll = scrollContainer else { return false }
            scroll.swipeUp()
            pause(0.4)
        }
        return query.count > 0
    }

    /// Whatever this screen scrolls with: a SwiftUI Form is a scroll view on some screens and a
    /// collection view on others, and a short one may be neither.
    private var scrollContainer: XCUIElement? {
        for query in [app.scrollViews, app.collectionViews, app.tables] where query.count > 0 {
            return query.firstMatch
        }
        return nil
    }

    // MARK: - System alerts

    /// Deals with the notification permission alert both ways: a monitor for whenever it turns up
    /// mid-gesture, and a direct dismissal for the common case where it is already on screen and
    /// blocking every tap. The simulator remembers the answer, so only the first run of a suite
    /// sees it at all.
    @discardableResult
    func allowSystemAlerts() -> NSObjectProtocol {
        let monitor = addUIInterruptionMonitor(withDescription: "notification permission") { alert in
            for name in ["Allow", "OK", "Continue"] where alert.buttons[name].exists {
                alert.buttons[name].tap()
                return true
            }
            return false
        }
        return monitor
    }

    /// Taps Allow on the permission alert if SpringBoard is showing one.
    func dismissPermissionAlert(timeout: TimeInterval = 4) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: timeout) {
            allow.tap()
            _ = waitUntil(4) { !allow.exists }
        }
    }

    // MARK: - Game screen

    /// The game screen's status line, which is one combined static text.
    var gameStatus: XCUIElement { app.staticTexts[UIID.Game.status] }

    func waitForLiveGame(timeout: TimeInterval = 25, file: StaticString = #filePath, line: UInt = #line) {
        waitFor(gameStatus, timeout: timeout, file: file, line: line)
        let live = waitUntil(timeout) { self.gameStatus.label.contains("Live") || self.gameStatus.label.contains("Finished") }
        XCTAssertTrue(live, "the game never went live (status: \(gameStatus.label))", file: file, line: line)
    }

    /// The board's accessibility children are the squares, top-left first for whoever is at the
    /// bottom, so this one label says which way round the board is.
    func topLeftSquare() -> String {
        let board = app.otherElements[UIID.Game.board].firstMatch
        guard board.exists else { return "" }
        return board.staticTexts.element(boundBy: 0).label
    }

    func moveButtons() -> [XCUIElement] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'game.move.'")).allElementsBoundByIndex
    }

    func moveCount() -> Int {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'game.move.'")).count
    }

    /// Waits for the paced fixture stream to deliver another move.
    func waitForAnotherMove(from count: Int, timeout: TimeInterval = 12) -> Bool {
        waitUntil(timeout) { self.moveCount() > count }
    }

    func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
