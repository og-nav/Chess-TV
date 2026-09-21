// Fixture mode: the app runs for real, but every request it makes is answered from the fixtures
// in the bundle, so a UI test (or a person at a simulator) sees populated shelves, a board that
// moves, a broadcast round with five boards and a follow server that never loses anything,
// without Lichess or the push server in the loop.
//
// Off unless the process was launched with `-uiFixtures`, and compiled to nothing in Release.
// The switches, all launch arguments:
//
//   -uiFixtures                 turn it on
//   -keepState                  keep UserDefaults and the follow file from the previous launch
//   -fixtureMoveInterval 2.5    seconds between live moves on a streamed board
//   -hitchReport <path>         write a running frame-lag summary to this file (see HitchMonitor)
//
// `AppSettings` reads `-engineEnabled NO` and friends from the argument domain on its own.
import Foundation

enum FixtureMode {

    static let isActive: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-uiFixtures")
        #else
        false
        #endif
    }()

    static var keepsState: Bool { ProcessInfo.processInfo.arguments.contains("-keepState") }

    /// Seconds between live moves on a streamed board.
    static var moveInterval: TimeInterval {
        argument("-fixtureMoveInterval").flatMap(Double.init).map { max(0.05, $0) } ?? 2.5
    }

    /// The value after a `-flag`, if the flag was given with one.
    static func argument(_ flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// Call first thing in the app's `init`, before anything builds a `URLSession`: the network
    /// swizzle only reaches sessions created after it.
    @discardableResult
    static func activateIfRequested() -> Bool {
        #if DEBUG
        guard isActive else { return false }
        if !keepsState { resetState() }
        FixtureNetwork.install()
        Task { @MainActor in HitchMonitor.startIfRequested() }
        return true
        #else
        return false
        #endif
    }

    /// A fresh install: no settings, no "Continue watching", no follows, no push identity.
    private static func resetState() {
        let defaults = UserDefaults.standard
        if let bundleId = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: bundleId)
        }
        defaults.removePersistentDomain(forName: "group.com.navin.chesstv")
        let manager = FileManager.default
        var candidates: [URL] = []
        if let group = manager.containerURL(forSecurityApplicationGroupIdentifier: "group.com.navin.chesstv") {
            candidates.append(group.appendingPathComponent("follows.json"))
        }
        if let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(support.appendingPathComponent("follows.json"))
        }
        for url in candidates { try? manager.removeItem(at: url) }
    }
}
