// One PGN block → one `GameSnapshot`.
//
// This is the only place the server parses chess, and it does it with ChessCore — the same parser
// and the same replay the TV app uses, so a position the phone draws and a position the server
// puts in a push cannot drift apart.

import ChessCore
import Foundation
import FollowKit

public enum PGNSnapshot {

    /// Builds a snapshot from a broadcast PGN block.
    ///
    /// A block whose movetext contains a move that is not legal is **not** thrown away: ChessCore
    /// hands back the prefix that did replay, and the snapshot is built from that. A broadcast
    /// operator typing the wrong move should cost one stale ply, not a game that stops updating.
    ///
    /// - Parameters:
    ///   - block: the PGN of one game.
    ///   - roundId: the round it came from; a broadcast block names its round only in a URL.
    ///   - context: the round JSON, for the federation flags and the FIDE ids that a PGN's tags
    ///     do not always carry.
    /// - Returns: nil when the block has no game id, which means it is not a broadcast block.
    public static func snapshot(block: String, roundId: String, context: RoundContext? = nil) -> GameSnapshot? {
        guard let game = PGN.parseGame(block), let gameId = game.gameId else { return nil }
        return snapshot(game: game, gameId: gameId, roundId: roundId, context: context)
    }

    static func snapshot(game: PGNGame, gameId: String, roundId: String, context: RoundContext?) -> GameSnapshot {
        let steps: [(san: String, uci: String, fen: String)]
        do {
            steps = try game.replay(from: game.initialPosition)
        } catch let error as PGNReplayError {
            steps = error.replayed
        } catch {
            steps = []
        }

        let last = steps.last
        let players = context?.boardPlayers[gameId]

        // `%clk` is the mover's clock *after* their move. Who the mover is at an even index is not
        // always White: a broadcast of an adjourned game, a Chess960 study, or any `[FEN]` setup
        // with Black to move starts its movetext on Black, and reading the parity off the index
        // alone would then swap both clocks for the whole game.
        let first = game.initialPosition.sideToMove
        var whiteClock: Int?
        var blackClock: Int?
        for (index, move) in game.moves.enumerated() where index < steps.count {
            guard let seconds = move.clockSeconds else { continue }
            let mover = index % 2 == 0 ? first : first.opposite
            if mover == .white { whiteClock = seconds } else { blackClock = seconds }
        }

        func player(_ name: String?, title: String?, elo: Int?, broadcast: BroadcastPlayer?) -> PushPlayer {
            PushPlayer(
                name: broadcast?.name ?? name ?? "",
                title: title ?? broadcast?.title,
                rating: elo ?? broadcast?.rating,
                fed: broadcast?.federation
            )
        }

        return GameSnapshot(
            roundId: roundId,
            gameId: gameId,
            ply: steps.count,
            fen: last?.fen ?? game.initialPosition.fen,
            previousFen: steps.isEmpty ? nil : (steps.count >= 2 ? steps[steps.count - 2].fen : game.initialPosition.fen),
            lastMove: last?.uci,
            san: last?.san,
            whiteClock: whiteClock ?? players?.white.clock,
            blackClock: blackClock ?? players?.black.clock,
            status: BroadcastDecoder.normalizeResult(game.outcome),
            white: player(game.white, title: game.whiteTitle, elo: game.whiteElo, broadcast: players?.white),
            black: player(game.black, title: game.blackTitle, elo: game.blackElo, broadcast: players?.black),
            // The PGN's own `WhiteFideId` tag when there is one; the round JSON otherwise, which
            // is where a tier-5 event reliably has them.
            whiteFideId: fideId(game["WhiteFideId"]) ?? players?.white.fideId,
            blackFideId: fideId(game["BlackFideId"]) ?? players?.black.fideId
        )
    }

    private static func fideId(_ text: String?) -> Int? {
        guard let text, let value = Int(text), value > 0 else { return nil }
        return value
    }
}
