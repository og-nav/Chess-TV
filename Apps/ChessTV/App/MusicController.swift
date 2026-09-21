// Apple Music while you watch: authorization, the playlists the Settings screen offers, and
// playback. Every MusicKit call in the app lives in this file.
//
// tvOS 26 has the whole MusicKit surface we need: MusicAuthorization (tvOS 15),
// MusicSubscription (tvOS 15), MusicLibraryRequest<Playlist> (tvOS 16),
// MusicCatalogSearchRequest (tvOS 15) and ApplicationMusicPlayer (tvOS 15).
import Foundation
import MusicKit
import SwiftUI
import os

let musicLog = Logger(subsystem: "com.navin.chesstv", category: "Music")

// MARK: - The playlist list

/// The two things the de-duplication needs from a playlist. It exists so the ordering rules can
/// be tested without building a MusicKit value or reaching the network.
protocol MusicPlaylistNaming {
    var id: String { get }
    var name: String { get }
}

/// One playlist the Music row can offer, whether it came from the library or the catalog.
struct MusicPlaylistItem: MusicPlaylistNaming, Identifiable, Equatable, Sendable {

    enum Origin: String, Sendable {
        case library
        case catalog
    }

    let id: String
    let name: String
    /// The curator, or the track count for a library playlist. Nil when neither is known.
    let subtitle: String?
    let origin: Origin
    /// Nil when the playlist has no artwork, and always nil in tests.
    let artwork: Artwork?

    init(id: String, name: String, subtitle: String? = nil, origin: Origin, artwork: Artwork? = nil) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.origin = origin
        self.artwork = artwork
    }
}

enum MusicPlaylists {

    /// The search terms used when the library has nothing to offer, in the order they are tried.
    static let searchTerms = ["lofi", "chill", "study beats", "jazz"]

    /// Library playlists first, in the order the library gave them, then the catalog results in
    /// search order. A repeated id is dropped, and so is a later playlist whose name matches one
    /// already kept, ignoring case and surrounding space: the four searches overlap heavily and
    /// "Lofi Beats" must not appear four times.
    static func ordered<Item: MusicPlaylistNaming>(library: [Item], catalog: [Item]) -> [Item] {
        var seenIDs = Set<String>()
        var seenNames = Set<String>()
        var result: [Item] = []
        for item in library + catalog {
            guard !item.id.isEmpty else { continue }
            guard seenIDs.insert(item.id).inserted else { continue }
            let key = item.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !key.isEmpty, !seenNames.insert(key).inserted { continue }
            result.append(item)
        }
        return result
    }
}

// MARK: - Where the playlists come from

/// What `MusicController` needs from MusicKit. The tests hand it a fake, so no test ever asks
/// for authorization, hits the catalog, or touches the player.
protocol MusicPlaylistProviding: Sendable {
    func libraryPlaylists() async throws -> [MusicPlaylistItem]
    func catalogPlaylists(matching term: String) async throws -> [MusicPlaylistItem]
    /// The playable playlist behind an id, if this provider has seen it.
    func playlist(for id: String) async -> Playlist?
}

/// The real one. It keeps the `Playlist` values it handed out so the controller can queue one
/// later by id alone.
actor MusicKitPlaylistProvider: MusicPlaylistProviding {

    private var playables: [String: Playlist] = [:]

    /// How many catalog playlists each search term contributes before de-duplication.
    private static let perTermLimit = 5

    func libraryPlaylists() async throws -> [MusicPlaylistItem] {
        let request = MusicLibraryRequest<Playlist>()
        let response = try await request.response()
        return response.items.map { store($0, origin: .library) }
    }

    func catalogPlaylists(matching term: String) async throws -> [MusicPlaylistItem] {
        var request = MusicCatalogSearchRequest(term: term, types: [Playlist.self])
        request.limit = Self.perTermLimit
        let response = try await request.response()
        return response.playlists.map { store($0, origin: .catalog) }
    }

    func playlist(for id: String) async -> Playlist? {
        playables[id]
    }

    private func store(_ playlist: Playlist, origin: MusicPlaylistItem.Origin) -> MusicPlaylistItem {
        let id = playlist.id.rawValue
        playables[id] = playlist
        return MusicPlaylistItem(
            id: id,
            name: playlist.name,
            subtitle: playlist.curatorName ?? playlist.shortDescription,
            origin: origin,
            artwork: playlist.artwork
        )
    }
}

