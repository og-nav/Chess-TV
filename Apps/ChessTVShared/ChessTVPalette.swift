// The six colours, for the surfaces this agent owns.
//
// Named `ChessTVPalette` rather than `Palette` on purpose: the tvOS app and ImageryKit each have a
// `Palette` of their own, and these sources are compiled into targets that may well have a third.
// The values are the ones in TV_BUILD_PLAN.md and the mockups.
import SwiftUI
import ChessUI   // for `Color(hex:)`

public enum ChessTVPalette {
    /// #161916 — the screen behind everything.
    public static let ground = Color(hex: 0x161916)
    /// #222820 — cards and panels.
    public static let panel = Color(hex: 0x222820)
    /// #384134 — hairlines.
    public static let line = Color(hex: 0x384134)
    /// #B3B9AA — secondary text.
    public static let muted = Color(hex: 0xB3B9AA)
    /// #F4F2E9 — primary text. Never `.black`: this app has no light appearance yet, and a
    /// hard-coded black would be invisible the day it gets one.
    public static let ink = Color(hex: 0xF4F2E9)
    /// #C4D49C — the one accent: the running clock, the live chip.
    public static let accent = Color(hex: 0xC4D49C)
}
