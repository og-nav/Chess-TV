// Decoding the NDJSON fixtures without LichessKit's decoder, which is internal to that module.
import Foundation
import ChessCore
import LichessKit

enum FixtureFeed {

    /// Reads a fixture bundled with the test target and decodes every line into a TVEvent.
    static func events(named name: String) throws -> [TVEvent] {
        guard let url = Bundle(for: BundleToken.self).url(forResource: name, withExtension: "ndjson") else {
            throw FixtureError.missing(name)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .compactMap(decode)
    }

    enum FixtureError: Error { case missing(String), badLine(String) }

    static func decode(_ line: String) throws -> TVEvent? {
        guard let data = line.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["t"] as? String,
              let payload = object["d"] as? [String: Any]
        else { throw FixtureError.badLine(line) }

        switch type {
        case "featured":
            guard let id = payload["id"] as? String,
                  let fen = payload["fen"] as? String,
                  let rawPlayers = payload["players"] as? [[String: Any]]
            else { throw FixtureError.badLine(line) }
            let orientation = color(payload["orientation"] as? String) ?? .white
            let players: [TVPlayer] = rawPlayers.map { raw in
                let user = raw["user"] as? [String: Any]
                return TVPlayer(
                    name: (user?["name"] as? String) ?? (raw["name"] as? String) ?? "Anonymous",
                    title: user?["title"] as? String,
                    rating: raw["rating"] as? Int,
                    color: color(raw["color"] as? String) ?? .white,
                    secondsRemaining: raw["seconds"] as? Int
                )
            }
            return .featured(gameId: id, orientation: orientation, players: players, fen: fen)
        case "fen":
            guard let fen = payload["fen"] as? String else { throw FixtureError.badLine(line) }
            return .fen(
                fen: fen,
                lastMove: payload["lm"] as? String,
                whiteClock: payload["wc"] as? Int,
                blackClock: payload["bc"] as? Int
            )
        default:
            return nil
        }
    }

    private static func color(_ raw: String?) -> PieceColor? {
        switch raw { case "white": .white; case "black": .black; default: nil }
    }
}

private final class BundleToken {}
