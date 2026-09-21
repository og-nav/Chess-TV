// Which fixture answers which request.
//
// The files under `Fixtures/` are real captures of the Lichess API. Where a capture would date
// itself the router rewrites it at serve time: arena and round start times are moved to sit
// around "now", ids in the path are written into the body so a follow made from a screen points
// at what the screen showed, and two engines on the ongoing broadcast board are given FIDE ids so
// the player bells and portraits have something to do. Streams are paced: the history of a game
// arrives in one burst, then one move every `FixtureMode.moveInterval`, then the connection is
// held open the way a live feed is.
import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum FixtureRouter {

    /// The ongoing round in `broadcast-top.json` and `broadcast-round.json`; every round id the
    /// app asks for is answered with this round's boards under the requested id.
    static let roundId = "q7gOEObq"
    static let tourId = "L2ydImaD"
    /// The board that is still being played in the round fixture.
    static let ongoingGameId = "oSiy8ZXF"
    /// FIDE ids written onto the ongoing board's players (they are engines in the capture).
    static let whiteFideId = 1_503_014
    static let blackFideId = 2_020_009

    static func answer(for request: URLRequest) -> FixtureAnswer {
        guard let url = request.url, let host = url.host() else { return .notFound }
        let path = url.path()
        if host.hasSuffix("lichess.org") {
            return lichess(path: path, query: url.query() ?? "")
        }
        if host.contains("lichess1.org") || host.contains("wikimedia.org") || host.contains("wikipedia.org") && path.contains("/thumb/") {
            return image(width: 800, height: 400, seed: path)
        }
        if host.contains("fide.com") || host.contains("photos") {
            return image(width: 300, height: 300, seed: path)
        }
        return .notFound
    }

    // MARK: - Lichess

    private static func lichess(path: String, query: String) -> FixtureAnswer {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.first == "api" else { return .notFound }
        let rest = Array(parts.dropFirst())
        switch rest.count {
        case 1 where rest[0] == "tournament":
            return .json(arenas())
        case 2 where rest[0] == "tv" && rest[1] == "channels":
            return .json(data("channels", "json"))
        case 2 where rest[0] == "tournament":
            return .json(arenaDetail(id: rest[1]))
        case 2 where rest[0] == "broadcast" && rest[1] == "top":
            return .json(broadcastTop())
        case 2 where rest[0] == "broadcast":
            return .json(tour(id: rest[1]))
        case 3 where rest[0] == "tv" && rest[2] == "feed":
            return feed(channel: rest[1])
        case 3 where rest[0] == "stream" && rest[1] == "game":
            return gameStream(id: rest[2])
        case 3 where rest[0] == "fide" && rest[1] == "player":
            return .json(fidePlayer(id: Int(rest[2]) ?? 0))
        case 4 where rest[0] == "broadcast" && rest[1] == "-" && rest[2] == "-":
            return .json(round(id: rest[3]))
        case 4 where rest[0] == "stream" && rest[1] == "broadcast" && rest[2] == "round" && rest[3].hasSuffix(".pgn"):
            return roundStream(roundId: String(rest[3].dropLast(4)))
        default:
            return .notFound
        }
    }

    // MARK: - Files

    static func data(_ name: String, _ ext: String) -> Data? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
            ?? Bundle.main.url(forResource: name, withExtension: ext) else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func lines(_ name: String, _ ext: String) -> [String] {
        guard let data = data(name, ext), let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }

    private static func json(_ name: String) -> Any? {
        data(name, "json").flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    private static func encode(_ object: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: object)
    }

    private static var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    // MARK: - Home shelves

    /// Started arenas began ten minutes ago, upcoming ones start in a quarter of an hour.
    private static func arenas() -> Data? {
        guard var root = json("arenas") as? [String: Any] else { return nil }
        for (bucket, offsetMinutes) in [("started", -10.0), ("created", 15.0), ("finished", -90.0)] {
            guard var items = root[bucket] as? [[String: Any]] else { continue }
            for index in items.indices {
                let starts = nowMs + offsetMinutes * 60_000 + Double(index) * 90_000
                items[index]["startsAt"] = starts
                if let minutes = items[index]["minutes"] as? Double {
                    items[index]["finishesAt"] = starts + minutes * 60_000
                }
            }
            root[bucket] = items
        }
        return encode(root)
    }

    private static func arenaDetail(id: String) -> Data? {
        guard var root = json("arena-detail") as? [String: Any] else { return nil }
        root["id"] = id
        root["startsAt"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-600))
        return encode(root)
    }

    /// The ongoing round started an hour ago; the others are hours away.
    private static func broadcastTop() -> Data? {
        guard var root = json("broadcast-top") as? [String: Any] else { return nil }
        for bucket in ["active", "upcoming"] {
            guard var entries = root[bucket] as? [[String: Any]] else { continue }
            for index in entries.indices {
                guard var round = entries[index]["round"] as? [String: Any] else { continue }
                let ongoing = round["ongoing"] as? Bool ?? false
                round["startsAt"] = ongoing ? nowMs - 3_600_000 : nowMs + Double(3 + index) * 3_600_000
                entries[index]["round"] = round
            }
            root[bucket] = entries
        }
        return encode(root)
    }

    // MARK: - Broadcasts

    private static func round(id: String) -> Data? {
        guard var root = json("broadcast-round") as? [String: Any] else { return nil }
        if var round = root["round"] as? [String: Any] {
            round["id"] = id
            round["startsAt"] = nowMs - 3_600_000
            root["round"] = round
        }
        if var games = root["games"] as? [[String: Any]] {
            for index in games.indices where games[index]["id"] as? String == ongoingGameId {
                guard var players = games[index]["players"] as? [[String: Any]], players.count == 2 else { continue }
                players[0]["fideId"] = whiteFideId
                players[0]["fed"] = "NOR"
                players[1]["fideId"] = blackFideId
                players[1]["fed"] = "USA"
                games[index]["players"] = players
            }
            root["games"] = games
        }
        // The round's own portrait book, which is where the app gets a face without a second
        // request. Black's is only here — the FIDE record below has no photo for him — so the
        // harness exercises both the FIDE record and the round-payload fallback.
        root["photos"] = [
            String(whiteFideId): photo(for: whiteFideId, credit: "Fixture Photography"),
            String(blackFideId): photo(for: blackFideId, credit: "Fixture Photography"),
        ]
        return encode(root)
    }

    /// The `{small, medium, credit}` object Lichess publishes for a portrait.
    private static func photo(for id: Int, credit: String) -> [String: String] {
        [
            "small": "https://image.lichess1.org/display?fmt=webp&h=100&w=100&path=fixture\(id).webp",
            "medium": "https://image.lichess1.org/display?fmt=webp&h=500&w=500&path=fixture\(id).webp",
            "credit": credit,
        ]
    }

    /// Three rounds: one finished, the ongoing one, one tomorrow.
    private static func tour(id: String) -> Data? {
        guard let root = json("broadcast-round") as? [String: Any], var tour = root["tour"] as? [String: Any] else { return nil }
        tour["id"] = id
        let rounds: [[String: Any]] = [
            ["id": "fixtureR1", "name": "Round 20", "finished": true, "finishedAt": nowMs - 86_400_000, "startsAt": nowMs - 90_000_000],
            ["id": roundId, "name": "Round 21", "ongoing": true, "startsAt": nowMs - 3_600_000],
            ["id": "fixtureR3", "name": "Round 22", "startsAt": nowMs + 86_400_000],
        ]
        return encode(["tour": tour, "rounds": rounds])
    }

    private static func fidePlayer(id: Int) -> Data? {
        let names = [whiteFideId: ("Magnus Carlsen", "NOR", 1990), blackFideId: ("Fabiano Caruana", "USA", 1992)]
        let (name, federation, year) = names[id] ?? ("Player \(id)", "FID", 1985)
        var record: [String: Any] = [
            "id": id, "name": name, "federation": federation, "title": "GM", "year": year,
            "standard": 2830, "rapid": 2800, "blitz": 2850,
        ]
        // Lichess has a portrait for a minority of FIDE records. Black stands for the majority
        // that has none, so his face has to come from the round payload or not at all.
        if id != blackFideId {
            record["photo"] = [
                "small": "https://photos.fixture.fide.com/\(id)/small.jpg",
                "medium": "https://photos.fixture.fide.com/\(id)/medium.jpg",
                "credit": "Fixture Photography",
            ]
        }
        return encode(record)
    }

    // MARK: - Streams

    /// The channel feed: its featured header at once, then held open. The featured game's moves
    /// come from `/api/stream/game/{id}`, which is how the real streamer works too.
    private static func feed(channel: String) -> FixtureAnswer {
        let name = channel == "bullet" ? "feed-bullet" : "feed-blitz"
        let all = lines(name, "ndjson")
        guard let featured = all.first(where: { $0.contains("\"featured\"") }) else { return .notFound }
        return .stream(contentType: "application/x-ndjson", chunks: [Data((featured + "\n").utf8)], holdOpen: true) { _ in 0 }
    }

    /// One game: the header and most of the moves in a burst, a pause long enough to count as the
    /// end of the replay, then the last moves one at a time, then held open. The terminal line is
    /// never sent, so the board stays live.
    private static func gameStream(id: String) -> FixtureAnswer {
        var all = lines("game-stream", "ndjson")
        guard all.count > 3 else { return .notFound }
        all[0] = all[0].replacingOccurrences(of: "\"id\":\"1bkVTDgw\"", with: "\"id\":\"\(id)\"")
        all.removeLast()                                   // the terminal status
        let liveCount = min(8, all.count - 2)
        let historyCount = all.count - liveCount
        let chunks = all.map { Data(($0 + "\n").utf8) }
        let interval = FixtureMode.moveInterval
        return .stream(contentType: "application/x-ndjson", chunks: chunks, holdOpen: true) { index in
            if index == 0 { return 0.15 }
            if index < historyCount { return 0.01 }
            if index == historyCount { return 2.5 }           // the silence that ends the replay
            return interval
        }
    }

    /// The round's PGN: every board once, the ongoing board short of its last moves, then that
    /// board again with one more move each interval, then held open.
    private static func roundStream(roundId requested: String) -> FixtureAnswer {
        guard let data = data("broadcast-round", "pgn"), let text = String(data: data, encoding: .utf8) else { return .notFound }
        let blocks = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.replacingOccurrences(of: "/\(roundId)/", with: "/\(requested)/").replacingOccurrences(of: "/\(roundId)\"", with: "/\(requested)\"") }
        guard let ongoingIndex = blocks.firstIndex(where: { $0.contains("/\(ongoingGameId)\"") }) else { return .notFound }
        let (headers, moves) = split(block: blocks[ongoingIndex])
        let liveMoves = min(10, max(0, moves.count - 2))
        let shownAtStart = moves.count - liveMoves
        func ongoing(upTo count: Int) -> String {
            headers + "\n\n" + moves.prefix(count).joined(separator: " ") + " *"
        }
        var chunks: [Data] = []
        var initial = blocks
        initial[ongoingIndex] = ongoing(upTo: shownAtStart)
        chunks.append(Data((initial.joined(separator: "\n\n\n") + "\n\n\n").utf8))
        for count in (shownAtStart + 1)...max(shownAtStart + 1, moves.count) {
            chunks.append(Data((ongoing(upTo: count) + "\n\n\n").utf8))
        }
        let interval = FixtureMode.moveInterval
        return .stream(contentType: "application/x-chess-pgn", chunks: chunks, holdOpen: true) { index in
            index == 0 ? 0.2 : interval
        }
    }

    /// Headers with the result set to "in progress", and the movetext cut into one entry per
    /// move (number, move, its comment).
    private static func split(block: String) -> (headers: String, moves: [String]) {
        let parts = block.components(separatedBy: "\n\n")
        let headerLines = parts.first?.split(separator: "\n").map(String.init) ?? []
        let headers = headerLines
            .filter { !$0.hasPrefix("[Termination") }
            .map { $0.hasPrefix("[Result") ? "[Result \"*\"]" : $0 }
            .joined(separator: "\n")
        var movetext = parts.dropFirst().joined(separator: " ")
        for result in ["1/2-1/2", "1-0", "0-1", "*"] where movetext.hasSuffix(result) {
            movetext = String(movetext.dropLast(result.count))
            break
        }
        let pattern = try! NSRegularExpression(pattern: #"(?<=\s)(?=\d+\.(?:\.\.)?\s)"#)
        let ns = movetext as NSString
        var moves: [String] = []
        var cursor = 0
        for match in pattern.matches(in: movetext, range: NSRange(location: 0, length: ns.length)) {
            let piece = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)).trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty { moves.append(piece) }
            cursor = match.range.location
        }
        let tail = ns.substring(from: cursor).trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { moves.append(tail) }
        return (headers, moves)
    }

    // MARK: - Pictures

    /// A banner or a portrait: two colours chosen from the path, so different cards look
    /// different and the same one is stable.
    private static func image(width: Int, height: Int, seed: String) -> FixtureAnswer {
        #if canImport(UIKit)
        // Drawn in the suite's own palette (sage ground, ivory and moss board squares) so a
        // screenshot taken under fixtures looks like the app and not like a test rig: a soft
        // ground, a few board squares placed by the seed, and one lighter shape for the portrait.
        let hash = seed.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
        let variant = abs(hash)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let png = renderer.pngData { context in
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            let cg = context.cgContext
            let ground = UIColor(red: 0x2a / 255, green: 0x31 / 255, blue: 0x28 / 255, alpha: 1)
            let moss = UIColor(red: 0x78 / 255, green: 0x81 / 255, blue: 0x6b / 255, alpha: 1)
            let ivory = UIColor(red: 0xde / 255, green: 0xd7 / 255, blue: 0xc5 / 255, alpha: 1)
            ground.setFill()
            context.fill(rect)
            if width > height {
                // Banner: a board corner, offset by the seed, fading into the ground on the left.
                let square = Double(height) / 6
                let columns = Int(ceil(Double(width) / square)) + 1
                let shift = variant % 3
                for row in 0..<6 {
                    for column in 0..<columns {
                        let x = Double(column) * square - Double(shift) * square / 3 + Double(width) * 0.35
                        guard x < Double(width) else { continue }
                        let light = (row + column + shift) % 2 == 0
                        let alpha = min(1, max(0, (x - Double(width) * 0.3) / (Double(width) * 0.5)))
                        (light ? ivory : moss).withAlphaComponent(alpha * (light ? 0.9 : 0.85)).setFill()
                        cg.fill(CGRect(x: x, y: Double(row) * square, width: square, height: square))
                    }
                }
            } else {
                // Portrait: a moss ground with an ivory silhouette, so the two players differ
                // only by the seed-driven shade behind them.
                UIColor(red: 0x4c / 255, green: 0x55 / 255, blue: 0x45 / 255, alpha: 1)
                    .withAlphaComponent(variant % 2 == 0 ? 1 : 0.8).setFill()
                context.fill(rect)
                let w = Double(width)
                ivory.withAlphaComponent(0.9).setFill()
                cg.fillEllipse(in: CGRect(x: w * 0.32, y: w * 0.18, width: w * 0.36, height: w * 0.36))
                cg.fillEllipse(in: CGRect(x: w * 0.12, y: w * 0.62, width: w * 0.76, height: w * 0.7))
            }
        }
        return FixtureAnswer(status: 200, contentType: "image/png", body: .whole(png))
        #else
        return .notFound
        #endif
    }
}
