import SwiftUI

/// A remote image that shows its placeholder at once and crossfades the picture in behind it.
///
/// Not `AsyncImage`: that one caches nothing between appearances, sends no `User-Agent` (both
/// the Lichess CDN and Wikimedia care), and decodes at full size, so a shelf of 500×500 portraits
/// would re-download and re-decode on every scroll. This goes through `ImageCache`, which
/// memoizes, coalesces, keeps the bytes on disk across launches and decodes straight to
/// `maxPixelSize`.
///
/// The one behaviour worth stating plainly: **a recycled view never shows the previous URL's
/// picture.** `.task(id: url)` cancels the in-flight load and the state is cleared before the new
/// one starts, and the decoded image carries its own URL so the body can refuse a late arrival.
/// Without that, scrolling a board list swaps the wrong faces onto the wrong names for a frame.
public struct RemoteImage<Placeholder: View>: View {
    private let url: URL?
    private let maxPixelSize: CGFloat
    private let contentMode: ContentMode
    private let cache: ImageCache
    private let placeholder: Placeholder

    @State private var loaded: DecodedImage?

    /// - Parameters:
    ///   - url: `nil` renders the placeholder and asks for nothing — the common case for a player
    ///     with no portrait.
    ///   - maxPixelSize: the longest side to decode to, in **pixels**. Pass the on-screen size
    ///     times the display scale; anything larger is memory spent on detail nobody can see.
    ///   - contentMode: `.fill` (the default) crops to the frame, which is what a portrait or a
    ///     banner wants; `.fit` letterboxes.
    ///   - cache: injectable so tests and previews can use a throwaway cache.
    ///   - placeholder: shown immediately, and left showing for good if the image never arrives.
    public init(
        url: URL?,
        maxPixelSize: CGFloat,
        contentMode: ContentMode = .fill,
        cache: ImageCache = .shared,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.url = url
        self.maxPixelSize = maxPixelSize
        self.contentMode = contentMode
        self.cache = cache
        self.placeholder = placeholder()
    }

    public var body: some View {
        ZStack {
            placeholder
            // The URL check is the guard against a load that finished after the id changed.
            if let loaded, loaded.url == url {
                Image(decorative: loaded.cgImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }
        }
        // `.fill` overflows its frame by definition; clipping here saves every caller from
        // remembering to, and a caller that wants rounded corners can still clip again outside.
        .clipped()
        .animation(.easeInOut(duration: 0.28), value: loaded?.url)
        .task(id: url) {
            // Cleared before the await, so the old picture is gone the instant the URL changes
            // rather than lingering until the new one decodes.
            loaded = nil
            guard let url else { return }
            let image = await cache.image(for: url, maxPixelSize: maxPixelSize)
            guard !Task.isCancelled else { return }
            loaded = image
        }
    }
}

extension RemoteImage where Placeholder == BannerPlaceholder {
    /// A tournament banner with the standard placeholder.
    public init(bannerURL: URL?, maxPixelSize: CGFloat, title: String? = nil, cache: ImageCache = .shared) {
        self.init(url: bannerURL, maxPixelSize: maxPixelSize, contentMode: .fill, cache: cache) {
            BannerPlaceholder(title: title)
        }
    }
}

extension RemoteImage where Placeholder == PlayerPlaceholder {
    /// A player portrait with the standard initials placeholder.
    public init(portraitURL: URL?, maxPixelSize: CGFloat, name: String, cache: ImageCache = .shared) {
        self.init(url: portraitURL, maxPixelSize: maxPixelSize, contentMode: .fill, cache: cache) {
            PlayerPlaceholder(name: name)
        }
    }
}
