import Foundation

/// A lead image found for a place, with the attribution that comes with it.
public struct WikipediaImage: Sendable, Equatable {
    /// The best image the summary offered: `originalimage` when there is one, else `thumbnail`.
    /// Full-size originals can be several thousand pixels wide, which is why every consumer goes
    /// through `ImageCache` and its `maxPixelSize` rather than decoding this directly.
    public let imageURL: URL
    /// The 320-ish pixel version, when the summary had one. Cheap enough for a shelf card.
    public let thumbnailURL: URL?
    /// The article the image came from, after redirects — "Samarkand" for "Samarkand, Uzbekistan".
    public let pageTitle: String
    /// The human-facing article URL, for a "read more" affordance.
    public let pageURL: URL?
    /// What to print under the picture. Commons images are freely licensed, but the licences all
    /// require credit, and naming the article is the honest minimum.
    public let attribution: String

    public init(imageURL: URL, thumbnailURL: URL?, pageTitle: String, pageURL: URL?, attribution: String) {
        self.imageURL = imageURL
        self.thumbnailURL = thumbnailURL
        self.pageTitle = pageTitle
        self.pageURL = pageURL
        self.attribution = attribution
    }
}

/// Finds a picture of a tournament's location from the English Wikipedia's page-summary API.
///
/// Broadcast tours give their location as free text an organiser typed: `"Samarkand, Uzbekistan"`,
/// `"Rosario, Santa Fe - Argentina"`, sometimes just `"Netherlands"`. The first comma- or
/// dash-separated segment is almost always the city, which is the interesting picture, so that is
/// tried first and the last segment — the country — is the fallback. Anything more clever (a
/// geocoder, Wikidata coordinates) would be a second network dependency for a decorative image.
///
/// Only summaries whose `type` is `standard` are accepted. A disambiguation page's lead image is
/// meaningless, and `no-extract` pages are stubs; taking their images is how you end up showing a
/// coat of arms captioned as a chess venue.
///
/// Every answer is memoized on the *input string*, negatives included, because the same tour is
/// re-rendered on every shelf refresh and its location text never changes. A transient failure —
/// a 429 or a dropped connection — is deliberately not memoized, so a flaky minute does not cost
/// the banner for the whole session.
public actor WikipediaImageClient {

    /// The instance the app uses, so one cache serves every shelf.
    public static let shared = WikipediaImageClient()

    private let session: URLSession
    private let baseURL: URL

    /// Input string → the answer, or `nil` for "there is no usable picture for this place".
    private var cache: [String: WikipediaImage?] = [:]

    /// Lookups in progress, so two shelves rendering the same tour make one pair of requests.
    private var inFlight: [String: Task<Outcome, Never>] = [:]

    /// - Parameter baseURL: the API root. Overridden by tests to point at a loopback server.
    public init(
        session: URLSession = ImageryURLSession.standard,
        baseURL: URL = URL(string: "https://en.wikipedia.org")!
    ) {
        self.session = session
        self.baseURL = baseURL
    }

    /// A lead image for `place`, or `nil` when neither the city nor the country yields one.
    ///
    /// Never throws: the caller is a banner with a placeholder already on screen.
    public func image(forPlace place: String) async -> WikipediaImage? {
        let key = place.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if let cached = cache[key] { return cached }
        // Unstructured, so one shelf disappearing does not cancel the lookup the other is sharing.
        if let existing = inFlight[key] { return await existing.value.image }

        let session = self.session
        let baseURL = self.baseURL
        let candidates = Self.candidateTitles(for: key)
        let task = Task<Outcome, Never> {
            await Self.lookup(candidates: candidates, session: session, baseURL: baseURL)
        }
        // Registered before the first suspension, so a second caller finds the task.
        inFlight[key] = task
        defer { inFlight[key] = nil }

        let outcome = await task.value
        // Only a definite answer is worth remembering; a throttle or a dropped connection is not
        // a fact about this place.
        if outcome.isDefinitive { cache.updateValue(outcome.image, forKey: key) }
        return outcome.image
    }

    /// Whether an answer for this place is already known.
    public func isCached(place: String) -> Bool {
        cache[place.trimmingCharacters(in: .whitespacesAndNewlines)] != nil
    }

    // MARK: - Candidates

    /// `"Rosario, Santa Fe - Argentina"` → `["Rosario", "Argentina"]`.
    ///
    /// Splits on commas and on hyphens *with spaces around them*: a bare hyphen is part of a name
    /// ("Guinea-Bissau", "Saint-Quentin") and splitting on it would make nonsense of both halves.
    /// The middle segments are dropped: a province or a state is rarely the picture anyone wants,
    /// and each extra candidate is another request.
    static func candidateTitles(for place: String) -> [String] {
        let separated = place
            .replacingOccurrences(of: " - ", with: ",")
            .replacingOccurrences(of: " \u{2013} ", with: ",")   // en dash
            .replacingOccurrences(of: " \u{2014} ", with: ",")   // em dash
        let segments = separated
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = segments.first else { return [] }
        guard let last = segments.last, last.caseInsensitiveCompare(first) != .orderedSame else { return [first] }
        return [first, last]
    }

    /// Percent-encodes a title for the REST path. Spaces become underscores, as MediaWiki writes
    /// them, and `/` is escaped because article titles legitimately contain one ("AC/DC").
    static func encodedTitle(_ title: String) -> String? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        return title.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: allowed)
    }

    // MARK: - The work, off the actor

    /// What one lookup produced, and whether it is worth caching.
    private struct Outcome: Sendable {
        let image: WikipediaImage?
        /// `false` when a request failed in a way that says nothing about the place.
        let isDefinitive: Bool
    }

    /// `static`, therefore nonisolated: the requests and the decoding run off the actor, which
    /// only owns the cache and the in-flight table.
    private static func lookup(candidates: [String], session: URLSession, baseURL: URL) async -> Outcome {
        var sawTransientFailure = false
        for title in candidates {
            switch await summary(title: title, session: session, baseURL: baseURL) {
            case .found(let image):
                return Outcome(image: image, isDefinitive: true)
            case .noUsableImage:
                continue
            case .transientFailure:
                sawTransientFailure = true
            }
        }
        return Outcome(image: nil, isDefinitive: !sawTransientFailure)
    }

    private enum SummaryResult {
        case found(WikipediaImage)
        /// The page exists but is a disambiguation, a stub, or simply has no lead image; or there
        /// is no such page. Either way, asking again will not change the answer.
        case noUsableImage
        case transientFailure
    }

    private static func summary(title: String, session: URLSession, baseURL: URL) async -> SummaryResult {
        guard let encoded = encodedTitle(title),
              let url = URL(string: "\(baseURL.absoluteString)/api/rest_v1/page/summary/\(encoded)")
        else { return .noUsableImage }

        do {
            let (data, response) = try await session.data(for: ImageryURLSession.request(url))
            guard let http = response as? HTTPURLResponse else { return .transientFailure }
            switch http.statusCode {
            case 200: break
            case 404: return .noUsableImage         // no such article; not going to appear
            default:
                log.notice("Wikipedia summary for \(title, privacy: .public): HTTP \(http.statusCode)")
                return .transientFailure
            }
            guard let wire = try? JSONDecoder().decode(SummaryWire.self, from: data) else {
                log.error("Could not decode the Wikipedia summary for \(title, privacy: .public)")
                return .noUsableImage
            }
            return wire.result ?? .noUsableImage
        } catch {
            log.notice("Wikipedia summary for \(title, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return .transientFailure
        }
    }

    private struct SummaryWire: Decodable {
        struct Image: Decodable { let source: String }
        struct ContentURLs: Decodable {
            struct Desktop: Decodable { let page: String? }
            let desktop: Desktop?
        }
        let type: String?
        let title: String
        let originalimage: Image?
        let thumbnail: Image?
        let contentURLs: ContentURLs?

        enum CodingKeys: String, CodingKey {
            case type, title, originalimage, thumbnail
            case contentURLs = "content_urls"
        }

        /// `nil` when the summary is unusable, so the caller can fall back to the next candidate.
        var result: SummaryResult? {
            // `standard` is the only type that is a real article about one thing. The others are
            // `disambiguation`, `no-extract`, `mainpage`.
            guard type == nil || type == "standard" else {
                log.debug("Wikipedia page \(title, privacy: .public) is \(self.type ?? "?", privacy: .public); skipping")
                return .noUsableImage
            }
            let thumbnailURL = thumbnail.flatMap { URL(string: $0.source) }
            guard let best = originalimage.flatMap({ URL(string: $0.source) }) ?? thumbnailURL else { return nil }
            return .found(WikipediaImage(
                imageURL: best,
                thumbnailURL: thumbnailURL,
                pageTitle: title,
                pageURL: contentURLs?.desktop?.page.flatMap(URL.init(string:)),
                attribution: "Image: Wikipedia — \(title)"
            ))
        }
    }
}
