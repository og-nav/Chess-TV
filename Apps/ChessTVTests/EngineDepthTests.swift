import Testing
import Foundation
@testable import ChessTV

@Suite("The engine depth setting survives a relaunch")
@MainActor
struct EngineDepthSettingTests {

    private func freshDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("A fresh install searches to Standard, and a chosen level comes back after a restart")
    func roundTrip() {
        let suite = "chesstv.enginedepth.roundtrip"
        let defaults = freshDefaults(suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = AppSettings(defaults: defaults)
        #expect(first.engineDepth == .standard)
        #expect(first.engineDepth.depth == 24)

        first.engineDepth = .deep

        let second = AppSettings(defaults: defaults)
        #expect(second.engineDepth == .deep)
        #expect(second.engineDepth.depth == 32)
    }

    @Test("A level this build no longer knows falls back to Standard")
    func unknownLevel() {
        let suite = "chesstv.enginedepth.unknown"
        let defaults = freshDefaults(suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("ludicrous", forKey: AppSettings.Key.engineDepth)

        #expect(AppSettings(defaults: defaults).engineDepth == .standard)
    }

    @Test("Every level names itself and caps the search where it says it does")
    func levels() {
        #expect(EngineDepth.allCases.map(\.displayName) == ["Light", "Standard", "Deep", "Maximum"])
        #expect(EngineDepth.allCases.map(\.depth) == [18, 24, 32, 40])
    }
}
