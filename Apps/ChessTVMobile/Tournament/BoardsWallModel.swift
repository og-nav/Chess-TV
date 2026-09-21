// One live connection updates every board while the round wall is in the foreground.
//
// SwiftUI cancels the active-scene task when the screen leaves the foreground. Returning
// fetches clock-corrected JSON and reconnects the shared round stream.
import Foundation
import ChessCore
import GameSessionKit
import LichessKit

@MainActor
@Observable
final class BoardsWallModel {

    let monitor: BroadcastRoundMonitor
    var state: LoadState<[BroadcastBoard]> {
        if monitor.hasLoaded { return .loaded(monitor.boards) }
        if let message = monitor.errorMessage { return .failed(message) }
        return .loading
    }
    var round: BroadcastTournament? { monitor.round }
    let roundId: String

    init(roundId: String, client: BroadcastClient = BroadcastClient()) {
        self.roundId = roundId
        self.monitor = BroadcastRoundMonitor(roundId: roundId, client: client)
    }

    var boards: [BroadcastBoard] { state.value ?? [] }

    /// Boards still being played, first — a viewer opening a finished round still sees results,
    /// but a live round never buries the live games under yesterday's.
    var orderedBoards: [NumberedBoard] { Self.liveFirst(boards) }

    struct NumberedBoard: Identifiable {
        let board: BroadcastBoard
        let number: Int
        var id: String { board.gameId }
    }

    /// Retain the source board number when a result moves a game below the live group.
    static func liveFirst(_ boards: [BroadcastBoard]) -> [NumberedBoard] {
        let numbered = boards.enumerated().map { NumberedBoard(board: $0.element, number: $0.offset + 1) }
        return numbered.filter { $0.board.isOngoing } + numbered.filter { !$0.board.isOngoing }
    }

    func run() async { await monitor.run() }
    func refresh() async { await monitor.refresh() }

    /// The destination for tapping a board, carrying everything the game screen would otherwise
    /// have to fetch again: the title, the federations and the FIDE ids behind the portraits.
    func destination(for board: BroadcastBoard, boardNumber: Int) -> GameDestination {
        GameDestination(
            source: .broadcastBoard(roundId: roundId, gameId: board.gameId),
            title: SourceTitle.board(
                tournament: round?.name ?? "",
                round: round?.roundName ?? "",
                boardNumber: boardNumber
            ),
            whiteFederation: board.white?.federation,
            blackFederation: board.black?.federation,
            whiteFideId: board.white?.fideId,
            blackFideId: board.black?.fideId,
            preview: GamePreview(board: board, receivedAt: monitor.clockAnchor(for: board.gameId),
                                 clocksRunning: monitor.canTick(board: board))
        )
    }
}

/// The clock text for one side of a wall cell, using its own streamed clock anchor.
///
/// Shares clock formatting with the game screen; disconnected or unanchored snapshots pause.
enum WallClock {
    static func text(
        for color: PieceColor,
        board: BroadcastBoard,
        receivedAt: ContinuousClock.Instant,
        now: ContinuousClock.Instant,
        isConnected: Bool = true
    ) -> String? {
        let reading = ClockReading(
            whiteSeconds: board.white?.clockSeconds,
            blackSeconds: board.black?.clockSeconds,
            receivedAt: receivedAt,
            sideToMove: sideToMove(of: board)
        )
        guard let seconds = ClockDisplay.remainingSeconds(
            for: color,
            clocks: reading,
            isLive: board.isOngoing && isConnected && (try? Position(fen: board.fen)) != nil,
            now: now
        ) else { return nil }
        return ClockDisplay.text(seconds)
    }

    /// Whose clock is running, from the board's FEN. A FEN that will not parse means nobody's,
    /// which is the safe answer: a frozen clock beats a wrong countdown.
    static func sideToMove(of board: BroadcastBoard) -> PieceColor {
        (try? Position(fen: board.fen))?.sideToMove ?? .white
    }
}
