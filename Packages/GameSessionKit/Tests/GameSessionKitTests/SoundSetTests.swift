import Foundation
import Testing
@testable import GameSessionKit

@Suite("Sound preferences")
@MainActor struct SoundSetTests {
    @Test("Each sound set survives relaunch and changing it preserves the mute preference", arguments: SoundSet.allCases)
    func persistence(set: SoundSet) {
        let suite = "SoundSetTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.soundSet == .recordedWood)
        settings.sounds = false
        settings.soundSet = set
        let restored = AppSettings(defaults: defaults)
        #expect(restored.soundSet == set)
        #expect(!restored.sounds)
    }

    @Test("An obsolete sound-set value falls back without changing mute")
    func unknownValue() {
        let suite = "SoundSetTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("removed-set", forKey: AppSettings.Key.soundSet)
        defaults.set(false, forKey: AppSettings.Key.sounds)
        let settings = AppSettings(defaults: defaults)
        #expect(settings.soundSet == .recordedWood)
        #expect(!settings.sounds)
    }
}
