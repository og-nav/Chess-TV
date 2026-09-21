// Parsing of the two UCI lines EngineKit cares about, plus the side-to-move
// field of a FEN. Kept free of state so it can be unit tested on its own.

import Foundation

enum UCIParser {

    /// The side to move of a FEN, or `nil` if the FEN has no second field.
    /// `true` means Black, i.e. scores must be negated for White's perspective.
    static func blackToMove(fen: String) -> Bool? {
        let fields = fen.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2 else { return nil }
        switch fields[1] {
        case "b", "B": return true
        case "w", "W": return false
        default: return nil
        }
    }

    /// Turns an `info` line into an `Evaluation`, or returns `nil` when the line
    /// carries no usable score.
    ///
    /// Lines for a MultiPV index other than 1 are ignored, as are `lowerbound` /
    /// `upperbound` scores: those are aspiration-window artefacts and make the
    /// eval bar jump by several pawns for a frame.
    static func evaluation(from line: String,
                           fen: String,
                           revision: Int,
                           negate: Bool) -> Evaluation? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count > 1, tokens[0] == "info" else { return nil }

        var depth: Int?
        var score: Evaluation.Score?
        var pv: [String] = []
        var index = 1

        while index < tokens.count {
            switch tokens[index] {
            case "depth":
                if index + 1 < tokens.count { depth = Int(tokens[index + 1]) }
                index += 2

            case "multipv":
                if index + 1 < tokens.count, tokens[index + 1] != "1" { return nil }
                index += 2

            case "lowerbound", "upperbound":
                return nil

            case "score":
                guard index + 2 < tokens.count, let value = Int(tokens[index + 2]) else {
                    return nil
                }
                switch tokens[index + 1] {
                case "cp":
                    score = .centipawns(negate ? -value : value)
                case "mate":
                    score = .mate(negate ? -value : value)
                default:
                    return nil
                }
                index += 3

            case "pv":
                pv = Array(tokens[(index + 1)...])
                index = tokens.count

            case "string":
                return nil  // `info string ...` is free-form text

            default:
                index += 1
            }
        }

        guard let depth, let score else { return nil }
        return Evaluation(score: score,
                          depth: depth,
                          principalVariation: pv,
                          positionFEN: fen,
                          revision: revision)
    }
}
