// LichessKit — frozen contracts (see TV_BUILD_PLAN.md).
import Foundation
import Synchronization
import ChessCore

public enum TVChannel: String, CaseIterable, Sendable, Codable {
    case best, bullet, blitz, rapid, classical, ultraBullet, chess960, crazyhouse, antichess, atomic, horde, kingOfTheHill, racingKings, threeCheck, bot, computer

    public var displayName: String {
        switch self {
        case .best: "Top rated"; case .bullet: "Bullet"; case .blitz: "Blitz"; case .rapid: "Rapid"; case .classical: "Classical"
        case .ultraBullet: "UltraBullet"; case .chess960: "Chess960"; case .crazyhouse: "Crazyhouse"; case .antichess: "Antichess"
        case .atomic: "Atomic"; case .horde: "Horde"; case .kingOfTheHill: "King of the Hill"; case .racingKings: "Racing Kings"
        case .threeCheck: "Three-check"; case .bot: "Bots"; case .computer: "Computer"
        }
    }
    /// True for channels where standard-chess engine analysis is meaningful.
    public var isStandardChess: Bool {
        switch self { case .best, .bullet, .blitz, .rapid, .classical, .ultraBullet, .bot, .computer: true; default: false }
    }
}

public struct TVPlayer: Sendable, Equatable {
    public let name: String
    public let title: String?
    public let rating: Int?
    public let color: PieceColor
    public let secondsRemaining: Int?
    public init(name: String, title: String?, rating: Int?, color: PieceColor, secondsRemaining: Int?) {
        self.name = name; self.title = title; self.rating = rating; self.color = color; self.secondsRemaining = secondsRemaining
    }
}

public enum TVEvent: Sendable, Equatable {
    case featured(gameId: String, orientation: PieceColor, players: [TVPlayer], fen: String)
    case fen(fen: String, lastMove: String?, whiteClock: Int?, blackClock: Int?)
}

public struct TVChannelSummary: Sendable, Equatable {
    public let channel: TVChannel
    public let gameId: String
    public let userName: String
    public let rating: Int?
    public init(channel: TVChannel, gameId: String, userName: String, rating: Int?) {
        self.channel = channel; self.gameId = gameId; self.userName = userName; self.rating = rating
    }
}

public enum ConnectionState: Sendable, Equatable {
    case connecting
    case live
    case reconnecting(attempt: Int, nextRetryIn: Duration)
    case failed(String)
}

public protocol TVFeedStreaming: Sendable {
    /// Long-lived stream of decoded events. Reconnects internally with backoff; finishes only on cancellation
    /// or an unrecoverable error. Connection transitions are reported on `connectionStates`.
    func events(for channel: TVChannel) -> AsyncThrowingStream<TVEvent, Error>
    var connectionStates: AsyncStream<ConnectionState> { get }
}

public protocol TVChannelsFetching: Sendable {
    func currentGames() async throws -> [TVChannelSummary]
}

public enum LichessConfig {
    public static let baseURL = URL(string: "https://lichess.org")!

    /// The identity sent until the app configures one, so tests and the probe still send a
    /// valid header. The app replaces it at launch with the real version and contact.
    public static let defaultUserAgent = "ChessTV/0.1 (zzzlabshq@gmail.com)"

    /// Guarded because this is process-wide state a request may read from any thread. A plain
    /// `static var` is not Sendable under Swift 6, and a lock is cheaper to reason about than
    /// an actor on a value every request reads.
    private static let userAgentStorage = Mutex<String>(defaultUserAgent)
    private static let tokenStorage = Mutex<String?>(nil)
    public static var bearerToken: String? { tokenStorage.withLock { $0 } }

    /// Optional server credential. Apps remain anonymous. Nil explicitly clears it.
    public static func configure(token: String?) {
        let value = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        tokenStorage.withLock { $0 = value.flatMap { $0.isEmpty ? nil : $0 } }
    }

    /// `User-Agent` for every Lichess request, as the API policy asks: the app, its version and
    /// a contact. Read at request time, so configuring it after a session exists still counts.
    public static var userAgent: String { userAgentStorage.withLock { $0 } }

    /// Set once at launch, from the app, before any request goes out. Ignores an empty string
    /// so a misconfiguration cannot strip the header.
    public static func configure(userAgent: String) {
        let trimmed = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        userAgentStorage.withLock { $0 = trimmed }
    }
}
