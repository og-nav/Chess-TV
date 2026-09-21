// Stockfish's principal variation, in the notation the move list uses.
//
// The engine reports UCI ("g1f3 b8c6"), which is unreadable beside a move list in SAN. ChessCore
// already knows how to turn one into the other given the position before the move, so the line
// is replayed move by move. A move the position rejects ends the line there rather than printing
// nonsense: a PV that outran a position change is better truncated than wrong.
import Foundation
import ChessCore

enum PrincipalVariation {

    /// How many plies of the line are worth showing on a phone.
    static let displayLimit = 6

    /// "23. Nf5 Qe7 24. Rd1" — numbered from the position's own move number, with the ellipsis
    /// form when Black is to move first.
    static func text(_ uciMoves: [String], from position: Position?, limit: Int = displayLimit) -> String {
        guard let position, !uciMoves.isEmpty else { return "" }
        var current = position
        var parts: [String] = []
        for uci in uciMoves.prefix(limit) {
            guard let move = SAN.move(forUCI: uci, in: current),
                  let san = SAN.notation(for: move, in: current) else { break }
            if current.sideToMove == .white {
                parts.append("\(current.fullmoveNumber). \(san)")
            } else if parts.isEmpty {
                parts.append("\(current.fullmoveNumber)\u{2026} \(san)")
            } else {
                parts.append(san)
            }
            current = current.making(move)
        }
        return parts.joined(separator: " ")
    }
}
