// Is this move worth a push?
//
// Pure: two evaluations in, a verdict out. The engine, the queue and the policy all live
// elsewhere, so the one judgement the feature rests on is a table of test cases.
//
// The measure is Lichess's own: centipawns become "winning chances" in [-1, 1] through a logistic
// curve, and a move is judged by how much of the mover's chances it gave away. That is what makes
// +8 → +12 nothing and 0 → −2.5 a story without any hand-tuned bands, and it means a push here
// agrees with the label the same move gets in Lichess's analysis afterwards (inaccuracy 0.1,
// mistake 0.2, blunder 0.3).

import Foundation

/// An evaluation from White's point of view.
public enum EngineScore: Sendable, Equatable {
    /// Centipawns, positive for White.
    case centipawns(Int)
    /// Moves to mate, positive when White mates. `mate(0)` is a position that is already mate,
    /// and says nothing about who delivered it; `SwingClassifier` reads it off the side to move.
    case mate(Int)

    /// A UCI `score` is from the side to move's point of view; this turns it into White's.
    public static func fromUCI(centipawns: Int?, mate: Int?, whiteToMove: Bool) -> EngineScore? {
        let sign = whiteToMove ? 1 : -1
        // `mate 0` (the side to move is already mated) stays 0 either way round.
        if let mate { return .mate(mate * sign) }
        if let centipawns { return .centipawns(centipawns * sign) }
        return nil
    }

    /// `+0.4`, `−2.8`, `#3`, `#−2`: White's point of view, the way chess sites print it.
    public var display: String {
        switch self {
        case .centipawns(let cp):
            let pawns = Double(cp) / 100
            if abs(pawns) < 0.05 { return "0.0" }
            let text = String(format: "%.1f", abs(pawns))
            return (pawns > 0 ? "+" : "\u{2212}") + text
        case .mate(let moves):
            return moves < 0 ? "#\u{2212}\(abs(moves))" : "#\(moves)"
        }
    }
}

public struct EvalSwing: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// Gave away a large share of their chances.
        case blunder
        /// Was clearly winning and no longer is.
        case throwsWin
        /// The reply now forces mate against them.
        case allowsMate
        /// Had a forced mate and played something that is not one.
        case missesMate
    }

    public var kind: Kind
    public var before: EngineScore
    public var after: EngineScore
    /// How much of the mover's winning chances went, on Lichess's [-1, 1] scale, so 0.3 is a
    /// blunder and 2.0 is winning to lost.
    public var loss: Double
}

public struct SwingClassifier: Sendable {

    /// The chance a move must give away to be pushed. Lichess calls 0.3 a blunder.
    public var threshold: Double

    public init(threshold: Double = 0.3) {
        self.threshold = threshold
    }

    /// Lichess's curve (`WinPercent.scala`): 1000 cp is as good as won, and a mate is exactly won.
    static func winningChances(_ score: EngineScore, whiteToMove: Bool) -> Double {
        switch score {
        case .centipawns(let cp):
            let clamped = Double(min(max(cp, -1000), 1000))
            return 2 / (1 + exp(-0.00368208 * clamped)) - 1
        case .mate(let moves):
            if moves > 0 { return 1 }
            if moves < 0 { return -1 }
            // Already mate: the side to move is the one that has been mated.
            return whiteToMove ? -1 : 1
        }
    }

    /// Judges one move.
    ///
    /// - Parameters:
    ///   - before: the position the mover faced, from White's point of view.
    ///   - after: the position after their move, from White's point of view.
    ///   - whiteMoved: which side played the move.
    /// - Returns: nil for anything short of the threshold.
    public func classify(before: EngineScore, after: EngineScore, whiteMoved: Bool) -> EvalSwing? {
        let pov: Double = whiteMoved ? 1 : -1
        let chancesBefore = Self.winningChances(before, whiteToMove: whiteMoved) * pov
        let chancesAfter = Self.winningChances(after, whiteToMove: !whiteMoved) * pov
        let loss = chancesBefore - chancesAfter
        guard loss >= threshold else { return nil }

        let kind: EvalSwing.Kind
        if case .mate(let moves) = after, moves * Int(pov) < 0 {
            kind = .allowsMate
        } else if case .mate(let moves) = before, moves * Int(pov) > 0 {
            kind = .missesMate
        } else if chancesBefore >= 0.5, chancesAfter <= 0.2 {
            // 0.5 is about +3, 0.2 about +1: a won game became one that might not be.
            kind = .throwsWin
        } else {
            kind = .blunder
        }
        return EvalSwing(kind: kind, before: before, after: after, loss: loss)
    }
}
