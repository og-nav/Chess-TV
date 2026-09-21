// The base for every phone UI test: launches the app in fixture mode and reads the hitch report.
import XCTest

class UITestCase: XCTestCase {

    var app: XCUIApplication!
    /// Where the app writes its frame-lag report for this test. See HitchMonitor.
    private(set) var hitchReportURL: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        hitchReportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("chesstv-uitests", isDirectory: true)
            .appendingPathComponent("\(name.filter(\.isLetter))-\(UUID().uuidString.prefix(8)).json")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    /// Launches with fixtures, a fresh install and the engine off unless the test says otherwise.
    /// `-fixtureMoveInterval` defaults to 1.5 s so a move list grows during a test.
    @discardableResult
    func launch(_ extra: [String] = [], engine: Bool = false, keepState: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-uiFixtures", "-fixtureMoveInterval", "1.5", "-hitchReport", hitchReportURL.path]
        if !engine { arguments += ["-engineEnabled", "NO"] }
        if keepState { arguments.append("-keepState") }
        app.launchArguments = arguments + extra
        app.launch()
        self.app = app
        return app
    }

    // MARK: - Waiting

    @discardableResult
    func waitFor(_ element: XCUIElement, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(element) did not appear within \(timeout)s", file: file, line: line)
        return element
    }

    func waitUntil(_ timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    // MARK: - Hitches

    struct HitchReport: Decodable {
        var frames: Int
        var hitches: Int
        var hitchTimeMs: Double
        var worstMs: Double
        var elapsedS: Double
        var ratioMsPerS: Double
    }

    /// The app's running report, or nil if it has not written one yet.
    func hitchReport() -> HitchReport? {
        guard let data = try? Data(contentsOf: hitchReportURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HitchReport.self, from: data)
    }

    /// Runs `scenario`, then reports the frame lag accumulated while it ran as a test attachment
    /// and asserts the hitch time ratio stayed under `maxMsPerSecond`. The reading is the app's
    /// main-thread frame lag on whatever this test ran on; TESTING.md says what that does and
    /// does not prove.
    func measureHitches(_ label: String, maxMsPerSecond: Double = 10, file: StaticString = #filePath, line: UInt = #line, _ scenario: () throws -> Void) rethrows {
        // The report is rewritten once a second; wait for a fresh one so the baseline is current.
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        let before = hitchReport()
        try scenario()
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        guard let before, let after = hitchReport() else {
            XCTContext.runActivity(named: "\(label): no hitch report (the app could not write \(hitchReportURL.path))") { _ in }
            return
        }
        let elapsed = after.elapsedS - before.elapsedS
        let hitchMs = after.hitchTimeMs - before.hitchTimeMs
        let ratio = elapsed > 0 ? hitchMs / elapsed : 0
        let summary = String(format: "%@: %.1f ms/s hitch time over %.1f s (%d hitches, worst %.1f ms)", label, ratio, elapsed, after.hitches - before.hitches, after.worstMs)
        let attachment = XCTAttachment(string: summary)
        attachment.name = "hitches-\(label)"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTContext.runActivity(named: summary) { _ in }
        XCTAssertLessThan(ratio, maxMsPerSecond, summary, file: file, line: line)
    }
}
