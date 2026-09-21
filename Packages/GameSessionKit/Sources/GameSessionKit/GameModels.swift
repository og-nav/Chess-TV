// Small value types the reducer, the views and the tests all share.
import Foundation
import ChessCore
import LichessKit

/// One side's identity, as the feed reports it.
public struct PlayerInfo: Equatable, Sendable {
    public var name: String
    public var title: String?
    public var rating: Int?

    public init(name: String, title: String?, rating: Int?) {
        self.name = name
        self.title = title
        self.rating = rating
    }

    public init(_ player: TVPlayer) {
        self.init(name: player.name, title: player.title, rating: player.rating)
    }
}

/// One ply in the side panel's move list. The TV feed carries no SAN, so ChessCore works it out
/// from the position before the move (see `SAN.notation(for:in:)`).
public struct MoveEntry: Equatable, Sendable {
    /// The move as the feed spelled it, e.g. "e2e4" (or "e1h1" for castling).
    public let uci: String
    /// What the move list shows: "e4", "Nbd7", "O-O", "Qxf7#". Falls back to `uci` when the
    /// position before the move is unknown — the first ply of a stream we joined mid-game.
    public let san: String
    /// The FEN *after* the move.
    public let fen: String
    /// The full-move number this ply belongs to.
    public let moveNumber: Int
    /// The color that played it.
    public let color: PieceColor
    public init(uci: String, san: String, fen: String, moveNumber: Int, color: PieceColor) {
        self.uci = uci; self.san = san; self.fen = fen; self.moveNumber = moveNumber; self.color = color
    }
}

/// The clocks exactly as received, plus when they arrived, so the UI can count down locally.
public struct ClockReading: Equatable, Sendable {
    public var whiteSeconds: Int?
    public var blackSeconds: Int?
    /// The monotonic instant the event carrying these numbers was accepted.
    public var receivedAt: ContinuousClock.Instant
    /// Whose clock is running.
    public var sideToMove: PieceColor
    public init(whiteSeconds: Int?, blackSeconds: Int?, receivedAt: ContinuousClock.Instant, sideToMove: PieceColor) {
        self.whiteSeconds = whiteSeconds; self.blackSeconds = blackSeconds; self.receivedAt = receivedAt; self.sideToMove = sideToMove
    }
}

/// What the last accepted move should sound like.
public enum MoveOutcome: Sendable, Equatable, CaseIterable {
    case move, capture, check
}

/// Turning a `ClockReading` into the number the screen shows.
public enum ClockDisplay {

    /// The seconds to display for `color`.
    ///
    /// The side to move counts down from the received value while the feed is `live`; everything
    /// else shows the received value unchanged (that is the honest number when we are
    /// reconnecting, and the idle side's clock is not running anyway). Never below zero.
    public static func remainingSeconds(
        for color: PieceColor,
        clocks: ClockReading?,
        isLive: Bool,
        now: ContinuousClock.Instant
    ) -> Int? {
        guard let clocks else { return nil }
        guard let received = (color == .white ? clocks.whiteSeconds : clocks.blackSeconds) else { return nil }
        guard isLive, color == clocks.sideToMove else { return max(0, received) }
        let elapsed = clocks.receivedAt.duration(to: now).inSeconds
        return max(0, Int((Double(received) - elapsed).rounded(.down)))
    }

    /// "2:12", "0:09", "1:02:03".
    public static func text(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }
}

extension Duration {
    /// Whole and fractional seconds as a Double.
    public var inSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
    }
}

/// The order the Lichess TV shelf shows: the headline channels first, then the variants.
public enum ChannelOrder {
    public static let featured: [TVChannel] = [.best, .bullet, .blitz, .rapid, .classical, .ultraBullet, .chess960]
    public static let all: [TVChannel] = featured + TVChannel.allCases.filter { !featured.contains($0) }
}
