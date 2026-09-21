import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// A decoded bitmap, already downscaled to the size the caller asked for.
///
/// `CGImage` rather than `UIImage` so the cache is the same code on tvOS and on the Mac, where
/// the tests run. `@unchecked Sendable` is sound because a `CGImage` is immutable once created
/// and this type exposes no way to mutate it.
public struct DecodedImage: @unchecked Sendable {
    public let cgImage: CGImage
    /// The URL it was decoded from, so a view can check it is not about to show a stale picture.
    public let url: URL

    public var pixelWidth: Int { cgImage.width }
    public var pixelHeight: Int { cgImage.height }

    /// Roughly what this image costs in memory, used as the `NSCache` cost and nothing else.
    var byteCost: Int { cgImage.height * max(cgImage.bytesPerRow, cgImage.width * 4) }

    init(cgImage: CGImage, url: URL) {
        self.cgImage = cgImage
        self.url = url
    }
}

/// Downloads, decodes and caches remote images: portraits from Lichess's CDN and tournament
/// banners from `tour.image`.
///
/// Two levels, because the two failure modes are different. The **memory** level is an `NSCache`
/// bounded by total pixel bytes; it exists so that scrolling a board list back and forth does not
/// re-decode. The **disk** level is a plain directory in Caches holding the bytes exactly as they
/// arrived; it exists so that relaunching the app, or walking back into a round, does not re-download.
/// Only the disk level survives the process, and the system may empty it at any time — which is
/// correct for a cache and is why nothing here is treated as durable storage.
///
/// Decoding goes through `CGImageSourceCreateThumbnailAtIndex` with a caller-supplied maximum
/// pixel size. A 500×500 portrait shown 120 points wide would otherwise pin a megabyte of bitmap
/// per player, and eighty of those is most of a tvOS app's memory budget. The thumbnail path also
/// means the format is ImageIO's problem: the Lichess CDN serves `fmt=webp`, which ImageIO decodes
/// natively on tvOS 26 and macOS 15, so no WebP library is vendored.
///
/// Failures are remembered for `failureTTL` (ten minutes by default). Without that, a player whose
/// portrait 404s would be re-requested on every re-render of the panel he is in.
public actor ImageCache {

    /// The instance `RemoteImage` uses. One cache per process, so every view shares the memory
    /// budget and the coalescing rather than each keeping its own copy of the same portraits.
    public static let shared = ImageCache()

    public struct Configuration: Sendable {
        /// Total decoded-pixel bytes held in memory. 64 MB is about sixty 500×500 portraits.
        public var memoryLimitBytes: Int = 64 * 1024 * 1024
        /// Total bytes of downloaded originals kept on disk before the oldest are trimmed.
        public var diskLimitBytes: Int = 200 * 1024 * 1024
        /// How long a failed URL is remembered before it is worth trying again.
        public var failureTTL: Duration = .seconds(600)
        /// Where the originals live. `nil` means `Caches/ImageryKit`.
        public var directory: URL?

        public init(
            memoryLimitBytes: Int = 64 * 1024 * 1024,
            diskLimitBytes: Int = 200 * 1024 * 1024,
            failureTTL: Duration = .seconds(600),
            directory: URL? = nil
        ) {
            self.memoryLimitBytes = memoryLimitBytes
            self.diskLimitBytes = diskLimitBytes
            self.failureTTL = failureTTL
            self.directory = directory
        }
    }

    private let session: URLSession
    private let configuration: Configuration
    private let directory: URL

    /// Decoded images, keyed by URL *and* requested size: the same portrait is legitimately held
    /// at 100 px for a board row and 500 px for the side panel.
    private let memory = NSCache<NSString, Box>()

    /// Loads that have started but not finished, so eighty rows asking for one portrait at the
    /// same moment produce one download.
    private var inFlight: [String: Task<LoadResult?, Never>] = [:]
    /// Different display sizes share downloaded originals, while keeping separate thumbnails.
    /// Retain the task until all size variants finish decoding/writing, closing the gap between
    /// the response arriving and the original becoming available in the disk cache.
    private var downloads: [String: Task<Data?, Never>] = [:]
    private var activeSizes: [String: Int] = [:]

    /// URL string → when it last failed.
    private var failures: [String: ContinuousClock.Instant] = [:]

    /// Bytes written to disk since the last sweep. Trimming stats every file in the directory,
    /// so it is done in batches rather than on every save.
    private var bytesWrittenSinceTrim = 0

    public init(configuration: Configuration = Configuration(), session: URLSession = ImageryURLSession.standard) {
        self.configuration = configuration
        self.session = session
        self.directory = configuration.directory ?? Self.defaultDirectory()
        memory.totalCostLimit = configuration.memoryLimitBytes
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Loading

    /// The image at `url`, downscaled so neither side exceeds `maxPixelSize`.
    ///
    /// Never throws: a missing or undecodable image is simply `nil`, because every caller is a
    /// view whose only recourse is to keep showing its placeholder. The reason is logged.
    ///
    /// - Parameter maxPixelSize: the longest side in *pixels*, not points. Multiply by the screen
    ///   scale at the call site; on tvOS that is 1 for the 1080p mode and 2 for 4K rendering.
    public func image(for url: URL, maxPixelSize: CGFloat) async -> DecodedImage? {
        let key = Self.memoryKey(url: url, maxPixelSize: maxPixelSize)
        if let hit = memory.object(forKey: key as NSString) { return hit.image }

        if let failedAt = failures[url.absoluteString] {
            if failedAt.duration(to: .now) < configuration.failureTTL { return nil }
            failures[url.absoluteString] = nil
        }

        // Unstructured, so one view disappearing mid-load does not cancel the download the
        // other views waiting on this URL are sharing.
        if let existing = inFlight[key] { return await existing.value?.image }

        let urlKey = url.absoluteString
        activeSizes[urlKey, default: 0] += 1
        let file = fileURL(for: url)
        let task = Task<LoadResult?, Never> {
            await Self.load(url: url, maxPixelSize: maxPixelSize, file: file) {
                await self.download(url)
            }
        }
        // Registered before the first suspension, so a second caller entering the actor while
        // this one awaits is guaranteed to find the task rather than start a second download.
        inFlight[key] = task
        defer {
            inFlight[key] = nil
            let remaining = (activeSizes[urlKey] ?? 1) - 1
            if remaining == 0 {
                activeSizes[urlKey] = nil
                downloads[urlKey] = nil
            } else {
                activeSizes[urlKey] = remaining
            }
        }

        guard let result = await task.value else {
            failures[url.absoluteString] = .now
            return nil
        }
        memory.setObject(Box(result.image), forKey: key as NSString, cost: result.image.byteCost)
        noteDiskWrite(bytes: result.bytesWritten)
        return result.image
    }

    /// Warms the cache for images that are about to appear, without making the caller wait.
    public func prefetch(urls: [URL], maxPixelSize: CGFloat) {
        for url in Set(urls) where memory.object(forKey: Self.memoryKey(url: url, maxPixelSize: maxPixelSize) as NSString) == nil {
            Task { _ = await self.image(for: url, maxPixelSize: maxPixelSize) }
        }
    }

    /// Drops the decoded bitmaps but keeps the downloaded originals, for a memory warning.
    public func purgeMemory() {
        memory.removeAllObjects()
    }

    /// Empties both levels. Only for tests and a "reset" affordance; the app never needs it.
    public func removeAll() {
        memory.removeAllObjects()
        failures.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        bytesWrittenSinceTrim = 0
    }

    /// Whether this URL is currently on the "do not retry yet" list.
    public func isFailureRemembered(for url: URL) -> Bool {
        guard let failedAt = failures[url.absoluteString] else { return false }
        return failedAt.duration(to: .now) < configuration.failureTTL
    }

    // MARK: - The work, off the actor

    /// `static`, therefore nonisolated: the download, the file write and the ImageIO decode all
    /// run on the concurrent executor rather than blocking the actor, which only owns bookkeeping.
    private static func load(
        url: URL, maxPixelSize: CGFloat, file: URL,
        download: @Sendable () async -> Data?
    ) async -> LoadResult? {
        if let cached = readFromDisk(file) {
            if let image = decode(cached, maxPixelSize: maxPixelSize) {
                // Already on disk, so nothing new to account for against the disk budget.
                return LoadResult(image: DecodedImage(cgImage: image, url: url), bytesWritten: 0)
            }
            // A truncated or corrupt file: drop it so the next attempt downloads again.
            try? FileManager.default.removeItem(at: file)
        }

        guard let data = await download() else { return nil }

        guard let image = decode(data, maxPixelSize: maxPixelSize) else {
            log.notice("Could not decode \(data.count) bytes from \(url.absoluteString, privacy: .public)")
            return nil
        }
        // The *original* bytes go to disk, not the thumbnail: the same file serves a 100 px row
        // and a 500 px panel, and re-decoding is far cheaper than re-downloading.
        try? data.write(to: file, options: .atomic)
        return LoadResult(image: DecodedImage(cgImage: image, url: url), bytesWritten: data.count)
    }

    /// Network work is shared by URL, independent of the requested thumbnail size.
    private func download(_ url: URL) async -> Data? {
        let key = url.absoluteString
        if let existing = downloads[key] { return await existing.value }
        let session = self.session
        let task = Task<Data?, Never> { await Self.fetch(url: url, session: session) }
        downloads[key] = task
        return await task.value
    }

    private static func fetch(url: URL, session: URLSession) async -> Data? {
        do {
            let (body, response) = try await session.data(for: ImageryURLSession.request(url))
            guard let http = response as? HTTPURLResponse else {
                log.error("Not an HTTP response for \(url.absoluteString, privacy: .public)")
                return nil
            }
            guard http.statusCode == 200 else {
                log.notice("HTTP \(http.statusCode) for \(url.absoluteString, privacy: .public)")
                return nil
            }
            return body
        } catch {
            log.notice("Image download failed for \(url.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }

    }

    /// What `load` hands back: the decoded image plus how many bytes it added to the disk cache,
    /// so the actor can decide when the directory is due a sweep without stat-ing it every time.
    private struct LoadResult: Sendable {
        let image: DecodedImage
        let bytesWritten: Int
    }

    private static func readFromDisk(_ file: URL) -> Data? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), !data.isEmpty else { return nil }
        // Touch it, so the trim below evicts what is genuinely least recently used.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    /// Decodes straight to the display size. `kCGImageSourceThumbnailMaxPixelSize` makes ImageIO
    /// produce the reduced bitmap itself, so the full-size one never exists.
    static func decode(_ data: Data, maxPixelSize: CGFloat) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Honour EXIF orientation now, so callers never have to.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize.rounded())),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - Disk bookkeeping

    /// SHA-256 of the whole URL string, hex. The Lichess CDN puts the identity of an image in its
    /// query (`path=…&w=…&sig=…`), so hashing the full string is the only safe file name — and it
    /// is fixed length, so no CDN URL can produce a path the file system rejects.
    static func fileName(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func fileURL(for url: URL) -> URL {
        directory.appendingPathComponent(Self.fileName(for: url))
    }

    private func noteDiskWrite(bytes: Int) {
        bytesWrittenSinceTrim += bytes
        // A sweep stats every file in the directory, so it is amortised: once per 16 MB written
        // keeps the directory within a few per cent of the limit at a negligible cost.
        guard bytesWrittenSinceTrim > 16 * 1024 * 1024 else { return }
        bytesWrittenSinceTrim = 0
        let directory = self.directory
        let limit = configuration.diskLimitBytes
        // Detached and not awaited: nothing depends on the sweep finishing, and the caller is a
        // view waiting for a picture.
        Task.detached(priority: .utility) { Self.trim(directory: directory, limitBytes: limit) }
    }

    /// Deletes least-recently-modified files until the directory is under the limit.
    /// `nonisolated` and `internal` so the tests can force a sweep without waiting for 16 MB.
    static func trim(directory: URL, limitBytes: Int) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: .skipsHiddenFiles
        ) else { return }

        var files: [(url: URL, modified: Date, size: Int)] = []
        var total = 0
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: Set(keys)) else { continue }
            let size = values.fileSize ?? 0
            files.append((entry, values.contentModificationDate ?? .distantPast, size))
            total += size
        }
        guard total > limitBytes else { return }

        log.notice("Image cache at \(total) bytes, trimming to \(limitBytes)")
        for file in files.sorted(by: { $0.modified < $1.modified }) {
            guard total > limitBytes else { break }
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }

    /// `Caches/ImageryKit`. Caches rather than Application Support because every byte here is
    /// re-downloadable and the system is welcome to reclaim it under storage pressure.
    private static func defaultDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("ImageryKit", isDirectory: true)
    }

    private static func memoryKey(url: URL, maxPixelSize: CGFloat) -> String {
        "\(Int(maxPixelSize.rounded()))|\(url.absoluteString)"
    }

    /// `NSCache` needs a class; this is the only reason it exists.
    private final class Box {
        let image: DecodedImage
        init(_ image: DecodedImage) { self.image = image }
    }
}
