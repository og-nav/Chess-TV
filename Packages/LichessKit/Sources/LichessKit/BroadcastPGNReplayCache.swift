import Foundation
import ChessCore

/// Validated, immutable replay shared by the visible round wall and a subsequently opened board.
struct BroadcastPGNReplay: Sendable {
    let game: PGNGame
    let steps: [(san: String, uci: String, fen: String)]
    var cost: Int {
        game.tags.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        + game.moves.reduce(0) { $0 + 128 + $1.san.utf8.count + ($1.comment?.utf8.count ?? 0) + ($1.eval?.utf8.count ?? 0) }
        + steps.reduce(0) { $0 + 96 + $1.san.utf8.count + $1.uci.utf8.count + $1.fen.utf8.count }
    }
}

/// Reads never extend freshness. Only receipt of another validated wire PGN does. Origin is part
/// of the key to prevent another provider (or a loopback fixture) aliasing a production game.
final class BroadcastPGNReplayCache: @unchecked Sendable {
    static let shared = BroadcastPGNReplayCache()
    private struct Key: Hashable { let origin: String; let round: String; let game: String }
    private struct Entry {
        let replay: BroadcastPGNReplay
        let received: ContinuousClock.Instant
        let cost: Int
        var access: UInt64
    }
    private let lock = NSLock()
    private let ttl: Duration
    private let capacity: Int
    private let costLimit: Int
    private let now: @Sendable () -> ContinuousClock.Instant
    private var entries: [Key: Entry] = [:]
    private var serial: UInt64 = 0

    init(ttl: Duration = .seconds(60), capacity: Int = 64, costLimit: Int = 8 * 1024 * 1024,
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.ttl = ttl; self.capacity = max(0, capacity); self.costLimit = max(0, costLimit); self.now = now
    }
    func replay(roundId: String, gameId: String, origin: URL) -> BroadcastPGNReplay? {
        lock.withLock {
            let instant = now()
            entries = entries.filter { $0.value.received.duration(to: instant) < ttl }
            let key = Key(origin: origin.absoluteString, round: roundId, game: gameId)
            guard var entry = entries[key] else { return nil }
            serial &+= 1; entry.access = serial; entries[key] = entry
            return entry.replay
        }
    }
    @discardableResult
    func retainMatching(roundId: String, gameId: String, fen: String, origin: URL) -> Bool {
        lock.withLock {
            let key = Key(origin: origin.absoluteString, round: roundId, game: gameId)
            guard let entry = entries[key] else { return false }
            guard entry.received.duration(to: now()) < ttl,
                  FENIdentity.same(entry.replay.steps.last?.fen ?? entry.replay.game.initialPosition.fen, fen) else {
                entries.removeValue(forKey: key)
                return false
            }
            return true
        }
    }
    /// Call only after the complete PGN has successfully replayed.
    func store(_ replay: BroadcastPGNReplay, roundId: String, gameId: String, origin: URL) {
        let cost = replay.cost
        guard capacity > 0, cost <= costLimit else {
            // An authoritative larger replay supersedes the old entry even when it cannot
            // fit. Do not leave an obsolete short line available as a warmup.
            _ = lock.withLock { entries.removeValue(forKey: Key(origin: origin.absoluteString, round: roundId, game: gameId)) }
            return
        }
        lock.withLock {
            let instant = now()
            entries = entries.filter { $0.value.received.duration(to: instant) < ttl }
            serial &+= 1
            let key = Key(origin: origin.absoluteString, round: roundId, game: gameId)
            entries[key] = Entry(replay: replay, received: instant, cost: cost, access: serial)
            var total = entries.values.reduce(0) { $0 + $1.cost }
            while entries.count > capacity || total > costLimit {
                guard let oldest = entries.min(by: { $0.value.access < $1.value.access }) else { break }
                total -= oldest.value.cost
                entries.removeValue(forKey: oldest.key)
            }
        }
    }
}

/// Before handing a live preview to a detail screen, discard a replay that describes a different
/// position. This prevents an older warmup from replacing the board the user just selected.
public enum BroadcastReplayWarmup {
    @discardableResult
    public static func retainMatching(roundId: String, gameId: String, fen: String,
                                      baseURL: URL = LichessConfig.baseURL) -> Bool {
        retainMatching(roundId: roundId, gameId: gameId, fen: fen, baseURL: baseURL, in: .shared)
    }

    /// The same check against a caller-supplied cache, for tests that must not share state.
    static func retainMatching(roundId: String, gameId: String, fen: String, baseURL: URL, in cache: BroadcastPGNReplayCache) -> Bool {
        cache.retainMatching(roundId: roundId, gameId: gameId, fen: fen, origin: baseURL)
    }
}
