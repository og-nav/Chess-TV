import SwiftUI

/// What stands in for a player portrait: the player's initials on a disc, over a soft silhouette.
///
/// Most players in a broadcast have no portrait at all, and the ones who do need something to
/// look at while the CDN answers, so this is the common case rather than an error state. It is
/// deliberately calm — no spinner, no "missing image" iconography — because a board list is
/// mostly placeholders and a grid of spinners would be the loudest thing on the screen.
public struct PlayerPlaceholder: View {
    private let name: String
    private let showsSilhouette: Bool

    /// - Parameters:
    ///   - name: the player's name in any of the forms the feeds use. FIDE writes "Last, First".
    ///   - showsSilhouette: the head-and-shoulders shape behind the initials. Turn it off at
    ///     small sizes, where it reads as smudge rather than as a person.
    public init(name: String, showsSilhouette: Bool = true) {
        self.name = name
        self.showsSilhouette = showsSilhouette
    }

    public var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                Circle().fill(Palette.panel)
                Circle().strokeBorder(Palette.line, lineWidth: max(1, side * 0.02))
                if showsSilhouette {
                    Image(systemName: "person.fill")
                        .font(.system(size: side * 0.52))
                        .foregroundStyle(Palette.line)
                        .offset(y: side * 0.06)
                }
                Text(Self.initials(for: name))
                    .font(.system(size: side * 0.36, weight: .semibold, design: .default))
                    .foregroundStyle(Palette.muted)
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel(Text(name))
    }

    /// One or two initials for a player name.
    ///
    /// FIDE and most broadcast PGNs write "Carlsen, Magnus", so a comma means surname first and
    /// the initials have to be *reversed* to read as "MC" rather than "CM". Without a comma the
    /// name is taken as written, first word then last word: "Magnus Carlsen" and the Indian
    /// surname-first style "Erigaisi Arjun" both give the order they are written in, which is
    /// the best that can be done without knowing the convention.
    ///
    /// `nonisolated` because conforming to `View` makes the whole type `@MainActor`, and this is
    /// pure string handling that a background formatter or a test has every right to call.
    public nonisolated static func initials(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "?" }

        let parts: [Substring]
        if let comma = trimmed.firstIndex(of: ",") {
            // "Last, First" → given name first.
            parts = [trimmed[trimmed.index(after: comma)...], trimmed[..<comma]]
        } else {
            parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        }

        // Ignore anything that is not a letter, so "O'Brien" and "van der Wiel" behave.
        let letters = parts.compactMap { $0.first(where: \.isLetter) }
        guard let first = letters.first else { return "?" }
        guard letters.count > 1, let last = letters.last else { return String(first).uppercased() }
        return (String(first) + String(last)).uppercased()
    }
}

/// What stands in for a tournament banner: a soft two-tone panel, optionally captioned.
///
/// Thirty-six of the thirty-seven active tours have a `tour.image`, so this is mostly a
/// one-frame flash before the real banner crossfades in — which is exactly why it must not be a
/// spinner or a grey box. The gradient runs in the same direction as the real banners' letterbox
/// crop, so the swap does not jump.
public struct BannerPlaceholder: View {
    private let title: String?

    /// - Parameter title: shown small in the corner when the caller has the tour name already.
    public init(title: String? = nil) {
        self.title = title
    }

    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [Palette.panel, Palette.line.opacity(0.65), Palette.panel],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // A single hairline along the bottom, so a shelf of these still reads as cards.
            Rectangle()
                .fill(Palette.line)
                .frame(height: 1)
                .frame(maxHeight: .infinity, alignment: .bottom)
            if let title {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
                    .lineLimit(2)
                    .padding(12)
            }
        }
        .accessibilityHidden(title == nil)
    }
}

#if DEBUG
#Preview("Placeholders") {
    VStack(spacing: 24) {
        HStack(spacing: 24) {
            PlayerPlaceholder(name: "Carlsen, Magnus").frame(width: 120, height: 120)
            PlayerPlaceholder(name: "Erigaisi Arjun").frame(width: 120, height: 120)
            PlayerPlaceholder(name: "Stockfish", showsSilhouette: false).frame(width: 120, height: 120)
        }
        BannerPlaceholder(title: "Tata Steel Masters 2026").frame(width: 640, height: 320)
    }
    .padding(40)
    .background(Palette.ground)
}
#endif
