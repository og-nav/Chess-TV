import SwiftUI

/// The Chess TV palette, duplicated here on purpose.
///
/// ImageryKit's placeholders have to look like the rest of the app while it is still a package
/// with no dependency on the app target — a package cannot import its client. The values are the
/// same six the mockups and `TV_BUILD_PLAN.md` specify; if they ever change, they change in both
/// places, which is the price of keeping the package standalone.
enum Palette {
    /// #161916 — the screen behind everything.
    public static let ground = Color(hex: 0x161916)
    /// #222820 — cards, panels, the ground of a placeholder.
    public static let panel = Color(hex: 0x222820)
    /// #384134 — hairlines and dividers.
    public static let line = Color(hex: 0x384134)
    /// #B3B9AA — secondary text, and the silhouette in a portrait placeholder.
    public static let muted = Color(hex: 0xB3B9AA)
    /// #F4F2E9 — primary text.
    public static let ink = Color(hex: 0xF4F2E9)
    /// #C4D49C — the one accent: active clock, focus, the live chip.
    public static let accent = Color(hex: 0xC4D49C)
}

extension Color {
    /// `0xRRGGBB`. Package-internal sugar so the palette above reads like the design notes.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