// MARK: - The controller

@Observable
@MainActor
final class MusicController {

    /// What the Music row should say before it can offer anything.
    enum Readiness: Equatable {
        case notDetermined
        case denied
        case restricted
        case checking
        case noSubscription
        case ready
    }

    private(set) var authorization: MusicAuthorization.Status
    /// Nil until `MusicSubscription.current` has answered once.
    private(set) var canPlayCatalogContent: Bool?
    private(set) var playlists: [MusicPlaylistItem] = []
    private(set) var isLoadingPlaylists = false
    private(set) var isPlaying = false
    private(set) var trackTitle: String?
    private(set) var trackArtist: String?
    /// The last thing that went wrong, for the state line. Nil once something works.
    private(set) var lastError: String?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let provider: any MusicPlaylistProviding
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var subscriptionTask: Task<Void, Never>?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var didStart = false
    /// True once a queue has been handed to the player, so `play()` need not rebuild it.
    @ObservationIgnored private var queuedPlaylistID: String?

    init(settings: AppSettings, provider: any MusicPlaylistProviding = MusicKitPlaylistProvider()) {
        self.settings = settings
        self.provider = provider
        self.authorization = MusicAuthorization.currentStatus
    }

    // MARK: Readiness

    var readiness: Readiness {
        switch authorization {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .authorized:
            switch canPlayCatalogContent {
            case .none: .checking
            case .some(false): .noSubscription
            case .some(true): .ready
            }
        @unknown default: .notDetermined
        }
    }

    var selectedPlaylistID: String? { settings.musicPlaylistID }
    var selectedPlaylistName: String? { settings.musicPlaylistName }

    /// One line for the game-screen footer, nil unless something is playing.
    var nowPlayingLine: String? {
        guard isPlaying, let title = trackTitle, !title.isEmpty else { return nil }
        guard let artist = trackArtist, !artist.isEmpty else { return "\u{266A} \(title)" }
        return "\u{266A} \(title) \u{00B7} \(artist)"
    }

    // MARK: Launch

    func start() {
        guard !didStart else { return }
        didStart = true
        musicLog.notice("Apple Music authorization is \(self.authorization.rawValue, privacy: .public)")
        guard authorization == .authorized else { return }
        observeSubscription()
        loadPlaylists()
    }

    func teardown() {
        loadTask?.cancel()
        subscriptionTask?.cancel()
        monitorTask?.cancel()
    }

    /// The "Connect Apple Music" button.
    func requestAuthorization() async {
        let status = await MusicAuthorization.request()
        authorization = status
        musicLog.notice("Authorization request returned \(status.rawValue, privacy: .public)")
        guard status == .authorized else { return }
        observeSubscription()
        loadPlaylists()
    }

    private func observeSubscription() {
        guard subscriptionTask == nil else { return }
        subscriptionTask = Task { @MainActor [weak self] in
            do {
                let current = try await MusicSubscription.current
                self?.apply(current)
            } catch {
                musicLog.error("Subscription check failed: \(String(describing: error), privacy: .public)")
                self?.canPlayCatalogContent = false
            }
            for await update in MusicSubscription.subscriptionUpdates {
                guard let self, !Task.isCancelled else { return }
                self.apply(update)
            }
        }
    }

    private func apply(_ subscription: MusicSubscription) {
        canPlayCatalogContent = subscription.canPlayCatalogContent
        musicLog.notice("Subscription: \(subscription.description, privacy: .public)")
    }

    // MARK: Playlists

