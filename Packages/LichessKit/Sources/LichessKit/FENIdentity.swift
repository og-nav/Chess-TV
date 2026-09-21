// Two writers, one position.
//
// Lichess (scalachess) writes a FEN's en passant field only when an en passant capture is
// actually legal; ChessCore writes the target square after every double pawn push, as the FEN
// specification says to. So after 1.e4 Lichess sends `… b KQkq - 0 1` and ChessCore produces
// `… b KQkq e3 0 1` for the very same position. Any "is this JSON board the position the stream
// is on?" check that compares whole FEN strings is therefore false after most pawn moves, and
// everything downstream of it — clock anchoring, warm-cache reuse, result confirmation — goes
// wrong on ordinary games. Compare through here instead.

public enum FENIdentity {

    /// Placement, side to move and castling rights: the fields both writers spell the same way.
    public static func key(_ fen: String) -> String {
        fen.split(separator: " ").prefix(3).joined(separator: " ")
    }

    /// `true` when both FENs describe the same position, whatever they say about en passant
    /// and the move counters.
    public static func same(_ a: String, _ b: String) -> Bool {
        key(a) == key(b)
    }

    /// The number of plies played to reach the position, from the side-to-move and fullmove
    /// fields, or nil for a FEN without them. Lets two snapshots of one game be ordered without
    /// either writer's history.
    public static func ply(_ fen: String) -> Int? {
        let fields = fen.split(separator: " ")
        guard fields.count >= 6, let fullmove = Int(fields[5]), fullmove >= 1 else { return nil }
        return (fullmove - 1) * 2 + (fields[1] == "b" ? 1 : 0)
    }
}
