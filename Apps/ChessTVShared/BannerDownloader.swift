// Fetching a tournament banner inside a notification service extension.
//
// A URL that arrives in a push is treated as untrusted metadata. Not because pushes are easy to
// forge — sending one needs the signing key for this app's APNs topic, not merely a device's APNs
// token — but because the extension cannot *check*: it holds no credential, verifies no signature,
// and the banner URL is a string our server itself copied out of a Lichess broadcast. So the rules
// here are deliberately mean, and all five are enforced:
//
//   1. **HTTPS only**, and only from an exact host on `allowedHosts`. No suffix matching — a
//      `lichess1.org.evil.example` must not slip through, and neither must plain HTTP.
//   2. **Every redirect hop re-checked** against the same rule, and a limit on how many there may
//      be. `URLSession` follows redirects by itself, so an allowed host that answers with a 302 to
//      anywhere would otherwise walk straight past rule 1.
//   3. **A byte cap**, enforced as the body arrives rather than by trusting `Content-Length`. The
//      task is cancelled the moment the cap is passed, so a server that lies about its length
//      cannot make the extension hold an arbitrary amount of data.
//   4. **A wall-clock timeout** on the whole operation, well short of the extension's own.
//   5. **A pixel cap** on the decode, so a small file that expands into a large bitmap cannot take
//      the memory the board needs.
//
// Anything that trips a rule returns nil, and the caller sends the notification without a picture.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum BannerDownloader {

    /// Lichess's image CDN and the site itself. Nothing else is fetched, ever.
    public static let allowedHosts: Set<String> = [
        "image.lichess1.org",
        "lichess1.org",
        "lichess.org",
    ]

    /// 512 KB. A Lichess tour banner is an 800×400 WebP of roughly 40 KB, so this is ten times
    /// generous and still a rounding error against the extension's 24 MB.
    public static let maximumBytes = 512 * 1024

    /// The longest side of the decoded bitmap. 800 px matches the source and is more than a
    /// notification banner ever shows.
    public static let maximumPixelSize = 800

    public static let timeout: Duration = .seconds(5)

    /// How many redirects may be followed. Lichess's CDN uses at most one; three is room for a
    /// scheme or a region hop without letting a chain run.
    public static let maximumRedirects = 3

    /// True when this URL is one we are willing to fetch at all. Applied to the URL in the push
    /// *and* to every redirect the response asks for. Exposed so the wording code can decide
    /// whether to bother, and so a test can assert the rule without a network.
    public static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else { return false }
        guard let host = url.host()?.lowercased() else { return false }
        return url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
            && allowedHosts.contains(host)
    }

    /// The banner as a JPEG on disk, ready for `UNNotificationAttachment`, or nil.
    public static func imageFile(for url: URL, named name: String, userAgent: String) async -> URL? {
        guard isAllowed(url) else {
            pushLog.notice("Banner refused: not an allowed HTTPS host")
            return nil
        }
        let download = await withTimeout(timeout) {
            await CappedDownload.body(of: url, cap: maximumBytes, userAgent: userAgent)
        }
        guard let data = download else { return nil }
        guard let image = decode(data) else {
            pushLog.notice("Banner refused: \(data.count) bytes did not decode")
            return nil
        }
        return writeJPEG(image, named: name)
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func writeJPEG(_ image: CGImage, named name: String) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("banners", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).jpg")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }
}

