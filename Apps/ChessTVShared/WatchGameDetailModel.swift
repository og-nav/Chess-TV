import Foundation
import Observation
import ChessCore
import LichessKit

/// Value route/seed shared by the Watch list and its independently refreshed detail screen.
struct WatchBoardRow: Identifiable, Hashable, Sendable {
    var id: String
    var followId: String
    var title: String
    var subtitle: String?
    var roundId: String?
    var roundName: String?
    var tourName: String?
    var board: BroadcastBoard?
    var asOf: Date
    var san: String? = nil
    var clockRunningFor: String? = nil
    var isStale: Bool = false
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.board == rhs.board && lhs.asOf == rhs.asOf && lhs.san == rhs.san
            && lhs.clockRunningFor == rhs.clockRunningFor && lhs.isStale == rhs.isStale
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

protocol WatchDetailStreaming: Sendable {
    var connectionStates: AsyncStream<ConnectionState> { get }
    func sourcedEvents(roundId: String, gameId: String) -> AsyncThrowingStream<SourcedEvent, Error>
    func result(forGameId gameId: String) -> BroadcastPGNStream.Termination?
    func finish()
}
extension BroadcastPGNStream: WatchDetailStreaming {}

/// Reduces PGN replay privately; SAN always uses the position before the move.
struct WatchPGNReducer {
    var position: Position?
    var lastMove: String?
    var san: String?
    var whiteClock: Int?
    var blackClock: Int?
    mutating func apply(_ event: TVEvent) {
        switch event {
        case .featured(_, _, let players, let fen):
            guard let parsed = try? Position(fen: fen) else { return }
            position = parsed
            lastMove = nil
            san = nil
            whiteClock = players.first { $0.color == .white }?.secondsRemaining
            blackClock = players.first { $0.color == .black }?.secondsRemaining
        case .fen(let fen, let uci, let white, let black):
            guard let parsed = try? Position(fen: fen) else { return }
            if position?.fen != parsed.fen {
                san = uci.flatMap { move in position.flatMap { SAN.notation(for: move, in: $0) } }
                lastMove = uci
            }
            position = parsed
            whiteClock = white ?? whiteClock
            blackClock = black ?? blackClock
        }
    }
}

/// A single foreground-only PGN stream for the open Watch board. List snapshots seed the view;
/// the detail owns its refresh and does not depend on a NavigationLink's captured value changing.
@MainActor @Observable
final class WatchGameDetailModel {
    private(set) var row: WatchBoardRow
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var stream: (any WatchDetailStreaming)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var connectionLive = false
    @ObservationIgnored private var hasStreamPosition = false
    @ObservationIgnored private var clockAnchor: (board: BroadcastBoard, asOf: Date)?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let streamFactory: @MainActor () -> any WatchDetailStreaming
    @ObservationIgnored private let loadBoard: @Sendable (String, String) async throws -> BroadcastBoard?

    init(row: WatchBoardRow,
         now: @escaping @Sendable () -> Date = { Date() },
         streamFactory: @escaping @MainActor () -> any WatchDetailStreaming = { BroadcastPGNStream() },
         loadBoard: @escaping @Sendable (String, String) async throws -> BroadcastBoard? = { round, game in
             try await BroadcastClient().round(id: round).boards.first { $0.gameId == game }
         }) {
        self.row = row
        self.now = now
        self.streamFactory = streamFactory
        self.loadBoard = loadBoard
        // A route may have been captured minutes earlier. It is a snapshot until this screen
        // confirms freshness, not a timer that should run offline to a fabricated zero.
        self.row.isStale = true
        self.row.clockRunningFor = nil
    }

    func updateSeed(_ seed: WatchBoardRow) {
        guard seed.board?.gameId == row.board?.gameId, seed.asOf > row.asOf else { return }
        // A later list response can still describe an older position. Once PGN is flowing,
        // only a matching position can refresh its clock anchor; moves belong to the stream.
        guard !hasStreamPosition || seed.board?.fen == row.board?.fen else { return }
        var updated = seed
        if seed.board?.fen == row.board?.fen, updated.san == nil { updated.san = row.san }
        if task == nil { updated.isStale = true; updated.clockRunningFor = nil }
        else if !updated.isStale, let board = updated.board {
            clockAnchor = (board, updated.asOf)
            updated.clockRunningFor = Self.runningSide(board)
        }
        row = updated
    }

