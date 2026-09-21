// Where the time goes between tapping a game and watching it live.
//
// One `OpenTiming` is started per `GameSession.open` and marks each milestone the first time it
// is reached. Every mark writes one line to the `timing` log category and, once the board is
// live with trusted clocks (or when the game is closed), one summary line with every number on
// it. That is what a week of ordinary use is measured with:
//
//   log stream --predicate 'subsystem == "com.navin.chesstv" AND category == "timing"'
//
// The origin is the tap when the screen told the session about it (`noteNavigationTap`), else
// the `open` call. `from=tap` in the summary says which. Nothing here influences behaviour; the
// session works identically with the log muted.
import Foundation
import os

let timingLog = Logger(subsystem: "com.navin.chesstv", category: "timing")

public struct OpenTiming: Sendable {

    public enum Milestone: String, CaseIterable, Sendable {
        /// The game screen is on screen (navigation finished).
        case screen
        /// A position is showing: the preview seed, or the first published position.
        case board
        /// The full move list has been published.
        case history
        /// The first live event arrived, so the board is current.
        case live
        /// The clocks are trusted enough to count down.
        case clocks
        /// The first engine evaluation was accepted for the shown position.
        case evaluation
    }

    /// The milestones that make an opening complete. The engine is optional and slow by
    /// design, so it is reported but not waited for.
    public static let required: [Milestone] = [.board, .history, .live, .clocks]

    public let source: String
    public let start: ContinuousClock.Instant
    /// True when `start` is the tap, false when it is the `open` call.
    public let fromTap: Bool
    public private(set) var marks: [Milestone: Duration] = [:]
    public private(set) var summarised = false
    private let sink: @Sendable (String) -> Void

    public init(
        source: String,
        start: ContinuousClock.Instant = .now,
        fromTap: Bool = false,
        sink: (@Sendable (String) -> Void)? = nil
    ) {
        self.source = source
        self.start = start
        self.fromTap = fromTap
        self.sink = sink ?? { timingLog.notice("\($0, privacy: .public)") }
    }

    /// Records the milestone the first time it is reached; later calls change nothing.
    /// - Returns: whether this call recorded it.
    @discardableResult
    public mutating func mark(_ milestone: Milestone, at now: ContinuousClock.Instant = .now) -> Bool {
        guard marks[milestone] == nil else { return false }
        let elapsed = now - start
        marks[milestone] = elapsed
        sink("open \(source) \(milestone.rawValue) +\(Self.millis(elapsed))ms")
        return true
    }

    public func milliseconds(_ milestone: Milestone) -> Int? {
        marks[milestone].map(Self.millis)
    }

    public var isComplete: Bool { Self.required.allSatisfy { marks[$0] != nil } }

    /// One line with every number: `opened tv:blitz from=open screen=12 board=0 history=410
    /// live=1210 clocks=1210 evaluation=1890`. An unreached milestone reads `-`.
    public func summary(reason: String, at now: ContinuousClock.Instant = .now) -> String {
        let fields = Milestone.allCases.map { milestone in
            "\(milestone.rawValue)=\(milliseconds(milestone).map(String.init) ?? "-")"
        }
        return "\(reason) \(source) from=\(fromTap ? "tap" : "open") after=\(Self.millis(now - start))ms " + fields.joined(separator: " ")
    }

    /// Writes the summary once. Called when the opening completes and again, harmlessly, on close.
    public mutating func summarise(reason: String, at now: ContinuousClock.Instant = .now) {
        guard !summarised else { return }
        summarised = true
        sink(summary(reason: reason, at: now))
    }

    static func millis(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000) + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