/// A `URLSession` delegate that stops a download the moment it grows past a cap.
///
/// `URLSession.data(for:)` would buffer whatever the server chose to send before this code ever
/// saw a byte count, and iterating `URLSession.bytes` one `UInt8` at a time costs half a million
/// async resumptions for half a megabyte. The delegate sees each chunk as it lands, which is both
/// cheap and actually bounded.
final class CappedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    /// The body of `url`, or nil if it was refused, failed, or passed `cap` bytes.
    static func body(of url: URL, cap: Int, userAgent: String) async -> Data? {
        let collector = CappedDownload(cap: cap)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 1
        let session = URLSession(configuration: configuration, delegate: collector, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("image/*", forHTTPHeaderField: "Accept")

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // `onCancel` can run *before* this closure does, and used to: `cancel()` would set
                // `settled` with no continuation to resume, and the continuation installed a moment
                // later was never resumed at all — the extension then hung until its own deadline
                // killed it, which is the one failure this file exists to avoid.
                guard collector.install(continuation) else { return }
                let task = session.dataTask(with: request)
                guard collector.install(task) else { return }
                task.resume()
            }
        } onCancel: {
            collector.cancel()
        }
    }

    private let cap: Int
    private let lock = NSLock()
    private var buffer = Data()
    private var settled = false
    private var redirects = 0
    private var _continuation: CheckedContinuation<Data?, Never>?
    private var _task: URLSessionDataTask?

    init(cap: Int) {
        self.cap = cap
    }

    /// Installs the continuation atomically against `finish`.
    ///
    /// - Returns: true when it was installed and the caller should go on to start a task. False
    ///   means the download had already settled — a cancellation that arrived first — in which case
    ///   the continuation is resumed here, and there is nothing to start.
    private func install(_ continuation: CheckedContinuation<Data?, Never>) -> Bool {
        let alreadySettled: Bool = lock.withLock {
            guard !settled else { return true }
            _continuation = continuation
            return false
        }
        if alreadySettled { continuation.resume(returning: nil) }
        return !alreadySettled
    }

    /// Stores the task, or cancels it at once if the download settled while it was being created.
    /// A task installed after the fact would otherwise keep running with nobody waiting on it.
    private func install(_ task: URLSessionDataTask) -> Bool {
        let alreadySettled: Bool = lock.withLock {
            guard !settled else { return true }
            _task = task
            return false
        }
        if alreadySettled { task.cancel() }
        return !alreadySettled
    }

    /// Resumes the continuation exactly once, whichever path gets here first (completion, cap
    /// exceeded, a refused redirect, cancellation).
    private func finish(with data: Data?) {
        let continuation: CheckedContinuation<Data?, Never>? = lock.withLock {
            guard !settled else { return nil }
            settled = true
            let held = _continuation
            _continuation = nil
            return held
        }
        continuation?.resume(returning: data)
    }

    func cancel() {
        let task: URLSessionDataTask? = lock.withLock { _task }
        task?.cancel()
        finish(with: nil)
    }

    /// Every hop is re-checked against the allow-list.
    ///
    /// `URLSession` follows redirects on its own, so without this an allowed host answering `302
    /// http://evil.example/` would be fetched with rule 1 satisfied exactly once — at the start,
    /// on a URL that no longer describes what is being downloaded.
    ///
    /// Returning nil declines the redirect; the task then completes with the redirect response and
    /// an empty body, which `didCompleteWithError` reads as nothing to deliver. The download is
    /// settled here regardless, so neither outcome depends on that.
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        let hops: Int = lock.withLock {
            redirects += 1
            return redirects
        }
        guard hops <= BannerDownloader.maximumRedirects else {
            pushLog.notice("Banner refused: more than \(BannerDownloader.maximumRedirects) redirects")
            task.cancel()
            finish(with: nil)
            return nil
        }
        guard let url = request.url, BannerDownloader.isAllowed(url) else {
            pushLog.notice("Banner refused: redirected to a host that is not on the allow-list")
            task.cancel()
            finish(with: nil)
            return nil
        }
        // A redirect starts a new body. The bytes counted so far belong to the response that is
        // being redirected away from, and keeping them would let a chain of small responses add up
        // past the cap — or, worse, prepend rubbish to the image.
        lock.withLock { buffer.removeAll(keepingCapacity: true) }
        return request
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse
    ) async -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            pushLog.notice("Banner refused: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            return .cancel
        }
        // An honest server that declares too much saves us the transfer entirely.
        if http.expectedContentLength > Int64(cap) {
            pushLog.notice("Banner refused: declared \(http.expectedContentLength) bytes")
            return .cancel
        }
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceeded: Bool = lock.withLock {
            guard !settled else { return false }
            buffer.append(data)
            return buffer.count > cap
        }
        guard exceeded else { return }
        pushLog.notice("Banner refused: body passed \(self.cap) bytes")
        dataTask.cancel()
        finish(with: nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            pushLog.notice("Banner download failed: \(logLabel(for: error), privacy: .public)")
            finish(with: nil)
            return
        }
        let body: Data? = lock.withLock { buffer.isEmpty ? nil : buffer }
        finish(with: body)
    }
}
