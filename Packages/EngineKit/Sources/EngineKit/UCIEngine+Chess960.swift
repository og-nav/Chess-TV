// Chess960 support. Lichess' chess960 TV channel sends ordinary FENs with
// shuffled back ranks; Stockfish only needs to be told how to read castling
// rights and how to spell castling moves in the principal variation.

import Foundation

extension UCIEngine {
    /// Sends `setoption name UCI_Chess960 value <flag>`.
    ///
    /// UCI options may only be changed while the engine is idle, so any running
    /// search is stopped first.
    public func setChess960(_ enabled: Bool) async {
        await stop()
        guard !isShutDown else { return }
        channel.send("setoption name UCI_Chess960 value \(enabled)")
        channel.send("isready")
    }
}
