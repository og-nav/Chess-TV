import Foundation
import Testing
@testable import LichessKit

/// Loads the NDJSON / JSON recordings captured from the live API.
enum Fixture: String, CaseIterable {
    case blitz = "feed-blitz"
    case bullet = "feed-bullet"
    case castling = "feed-castling"

    var data: Data {
        get throws {
            let url = try #require(
                Bundle.module.url(forResource: rawValue, withExtension: "ndjson", subdirectory: "Fixtures"),
                "missing fixture \(rawValue).ndjson"
            )
            return try Data(contentsOf: url)
        }
    }

    var lines: [String] {
        get throws {
            var decoder = NDJSONLineDecoder()
            var lines = try decoder.append(data)
            if let tail = decoder.flush() { lines.append(tail) }
            return lines
        }
    }

    var events: [TVEvent] {
        get throws {
            let decoder = TVEventDecoder()
            return try lines.compactMap { try decoder.decode(line: $0) }
        }
    }

    /// A JSON fixture recorded from the live API.
    enum JSON: String, CaseIterable {
        case channels
        case arenas
        case arenaDetail = "arena-detail"
        case broadcastTop = "broadcast-top"
        case broadcastRound = "broadcast-round"

        var data: Data {
            get throws {
                let url = try #require(
                    Bundle.module.url(forResource: rawValue, withExtension: "json", subdirectory: "Fixtures"),
                    "missing fixture \(rawValue).json"
                )
                return try Data(contentsOf: url)
            }
        }
    }

    /// A recorded `/api/stream/game/{id}` NDJSON body (a complete bullet game, ending in mate).
    /// Deliberately not a `Fixture` case: those are all TV-feed recordings and several tests
    /// iterate `Fixture.allCases` expecting TV events.
    static var gameStreamData: Data {
        get throws {
            let url = try #require(
                Bundle.module.url(forResource: "game-stream", withExtension: "ndjson", subdirectory: "Fixtures"),
                "missing fixture game-stream.ndjson"
            )
            return try Data(contentsOf: url)
        }
    }

    /// The recorded `GET /api/broadcast/round/q7gOEObq.pgn` — five finished TCEC games.
    static var broadcastRoundText: String {
        get throws {
            let url = try #require(
                Bundle.module.url(forResource: "broadcast-round", withExtension: "pgn", subdirectory: "Fixtures"),
                "missing fixture broadcast-round.pgn"
            )
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    /// 90 seconds of `GET /api/stream/broadcast/round/JUiFwhFj.pgn`: one live game sent four
    /// times, two plies longer each time — the re-send behaviour the stream has to deduplicate.
    static var broadcastStreamData: Data {
        get throws {
            let url = try #require(
                Bundle.module.url(forResource: "broadcast-stream", withExtension: "pgn", subdirectory: "Fixtures"),
                "missing fixture broadcast-stream.pgn"
            )
            return try Data(contentsOf: url)
        }
    }

    static var channelsData: Data {
        get throws {
            let url = try #require(
                Bundle.module.url(forResource: "channels", withExtension: "json", subdirectory: "Fixtures"),
                "missing fixture channels.json"
            )
            return try Data(contentsOf: url)
        }
    }
}
