// The pure part of the game pipeline: feed events in, board state out.
//
// Nothing here touches SwiftUI, UserDefaults, the network or the engine, so ChessTVTests can drive
// it straight from the NDJSON fixtures.
import Foundation
import ChessCore
import LichessKit

public struct GameReducer: Sendable {

    public private(set) var gameId: String?
    /// Incremented on every *accepted* event. Engine results carrying a different number are stale.
    public private(set) var revision: Int = 0
    public private(set) var position: Position?
    /// Position at the start of the available history, including a nonstandard PGN setup.
    public private(set) var initialPosition: Position?
    public private(set) var lastMove: LastMove?
    /// The color the feed wants at the bottom of the board.
    public private(set) var orientation: PieceColor = .white
    public private(set) var white: PlayerInfo?
    public private(set) var black: PlayerInfo?
    public private(set) var clocks: ClockReading?
    public private(set) var moveHistory: [MoveEntry] = []

    public init() {}

    /// Shows a known final position without inventing a move or partial scrub history.
    mutating func seed(_ preview: GamePreview, at now: ContinuousClock.Instant = .now) {
        let board = preview.board
        let reading = preview.clocks(at: now)
        let players = board.players.enumerated().map { index, player in
            TVPlayer(name: player.name, title: player.title, rating: player.rating,
                     color: index == 0 ? .white : .black,
                     secondsRemaining: index == 0 ? reading.whiteSeconds : reading.blackSeconds)
        }
        apply(.featured(gameId: board.gameId, orientation: .white, players: players, fen: board.fen), at: now)
        if let position { lastMove = board.lastMove.flatMap { LastMove(uci: $0, position: position) } }
    }

    /// Applies one feed event.
    ///
    /// An event whose FEN will not parse is dropped whole: the revision does not move and the
    /// last good board stays on screen.
    ///
    /// - Returns: the sound the move deserves, or nil when the event carried no move.
    @discardableResult
    public mutating func apply(_ event: TVEvent, at instant: ContinuousClock.Instant = .now) -> MoveOutcome? {
        switch event {
        case let .featured(gameId, orientation, players, fen):
            guard let newPosition = try? Position(fen: fen) else {
                appLog.error("Dropping featured event with unparseable FEN: \(fen, privacy: .public)")
                return nil
            }
            revision += 1
            self.gameId = gameId
            self.orientation = orientation
            self.position = newPosition
            self.initialPosition = newPosition
            self.lastMove = nil
            self.moveHistory = []
            let whitePlayer = players.first { $0.color == .white }
            let blackPlayer = players.first { $0.color == .black }
            self.white = whitePlayer.map(PlayerInfo.init)
            self.black = blackPlayer.map(PlayerInfo.init)
            self.clocks = ClockReading(
                whiteSeconds: whitePlayer?.secondsRemaining,
                blackSeconds: blackPlayer?.secondsRemaining,
                receivedAt: instant,
                sideToMove: newPosition.sideToMove
            )
            let acceptedRevision = revision
            appLog.debug("featured \(gameId, privacy: .public) rev \(acceptedRevision) fen \(newPosition.fen, privacy: .public)")
            return nil

        case let .fen(fen, lastMoveUCI, whiteClock, blackClock):
            guard let newPosition = try? Position(fen: fen) else {
                appLog.error("Dropping fen event with unparseable FEN: \(fen, privacy: .public)")
                return nil
            }
            let previous = position
            // Clock-only snapshots must not invalidate an evaluation or append/sound the
            // same move twice. They still refresh the received clock values below.
            if previous?.fen == newPosition.fen {
                clocks = ClockReading(
                    whiteSeconds: whiteClock ?? ClockDisplay.remainingSeconds(for: .white, clocks: clocks, isLive: true, now: instant),
                    blackSeconds: blackClock ?? ClockDisplay.remainingSeconds(for: .black, clocks: clocks, isLive: true, now: instant),
                    receivedAt: instant, sideToMove: newPosition.sideToMove
                )
                return nil
            }
            revision += 1
            position = newPosition
            let move = lastMoveUCI.flatMap { LastMove(uci: $0, position: newPosition) }
            lastMove = move
            if let lastMoveUCI, move != nil {
                // SAN is relative to what else was legal, so it needs the position *before* the
                // move. Without one — the first event of a stream we joined mid-game — the row
                // keeps the feed's own spelling.
                let san = previous.flatMap { SAN.notation(for: lastMoveUCI, in: $0) }
                append(uci: lastMoveUCI, san: san ?? lastMoveUCI, position: newPosition)
            }
            clocks = ClockReading(
                whiteSeconds: whiteClock ?? ClockDisplay.remainingSeconds(for: .white, clocks: clocks, isLive: true, now: instant),
                blackSeconds: blackClock ?? ClockDisplay.remainingSeconds(for: .black, clocks: clocks, isLive: true, now: instant),
                receivedAt: instant,
                sideToMove: newPosition.sideToMove
            )
            let acceptedRevision = revision
            appLog.debug("fen rev \(acceptedRevision) lm \(lastMoveUCI ?? "-", privacy: .public) fen \(newPosition.fen, privacy: .public)")
            guard move != nil else { return nil }
            if newPosition.isInCheck(newPosition.sideToMove) { return .check }
            if let previous, newPosition.pieceCount < previous.pieceCount { return .capture }
            return .move
        }
    }

    public mutating func freezeClocks(at instant: ContinuousClock.Instant = .now) {
        guard let reading = clocks else { return }
        clocks = ClockReading(
            whiteSeconds: ClockDisplay.remainingSeconds(for: .white, clocks: reading, isLive: true, now: instant),
            blackSeconds: ClockDisplay.remainingSeconds(for: .black, clocks: reading, isLive: true, now: instant),
            receivedAt: instant, sideToMove: reading.sideToMove
        )
    }

    /// The connection is back. The player's clock did not stop while we were offline, so the
    /// frozen reading is aged from the instant it was frozen: the same arithmetic as a freeze,
    /// which re-anchors at `instant`. The next `.fen` with clocks corrects any estimate.
    public mutating func resumeClocks(at instant: ContinuousClock.Instant = .now) {
        freezeClocks(at: instant)
    }

    /// The move list rows: the moving color and the full-move number come from the FEN that
    /// follows the move (after White plays, it is Black to move and the number has not advanced).
    private mutating func append(uci: String, san: String, position: Position) {
        let mover = position.sideToMove.opposite
        let number = mover == .white ? position.fullmoveNumber : max(1, position.fullmoveNumber - 1)
        // The whole game is kept: every source now replays its history on join, and a
        // classical game is a few hundred entries at most. The side panel shows the tail.
        moveHistory.append(MoveEntry(uci: uci, san: san, fen: position.fen, moveNumber: number, color: mover))
    }

    /// One row of the side panel's move list.
    public struct Row: Equatable, Sendable {
        public let number: Int
        public let white: MoveEntry?
        public let black: MoveEntry?
    }

    /// `moveHistory` folded into numbered rows, oldest first.
    public var rows: [Row] {
        var rows: [Row] = []
        for entry in moveHistory {
            if entry.color == .white {
                rows.append(Row(number: entry.moveNumber, white: entry, black: nil))
            } else if let last = rows.last, last.number == entry.moveNumber, last.black == nil {
                rows[rows.count - 1] = Row(number: last.number, white: last.white, black: entry)
            } else {
                rows.append(Row(number: entry.moveNumber, white: nil, black: entry))
            }
        }
        return rows
    }
}
