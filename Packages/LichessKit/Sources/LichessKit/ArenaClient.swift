import Foundation

/// Reads the Lichess arena endpoints: the schedule (`/api/tournament`) and one arena's
/// live state (`/api/tournament/{id}`).
public final class ArenaClient: @unchecked Sendable {   // @unchecked: URLSession is not Sendable; every stored property is immutable
    private let session: URLSession
    private let baseURL: URL

    public init(session: URLSession = LichessURLSession.standard, baseURL: URL = LichessConfig.baseURL) {
        self.session = session
        self.baseURL = baseURL
    }

    /// `GET /api/tournament`, keeping the two buckets an ambient screen cares about.
    ///
    /// - Returns: arenas in progress (most players first) and arenas about to begin (soonest first).
    ///   The `finished` bucket is dropped.
    public func list() async throws -> (started: [ArenaSummary], upcoming: [ArenaSummary]) {
        let data = try await LichessHTTP.get(baseURL.appendingPathComponent("api/tournament"), session: session)
        let wire = try LichessHTTP.decode(ListWire.self, from: data, what: "arena list")
        let started = wire.started.map { $0.summary(isStarted: true, isFinished: false) }
            .sorted { $0.nbPlayers > $1.nbPlayers }
        let upcoming = wire.created.map { $0.summary(isStarted: false, isFinished: false) }
            .sorted { $0.startsAt < $1.startsAt }
        log.debug("Arenas: \(started.count) started, \(upcoming.count) upcoming")
        return (started, upcoming)
    }

    /// `GET /api/tournament/{id}`: summary, the featured game, and the first page of the standing.
    ///
    /// The detail payload does not match the list payload field for field: `startsAt` is an
    /// ISO-8601 string here and epoch milliseconds there, and `variant` is a bare string here
    /// and an object there. `VariantKey` and `LichessTimestamp` absorb both.
    public func detail(id: String) async throws -> ArenaDetail {
        let url = baseURL.appendingPathComponent("api/tournament").appendingPathComponent(id)
        let data = try await LichessHTTP.get(url, session: session)
        return try Self.decodeDetail(data)
    }

    /// Split out so tests can drive it straight from a fixture.
    static func decodeDetail(_ data: Data) throws -> ArenaDetail {
        let wire = try LichessHTTP.decode(DetailWire.self, from: data, what: "arena detail")
        return ArenaDetail(
            summary: wire.summary,
            featured: wire.featured?.model,
            standings: (wire.standing?.players ?? []).map(\.model)
        )
    }

    /// Split out so tests can drive it straight from a fixture.
    static func decodeList(_ data: Data) throws -> (started: [ArenaSummary], upcoming: [ArenaSummary]) {
        let wire = try LichessHTTP.decode(ListWire.self, from: data, what: "arena list")
        return (
            wire.started.map { $0.summary(isStarted: true, isFinished: false) },
            wire.created.map { $0.summary(isStarted: false, isFinished: false) }
        )
    }
}

// MARK: - Wire shapes

private struct Keyed: Decodable { let key: String }

private struct ListWire: Decodable {
    let created: [ArenaWire]
    let started: [ArenaWire]
    let finished: [ArenaWire]
}

/// The list endpoint sends `status` (10 created / 20 started / 30 finished) and `finishesAt`
/// rather than `secondsToFinish`; the bucket the arena arrived in is authoritative, and
/// `status` is only used as a cross-check when present.
private struct ArenaWire: Decodable {
    let id: String
    let fullName: String
    let nbPlayers: Int
    let variant: VariantKey
    let perf: Keyed
    let startsAt: LichessTimestamp
    let minutes: Int
    let secondsToFinish: Int?
    let status: Int?

    func summary(isStarted: Bool, isFinished: Bool) -> ArenaSummary {
        ArenaSummary(
            id: id,
            fullName: fullName,
            perfKey: perf.key,
            variantKey: variant.key,
            nbPlayers: nbPlayers,
            startsAt: startsAt.date,
            minutes: minutes,
            secondsToFinish: secondsToFinish,
            isStarted: status.map { $0 >= 20 } ?? isStarted,
            isFinished: status.map { $0 >= 30 } ?? isFinished
        )
    }
}

private struct DetailWire: Decodable {
    let id: String
    let fullName: String
    let nbPlayers: Int
    let variant: VariantKey
    let perf: Keyed
    let startsAt: LichessTimestamp
    let minutes: Int
    let secondsToFinish: Int?
    /// Present and `true` once play begins; absent otherwise.
    let isStarted: Bool?
    /// Only sent once the arena is over.
    let isFinished: Bool?
    let featured: FeaturedWire?
    let standing: StandingWire?

    var summary: ArenaSummary {
        ArenaSummary(
            id: id,
            fullName: fullName,
            perfKey: perf.key,
            variantKey: variant.key,
            nbPlayers: nbPlayers,
            startsAt: startsAt.date,
            minutes: minutes,
            secondsToFinish: secondsToFinish,
            isStarted: isStarted ?? false,
            isFinished: isFinished ?? false
        )
    }
}

private struct FeaturedWire: Decodable {
    struct Side: Decodable {
        let name: String
        let rating: Int?
        let rank: Int?
    }
    struct Clocks: Decodable {
        let white: Int?
        let black: Int?
    }
    let id: String
    let fen: String
    let lastMove: String?
    let white: Side
    let black: Side
    /// Clocks in seconds. Absent before the first move of the game.
    let c: Clocks?

    var model: ArenaFeaturedGame {
        ArenaFeaturedGame(
            gameId: id,
            fen: fen,
            lastMove: lastMove,
            white: .init(name: white.name, rating: white.rating, rank: white.rank, secondsRemaining: c?.white),
            black: .init(name: black.name, rating: black.rating, rank: black.rank, secondsRemaining: c?.black)
        )
    }
}

private struct StandingWire: Decodable {
    struct Player: Decodable {
        /// `sheet.scores` is a digit per game; only the streak flag beside it is shown here.
        struct Sheet: Decodable {
            let fire: Bool?
        }
        let name: String
        let title: String?
        let rank: Int
        let score: Int
        let rating: Int?
        let sheet: Sheet?
        /// Present and `true` once the player pauses; absent otherwise.
        let withdraw: Bool?

        var model: ArenaStanding {
            ArenaStanding(
                name: name,
                title: title,
                score: score,
                rank: rank,
                rating: rating,
                onStreak: sheet?.fire ?? false,
                withdrawn: withdraw ?? false
            )
        }
    }
    let players: [Player]
}
