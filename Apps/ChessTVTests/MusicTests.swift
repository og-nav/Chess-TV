import Testing
import Foundation
import MusicKit
@testable import ChessTV

/// A stand-in for `MusicPlaylistItem` so the ordering rules can be checked without building a
/// MusicKit value or asking MusicKit for anything.
private struct FakePlaylist: MusicPlaylistNaming, Equatable {
    let id: String
    let name: String
}

@Suite("Which playlists the Music row offers, in what order")
struct MusicPlaylistOrderingTests {

    @Test("Library playlists come first, then the catalog, each in the order given")
    func libraryFirst() {
        let library = [FakePlaylist(id: "l1", name: "Evening"), FakePlaylist(id: "l2", name: "Focus")]
        let catalog = [FakePlaylist(id: "c1", name: "Lofi Beats"), FakePlaylist(id: "c2", name: "Jazz Chill")]
        let ordered = MusicPlaylists.ordered(library: library, catalog: catalog)
        #expect(ordered.map(\.id) == ["l1", "l2", "c1", "c2"])
    }

    @Test("A repeated id is kept once, at its first position")
    func duplicateIDs() {
        let catalog = [
            FakePlaylist(id: "c1", name: "Lofi Beats"),
            FakePlaylist(id: "c2", name: "Study Beats"),
            FakePlaylist(id: "c1", name: "Lofi Beats"),
        ]
        let ordered = MusicPlaylists.ordered(library: [], catalog: catalog)
        #expect(ordered.map(\.id) == ["c1", "c2"])
    }

    @Test("The four searches overlap, so a repeated name is dropped whatever its id")
    func duplicateNames() {
        let catalog = [
            FakePlaylist(id: "c1", name: "Lofi Beats"),
            FakePlaylist(id: "c9", name: "  lofi beats "),
            FakePlaylist(id: "c2", name: "Pure Jazz"),
        ]
        let ordered = MusicPlaylists.ordered(library: [], catalog: catalog)
        #expect(ordered.map(\.id) == ["c1", "c2"])
    }

    @Test("A catalog playlist the user already has in their library is dropped")
    func catalogDoesNotRepeatLibrary() {
        let library = [FakePlaylist(id: "l1", name: "Chill Vibes")]
        let catalog = [FakePlaylist(id: "c1", name: "Chill Vibes"), FakePlaylist(id: "c2", name: "Late Night")]
        let ordered = MusicPlaylists.ordered(library: library, catalog: catalog)
        #expect(ordered.map(\.id) == ["l1", "c2"])
    }

    @Test("A playlist with no id is not offered")
    func emptyIDsDropped() {
        let ordered = MusicPlaylists.ordered(
            library: [FakePlaylist(id: "", name: "Nameless")],
            catalog: [FakePlaylist(id: "c1", name: "Lofi Beats")]
        )
        #expect(ordered.map(\.id) == ["c1"])
    }

    @Test("Four search terms, in the documented order")
    func searchTerms() {
        #expect(MusicPlaylists.searchTerms == ["lofi", "chill", "study beats", "jazz"])
    }
}

@Suite("The music settings survive a relaunch")
@MainActor
struct MusicSettingsPersistenceTests {

    private func freshDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("A chosen playlist and the playing flag come back after a restart")
    func roundTrip() {
        let suite = "chesstv.music.roundtrip"
        let defaults = freshDefaults(suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = AppSettings(defaults: defaults)
        #expect(first.musicPlaylistID == nil)
        #expect(first.musicPlaylistName == nil)
        #expect(first.musicWasPlaying == false)

        first.musicPlaylistID = "pl.u-abc123"
        first.musicPlaylistName = "Lo-Fi Chess"
        first.musicWasPlaying = true

        let second = AppSettings(defaults: defaults)
        #expect(second.musicPlaylistID == "pl.u-abc123")
        #expect(second.musicPlaylistName == "Lo-Fi Chess")
        #expect(second.musicWasPlaying == true)
    }

    @Test("Clearing the selection clears both halves of it")
    func clearing() {
        let suite = "chesstv.music.clearing"
        let defaults = freshDefaults(suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = AppSettings(defaults: defaults)
        first.musicPlaylistID = "pl.u-abc123"
        first.musicPlaylistName = "Lo-Fi Chess"
        first.musicWasPlaying = true
        first.musicPlaylistID = nil
        first.musicPlaylistName = nil
        first.musicWasPlaying = false

        let second = AppSettings(defaults: defaults)
        #expect(second.musicPlaylistID == nil)
        #expect(second.musicPlaylistName == nil)
        #expect(second.musicWasPlaying == false)
    }
}

@Suite("Play/Pause on the Siri Remote")
@MainActor
struct MusicRemoteToggleTests {

    /// Answers nothing and reaches nothing. `playlist(for:)` returning nil is enough: the
    /// controller must not get that far when Apple Music is not connected.
    private struct SilentProvider: MusicPlaylistProviding {
        func libraryPlaylists() async throws -> [MusicPlaylistItem] { [] }
        func catalogPlaylists(matching term: String) async throws -> [MusicPlaylistItem] { [] }
        func playlist(for id: String) async -> Playlist? { nil }
    }

    private func controller(_ suite: String) -> (MusicController, AppSettings, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        return (MusicController(settings: settings, provider: SilentProvider()), settings, defaults)
    }

    @Test("With Apple Music not connected it is a no-op: no prompt, no state, no settings touched")
    func noOpUntilConnected() async {
        let suite = "chesstv.music.remotetoggle"
        let (music, settings, defaults) = controller(suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        // Nothing here has asked for authorization, so this is never `.ready`; the guard in
        // `toggleFromRemote()` is what the test is about.
        let before = music.authorization
        #expect(music.readiness != .ready)

        await music.toggleFromRemote()

        #expect(music.authorization == before)          // it did not ask
        #expect(music.isPlaying == false)
        #expect(music.lastError == nil)                 // and said nothing on screen
        #expect(settings.musicWasPlaying == false)
        #expect(settings.musicPlaylistID == nil)
        #expect(settings.musicPlaylistName == nil)
    }

    @Test("A chosen playlist is not enough on its own")
    func noOpWithAPlaylistButNoMusic() async {
        let suite = "chesstv.music.remotetoggle.chosen"
        let (music, settings, defaults) = controller(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.musicPlaylistID = "pl.u-abc123"
        settings.musicPlaylistName = "Lo-Fi Chess"

        await music.toggleFromRemote()

        #expect(music.isPlaying == false)
        #expect(settings.musicWasPlaying == false)      // untouched: nothing was queued
        #expect(music.lastError == nil)
    }
}
