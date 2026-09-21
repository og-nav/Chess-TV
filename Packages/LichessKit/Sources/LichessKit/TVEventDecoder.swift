import Foundation
import ChessCore

/// Decodes one NDJSON line from `/api/tv/{channel}/feed` into a `TVEvent`.
///
/// The wire format carries keys we do not model (`flair`, `patron`, `patronColor`, `id`, …);
/// they are ignored. `title`, `rating` and `seconds` are genuinely optional in live data.
struct TVEventDecoder: Sendable {
    private let json = JSONDecoder()

    /// - Returns: the decoded event, or `nil` for a well-formed line whose `t` we do not handle.
    /// - Throws: when the line is not the JSON we expect (caller logs and skips).
    func decode(line: String) throws -> TVEvent? {
        guard let data = line.data(using: .utf8) else { throw LichessError.malformedBody }
        return try decode(data: data)
    }

    func decode(data: Data) throws -> TVEvent? {
        do {
            return try json.decode(Wire.self, from: data).event
        } catch TVEventDecodingError.unknownEventType(let type) {
            log.debug("Ignoring unknown TV event type \(type, privacy: .public)")
            return nil
        }
    }
}

// MARK: - Wire shapes

private struct Wire: Decodable {
    let event: TVEvent

    enum CodingKeys: String, CodingKey { case t, d }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .t)
        switch type {
        case "featured":
            let d = try container.decode(FeaturedPayload.self, forKey: .d)
            event = .featured(
                gameId: d.id,
                orientation: PieceColor(wire: d.orientation) ?? .white,
                players: d.players.map(\.player),
                fen: d.fen
            )
        case "fen":
            let d = try container.decode(FenPayload.self, forKey: .d)
            event = .fen(fen: d.fen, lastMove: d.lm, whiteClock: d.wc, blackClock: d.bc)
        default:
            throw TVEventDecodingError.unknownEventType(type)
        }
    }
}

private struct FeaturedPayload: Decodable {
    let id: String
    let orientation: String
    let players: [PlayerPayload]
    let fen: String
}

private struct FenPayload: Decodable {
    let fen: String
    let lm: String?
    let wc: Int?
    let bc: Int?
}

private struct PlayerPayload: Decodable {
    struct User: Decodable {
        let name: String?
        let title: String?
    }
    let color: String
    let user: User?
    /// Present instead of `user` for engine opponents on the `computer` channel.
    let ai: Int?
    let name: String?
    let rating: Int?
    let seconds: Int?

    var player: TVPlayer {
        TVPlayer(
            name: user?.name ?? name ?? ai.map { "Stockfish level \($0)" } ?? "Anonymous",
            title: user?.title,
            rating: rating,
            color: PieceColor(wire: color) ?? .white,
            secondsRemaining: seconds
        )
    }
}

extension PieceColor {
    /// Maps the Lichess `"white"` / `"black"` strings. `PieceColor` is not `RawRepresentable`.
    init?(wire: String) {
        switch wire {
        case "white": self = .white
        case "black": self = .black
        default: return nil
        }
    }
}
