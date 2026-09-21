import Foundation
import Testing
import ChessCore
@testable import LichessKit

/// Decoding of the arena and broadcast payloads, driven by recordings taken from the live API
/// on 2026-09-17.
@Suite("Arena and broadcast decoding")
struct ArenaBroadcastDecodingTests {

    // MARK: - Arenas

    @Test("The arena list decodes into started and upcoming")
    func arenaList() throws {
        let (started, upcoming) = try ArenaClient.decodeList(Fixture.JSON.arenas.data)
        #expect(started.count == 3)
        #expect(upcoming.count == 3)

        let first = try #require(started.first)
        #expect(first.id == "FfsuUfQP")
        #expect(first.fullName == "≤2000 Rapid Arena")
        #expect(first.perfKey == "rapid")
        #expect(first.variantKey == "standard")
        #expect(first.nbPlayers == 81)
        #expect(first.minutes == 57)
        #expect(first.startsAt == Date(timeIntervalSince1970: 1_789_696_800))
        #expect(first.isStarted)
        #expect(!first.isFinished)
        // The *list* endpoint sends `finishesAt`, never `secondsToFinish`.
        #expect(first.secondsToFinish == nil)

        #expect(upcoming.allSatisfy { !$0.isStarted && !$0.isFinished })
    }

    @Test("The arena detail decodes the featured game and the top of the standing")
    func arenaDetail() throws {
        let detail = try ArenaClient.decodeDetail(Fixture.JSON.arenaDetail.data)
        #expect(detail.summary.id == "MHVqmH8B")
        #expect(detail.summary.fullName == "Hourly Bullet Arena")
        #expect(detail.summary.perfKey == "bullet")
        #expect(detail.summary.isStarted)
        #expect(!detail.summary.isFinished)          // `isFinished` is simply absent while running
        #expect(detail.summary.secondsToFinish == 824)
        // The detail endpoint sends `startsAt` as ISO-8601 and `variant` as a bare string,
        // unlike the list endpoint; both shapes have to decode.
        #expect(detail.summary.variantKey == "standard")
        #expect(detail.summary.startsAt == ISO8601DateFormatter().date(from: "2026-09-18T02:30:20Z"))

        let featured = try #require(detail.featured)
        #expect(featured.gameId == "1bkVTDgw")
        #expect(featured.lastMove == "d3c2")
        #expect(featured.fen == "2r1r1k1/pp3ppp/2pb4/8/q2P4/P3PN2/2QBP1PP/R2K1B1R b")
        #expect(featured.white.name == "joserivas")
        #expect(featured.white.rating == 2350)
        #expect(featured.white.rank == 2)
        #expect(featured.white.secondsRemaining == 38)
        #expect(featured.black.name == "CRUYFFORD_ChesYT")
        #expect(featured.black.rank == 5)
        #expect(featured.black.secondsRemaining == 30)

        // Lichess sends the standing one page at a time, ten rows deep; all ten are kept.
        #expect(detail.standings.count == 10)
        #expect(detail.summary.nbPlayers == 135)
        let leader = try #require(detail.standings.first)
        #expect(leader.rank == 1)
        #expect(leader.name == "Matanzas67")
        #expect(leader.title == "IM")
        #expect(leader.score == 20)
        #expect(leader.rating == 2532)
        #expect(leader.onStreak)                     // `sheet.fire`
        #expect(!leader.withdrawn)
        #expect(detail.standings.map(\.rank) == Array(1...10))
        // A row without a title, and one whose sheet carries no `fire`.
        let second = try #require(detail.standings.dropFirst().first)
        #expect(second.name == "joserivas")
        #expect(second.title == nil)
        #expect(second.rating == 2350)
        let sixth = try #require(detail.standings.first { $0.rank == 6 })
        #expect(!sixth.onStreak)
        // `withdraw` marks a player who paused.
        let ninth = try #require(detail.standings.first { $0.rank == 9 })
        #expect(ninth.name == "AkbasYunus")
        #expect(ninth.withdrawn)
        #expect(!ninth.onStreak)
        #expect(detail.standings.filter(\.withdrawn).map(\.rank) == [9])
    }

