import Foundation
import Testing
import ChessCore
import LichessKit
@testable import ChessTVMobile

private final class WatchTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: Double) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(seconds) }
}

private final class WatchTestStream: WatchDetailStreaming, @unchecked Sendable {
    let connectionStates: AsyncStream<ConnectionState>
    let states: AsyncStream<ConnectionState>.Continuation
    let feed: AsyncThrowingStream<SourcedEvent, Error>
    let events: AsyncThrowingStream<SourcedEvent, Error>.Continuation
    private let lock = NSLock()
    private var calls = 0
    private var finishes = 0
    init() {
        (connectionStates, states) = AsyncStream.makeStream()
        (feed, events) = AsyncThrowingStream.makeStream()
    }
    var startCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var finishCount: Int { lock.lock(); defer { lock.unlock() }; return finishes }
    func sourcedEvents(roundId: String, gameId: String) -> AsyncThrowingStream<SourcedEvent, Error> {
        lock.lock(); defer { lock.unlock() }; calls += 1; return feed
    }
    func result(forGameId gameId: String) -> BroadcastPGNStream.Termination? { nil }
    func finish() { lock.lock(); finishes += 1; lock.unlock(); states.finish(); events.finish() }
}

@Suite("Watch foreground game detail") @MainActor
struct WatchGameDetailTests {
    private func board(_ fen: String, white: Int = 48_000, black: Int = 100_000) -> BroadcastBoard {
        BroadcastBoard(gameId: "game", name: "White - Black", fen: fen, lastMove: nil, status: "*", players: [
            BroadcastPlayer(name: "White", title: nil, rating: nil, federation: nil, clockMs: white),
            BroadcastPlayer(name: "Black", title: nil, rating: nil, federation: nil, clockMs: black)
        ])
    }
    private func row(_ board: BroadcastBoard, _ date: Date) -> WatchBoardRow {
        WatchBoardRow(id: "game", followId: "follow", title: "Game", subtitle: nil, roundId: "round",
                      roundName: nil, tourName: nil, board: board, asOf: date)
    }
    private func waitFor(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(predicate())
    }
    private func replay(_ text: String) throws -> [(san: String, uci: String, fen: String)] {
        try #require(PGN.parseGame(text)).replay()
    }
    private func feature() -> SourcedEvent {
        SourcedEvent(event: .featured(gameId: "game", orientation: .white, players: [], fen: Position.standard.fen),
                     isHistorical: true, historyComplete: false)
    }
    private func move(_ ply: (san: String, uci: String, fen: String), historical: Bool, complete: Bool = false) -> SourcedEvent {
        SourcedEvent(event: .fen(fen: ply.fen, lastMove: ply.uci, whiteClock: 60, blackClock: 100),
                     isHistorical: historical, historyComplete: complete)
    }

    @Test func reducerUsesBeforePositionForCastlesCapturesAndMate() throws {
        for pgn in ["1. e4 e5 2. Nf3 Nc6 3. Bc4 Nf6 4. O-O Nxe4 *", "1. e4 e5 2. Bc4 Nc6 3. Qh5 Nf6 4. Qxf7# 1-0"] {
            var reducer = WatchPGNReducer()
            reducer.apply(feature().event)
            for ply in try replay(pgn) {
                reducer.apply(move(ply, historical: true).event)
                #expect(reducer.san == ply.san)
            }
        }
    }

    @Test func historyPublishesAtomicallyAndKeepsCurrentRoundClockThroughConnecting() async throws {
        let plies = try replay("1. e4 e5 *")
        let clock = WatchTestClock(), source = WatchTestStream()
        let current = board(try #require(plies.last).fen)
        let model = WatchGameDetailModel(row: row(current, clock.now()), now: { clock.now() },
                                        streamFactory: { source }, loadBoard: { _, _ in current })
        model.start(); model.start()
        try await waitFor { source.startCount == 1 }
        source.states.yield(.connecting)
        try await waitFor { model.row.isStale }
        source.states.yield(.live)
        try await Task.sleep(for: .milliseconds(20))
        clock.advance(9)
        source.events.yield(feature())
        source.events.yield(move(plies[0], historical: true))
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.row.board?.fen == current.fen)
        #expect(model.row.san == nil)
        source.events.yield(move(plies[1], historical: true, complete: true))
        try await waitFor { model.row.san == "e5" }
        #expect(model.row.board?.white?.clockSeconds == 48)
        #expect(model.row.asOf == Date(timeIntervalSince1970: 1000))
        #expect(model.row.clockRunningFor == "white")
        #expect(!model.row.isStale)
        source.states.yield(.reconnecting(attempt: 1, nextRetryIn: .seconds(1)))
        try await waitFor { model.row.isStale }
        #expect(model.row.board?.white?.clockSeconds == 39)
        clock.advance(200)
        #expect(model.row.board?.white?.clockSeconds == 39)
        #expect(model.row.clockRunningFor == nil)
        model.stop()
        #expect(source.finishCount == 1)
    }

    @Test func historicalClockWithoutFreshAnchorStaysFrozen() async throws {
        let plies = try replay("1. e4 e5 *")
        let clock = WatchTestClock(), source = WatchTestStream()
        let model = WatchGameDetailModel(row: row(board(Position.standard.fen), clock.now()), now: { clock.now() },
                                        streamFactory: { source }, loadBoard: { _, _ in throw URLError(.notConnectedToInternet) })
        model.start()
        try await waitFor { source.startCount == 1 }
        source.states.yield(.live)
        try await Task.sleep(for: .milliseconds(20))
        source.events.yield(feature())
        for (index, ply) in plies.enumerated() { source.events.yield(move(ply, historical: true, complete: index == plies.count - 1)) }
        try await waitFor { model.row.san == "e5" }
        #expect(model.row.isStale)
        #expect(model.row.clockRunningFor == nil)
        #expect(model.row.board?.white?.clockSeconds == 60)
        model.stop()
    }

    @Test func liveMoveAndFreshSeedKeepSANButRejectOlderPosition() async throws {
        let plies = try replay("1. e4 e5 2. Nf3 *")
        let clock = WatchTestClock(), source = WatchTestStream()
        let current = board(plies[1].fen)
        let model = WatchGameDetailModel(row: row(current, clock.now()), now: { clock.now() },
                                        streamFactory: { source }, loadBoard: { _, _ in current })
        model.start()
        try await waitFor { source.startCount == 1 }
        source.states.yield(.live)
        try await Task.sleep(for: .milliseconds(20))
        source.events.yield(feature())
        source.events.yield(move(plies[0], historical: true))
        source.events.yield(move(plies[1], historical: true, complete: true))
        try await waitFor { model.row.san == "e5" }
        clock.advance(1)
        source.events.yield(move(plies[2], historical: false))
        try await waitFor { model.row.san == "Nf3" }
        clock.advance(1)
        model.updateSeed(row(board(plies[1].fen), clock.now()))
        #expect(model.row.board?.fen == plies[2].fen)
        model.updateSeed(row(board(plies[2].fen, white: 59_000, black: 97_000), clock.now()))
        #expect(model.row.san == "Nf3")
        #expect(model.row.clockRunningFor == "black")
        #expect(model.row.board?.black?.clockSeconds == 97)
        model.stop()
        clock.advance(1)
        model.updateSeed(row(board(plies[2].fen), clock.now()))
        #expect(model.row.isStale)
        #expect(model.row.clockRunningFor == nil)
    }
}
