// A frame-lag monitor for fixture mode, so a UI test can say something measured about smoothness.
//
// A `CADisplayLink` fires once per display refresh whether or not anything was drawn, so the gap
// between two callbacks is a direct reading of whether the main thread kept up with the display.
// A callback that arrives later than the frame it was due for is a hitch, and the lag is the
// hitch time. Summed and divided by elapsed time that is the "hitch time ratio" Apple's tools
// report in milliseconds per second: under 5 is smooth, over 10 is something a person notices.
//
// This is the main-thread half of the story. It does not see a slow render server, and it is a
// simulator reading when it runs on a simulator. Both are said in TESTING.md. The report is a
// JSON file rewritten once a second at the path given by `-hitchReport`; the UI tests read it
// before and after a scenario and assert on the difference.
import Foundation
import QuartzCore
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class HitchMonitor {

    static let shared = HitchMonitor()

    struct Report: Codable {
        var frames = 0
        var hitches = 0
        var hitchTimeMs = 0.0
        var worstMs = 0.0
        var elapsedS = 0.0
        var ratioMsPerS = 0.0
        var updatedAt = Date()
    }

    private var link: CADisplayLink?
    private var reportURL: URL?
    private var lastTimestamp: CFTimeInterval?
    private var startedAt: CFTimeInterval?
    private var lastWrite: CFTimeInterval = 0
    private(set) var report = Report()

    /// Any lag past this is counted. Half a millisecond ignores timer jitter without hiding a
    /// dropped frame, which is at least a whole frame late.
    private static let lagFloor: CFTimeInterval = 0.0005

    static func startIfRequested() {
        guard let path = FixtureMode.argument("-hitchReport") else { return }
        shared.start(reportURL: URL(fileURLWithPath: path))
    }

    func start(reportURL: URL) {
        guard link == nil else { return }
        self.reportURL = reportURL
        try? FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        write(force: true)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let expected = link.targetTimestamp - link.timestamp
        if startedAt == nil { startedAt = now }
        if let last = lastTimestamp, expected > 0 {
            let actual = now - last
            let lag = actual - expected
            report.frames += 1
            if lag > Self.lagFloor {
                report.hitches += 1
                report.hitchTimeMs += lag * 1000
                report.worstMs = max(report.worstMs, lag * 1000)
            }
        }
        lastTimestamp = now
        if now - lastWrite >= 1 { write() }
    }

    private func write(force: Bool = false) {
        guard let reportURL else { return }
        if let startedAt, let lastTimestamp {
            report.elapsedS = lastTimestamp - startedAt
            report.ratioMsPerS = report.elapsedS > 0 ? report.hitchTimeMs / report.elapsedS : 0
        }
        report.updatedAt = Date()
        lastWrite = lastTimestamp ?? 0
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(report) else { return }
        try? data.write(to: reportURL, options: .atomic)
    }
}
