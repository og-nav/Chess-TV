import Foundation
import ChessCore

/// A `TVEvent` with the one thing a viewer joining halfway through needs to know: whether the
/// event is part of the **history** the server replayed, or something that has just happened.
///
/// `TVEvent` is frozen — it cannot grow a case or a field — so the flag travels beside it.
/// Every stream that can replay history offers a `sourcedEvents…` method producing these, and
/// the plain `events…` method is that stream with the flag dropped.
///
/// A consumer typically fast-forwards through the historical events (no animation, no sound)
/// and animates the rest.
public struct SourcedEvent: Sendable, Equatable {
    public let event: TVEvent
    /// `true` when this event is part of the replayed history rather than a live move.
    public let isHistorical: Bool

    /// nil for a stream without an exact boundary, false inside a replay batch, true on its
    /// final event. Consumers can publish the entire historical reducer atomically.
    public let historyComplete: Bool?
    /// A validated in-memory warmup, not evidence that the provider has just updated its clocks.
    public let isCached: Bool

    public init(event: TVEvent, isHistorical: Bool, historyComplete: Bool? = nil, isCached: Bool = false) {
        self.event = event
        self.isHistorical = isHistorical
        self.historyComplete = historyComplete
        self.isCached = isCached
    }
}

/// Decides where the replayed history of `/api/stream/game/{id}` ends and the live game begins.
///
/// That endpoint replays the whole game from move one and then stays connected, with nothing in
/// the wire format to mark the join. Two signals settle it, whichever comes first:
///
/// * **The burst ends.** The replayed lines arrive together, within a second or two; the first
///   gap of `gap` (1.5 s by default) between two lines means the replay is over and the
///   connection is now idling on a live game.
/// * **The position catches up.** When the caller already knows the live FEN — the TV channel
///   feed announces it with the featured game — the event that reaches that position is the last
///   of the replay, whatever the timing says.
///
/// The position an event carries is compared on placement and side to move only, because the TV
/// feed sends two-field FENs while the game stream sends six.
///
/// Both signals are one-way: once the stream is live it never goes back to being history.
struct HistoryBoundaryDetector: Sendable {
    /// The silence that separates the replay burst from the first live move.
    static let defaultGap = Duration.milliseconds(1500)

    private let gap: Duration
    private let liveKey: String?
    private var lastEventAt: ContinuousClock.Instant?
    private var inBurst = true

    /// Number of events classified as history so far — the "history burst" count.
    private(set) var historicalCount = 0

    /// - Parameters:
    ///   - gap: the silence that ends the burst.
    ///   - liveFen: the position the game is known to be in right now, when the caller knows it.
    ///   - startedAt: when the connection opened; the first gap is measured from here.
    init(gap: Duration = HistoryBoundaryDetector.defaultGap, liveFen: String? = nil, startedAt: ContinuousClock.Instant? = nil) {
        self.gap = gap
        self.liveKey = liveFen.map(Self.key)
        self.lastEventAt = startedAt
    }

    /// Classifies one event and advances the boundary. `true` means "part of the replay".
    mutating func classify(_ event: TVEvent, at now: ContinuousClock.Instant = .now) -> Bool {
        defer { lastEventAt = now }

        // A game featured at its starting position has no replay to wait for. Otherwise a
        // fast opening (or a very short game) could remain classified as history until it ends.
        if case .featured(_, _, _, let fen) = event {
            if let liveKey, Self.key(fen) == liveKey { inBurst = false }
            return false
        }
        guard case .fen(let fen, _, _, _) = event else { return false }
        guard inBurst else { return false }

        if let lastEventAt, lastEventAt.duration(to: now) >= gap {
            inBurst = false
            return false
        }

        // Catching up to the announced live position ends the replay *after* this event: the
        // position itself is the last thing the viewer fast-forwards to.
        if let liveKey, Self.key(fen) == liveKey { inBurst = false }

        historicalCount += 1
        return true
    }

    /// `true` once the stream has been classified as live.
    var isLive: Bool { !inBurst }

    /// Placement and side to move: the part of a FEN two sources agree on.
    private static func key(_ fen: String) -> String {
        let fields = fen.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2 else { return fen }
        return "\(fields[0]) \(fields[1])"
    }
}

/// One item of the feed a `GameSourceStreamer` hands the app: an event, or the news that the
/// game on screen has ended.
///
/// The end of a game is not an event — it is the *absence* of any more of them — and `TVEvent`
/// is frozen, so it cannot be one. It travels as its own case instead, which is what lets the
/// screen show a result, make a sound and pause before the next game replaces it.
///
/// Only the combined stream produces these. The per-stream `sourcedEvents…` methods
/// (`GameStream`, `BroadcastPGNStream`) still hand back plain `SourcedEvent`s.
public enum FeedItem: Sendable, Equatable {
    case event(SourcedEvent)
    /// The game that was being shown is over. `status` is Lichess' own reason: `"mate"`,
    /// `"resign"`, `"outoftime"`, `"draw"`, `"stalemate"`, `"aborted"`, …
    case gameEnded(gameId: String, status: GameStatus)

    /// The event this item carries, or `nil` for a game-over item.
    public var sourced: SourcedEvent? {
        guard case .event(let sourced) = self else { return nil }
        return sourced
    }

    /// The bare event this item carries, or `nil` for a game-over item.
    public var event: TVEvent? { sourced?.event }
}
