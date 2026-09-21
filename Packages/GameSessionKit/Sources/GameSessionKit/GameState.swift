// The single object every view reads from.
import Foundation
import ChessCore
import LichessKit
import EngineKit

@Observable
@MainActor
public final class GameState {
    public init() {}

    /// Where these events come from.
    public var source: GameSource = .tvChannel(.best)
    /// Set once the stream ends because the game is over; the final position stays on screen.
    /// The string is the result when we could find it ("1-0"), nil when we only know it ended.
    public var finished: Finished?
    /// The feed's connection, owned by AppModel's subscription to TVFeedStream.
    public var connection: ConnectionState = .connecting

    /// The reduced board state. Mutating it through `apply` keeps observation on one property.
    public private(set) var reducer = GameReducer()
    /// The newest engine result that still matches the position on screen.
    public private(set) var evaluation: Evaluation?

    public var gameId: String? { reducer.gameId }
    public var revision: Int { reducer.revision }
    public var position: Position? { reducer.position }
    public var lastMove: LastMove? { reducer.lastMove }
    public var feedOrientation: PieceColor { reducer.orientation }
    public var white: PlayerInfo? { reducer.white }
    public var black: PlayerInfo? { reducer.black }
    public var clocks: ClockReading? { reducer.clocks }
    public var moveHistory: [MoveEntry] { reducer.moveHistory }
    public var moveRows: [GameReducer.Row] { reducer.rows }

    public var isLive: Bool { connection == .live && finished == nil }
    /// Historical PGN clocks are after-move readings, not a current-time anchor.
    public var hasReliableClocks = true
    public var clocksAreLive: Bool { isLive && hasReliableClocks }

    /// "Game over" plus the result when the source told us one.
    public struct Finished: Equatable, Sendable {
        public var result: String?
        public var text: String { result.map { "Game over \u{00B7} \($0)" } ?? "Game over" }

        /// The result a Lichess terminal status implies, or none for a game that was aborted
        /// or ended in a way the API did not spell out.
        public init(status: GameStatus) {
            switch status.winner {
            case .white: self.init(result: "1-0")
            case .black: self.init(result: "0-1")
            case nil: self.init(result: Self.drawStatuses.contains(status.name) ? "\u{00BD}-\u{00BD}" : nil)
            }
        }

        public init(result: String?) {
            self.result = result
        }

        /// Winnerless endings that are still a result. "aborted" and "noStart" are not here:
        /// those games produced none.
        private static let drawStatuses: Set<String> = ["draw", "stalemate"]
    }

    public func player(_ color: PieceColor) -> PlayerInfo? { color == .white ? white : black }

    /// Feeds one event through the reducer and drops an evaluation the move invalidated.
    @discardableResult
    public func apply(_ event: TVEvent, at instant: ContinuousClock.Instant = .now) -> MoveOutcome? {
        // A different game on the same feed: the previous one's result goes with it, or the
        // Game over chip would sit over the new board.
        if case .featured(let gameId, _, _, let fen) = event,
           gameId != reducer.gameId, (try? Position(fen: fen)) != nil { finished = nil }
        let outcome = reducer.apply(event, at: instant)
        if let evaluation, evaluation.positionFEN != reducer.position?.fen || evaluation.revision != reducer.revision {
            self.evaluation = nil
        }
        return outcome
    }

    func seed(_ preview: GamePreview, at now: ContinuousClock.Instant = .now) {
        reducer.seed(preview, at: now)
        if !preview.board.isOngoing { finished = Finished(result: preview.board.status) }
    }

    /// Publishes a privately reduced replay in one observed mutation, retaining every scrub ply.
    func replaceReducer(_ snapshot: GameReducer) {
        if snapshot.gameId != reducer.gameId { finished = nil }
        reducer = snapshot
        if let evaluation, evaluation.positionFEN != snapshot.position?.fen || evaluation.revision != snapshot.revision {
            self.evaluation = nil
        }
    }

    /// Stores an engine result only when it belongs to exactly the position on screen.
    /// - Returns: true when it was accepted.
    @discardableResult
    public func applyEvaluation(_ evaluation: Evaluation) -> Bool {
        guard evaluation.positionFEN == reducer.position?.fen, evaluation.revision == reducer.revision else {
            return false
        }
        self.evaluation = evaluation
        return true
    }

    /// New source, or leaving the game screen: forget the game, keep the connection state.
    public func clearGame() {
        reducer = GameReducer()
        evaluation = nil
        finished = nil
        hasReliableClocks = true
    }

    public func freezeClocks(at instant: ContinuousClock.Instant = .now) {
        if clocksAreLive { reducer.freezeClocks(at: instant) }
    }

    public func setConnection(_ state: ConnectionState, at instant: ContinuousClock.Instant = .now) {
        if state != .live { freezeClocks(at: instant) }
        else if connection != .live, hasReliableClocks { reducer.resumeClocks(at: instant) }
        connection = state
    }

    /// White's share of the eval bar, or nil when there is nothing to show.
    public var whiteShare: Double? {
        guard let evaluation else { return nil }
        switch evaluation.score {
        case .centipawns(let value): return EvalMappingBridge.whiteShare(centipawns: value)
        case .mate(let value): return EvalMappingBridge.whiteShare(mateIn: value)
        }
    }

    public var evaluationText: String? {
        guard let evaluation else { return nil }
        switch evaluation.score {
        case .centipawns(let value): return EvalMappingBridge.displayString(centipawns: value)
        case .mate(let value): return EvalMappingBridge.displayString(mateIn: value)
        }
    }
}