    // MARK: - Broadcasts

    @Test("The broadcast list decodes tour and round into one row")
    func broadcastTop() throws {
        let (active, upcoming) = try BroadcastClient.decodeTop(Fixture.JSON.broadcastTop.data)
        #expect(active.count == 2)
        #expect(upcoming.isEmpty)

        let olympiad = try #require(active.first)
        #expect(olympiad.tourId == "n1pPI5Q0")
        #expect(olympiad.tier == 5)
        #expect(olympiad.roundId == "bmI956uk")
        #expect(olympiad.roundName == "Round 3")
        #expect(olympiad.location == "Samarkand, Uzbekistan")
        #expect(olympiad.format == "11-round swiss for teams")
        #expect(olympiad.isActive)
        #expect(olympiad.roundStartsAt == Date(timeIntervalSince1970: 1_789_726_500))
        #expect(!olympiad.roundOngoing)        // round 3 had not begun when this was recorded
        #expect(active.contains { $0.roundOngoing })
        #expect(olympiad.imageURL?.host == "image.lichess1.org")
    }

    @Test("A broadcast round decodes its boards, clocks and results")
    func broadcastRound() throws {
        let (round, boards) = try BroadcastClient.decodeRound(Fixture.JSON.broadcastRound.data)
        #expect(round.roundId == "q7gOEObq")
        #expect(round.roundName == "Round 21")
        #expect(round.roundOngoing)
        #expect(round.isActive)

        #expect(boards.count == 5)
        let first = try #require(boards.first)
        #expect(first.gameId == "ZD7czPL6")
        #expect(first.status == "1-0")
        #expect(!first.isOngoing)
        #expect(first.lastMove == "d8g8")
        #expect(first.players.count == 2)
        #expect(first.players[0].name == "Raphael 4.3.0-dev-acd050b")
        #expect(first.players[0].title == "BOT")
        #expect(first.players[0].rating == 3703)
        #expect(first.players[0].clockMs == 51300)
        #expect(first.players[0].clockSeconds == 51)
        // Engine events carry no federation, and Lichess writes their FIDE id as 0.
        #expect(first.players.allSatisfy { $0.federation == nil })
        #expect(first.players.allSatisfy { $0.fideId == nil })
        #expect(BroadcastPlayer(name: "x", title: nil, rating: nil, federation: nil, clockMs: nil, fideId: 0).fideId == nil)
        #expect(BroadcastPlayer(name: "x", title: nil, rating: nil, federation: nil, clockMs: nil, fideId: 1503014).fideId == 1503014)

        let ongoing = try #require(boards.first { $0.isOngoing })
        #expect(ongoing.gameId == "oSiy8ZXF")
        #expect(ongoing.status == "*")
        // The engine round in the capture has an empty portrait book, which is why nothing
        // noticed for a while that the book was being thrown away. See `roundPortraits`.
        #expect(ongoing.players.allSatisfy { $0.photo == nil })
    }

