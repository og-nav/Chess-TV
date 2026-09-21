// `follow-server --replay <round.pgn>`: run the whole pipeline over a recorded stream, with APNs
// stubbed, and print exactly what would have been sent.
//
// This is the plan's "a replay against the fixture logs the exact pushes it would send" and it is
// also how the watcher is tested: the same objects, the same rules, a fake clock and a file
// instead of a socket.

import Foundation
import FollowKit
import Logging

/// A replay's inputs: a recorded PGN stream, the round JSON that gives it board order and FIDE
/// ids, and who is following what.
public struct ReplaySeed: Sendable {
    public var device: DeviceRegistration
    public var preferences: NotificationPreferences
    public var follows: [Follow]
    /// Seconds of wall clock between two blocks of the recorded stream. The recording has no
    /// timestamps, so the replay chooses them; 60 s is a classical game's pace and makes the
    /// long-think rules visible.
    public var secondsBetweenBlocks: Int

    public init(
        device: DeviceRegistration = DeviceRegistration(platform: "ios", environment: "sandbox", apnsToken: String(repeating: "a", count: 64), appVersion: "replay"),
        preferences: NotificationPreferences = NotificationPreferences(timeZoneIdentifier: "UTC"),
        follows: [Follow] = [],
        secondsBetweenBlocks: Int = 60
    ) {
        self.device = device
        self.preferences = preferences
        self.follows = follows
        self.secondsBetweenBlocks = secondsBetweenBlocks
    }

    /// Reads a seed from a JSON file. Everything is optional; what is missing takes the defaults
    /// above.
    public static func load(contentsOf url: URL) throws -> ReplaySeed {
        struct File: Decodable {
            var device: DeviceRegistration?
            var preferences: NotificationPreferences?
            var follows: [Follow]?
            var secondsBetweenBlocks: Int?
        }
        let file = try FollowJSON.decoder.decode(File.self, from: Data(contentsOf: url))
        var seed = ReplaySeed()
        if let device = file.device { seed.device = device }
        if let preferences = file.preferences { seed.preferences = preferences }
        if let follows = file.follows { seed.follows = follows }
        if let seconds = file.secondsBetweenBlocks { seed.secondsBetweenBlocks = seconds }
        return seed
    }
}

/// What a replay produced, in the order it produced it.
public struct ReplayResult: Sendable {
    public var events: [MoveEvent]
    public var pushes: [OutboundPush]
}

public struct ReplayRunner: Sendable {

    private let logger: Logger

    public init(logger: Logger = ServerLog.make("replay")) { self.logger = logger }

    /// Runs a recorded stream through the pipeline.
    ///
    /// - Parameters:
    ///   - pgn: the recorded stream, whole.
    ///   - roundDetail: the round JSON that was current when it was recorded, or nil to run with
    ///     names from the PGN tags alone.
    ///   - seed: who is following what. With no follows, one is invented: the round's tournament
    ///     and its first board, which is what a person checking "would this work" wants.
    ///   - startingAt: the replay's clock at the first block.
    public func run(
        pgn: String,
        roundId: String,
        roundDetail: BroadcastRoundDetail? = nil,
        seed: ReplaySeed = ReplaySeed(),
        startingAt: Date = Date(timeIntervalSince1970: 1_790_000_000)
    ) async throws -> ReplayResult {
        let context = roundDetail.map(RoundContext.init) ?? RoundContext(roundId: roundId, roundName: "Round", tourId: "replay", tourName: "Replay")
        let blocks = PGNStreamSplitter.blocks(in: pgn)
        guard !blocks.isEmpty else { return ReplayResult(events: [], pushes: []) }

        let clock = MutableClock(startingAt)
        let store = try await FollowStore.open(path: ":memory:", logger: logger, now: clock.read)
        let delivery = RecordingDelivery()
        var configuration = ServerConfig()
        configuration.databasePath = ":memory:"
        let outbox = OutboxWorker(store: store, delivery: delivery, configuration: configuration, logger: logger)
        let pipeline = FollowPipeline(store: store, outbox: outbox, logger: logger)

        // Seed the device and its follows.
        let registration = try await store.register(seed.device)
        try await store.setPreferences(seed.preferences, deviceId: registration.device.id)
        var follows = seed.follows
        if follows.isEmpty {
            // Every switch on for the first board, so a replay with no seed shows what the
            // watcher noticed rather than what the shipping defaults would have filtered out.
            follows = [Follow(target: .tournament(tourId: context.tourId), alerts: .tournamentDefaults)]
            if let first = context.boards.first ?? PGNSnapshot.snapshot(block: blocks[0], roundId: roundId, context: context)?.gameId {
                follows.append(Follow(target: .game(roundId: roundId, gameId: first), alerts: FollowAlerts(game: Set(GameAlert.allCases))))
            }
        }
        for follow in follows { _ = try await store.addFollow(follow, deviceId: registration.device.id) }

        var events: [MoveEvent] = []
        for block in blocks {
            guard let snapshot = PGNSnapshot.snapshot(block: block, roundId: roundId, context: context) else { continue }
            events.append(contentsOf: try await pipeline.ingest(snapshot: snapshot, context: context, now: clock.read()))
            clock.advance(by: TimeInterval(seed.secondsBetweenBlocks))
        }
        await outbox.drain()

        let pushes = await delivery.record()
        await store.close()
        return ReplayResult(events: events, pushes: pushes)
    }

    /// One JSON line per push, which is what `scripts/server-replay.sh` prints.
    public static func report(_ result: ReplayResult) -> String {
        struct Line: Encodable {
            var category: String
            var device: String
            var collapseId: String
            var dedupeKey: String
            var title: String
            var body: String
        }
        let encoder = FollowJSON.encoder
        return result.pushes.compactMap { push in
            let line = Line(
                category: push.entry.category.rawValue,
                device: push.entry.deviceId,
                collapseId: push.entry.collapseId,
                dedupeKey: push.entry.dedupeKey,
                title: push.entry.title,
                body: push.entry.body
            )
            return (try? encoder.encode(line)).map { String(decoding: $0, as: UTF8.self) }
        }.joined(separator: "\n")
    }
}

/// A clock a test or a replay can move by hand. The store, the differ and the policy all take
/// their time from a closure for exactly this reason: a long-think rule that can only be tested
/// by waiting ten minutes is a rule that does not get tested.
public final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ start: Date) { current = start }

    public var read: @Sendable () -> Date {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            return current
        }
    }

    public func advance(by interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        lock.unlock()
    }

    public func set(_ date: Date) {
        lock.lock()
        current = date
        lock.unlock()
    }

    public func value() -> Date { read() }
}