    func start() {
        guard task == nil, let round = row.roundId, let game = row.board?.gameId else { return }
        generation += 1
        let mine = generation
        hasStreamPosition = false
        clockAnchor = nil
        connectionLive = false
        let source = streamFactory()
        stream = source
        let states = source.connectionStates
        stateTask = Task { [weak self] in
            for await state in states {
                guard let self, !Task.isCancelled, self.generation == mine else { return }
                self.connectionLive = state == .live
                if state != .live { self.freeze() }
                else if self.hasStreamPosition { await self.refreshRound(round, game, generation: mine) }
            }
        }
        task = Task { [weak self] in
            guard let self else { return }
            await self.refreshRound(round, game, generation: mine)
            guard !Task.isCancelled, self.generation == mine else { return }
            if let board = self.row.board {
                BroadcastReplayWarmup.retainMatching(roundId: round, gameId: game, fen: board.fen)
            }
            var reducer = WatchPGNReducer()
            do {
                for try await event in source.sourcedEvents(roundId: round, gameId: game) {
                    guard !Task.isCancelled, self.generation == mine else { return }
                    reducer.apply(event.event)
                    if !event.isHistorical || event.historyComplete == true {
                        self.publish(reducer, historical: event.isHistorical)
                    }
                }
                guard !Task.isCancelled, self.generation == mine else { return }
                if let result = source.result(forGameId: game) {
                    self.freeze()
                    if let board = self.row.board {
                        self.row.board = Self.board(board, status: result.result)
                        self.row.isStale = false
                    }
                } else { self.freeze() }
            } catch {
                guard !Task.isCancelled, self.generation == mine else { return }
                self.freeze()
            }
            self.stateTask?.cancel()
            source.finish()
            self.task = nil
        }
    }

    func stop() {
        generation += 1
        task?.cancel()
        task = nil
        stateTask?.cancel()
        stateTask = nil
        stream?.finish()
        stream = nil
        connectionLive = false
        freeze()
    }

    private func refreshRound(_ round: String, _ game: String, generation mine: Int) async {
        let started = now()
        do {
            guard let board = try await loadBoard(round, game), !Task.isCancelled, generation == mine else { return }
            guard row.asOf <= started else { return } // A streamed move already superseded this request.
            let samePosition = row.board?.fen == board.fen
            row.board = board
            row.asOf = now()
            clockAnchor = (board, row.asOf)
            row.isStale = false
            row.clockRunningFor = Self.runningSide(board)
            if !samePosition { row.san = nil }
        } catch {
            if generation == mine, !Task.isCancelled { freeze() }
        }
    }

    private func publish(_ reducer: WatchPGNReducer, historical: Bool) {
        guard let position = reducer.position, let previous = row.board else { return }
        let timestamp = now()
        // On join, a round snapshot includes thinkTime and is more current than PGN's clocks
        // after the last move. Preserve that anchor when both describe the same position.
        let keepClockAnchor = historical && clockAnchor?.board.fen == position.fen
        let players = previous.players.enumerated().map { index, player in
            let seconds = index == 0 ? reducer.whiteClock : reducer.blackClock
            return BroadcastPlayer(name: player.name, title: player.title, rating: player.rating,
                federation: player.federation, clockMs: keepClockAnchor ? clockAnchor?.board.players[safe: index]?.clockMs : seconds.map { max(0, $0) * 1000 }, fideId: player.fideId)
        }
        row.board = BroadcastBoard(gameId: previous.gameId, name: previous.name, fen: position.fen,
            lastMove: reducer.lastMove, status: previous.status, players: players)
        row.san = reducer.san
        row.asOf = keepClockAnchor ? clockAnchor!.asOf : timestamp
        row.isStale = !connectionLive || (historical && !keepClockAnchor)
        row.clockRunningFor = !row.isStale ? Self.runningSide(row.board!) : nil
        hasStreamPosition = true
    }

    private func freeze() {
        let timestamp = now()
        if !row.isStale, let board = row.board, let running = row.clockRunningFor {
            let elapsed = max(0, timestamp.timeIntervalSince(row.asOf))
            let players = board.players.enumerated().map { index, player in
                let active = (index == 0 && running == "white") || (index == 1 && running == "black")
                let remaining = player.clockMs.map { max(0, $0 - (active ? Int(min(elapsed, Double(Int.max / 1000))) * 1000 : 0)) }
                return BroadcastPlayer(name: player.name, title: player.title, rating: player.rating,
                    federation: player.federation, clockMs: remaining, fideId: player.fideId)
            }
            row.board = Self.board(board, players: players)
            row.asOf = timestamp
        }
        row.isStale = row.board?.isOngoing ?? true
        row.clockRunningFor = nil
    }

    private static func runningSide(_ board: BroadcastBoard) -> String? {
        guard board.isOngoing, let position = try? Position(fen: board.fen) else { return nil }
        return position.sideToMove == .white ? "white" : "black"
    }
    private static func board(_ board: BroadcastBoard, status: String? = nil, players: [BroadcastPlayer]? = nil) -> BroadcastBoard {
        BroadcastBoard(gameId: board.gameId, name: board.name, fen: board.fen, lastMove: board.lastMove,
                       status: status ?? board.status, players: players ?? board.players)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