    func loadPlaylists() {
        guard authorization == .authorized, loadTask == nil else { return }
        isLoadingPlaylists = true
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let library = await self.fetchLibrary()
            var catalog: [MusicPlaylistItem] = []
            for term in MusicPlaylists.searchTerms {
                catalog += await self.fetchCatalog(term)
            }
            self.isLoadingPlaylists = false
            self.loadTask = nil
            guard !Task.isCancelled else { return }
            self.playlists = MusicPlaylists.ordered(library: library, catalog: catalog)
            musicLog.notice("Offering \(self.playlists.count) playlists (\(library.count) from the library)")
        }
    }

    private func fetchLibrary() async -> [MusicPlaylistItem] {
        do {
            return try await provider.libraryPlaylists()
        } catch {
            // A tvOS without iCloud Music Library simply has no library playlists; the curated
            // catalog searches below still fill the row.
            musicLog.notice("No library playlists: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    private func fetchCatalog(_ term: String) async -> [MusicPlaylistItem] {
        do {
            return try await provider.catalogPlaylists(matching: term)
        } catch {
            musicLog.error("Catalog search for \(term, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            lastError = "Apple Music could not be reached."
            return []
        }
    }

    // MARK: Selection and playback

    func select(_ item: MusicPlaylistItem) {
        settings.musicPlaylistID = item.id
        settings.musicPlaylistName = item.name
        queuedPlaylistID = nil
        musicLog.notice("Selected playlist \(item.name, privacy: .public)")
        Task { await play() }
    }

    func isSelected(_ item: MusicPlaylistItem) -> Bool {
        item.id == settings.musicPlaylistID
    }

    func toggle() async {
        if isPlaying {
            pause()
        } else {
            await play()
        }
    }

    /// Play/Pause on the Siri Remote. Doing nothing is the right answer when Apple Music has
    /// not been connected or no playlist has been picked, but it is never silent: the log says
    /// which of the two it was, since the screen has no room to.
    func toggleFromRemote() async {
        guard readiness == .ready else {
            musicLog.notice("Play/Pause ignored: Apple Music is \(String(describing: self.readiness), privacy: .public)")
            return
        }
        guard settings.musicPlaylistID != nil else {
            musicLog.notice("Play/Pause ignored: no playlist picked yet (Settings \u{203A} Music)")
            return
        }
        await toggle()
    }

    func play() async {
        guard readiness == .ready else { return }
        guard let id = settings.musicPlaylistID else { return }
        do {
            if queuedPlaylistID != id {
                guard let playlist = await provider.playlist(for: id) else {
                    musicLog.error("No playable playlist for \(id, privacy: .public)")
                    return
                }
                let player = ApplicationMusicPlayer.shared
                player.queue = [playlist]
                player.state.shuffleMode = .songs
                queuedPlaylistID = id
            }
            try await ApplicationMusicPlayer.shared.play()
            settings.musicWasPlaying = true
            lastError = nil
            startMonitoring()
            refreshNowPlaying()
        } catch {
            queuedPlaylistID = nil
            lastError = "Playback failed. \(error.localizedDescription)"
            musicLog.error("Play failed: \(String(describing: error), privacy: .public)")
            refreshNowPlaying()
        }
    }

    func pause() {
        ApplicationMusicPlayer.shared.pause()
        settings.musicWasPlaying = false
        refreshNowPlaying()
        stopMonitoring()
    }

    func next() async {
        guard readiness == .ready, queuedPlaylistID != nil else { return }
        do {
            try await ApplicationMusicPlayer.shared.skipToNextEntry()
        } catch {
            musicLog.error("Skip failed: \(String(describing: error), privacy: .public)")
        }
        refreshNowPlaying()
    }

    // MARK: Now playing

    /// The player publishes through Combine, which would drag an `ObservableObject` across the
    /// actor boundary; a one-second read while something is playing is cheaper to reason about.
    private func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.refreshNowPlaying()
            }
        }
    }

    private func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func refreshNowPlaying() {
        let player = ApplicationMusicPlayer.shared
        switch player.state.playbackStatus {
        case .playing, .seekingForward, .seekingBackward:
            isPlaying = true
        default:
            isPlaying = false
        }
        let entry = player.queue.currentEntry
        trackTitle = entry?.title
        trackArtist = entry?.subtitle
    }

    // MARK: Scene phase

    /// Music stops when the app leaves the screen; whether it was playing is remembered so the
    /// next activation can pick it back up.
    func enterBackground() {
        stopMonitoring()
        guard isPlaying else {
            settings.musicWasPlaying = false
            return
        }
        musicLog.notice("Entering background: pausing Apple Music")
        ApplicationMusicPlayer.shared.pause()
        settings.musicWasPlaying = true
        isPlaying = false
    }

    /// Never starts music on its own: only picks up what the user had going.
    func becameActive() {
        guard didStart, settings.musicWasPlaying, settings.musicPlaylistID != nil else { return }
        musicLog.notice("Becoming active: resuming Apple Music")
        Task { await play() }
    }
}
