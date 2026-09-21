// Moving up and down a game's history.
//
// `GameSession.viewedPly` is the state: nil is live, 0 is the position before the first move,
// and 1…moveHistory.count is "after that ply". Everything that turns a tap, a swipe or a
// keyboard arrow into one of those numbers is here, pure, so the arithmetic is tested rather
// than eyeballed on a board that is also moving.
import Foundation
import ChessCore
import GameSessionKit

enum ScrubTimeline {

    /// The ply for a row in `moveHistory`.
    static func ply(forHistoryIndex index: Int) -> Int { index + 1 }

    /// The `moveHistory` index a ply refers to, or nil for ply 0 (the initial position).
    static func historyIndex(forPly ply: Int) -> Int? { ply >= 1 ? ply - 1 : nil }

    static func clamped(_ ply: Int, total: Int) -> Int { min(max(ply, 0), total) }

    /// One ply back. From live, that is the ply before the last one played, because live already
    /// shows the last one.
    static func previous(_ viewed: Int?, total: Int) -> Int? {
        guard total > 0 else { return nil }
        let current = viewed ?? total
        return current <= 0 ? 0 : clamped(current - 1, total: total)
    }

    /// One ply forward. Stepping past the last ply returns nil, which is live — the board then
    /// follows the game again instead of freezing on the newest move.
    static func next(_ viewed: Int?, total: Int) -> Int? {
        guard let viewed, total > 0 else { return nil }
        let candidate = viewed + 1
        return candidate >= total ? nil : clamped(candidate, total: total)
    }

    /// The FEN a ply shows, given the history and the position the game started from.
    ///
    /// `MoveEntry.fen` is the position *after* its move, so ply n is `history[n - 1].fen` and
    /// ply 0 is the starting position. A ply past the end is nil rather than the last move,
    /// so a caller that got its arithmetic wrong sees nothing instead of the wrong board.
    static func fen(atPly ply: Int, history: [MoveEntry], initialFEN: String) -> String? {
        guard ply >= 0, ply <= history.count else { return nil }
        guard let index = historyIndex(forPly: ply) else { return initialFEN }
        return history[index].fen
    }

    /// The label on the scrub bar: "Live" or "23… Nf5".
    static func label(viewed: Int?, history: [MoveEntry]) -> String {
        guard let viewed else { return "Live" }
        guard let index = historyIndex(forPly: viewed), index < history.count else { return "Start" }
        let entry = history[index]
        let separator = entry.color == .white ? "." : "\u{2026}"
        return "\(entry.moveNumber)\(separator) \(entry.san)"
    }

    /// True when the board is showing the live position.
    static func isLive(_ viewed: Int?, total: Int) -> Bool { viewed == nil || viewed == total }

    /// How far through the game the scrubber sits, for the slider and for VoiceOver.
    static func progress(viewed: Int?, total: Int) -> Double {
        guard total > 0 else { return 1 }
        return Double(viewed ?? total) / Double(total)
    }
}

/// One numbered line of the move list, with the ply behind each half so a tap scrubs to exactly
/// the move that was tapped.
///
/// `GameReducer.Row` pairs the entries but does not carry their position in `moveHistory`, and
/// working it back out from the move number is wrong for a stream joined mid-game — the first
/// entry there is not ply 1. So the rows are folded here, from the indices themselves.
struct NumberedMoveRow: Identifiable, Equatable, Sendable {
    /// The index of this row, which is all `ForEach` needs and is stable as moves arrive.
    let id: Int
    let number: Int
    let white: PliedMove?
    let black: PliedMove?
}

struct PliedMove: Equatable, Sendable {
    let ply: Int
    let entry: MoveEntry
}

extension NumberedMoveRow {
    /// Folds `moveHistory` into numbered rows, oldest first, keeping each entry's ply.
    ///
    /// A game joined at Black's move starts with a row whose White half is empty, exactly as
    /// `GameReducer.rows` does.
    static func rows(from history: [MoveEntry]) -> [NumberedMoveRow] {
        var rows: [NumberedMoveRow] = []
        for (index, entry) in history.enumerated() {
            let move = PliedMove(ply: ScrubTimeline.ply(forHistoryIndex: index), entry: entry)
            if entry.color == .white {
                rows.append(NumberedMoveRow(id: rows.count, number: entry.moveNumber, white: move, black: nil))
            } else if let last = rows.last, last.number == entry.moveNumber, last.black == nil {
                rows[rows.count - 1] = NumberedMoveRow(id: last.id, number: last.number, white: last.white, black: move)
            } else {
                rows.append(NumberedMoveRow(id: rows.count, number: entry.moveNumber, white: nil, black: move))
            }
        }
        return rows
    }
}
