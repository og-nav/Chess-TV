// The palette and type scale from design/mockups/Main.dc.html.
//
// tvOS points are 1:1 with 1080p pixels, so every number here is the mockup's pixel value.
import SwiftUI
import ChessUI
import os

/// One logger for the whole app. `print` is unusable once Stockfish owns stdout.
let appLog = Logger(subsystem: "com.navin.chesstv", category: "App")

enum Palette {
    static let ground = Color(hex: 0x161916)
    static let ink = Color(hex: 0xF4F2E9)
    static let muted = Color(hex: 0xB3B9AA)
    static let panel = Color(hex: 0x222820)
    static let line = Color(hex: 0x384134)
    static let accent = Color(hex: 0xC4D49C)
    /// Reconnecting.
    static let amber = Color(hex: 0xE0B86A)
    /// Offline.
    static let alert = Color(hex: 0xD98A72)
    /// Move numbers and other third-level text.
    static let faint = Color(hex: 0x8F978A)
    static let moveText = Color(hex: 0xD9DBD2)
}

enum Metrics {
    static let boardSide: Double = 800
    static let evalBarWidth: Double = 22
    static let columnGap: Double = 18
    static let panelGap: Double = 46
    static let headerHeight: Double = 56
    static let footerHeight: Double = 52
    static let sectionGap: Double = 32
    /// The mockup pads 80 pt horizontally; the tvOS safe area already supplies ~60.
    static let extraHorizontalPadding: Double = 20
}
