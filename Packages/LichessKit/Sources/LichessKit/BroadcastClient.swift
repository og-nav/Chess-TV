import Foundation

/// Reads the Lichess broadcast (relay) endpoints: the curated list and one round's boards.
public final class BroadcastClient: @unchecked Sendable {   // @unchecked: URLSession is not Sendable; every stored property is immutable
    private let session: URLSession
    private let baseURL: URL

    public init(session: URLSession = LichessURLSession.standard, baseURL: URL = LichessConfig.baseURL) {
        self.session = session
        self.baseURL = baseURL
    }

    /// `GET /api/broadcast/top?page=1`. Only page 1 carries the `active` bucket.
    public func top() async throws -> (active: [BroadcastTournament], upcoming: [BroadcastTournament]) {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/broadcast/top"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "page", value: "1")]
        let data = try await LichessHTTP.get(components.url!, session: session)
        return try Self.decodeTop(data)
    }

    /// `GET /api/broadcast/-/-/{roundId}`. The slugs are placeholders Lichess accepts as `-`.
    ///
    /// `boards` is empty until the round starts.
    public func round(id: String) async throws -> (round: BroadcastTournament, boards: [BroadcastBoard]) {
        let url = baseURL
            .appendingPathComponent("api/broadcast")
            .appendingPathComponent("-")
            .appendingPathComponent("-")
            .appendingPathComponent(id)
        let data = try await LichessHTTP.get(url, session: session)
        return try Self.decodeRound(data)
    }

    /// All rounds of one event, including scheduled rounds after the current one.
    public func tournament(id: String) async throws -> BroadcastTour {
        let url = baseURL.appendingPathComponent("api/broadcast").appendingPathComponent(id)
        return try Self.decodeTournament(await LichessHTTP.get(url, session: session))
    }

    static func decodeTournament(_ data: Data) throws -> BroadcastTour {
        let wire = try LichessHTTP.decode(TourWithRoundsWire.self, from: data, what: "broadcast tournament")
        return BroadcastTour(id: wire.tour.id, name: wire.tour.name, rounds: wire.rounds.map {
            BroadcastRound(id: $0.id, name: $0.name, ongoing: $0.ongoing ?? false,
                           finished: $0.finishedAt != nil || $0.finished == true,
                           startsAt: $0.startsAt.map { Date(epochMilliseconds: $0) })
        }, imageURL: wire.tour.image.flatMap(URL.init(string:)))
    }

    /// Split out so tests can drive it straight from a fixture.
    static func decodeTop(_ data: Data) throws -> (active: [BroadcastTournament], upcoming: [BroadcastTournament]) {
        let wire = try LichessHTTP.decode(TopWire.self, from: data, what: "broadcast top")
        return (
            (wire.active ?? []).map { $0.model(isActive: true) },
            (wire.upcoming ?? []).map { $0.model(isActive: false) }
        )
    }

    /// Split out so tests can drive it straight from a fixture.
    static func decodeRound(_ data: Data) throws -> (round: BroadcastTournament, boards: [BroadcastBoard]) {
        let wire = try LichessHTTP.decode(RoundWire.self, from: data, what: "broadcast round")
        let entry = EntryWire(tour: wire.tour, round: wire.round)
        // `photos` is the round's portrait book: every player of the round that Lichess has a
        // picture for, keyed by FIDE id as a string. It arrives with the boards, so attaching it
        // here is what makes a portrait cost no request of its own.
        var photos: [Int: PlayerPhoto] = [:]
        for (key, photo) in wire.photos ?? [:] {
            guard let fideId = Int(key) else { continue }
            photos[fideId] = photo.model
        }
        return (entry.model(isActive: wire.round.ongoing ?? false), (wire.games ?? []).map { $0.model(photos: photos) })
    }
}

// MARK: - Wire shapes

private struct TopWire: Decodable {
    let active: [EntryWire]?
    let upcoming: [EntryWire]?
}

private struct RoundWire: Decodable {
    let round: RoundInfoWire
    let tour: TourWire
    let games: [GameWire]?
    /// `fideId (as a string) → portrait`, for every player of the round Lichess has a picture of.
    let photos: [String: PhotoWire]?
}

/// The `{small, medium, credit}` object Lichess uses for a portrait, on the round payload and on
/// `/api/fide/player/{id}` alike.
struct PhotoWire: Decodable {
    let small: String?
    let medium: String?
    let credit: String?

    var model: PlayerPhoto {
        PlayerPhoto(
            smallURL: small.flatMap(URL.init(string:)),
            mediumURL: medium.flatMap(URL.init(string:)),
            credit: credit
        )
    }
}

private struct TourWithRoundsWire: Decodable {
    let tour: TourWire
    let rounds: [RoundInfoWire]
}

private struct EntryWire: Decodable {
    let tour: TourWire
    let round: RoundInfoWire

    func model(isActive: Bool) -> BroadcastTournament {
        BroadcastTournament(
            tourId: tour.id,
            name: tour.name,
            tier: tour.tier,
            roundId: round.id,
            roundName: round.name,
            roundOngoing: round.ongoing ?? false,
            roundStartsAt: round.startsAt.map { Date(epochMilliseconds: $0) },
            format: tour.info?.format,
            location: tour.info?.location,
            isActive: isActive || (round.ongoing ?? false),
            imageURL: tour.image.flatMap(URL.init(string:))
        )
    }
}

private struct TourWire: Decodable {
    struct Info: Decodable {
        let format: String?
        let location: String?
    }
    let id: String
    let name: String
    let tier: Int?
    let info: Info?
    let image: String?
}

private struct RoundInfoWire: Decodable {
    let id: String
    let name: String
    let ongoing: Bool?
    /// Epoch milliseconds. Absent on rounds that start when the previous one ends.
    let startsAt: Double?
    let finishedAt: Double?
    let finished: Bool?
}

private struct GameWire: Decodable {
    struct Player: Decodable {
        let name: String?
        let title: String?
        let rating: Int?
        let fed: String?
        /// Centiseconds on the wire (Lichess ChapterPlayer.clock is Centis).
        let clock: Int?
        /// `0` when the player has no FIDE id.
        let fideId: Int?
    }
    let id: String
    let name: String?
    let fen: String
    let lastMove: String?
    let status: String?
    let players: [Player]?
    let thinkTime: Int?

    func model(photos: [Int: PlayerPhoto] = [:]) -> BroadcastBoard {
        BroadcastBoard(
            gameId: id,
            name: name ?? "",
            fen: fen,
            lastMove: lastMove,
            status: status ?? "*",
            players: (players ?? []).enumerated().map { index, player in
                let side = fen.split(separator: " ").dropFirst().first
                let runningIndex: Int? = side == "w" ? 0 : (side == "b" ? 1 : nil)
                let ongoing = status == nil || status == "*" || status == ""
                let elapsed = ongoing && index == runningIndex ? max(0, thinkTime ?? 0) : 0
                let milliseconds = player.clock.map { centis in
                    let raw = max(0, min(centis, Int.max / 10)) * 10
                    return max(0, raw - min(elapsed, Int.max / 1000) * 1000)
                }
                return BroadcastPlayer(
                    name: player.name ?? "Unknown",
                    title: player.title,
                    rating: player.rating,
                    federation: player.fed,
                    clockMs: milliseconds,
                    fideId: player.fideId,
                    photo: player.fideId.flatMap { photos[$0] }
                )
            }
        )
    }
}
