// The navigation model: what the NavigationStack can push, how a source is spelled in
// UserDefaults, and the launch arguments that jump straight to a screen.
import Foundation
import LichessKit
import ChessCore

/// Everything GameScreen needs that the event stream does not carry: the header title and,
/// for broadcasts, the federations and FIDE ids the board list already knew.
public struct GameDestination: Hashable, Sendable {
    public let source: GameSource
    /// Title for the header, e.g. "Blitz · Lichess TV". Nil means "work it out from the source".
    public var title: String?
    public var whiteFederation: String?
    public var blackFederation: String?
    /// FIDE ids, when the board list had them: the key to a player's portrait.
    public var whiteFideId: Int?
    public var blackFideId: Int?
    /// The portraits the round payload already carried, so the panel can show a face before —
    /// or without — a FIDE lookup of its own.
    public var whitePhoto: PlayerPhoto?
    public var blackPhoto: PlayerPhoto?
    /// Position already visible on the round wall; renders before any new network response.
    public var preview: GamePreview?

    public init(
        source: GameSource,
        title: String? = nil,
        whiteFederation: String? = nil,
        blackFederation: String? = nil,
        whiteFideId: Int? = nil,
        blackFideId: Int? = nil,
        whitePhoto: PlayerPhoto? = nil,
        blackPhoto: PlayerPhoto? = nil,
        preview: GamePreview? = nil
    ) {
        self.source = source
        self.title = title
        self.whiteFederation = whiteFederation
        self.blackFederation = blackFederation
        self.whiteFideId = whiteFideId
        self.blackFideId = blackFideId
        self.whitePhoto = whitePhoto ?? preview?.board.white?.photo
        self.blackPhoto = blackPhoto ?? preview?.board.black?.photo
        self.preview = preview
    }
}

// MARK: - Persistence

extension GameSource {
    /// A flat spelling used both by `AppSettings.lastSource` and by the `-open` launch argument.
    public var storageKey: String {
        switch self {
        case .tvChannel(let channel): "tv:\(channel.rawValue)"
        case .arena(let id): "arena:\(id)"
        case .broadcastBoard(let roundId, let gameId): "board:\(roundId):\(gameId)"
        }
    }

    public init?(storageKey: String) {
        let parts = storageKey.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch (parts.first, parts.count) {
        case ("tv", 2):
            guard let channel = TVChannel(rawValue: parts[1]) else { return nil }
            self = .tvChannel(channel)
        case ("arena", 2):
            guard !parts[1].isEmpty else { return nil }
            self = .arena(tournamentId: parts[1])
        case ("board", 3):
            guard !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
            self = .broadcastBoard(roundId: parts[1], gameId: parts[2])
        default:
            return nil
        }
    }
}


/// Ephemeral navigation handoff. The anchor is monotonic and never persisted to disk.
public struct GamePreview: Hashable, Sendable {
    public let board: BroadcastBoard
    public let receivedAt: ContinuousClock.Instant
    public let clocksRunning: Bool
    public init(board: BroadcastBoard, receivedAt: ContinuousClock.Instant, clocksRunning: Bool) {
        self.board = board; self.receivedAt = receivedAt; self.clocksRunning = clocksRunning
    }
    func clocks(at now: ContinuousClock.Instant) -> ClockReading {
        let side = (try? Position(fen: board.fen))?.sideToMove ?? .white
        let reading = ClockReading(whiteSeconds: board.white?.clockSeconds, blackSeconds: board.black?.clockSeconds,
                                   receivedAt: receivedAt, sideToMove: side)
        return ClockReading(
            whiteSeconds: ClockDisplay.remainingSeconds(for: .white, clocks: reading, isLive: clocksRunning && board.isOngoing, now: now),
            blackSeconds: ClockDisplay.remainingSeconds(for: .black, clocks: reading, isLive: clocksRunning && board.isOngoing, now: now),
            receivedAt: now, sideToMove: side)
    }
}
