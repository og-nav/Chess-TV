import Foundation

/// One player's FIDE record as Lichess republishes it at `/api/fide/player/{id}`.
///
/// Lichess serves the official FIDE rating list plus, for the players it has a portrait for,
/// a photo hosted on its own image CDN in three sizes. Only `id`, `name` and `federation`
/// are always present: the rating fields are absent for unrated players, `title` for untitled
/// ones, and `photo` for the large majority of the eight-hundred-thousand-odd records.
public struct FIDEPlayer: Sendable, Equatable, Identifiable {
    /// The FIDE id, which is also the identity of the record.
    public let id: Int
    /// As FIDE writes it, "Last, First" — see `PlayerPlaceholder` for how that is initialled.
    public let name: String
    /// Three-letter FIDE (IOC-style) federation code, e.g. `NOR`. `Federations` maps it to a flag.
    public let federation: String
    /// `GM`, `IM`, `WGM`, … Absent for untitled players.
    public let title: String?
    /// Year of birth. Absent for a few older records.
    public let year: Int?
    public let standard: Int?
    public let rapid: Int?
    public let blitz: Int?
    /// 100×100 WebP on `image.lichess1.org`, for board lists.
    public let photoSmallURL: URL?
    /// 500×500 WebP on `image.lichess1.org`, for the game side panel.
    public let photoMediumURL: URL?
    /// The photographer Lichess credits. Shown next to the portrait when there is room.
    public let photoCredit: String?

    public init(
        id: Int,
        name: String,
        federation: String,
        title: String? = nil,
        year: Int? = nil,
        standard: Int? = nil,
        rapid: Int? = nil,
        blitz: Int? = nil,
        photoSmallURL: URL? = nil,
        photoMediumURL: URL? = nil,
        photoCredit: String? = nil
    ) {
        self.id = id
        self.name = name
        self.federation = federation
        self.title = title
        self.year = year
        self.standard = standard
        self.rapid = rapid
        self.blitz = blitz
        self.photoSmallURL = photoSmallURL
        self.photoMediumURL = photoMediumURL
        self.photoCredit = photoCredit
    }
}

/// Looks up FIDE players, memoizing every answer for the life of the process.
///
/// An actor rather than the `@unchecked Sendable` class the other clients use, because this one
/// owns mutable state: a broadcast round's board list carries up to eighty players and the same
/// ids reappear on every round and every re-render, so the client must both cache answers and
/// coalesce the simultaneous first lookups. Without coalescing, opening a round would fire
/// eighty requests and then eighty more when the boards refresh.
///
/// What is cached is the *fact*, not the outcome of a request: a 404 means the id is not in the
/// FIDE table and is remembered as `nil`, while a 429 or a dropped connection is left uncached so
/// the next caller tries again. The record itself changes only when FIDE publishes a new rating
/// list (monthly), so a process-lifetime cache is not stale in any way that matters on a TV.
public actor FIDEPlayerClient {
    public static let shared = FIDEPlayerClient()
    private let session: URLSession
    private let baseURL: URL

    /// `fideId → player or "known not to exist"`. The nested optional is the point: a present key
    /// with a `nil` value is a cached 404, so `updateValue` is used rather than subscript
    /// assignment, which would delete the key instead.
    private var cache: [Int: FIDEPlayer?] = [:]

    /// Lookups that have been started but not finished, so concurrent callers share one request.
    private var inFlight: [Int: Task<FIDEPlayer?, Error>] = [:]

    public init(session: URLSession = LichessURLSession.standard, baseURL: URL = LichessConfig.baseURL) {
        self.session = session
        self.baseURL = baseURL
    }

    /// The FIDE record for `fideId`, or `nil` when FIDE has no such player.
    ///
    /// - Parameter fideId: a FIDE id. Lichess reports `0` for a player without one — every engine
    ///   account, and most amateurs in a broadcast — so that short-circuits without a request.
    /// - Throws: `LichessError.rateLimited` or a transport error. Neither is cached.
    public func player(fideId: Int) async throws -> FIDEPlayer? {
        guard fideId > 0 else { return nil }
        if let cached = cache[fideId] { return cached }
        // The in-flight task is unstructured, so it does not inherit any caller's cancellation:
        // one view disappearing mid-load must not cancel the request the other callers share.
        if let existing = inFlight[fideId] { return try await existing.value }

        let session = self.session
        let baseURL = self.baseURL
        let task = Task<FIDEPlayer?, Error> {
            do {
                return try await Self.fetch(fideId: fideId, session: session, baseURL: baseURL)
            } catch LichessError.unrecoverableStatus(404) {
                log.debug("No FIDE record for \(fideId)")
                return nil
            }
        }
        // Registered before the first suspension, so a second caller entering the actor while this
        // one is awaiting is guaranteed to find the task rather than start a second request.
        inFlight[fideId] = task
        defer { inFlight[fideId] = nil }

        let player = try await task.value
        cache.updateValue(player, forKey: fideId)
        return player
    }

    /// Whether an answer for `fideId` is already known, so a view can decide not to show a spinner.
    /// `0` counts as known: it is the "no FIDE id" sentinel.
    public func isCached(fideId: Int) -> Bool {
        fideId <= 0 || cache[fideId] != nil
    }

    /// Warms the cache for a whole board list without making the caller wait or handle failures.
    /// Duplicate and already-cached ids cost nothing; `player(fideId:)` coalesces the rest.
    public func prefetch(fideIds: [Int]) {
        for fideId in Set(fideIds) where !isCached(fideId: fideId) {
            Task { _ = try? await self.player(fideId: fideId) }
        }
    }

    // MARK: - Wire

    private static func fetch(fideId: Int, session: URLSession, baseURL: URL) async throws -> FIDEPlayer {
        let url = baseURL.appendingPathComponent("api/fide/player").appendingPathComponent(String(fideId))
        let data = try await LichessHTTP.get(url, session: session)
        return try decode(data)
    }

    /// Split out so tests can drive it straight from a fixture.
    static func decode(_ data: Data) throws -> FIDEPlayer {
        try LichessHTTP.decode(PlayerWire.self, from: data, what: "FIDE player").model
    }
}

private struct PlayerWire: Decodable {
    struct Photo: Decodable {
        let small: String?
        let medium: String?
        let credit: String?
    }
    let id: Int
    let name: String
    let federation: String
    let title: String?
    let year: Int?
    let standard: Int?
    let rapid: Int?
    let blitz: Int?
    let photo: Photo?

    var model: FIDEPlayer {
        FIDEPlayer(
            id: id,
            name: name,
            federation: federation,
            title: title,
            year: year,
            standard: standard,
            rapid: rapid,
            blitz: blitz,
            photoSmallURL: photo?.small.flatMap(URL.init(string:)),
            photoMediumURL: photo?.medium.flatMap(URL.init(string:)),
            photoCredit: photo?.credit
        )
    }
}