    /// A broadcast round publishes its players' portraits itself, under `photos`, keyed by FIDE
    /// id as a string. Decoding it is what lets a board show a face without a request of its own —
    /// and without depending on `/api/fide/player/{id}`, which is rate limited like everything
    /// else on the API and used to be the only source the app had.
    @Test("A round's players pick up the portraits the round payload carries")
    func roundPortraits() throws {
        let photo: [String: String] = [
            "small": "https://image.lichess1.org/display?fmt=webp&h=100&w=100&path=magnus.webp",
            "medium": "https://image.lichess1.org/display?fmt=webp&h=500&w=500&path=magnus.webp",
            "credit": "Brigham Aldrich",
        ]
        let payload: [String: Any] = [
            "round": ["id": "r1", "name": "Round 6", "ongoing": true],
            "tour": ["id": "t1", "name": "Olympiad"],
            // Only white is in the book, and one entry belongs to a player on another board:
            // both are normal, and neither may leak onto the wrong face.
            "photos": ["1503014": photo, "99999999": photo],
            "games": [[
                "id": "g1",
                "name": "Carlsen, Magnus - Caruana, Fabiano",
                "fen": "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1",
                "status": "*",
                "players": [
                    ["name": "Carlsen, Magnus", "fideId": 1_503_014, "fed": "NOR"],
                    ["name": "Caruana, Fabiano", "fideId": 2_020_009, "fed": "USA"],
                ],
            ]],
        ]
        let (_, boards) = try BroadcastClient.decodeRound(JSONSerialization.data(withJSONObject: payload))
        let board = try #require(boards.first)
        let white = try #require(board.white?.photo)
        #expect(white.mediumURL?.absoluteString.hasSuffix("path=magnus.webp") == true)
        #expect(white.smallURL?.host == "image.lichess1.org")
        #expect(white.credit == "Brigham Aldrich")
        #expect(white.hasPicture)
        // Black is not in the book: no picture, and nothing borrowed from the other entry.
        #expect(board.black?.photo == nil)
        // A credit with no picture at all is not a photo worth keeping.
        #expect(BroadcastPlayer(name: "x", title: nil, rating: nil, federation: nil, clockMs: nil,
                                fideId: 1, photo: PlayerPhoto(credit: "Nobody")).photo == nil)
    }

    // MARK: - Game stream lines

    @Test("A recorded game stream decodes into metadata, moves and a terminal status")
    func gameStreamLines() throws {
        var lineDecoder = NDJSONLineDecoder()
        var lines = try lineDecoder.append(Fixture.gameStreamData)
        if let tail = lineDecoder.flush() { lines.append(tail) }
        #expect(lines.count == 27)

        let decoded = try lines.compactMap { try GameStreamLineDecoder.decode(line: $0) }
        #expect(decoded.count == 27)

        guard case .metadata(let head) = decoded[0] else { Issue.record("first line is metadata"); return }
        #expect(head.id == "1bkVTDgw")
        #expect(head.fen == nil)                       // the opening line carries no position
        #expect(head.status == nil)
        #expect(head.players.map(\.name) == ["joserivas", "CRUYFFORD_ChesYT"])
        #expect(head.players.map(\.color) == [.white, .black])
        #expect(head.players.map(\.rating) == [2350, 2523])
        #expect(head.players.allSatisfy { $0.secondsRemaining == nil })

        guard case .move(let fen, let lastMove, let whiteClock, let blackClock) = decoded[1] else {
            Issue.record("second line is a move"); return
        }
        #expect(!fen.isEmpty)
        #expect(lastMove != nil)
        #expect(whiteClock != nil && blackClock != nil)

        guard case .metadata(let tail) = decoded[26] else { Issue.record("last line is metadata"); return }
        let status = try #require(tail.status)
        #expect(status.name == "mate")
        #expect(status.id == 30)
        #expect(status.winner == .black)
        #expect(status.isOver)
        #expect(!GameStatus(id: 20, name: "started", winner: nil).isOver)
    }

    @Test("TVEvent exposes NDJSON decoding publicly")
    func publicLineDecoding() throws {
        let line = try #require(try Fixture.blitz.lines.first)
        let event = try #require(TVEvent(ndjsonLine: line))
        #expect(event == (try #require(try Fixture.blitz.events.first)))
        #expect(TVEvent(ndjsonLine: "{ not json") == nil)
        #expect(TVEvent(ndjsonLine: #"{"t":"someFutureEvent","d":{}}"#) == nil)

        let all = LichessTVEventDecoder().decodeAll(try Fixture.bullet.data)
        #expect(all == (try Fixture.bullet.events))
    }

    @Test("GameSource titles every source")
    func gameSourceTitles() {
        #expect(GameSource.tvChannel(.blitz).displayTitle == "Lichess TV — Blitz")
        #expect(GameSource.arena(tournamentId: "MHVqmH8B").displayTitle == "Arena MHVqmH8B")
        #expect(GameSource.broadcastBoard(roundId: "q7gOEObq", gameId: "oSiy8ZXF").displayTitle == "Broadcast board oSiy8ZXF")
        #expect(!GameSource.tvChannel(.atomic).isStandardChess)
    }
}
