// The phone's palette and metrics, and the app's one logger.
//
// The identity is the TV app's, from Apps/ChessTV/App/Palette.swift and the mockup canvas: the
// same ground, ink, panel and accent, so a screenshot of the phone beside the TV reads as one
// product. Nothing here hard-codes black text, so a light appearance stays possible later.
import SwiftUI
import ChessUI
import os

/// `print` is unusable in a process that hosts Stockfish on stdout, and a Logger is what the
/// device console shows.
let mobileLog = Logger(subsystem: "com.navin.chesstv", category: "Mobile")

enum Palette {
    static let ground = Color(hex: 0x161916)
    static let ink = Color(hex: 0xF4F2E9)
    static let muted = Color(hex: 0xB3B9AA)
    static let panel = Color(hex: 0x222820)
    static let line = Color(hex: 0x384134)
    static let accent = Color(hex: 0xC4D49C)
    /// Reconnecting.
    static let amber = Color(hex: 0xE0B86A)
    /// Offline, and anything that failed.
    static let alert = Color(hex: 0xD98A72)
    /// Move numbers and other third-level text.
    static let faint = Color(hex: 0x8F978A)
    static let moveText = Color(hex: 0xD9DBD2)
}

enum Metrics {
    /// The eval bar down the board's left edge. Thinner than the TV's 22 pt: it sits beside a
    /// board that is one phone wide, not 800 pt.
    static let evalBarWidth: Double = 14
    static let cardCorner: Double = 14
    static let cardPadding: Double = 12
    /// The gap between the board and the panel beside it on iPad and in landscape.
    static let panelGap: Double = 20
    /// A mini board on the boards wall never shrinks below this, so the pieces stay readable.
    static let minimumMiniBoard: Double = 132
}

// MARK: - Shared chrome

/// The dark card every list row and shelf cell sits on.
struct PanelBackground: ViewModifier {
    var corner: Double = Metrics.cardCorner
    func body(content: Content) -> some View {
        content
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Palette.line, lineWidth: 1)
            )
    }
}

extension View {
    func panelCard(corner: Double = Metrics.cardCorner) -> some View {
        modifier(PanelBackground(corner: corner))
    }

    /// Hides a decorative view from VoiceOver without hiding its neighbours.
    func decorative() -> some View { accessibilityHidden(true) }
}

/// A small pill: "Live", "Round 5", a result. Scales with Dynamic Type rather than a fixed size.
struct Chip: View {
    let text: String
    var tint: Color = Palette.accent
    var filled = false

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(filled ? Palette.ground : tint)
            .background(filled ? tint : tint.opacity(0.16), in: Capsule())
    }
}

/// The dot-and-word the header uses for the feed's connection.
struct ConnectionDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}
