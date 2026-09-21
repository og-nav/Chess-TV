import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ImageryKit

/// `ImageCache` behaviour, driven by the loopback server so that real `URLSession`, real file
/// writes and real ImageIO decoding are exercised. No test touches the internet.
@Suite("Image cache")
struct ImageCacheTests {

    /// A 500×500 WebP portrait, downloaded from Lichess's CDN on 2026-09-18. It is in the bundle
    /// because WebP support is the one thing about the imagery path that could simply not work:
    /// the CDN serves `fmt=webp` for every portrait and nothing here vendors a WebP decoder.
    private static func portraitWebP() throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "portrait", withExtension: "webp", subdirectory: "Fixtures"),
            "missing fixture portrait.webp"
        )
        return try Data(contentsOf: url)
    }

    /// A throwaway cache in its own temporary directory, so tests never touch the real Caches dir
    /// and never see each other's files.
    private static func cache(failureTTL: Duration = .seconds(600), directory: URL? = nil) -> (ImageCache, URL) {
        let directory = directory ?? Self.temporaryDirectory()
        var configuration = ImageCache.Configuration()
        configuration.directory = directory
        configuration.failureTTL = failureTTL
        return (ImageCache(configuration: configuration, session: ImageryURLSession.make()), directory)
    }

    private static func temporaryDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ImageryKitTests-\(UUID().uuidString)", isDirectory: true)
    }

    /// A PNG of the given size, for tests that care about aspect ratio rather than format.
    private static func png(width: Int, height: Int) throws -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.3, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    // MARK: - Decoding

    @Test("ImageIO decodes the Lichess CDN's WebP natively, with no vendored decoder")
    func decodesWebP() throws {
        let data = try Self.portraitWebP()
        // A WebP file, not a PNG that happens to be named .webp.
        #expect(data.prefix(4) == Data("RIFF".utf8))
        #expect(data.dropFirst(8).prefix(4) == Data("WEBP".utf8))

        let full = try #require(ImageCache.decode(data, maxPixelSize: 2000))
        #expect(full.width == 500)
        #expect(full.height == 500)
    }

    @Test("Decoding downscales to the requested maximum pixel size, keeping the aspect ratio")
    func downscalesOnDecode() throws {
        let square = try #require(ImageCache.decode(try Self.portraitWebP(), maxPixelSize: 120))
        #expect(max(square.width, square.height) == 120)
        #expect(square.width == square.height)

        // A banner is not square: the long side is what the limit applies to.
        let banner = try #require(ImageCache.decode(try Self.png(width: 800, height: 400), maxPixelSize: 200))
        #expect(banner.width == 200)
        #expect(banner.height == 100)
    }

    @Test("Undecodable bytes are nil rather than a crash")
    func rejectsGarbage() {
        #expect(ImageCache.decode(Data("this is not an image".utf8), maxPixelSize: 100) == nil)
        #expect(ImageCache.decode(Data(), maxPixelSize: 100) == nil)
    }

    // MARK: - Caching

    @Test("A second request for the same URL and size is answered from memory")
    func memoizesDecodedImages() async throws {
        let body = try Self.portraitWebP()
        let server = try LoopbackHTTPServer(response: .init(contentType: "image/webp", body: body))
        defer { server.stop() }
        let (cache, directory) = Self.cache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = server.baseURL.appendingPathComponent("portrait.webp")

        let first = try await withTimeout(.seconds(10), "first load") { await cache.image(for: url, maxPixelSize: 120) }
        let second = try await withTimeout(.seconds(10), "second load") { await cache.image(for: url, maxPixelSize: 120) }
        #expect(first?.pixelWidth == 120)
        #expect(second?.pixelWidth == 120)
        #expect(first?.url == url)
        #expect(server.requestCount == 1)

        let head = try #require(server.requests.first)
        #expect(head.contains("User-Agent: ChessTV/"))   // the exact value is UserAgentTests' business
    }

    @Test("The downloaded bytes survive a new cache over the same directory")
    func reusesTheDiskCache() async throws {
        let body = try Self.portraitWebP()
        let server = try LoopbackHTTPServer(response: .init(contentType: "image/webp", body: body))
        defer { server.stop() }
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = server.baseURL.appendingPathComponent("portrait.webp")

        let (first, _) = Self.cache(directory: directory)
        _ = try await withTimeout(.seconds(10), "first load") { await first.image(for: url, maxPixelSize: 500) }
        #expect(server.requestCount == 1)

        // A fresh instance: no memory cache at all, so anything it finds came off disk. Asking for
        // a different size proves the *original* bytes were kept, not the thumbnail.
        let (second, _) = Self.cache(directory: directory)
        let reloaded = try await withTimeout(.seconds(10), "disk load") { await second.image(for: url, maxPixelSize: 100) }
        #expect(reloaded?.pixelWidth == 100)
        #expect(server.requestCount == 1)

        let file = await second.fileURL(for: url)
        #expect(FileManager.default.fileExists(atPath: file.path))
        // SHA-256 hex: fixed length whatever the CDN puts in the query string.
        #expect(ImageCache.fileName(for: url).count == 64)
    }

    @Test("A 404 is remembered, so a missing portrait is not re-requested on every re-render")
    func remembersFailures() async throws {
        let server = try LoopbackHTTPServer(response: .init(statusCode: 404, body: Data("nope".utf8)))
        defer { server.stop() }
        let (cache, directory) = Self.cache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = server.baseURL.appendingPathComponent("missing.webp")

        #expect(await cache.image(for: url, maxPixelSize: 120) == nil)
        #expect(await cache.isFailureRemembered(for: url))
        for _ in 0..<5 { #expect(await cache.image(for: url, maxPixelSize: 120) == nil) }
        #expect(server.requestCount == 1)
    }

    @Test("A remembered failure expires, so a transient outage is not permanent")
    func failuresExpire() async throws {
        let body = try Self.portraitWebP()
        let server = try LoopbackHTTPServer(router: { _, index in
            index == 0 ? .init(statusCode: 500, body: Data()) : .init(contentType: "image/webp", body: body)
        })
        defer { server.stop() }
        let (cache, directory) = Self.cache(failureTTL: .milliseconds(50))
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = server.baseURL.appendingPathComponent("flaky.webp")

        #expect(await cache.image(for: url, maxPixelSize: 100) == nil)
        try await Task.sleep(for: .milliseconds(120))
        #expect(await cache.isFailureRemembered(for: url) == false)
        let recovered = try await withTimeout(.seconds(10), "retry") { await cache.image(for: url, maxPixelSize: 100) }
        #expect(recovered?.pixelWidth == 100)
        #expect(server.requestCount == 2)
    }

    @Test("Eighty rows asking for one portrait at once produce one download")
    func coalescesConcurrentLoads() async throws {
        let body = try Self.portraitWebP()
        let server = try LoopbackHTTPServer(response: .init(contentType: "image/webp", body: body, delay: 0.4))
        defer { server.stop() }
        let (cache, directory) = Self.cache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = server.baseURL.appendingPathComponent("portrait.webp")

        let widths = try await withTimeout(.seconds(20), "eighty concurrent loads") {
            await withTaskGroup(of: Int?.self) { group in
                for _ in 0..<80 { group.addTask { await cache.image(for: url, maxPixelSize: 120)?.pixelWidth } }
                var collected: [Int?] = []
                for await width in group { collected.append(width) }
                return collected
            }
        }
        #expect(widths.count == 80)
        #expect(widths.allSatisfy { $0 == 120 })
        #expect(server.requestCount == 1)
    }

    @Test("Concurrent size variants share one download and retain distinct thumbnail sizes")
    func coalescesDownloadsAcrossSizes() async throws {
        let body = try Self.png(width: 800, height: 400)
        let server = try LoopbackHTTPServer(response: .init(contentType: "image/png", body: body, delay: 0.3))
        defer { server.stop() }
        let (cache, directory) = Self.cache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = server.baseURL.appendingPathComponent("banner.png")

        let images = try await withTimeout(.seconds(10), "different thumbnail sizes") {
            async let small = cache.image(for: url, maxPixelSize: 160)
            async let large = cache.image(for: url, maxPixelSize: 240)
            return await (small, large)
        }
        #expect(images.0?.pixelWidth == 160)
        #expect(images.0?.pixelHeight == 80)
        #expect(images.1?.pixelWidth == 240)
        #expect(images.1?.pixelHeight == 120)
        #expect(server.requestCount == 1)
        await cache.purgeMemory()
        let fromDisk = await cache.image(for: url, maxPixelSize: 320)
        #expect(fromDisk?.pixelWidth == 320)
        #expect(server.requestCount == 1)
    }

    @Test("Concurrent sizes also share failed downloads without creating invalid disk images")
    func coalescesFailuresAcrossSizes() async throws {
        let server = try LoopbackHTTPServer(response: .init(statusCode: 404, body: Data(), delay: 0.3))
        defer { server.stop() }
        let (cache, directory) = Self.cache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = server.baseURL.appendingPathComponent("missing.png")
        async let small = cache.image(for: url, maxPixelSize: 160)
        async let large = cache.image(for: url, maxPixelSize: 240)
        let images = await (small, large)
        #expect(images.0 == nil)
        #expect(images.1 == nil)
        #expect(server.requestCount == 1)
        #expect(await cache.isFailureRemembered(for: url))
        #expect(await cache.image(for: url, maxPixelSize: 320) == nil)
        #expect(server.requestCount == 1)
        let file = await cache.fileURL(for: url)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Disk budget

    @Test("Trimming deletes the least recently modified files until the directory fits")
    func trimsTheDiskCache() throws {
        let directory = Self.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Ten 10 KB files, each a minute older than the next.
        let payload = Data(repeating: 0x41, count: 10_000)
        for index in 0..<10 {
            let file = directory.appendingPathComponent("file\(index)")
            try payload.write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(Double(index) * 60 - 600)],
                ofItemAtPath: file.path
            )
        }

        ImageCache.trim(directory: directory, limitBytes: 45_000)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        // The four oldest go; what is left is under the limit.
        #expect(remaining.count == 4)
        #expect(remaining == ["file6", "file7", "file8", "file9"])
    }

    @Test("A directory already under the limit is left alone")
    func trimIsANoOpWhenUnderTheLimit() throws {
        let directory = Self.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(repeating: 0, count: 1000).write(to: directory.appendingPathComponent("only"))

        ImageCache.trim(directory: directory, limitBytes: 200 * 1024 * 1024)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["only"])
    }
}
