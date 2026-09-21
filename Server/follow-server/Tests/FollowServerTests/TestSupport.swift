// Fixtures, a broadcast source that reads from disk, and the small builders every suite uses.

import Foundation
import FollowKit
import Testing
@testable import FollowServer

enum Fixture {
    static func url(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil), "fixture \(name) is missing")
    }

    static func text(_ name: String) throws -> String {
        try String(contentsOf: try url(name), encoding: .utf8)
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: try url(name))
    }

    static func round(_ name: String) throws -> BroadcastRoundDetail {
        try BroadcastDecoder.roundDetail(from: try data(name))
    }

    static func tour(_ name: String) throws -> BroadcastTourDetail {
        try BroadcastDecoder.tourDetail(from: try data(name))
    }

    static func top(_ name: String) throws -> BroadcastTop {
        try BroadcastDecoder.top(from: try data(name))
    }

    /// The instant every fixture is written relative to, so a test can say "now" and mean the
    /// same thing the JSON does.
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
}

/// A `BroadcastSource` backed by fixtures, with the pieces a test wants to change between polls.
actor FixtureSource: BroadcastSource {
    var topListing: BroadcastTop
    var tours: [String: BroadcastTourDetail]
    var rounds: [String: BroadcastRoundDetail]
    /// The PGN blocks a round's stream will hand out, in order, then finish.
    var streams: [String: [String]]
    private(set) var roundFetches = 0
    private(set) var topFetches = 0

    init(
        top: BroadcastTop = BroadcastTop(),
        tours: [BroadcastTourDetail] = [],
        rounds: [BroadcastRoundDetail] = [],
        streams: [String: [String]] = [:]
    ) {
        self.topListing = top
        self.tours = Dictionary(uniqueKeysWithValues: tours.map { ($0.tour.id, $0) })
        self.rounds = Dictionary(uniqueKeysWithValues: rounds.map { ($0.round.id, $0) })
        self.streams = streams
    }

    func set(tour: BroadcastTourDetail) { tours[tour.tour.id] = tour }
    func set(round: BroadcastRoundDetail) { rounds[round.round.id] = round }

    func top() async throws -> BroadcastTop {
        topFetches += 1
        return topListing
    }

    func tour(id: String) async throws -> BroadcastTourDetail {
        guard let tour = tours[id] else { throw BroadcastSourceError.http(404) }
        return tour
    }

    func round(id: String) async throws -> BroadcastRoundDetail {
        roundFetches += 1
        guard let round = rounds[id] else { throw BroadcastSourceError.http(404) }
        return round
    }

    nonisolated func pgnStream(roundId: String) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                for block in await self.streams[roundId] ?? [] { continuation.yield(block) }
                continuation.finish()
            }
        }
    }
}

/// A store, an outbox and a pipeline wired together on an in-memory database, with a clock the
/// test moves by hand.
struct TestRig {
    let store: FollowStore
    let delivery: RecordingDelivery
    let outbox: OutboxWorker
    let pipeline: FollowPipeline
    let clock: MutableClock
    var configuration: ServerConfig

    static func make(now: Date = Fixture.now, configuration: ServerConfig? = nil) async throws -> TestRig {
        let clock = MutableClock(now)
        var settings = configuration ?? ServerConfig()
        settings.databasePath = ":memory:"
        settings.requireHTTPS = false
        let store = try await FollowStore.open(path: ":memory:", now: clock.read)
        let delivery = RecordingDelivery()
        let outbox = OutboxWorker(store: store, delivery: delivery, configuration: settings, now: clock.read)
        let pipeline = FollowPipeline(store: store, outbox: outbox)
        return TestRig(store: store, delivery: delivery, outbox: outbox, pipeline: pipeline, clock: clock, configuration: settings)
    }

    /// Registers a device with the given follows and preferences.
    @discardableResult
    func device(
        apnsToken: String = String(repeating: "a", count: 64),
        environment: String = "sandbox",
        preferences: NotificationPreferences = NotificationPreferences(timeZoneIdentifier: "UTC"),
        follows: [Follow] = []
    ) async throws -> DeviceRecord {
        let result = try await store.register(DeviceRegistration(environment: environment, apnsToken: apnsToken, appVersion: "test"))
        try await store.setPreferences(preferences, deviceId: result.device.id)
        for follow in follows { _ = try await store.addFollow(follow, deviceId: result.device.id) }
        return result.device
    }

    func close() async { await store.close() }
}

extension GameSnapshot {
    /// A board, briefly.
    static func make(
        gameId: String = "wchGam01",
        roundId: String = "WCHr0002",
        ply: Int = 10,
        fen: String = "r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4",
        san: String? = "Nc6",
        status: String = "*",
        whiteFideId: Int? = 1_503_014,
        blackFideId: Int? = 4_168_119,
        whiteClock: Int? = 3600,
        blackClock: Int? = 3540
    ) -> GameSnapshot {
        GameSnapshot(
            roundId: roundId,
            gameId: gameId,
            ply: ply,
            fen: fen,
            lastMove: "b8c6",
            san: san,
            whiteClock: whiteClock,
            blackClock: blackClock,
            status: status,
            white: PushPlayer(name: "Carlsen, Magnus", title: "GM", rating: 2839, fed: "NOR"),
            black: PushPlayer(name: "Nepomniachtchi, Ian", title: "GM", rating: 2789, fed: "FID"),
            whiteFideId: whiteFideId,
            blackFideId: blackFideId
        )
    }
}

extension RoundContext {
    static func make(boards: [String] = ["wchGam01", "wchGam02"]) -> RoundContext {
        RoundContext(
            roundId: "WCHr0002",
            roundName: "Round 2",
            tourId: "WCHtour1",
            tourName: "World Championship 2026",
            bannerURL: URL(string: "https://image.lichess1.org/display?path=wch2026.webp"),
            boards: boards
        )
    }
}

extension DeviceContext {
    static func make(
        id: String = "d_test",
        preferences: NotificationPreferences = NotificationPreferences(timeZoneIdentifier: "UTC"),
        follows: [Follow]
    ) -> DeviceContext {
        DeviceContext(
            device: DeviceRecord(
                id: id,
                platform: "ios",
                environment: "sandbox",
                apnsToken: String(repeating: "a", count: 64),
                appVersion: "test",
                createdAt: Fixture.now,
                lastSeenAt: Fixture.now
            ),
            preferences: preferences,
            follows: follows
        )
    }
}
