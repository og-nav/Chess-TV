// Turning an engine score into a bar fraction and a label.
import Foundation

public enum EvalMapping {
    /// Maps centipawns (White's perspective) to White's share of the bar via 1/(1+10^(-cp/400)).
    /// This is the Lichess win-probability curve: 0 cp → 0.5, +400 cp → ≈0.909.
    public static func whiteShare(centipawns: Int) -> Double {
        1 / (1 + pow(10, -Double(centipawns) / 400))
    }

    /// Mate in N for White → 1.0; for Black → 0.0. A score of `mate 0` (the side to move is
    /// already mated) carries no direction, so it maps to the middle.
    public static func whiteShare(mateIn: Int) -> Double {
        if mateIn > 0 { return 1.0 }
        if mateIn < 0 { return 0.0 }
        return 0.5
    }

    /// A real minus sign (U+2212), not a hyphen: it lines up with the digits in tabular figures.
    public static let minusSign = "\u{2212}"

    /// The numeric score as shown beside the bar: "+0.4", "−1.2", "+0.0".
    public static func displayString(centipawns: Int) -> String {
        let pawns = Double(abs(centipawns)) / 100
        let magnitude = String(format: "%.1f", pawns)
        return (centipawns < 0 ? minusSign : "+") + magnitude
    }

    /// A mate score as shown beside the bar: "M3" for White, "−M2" for Black.
    public static func displayString(mateIn: Int) -> String {
        let moves = abs(mateIn)
        return (mateIn < 0 ? minusSign : "") + "M\(moves)"
    }
}
