// Everything the Settings screen changes, persisted in UserDefaults.
//
// Launch arguments of the form `-sounds NO` land in NSArgumentDomain, which UserDefaults
// searches before the persistent domain, so simulator runs honour them for free. The screen the
// app opens on is not a setting any more: see `LaunchArguments` for `-open`.
import Foundation
import ChessUI
import LichessKit

/// How deep Stockfish searches each position. Deeper search keeps the fanless Apple TV's chip
/// busy for longer, so this is the user's dial between a cool box and a sharper evaluation.
public enum EngineDepth: String, CaseIterable, Sendable, Codable {
    case light
    case standard
    case deep
    case maximum

    public var depth: Int {
        switch self {
        case .light: 18
        case .standard: 24
        case .deep: 32
        case .maximum: 40
        }
    }

    public var displayName: String {
        switch self {
        case .light: "Light"
        case .standard: "Standard"
        case .deep: "Deep"
        case .maximum: "Maximum"
        }
    }
}

@Observable
@MainActor
public final class AppSettings {

    public enum Key {
        public static let boardTheme = "boardTheme"
        public static let pieceSet = "pieceSet"
        public static let coordinates = "coordinates"
        public static let sounds = "sounds"
        public static let engineEnabled = "engineEnabled"
        public static let engineDepth = "engineDepth"
        public static let followFeaturedPlayer = "followFeaturedPlayer"
        public static let keepTVOn = "keepTVOn"
        public static let flipBoard = "flipBoard"
        public static let tournamentAlerts = "tournamentAlerts"
        public static let lastSource = "lastSource"
        public static let musicPlaylistID = "musicPlaylistID"
        public static let musicPlaylistName = "musicPlaylistName"
        public static let musicWasPlaying = "musicWasPlaying"
    }

    @ObservationIgnored private let defaults: UserDefaults

    public var boardThemeName: String { didSet { defaults.set(boardThemeName, forKey: Key.boardTheme) } }
    public var pieceSet: PieceSet { didSet { defaults.set(pieceSet.rawValue, forKey: Key.pieceSet) } }
    public var coordinates: Bool { didSet { defaults.set(coordinates, forKey: Key.coordinates) } }
    public var sounds: Bool { didSet { defaults.set(sounds, forKey: Key.sounds) } }
    public var engineEnabled: Bool { didSet { defaults.set(engineEnabled, forKey: Key.engineEnabled) } }
    /// How hard the engine works on each position. See `EngineDepth`.
    public var engineDepth: EngineDepth { didSet { defaults.set(engineDepth.rawValue, forKey: Key.engineDepth) } }
    public var followFeaturedPlayer: Bool { didSet { defaults.set(followFeaturedPlayer, forKey: Key.followFeaturedPlayer) } }
    public var keepTVOn: Bool { didSet { defaults.set(keepTVOn, forKey: Key.keepTVOn) } }
    /// Watch from Black's side. Applied after "follow the featured player", so both can be on.
    public var flipBoard: Bool { didSet { defaults.set(flipBoard, forKey: Key.flipBoard) } }
    /// Toasts for results and time scrambles on the other boards of a broadcast round.
    public var tournamentAlerts: Bool { didSet { defaults.set(tournamentAlerts, forKey: Key.tournamentAlerts) } }
    /// The last source the user opened, for the "Continue watching" card. Stored as a flat key
    /// ("tv:blitz", "arena:abc123", "board:round:game") so a new case never breaks an old install.
    public var lastSource: GameSource? {
        didSet { defaults.set(lastSource?.storageKey, forKey: Key.lastSource) }
    }
    /// The Apple Music playlist the Music row plays. The name is stored beside the id so the
    /// screen has something to show before MusicKit has answered.
    public var musicPlaylistID: String? { didSet { defaults.set(musicPlaylistID, forKey: Key.musicPlaylistID) } }
    public var musicPlaylistName: String? { didSet { defaults.set(musicPlaylistName, forKey: Key.musicPlaylistName) } }
    /// True while the user has music going, so backgrounding the app can pause it and the next
    /// activation can resume exactly what they left playing.
    public var musicWasPlaying: Bool { didSet { defaults.set(musicWasPlaying, forKey: Key.musicWasPlaying) } }

    public init(defaults: UserDefaults = .standard, defaultEngineDepth: EngineDepth = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.boardTheme: BoardTheme.sage.name,
            Key.pieceSet: PieceSet.cburnett.rawValue,
            Key.coordinates: true,
            Key.sounds: true,
            Key.engineEnabled: true,
            Key.engineDepth: defaultEngineDepth.rawValue,
            Key.followFeaturedPlayer: false,
            Key.keepTVOn: true,
            Key.flipBoard: false,
            Key.tournamentAlerts: true,
            Key.musicWasPlaying: false,
        ])
        boardThemeName = defaults.string(forKey: Key.boardTheme) ?? BoardTheme.sage.name
        pieceSet = PieceSet(rawValue: defaults.string(forKey: Key.pieceSet) ?? "") ?? .cburnett
        coordinates = defaults.bool(forKey: Key.coordinates)
        sounds = defaults.bool(forKey: Key.sounds)
        engineEnabled = defaults.bool(forKey: Key.engineEnabled)
        engineDepth = EngineDepth(rawValue: defaults.string(forKey: Key.engineDepth) ?? "") ?? .standard
        followFeaturedPlayer = defaults.bool(forKey: Key.followFeaturedPlayer)
        keepTVOn = defaults.bool(forKey: Key.keepTVOn)
        flipBoard = defaults.bool(forKey: Key.flipBoard)
        tournamentAlerts = defaults.bool(forKey: Key.tournamentAlerts)
        lastSource = (defaults.string(forKey: Key.lastSource)).flatMap(GameSource.init(storageKey:))
        musicPlaylistID = defaults.string(forKey: Key.musicPlaylistID)
        musicPlaylistName = defaults.string(forKey: Key.musicPlaylistName)
        musicWasPlaying = defaults.bool(forKey: Key.musicWasPlaying)
    }

    public var boardTheme: BoardTheme {
        BoardTheme.all.first { $0.name == boardThemeName } ?? .sage
    }
}
