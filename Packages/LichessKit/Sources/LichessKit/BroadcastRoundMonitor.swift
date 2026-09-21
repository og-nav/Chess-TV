import Foundation
import Observation
import ChessCore

/// Foreground round wall: one PGN connection for every board, plus JSON reconciliation for
/// metadata and clock anchors when joining/rejoining between moves.
@MainActor @Observable
public final class BroadcastRoundMonitor {
    public let roundId: String
    public private(set) var round: BroadcastTournament?
    public private(set) var boards: [BroadcastBoard] = []
    public private(set) var isConnected = false
    public private(set) var hasLoaded = false
    public private(set) var errorMessage: String?
    private var anchors: [String: ContinuousClock.Instant] = [:]
    private var timedBoards: Set<String> = []
    private var revisions: [String: UInt64] = [:]
    private var streamedBoards: Set<String> = []
    @ObservationIgnored private var refreshRequest: UInt64 = 0
    private(set) var revision: UInt64 = 0
    private var frozenAt: ContinuousClock.Instant = .now
    @ObservationIgnored private let client: BroadcastClient
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var reconciliation: Task<Void, Never>?
    @ObservationIgnored private var activeStream: BroadcastRoundStream?

    public init(roundId: String, client: BroadcastClient = BroadcastClient()) {
        self.roundId = roundId; self.client = client
    }
    public var clockNow: ContinuousClock.Instant { isConnected ? .now : frozenAt }
    public func clockAnchor(for gameId: String) -> ContinuousClock.Instant { anchors[gameId] ?? frozenAt }
    public func canTick(board: BroadcastBoard) -> Bool {
        isConnected && timedBoards.contains(board.gameId) && board.isOngoing && (try? Position(fen: board.fen)) != nil
    }

    public func run() async {
        activeStream?.finish()
        reconciliation?.cancel(); reconciliation = nil
        connectionChanged(.connecting, now: .now)
        let token = UUID(); generation = token
        streamedBoards.removeAll()
        let stream = BroadcastRoundStream()
        activeStream = stream
        defer {
            stream.finish()
            if generation == token {
                activeStream = nil
                reconciliation?.cancel(); reconciliation = nil
                connectionChanged(.connecting, now: .now)
            }
        }
        // Load clock-corrected JSON before accepting the historical stream batch.
        await refresh()
        guard !Task.isCancelled, generation == token else { return }
        let states = stream.connectionStates
        let stateTask = Task { [weak self] in
            for await state in states {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.connectionChanged(state, now: .now)
                if state == .live { self.scheduleRefresh(token: token) }
            }
        }
        let repairTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, self.generation == token else { return }
                await self.refresh()
            }
        }
        defer { stateTask.cancel(); repairTask.cancel() }
        await withTaskCancellationHandler {
            do {
                for try await update in stream.updates(roundId: roundId) {
                    guard !Task.isCancelled, generation == token else { return }
                    accept(update, now: .now)
                    if !timedBoards.contains(update.board.gameId) { scheduleRefresh(token: token) }
                }
            } catch {
                // The stream gave up for good (a 404 or 410 on the round, say). The wall is still
                // worth showing, so fall back to the 30-second JSON refresh that is already
                // running rather than returning — which would cancel it and leave a frozen wall
                // under a "retrying" message that nothing ever acts on.
                guard !Task.isCancelled, generation == token else { return }
                errorMessage = "Live updates unavailable · refreshing every 30 s"
                connectionChanged(.connecting, now: .now)
                streamedBoards.removeAll()
                while !Task.isCancelled, generation == token {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                }
            }
        } onCancel: { stream.finish() }
    }

    private func scheduleRefresh(token: UUID) {
        guard reconciliation == nil else { return }
        reconciliation = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, self.generation == token else { return }
            await self.refresh()
            // An initial block may have arrived while the first JSON request was in flight.
            // Its revision correctly rejects that response; give it one fresh anchor request.
            if self.generation == token, self.boards.contains(where: { $0.isOngoing && !self.timedBoards.contains($0.gameId) }) {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                guard self.generation == token else { return }
                await self.refresh()
            }
            if self.generation == token { self.reconciliation = nil }
        }
    }

    public func refresh() async {
        refreshRequest &+= 1
        let request = refreshRequest
        let stamp = revision, token = generation
        do {
            let fetched = try await client.round(id: roundId)
            guard !Task.isCancelled, generation == token, request == refreshRequest else { return }
            applyJSON(round: fetched.round, boards: fetched.boards, startedRevision: stamp, now: .now)
        } catch {
            guard !Task.isCancelled, generation == token, request == refreshRequest else { return }
            errorMessage = "Couldn’t refresh boards · retrying"
        }
    }

    // Internal deterministic reducer seams are exercised without networking by package tests.
    func applyJSON(round: BroadcastTournament, boards incoming: [BroadcastBoard], startedRevision: UInt64,
                   now: ContinuousClock.Instant) {
        self.round = round; hasLoaded = true; errorMessage = nil
        for board in incoming {
            guard (revisions[board.gameId] ?? 0) <= startedRevision else { continue }
            // JSON may trail the PGN stream even when its request began after the move, so a
            // JSON board that is *behind* the streamed one is ignored. One that is ahead is not:
            // when the stream has gone quiet (a half-open socket, a long 429 backoff) the JSON
            // refresh is the only thing that can move the wall, and it must be allowed to.
            if streamedBoards.contains(board.gameId),
               let current = self.boards.first(where: { $0.gameId == board.gameId }),
               !FENIdentity.same(current.fen, board.fen) || (!current.isOngoing && board.isOngoing) {
                let currentPly = FENIdentity.ply(current.fen) ?? 0
                let incomingPly = FENIdentity.ply(board.fen) ?? 0
                if incomingPly <= currentPly { continue }
            }
            replace(board)
            anchors[board.gameId] = now
            timedBoards.insert(board.gameId)
        }
    }

    func accept(_ update: BroadcastRoundUpdate, now: ContinuousClock.Instant) {
        let incoming = update.board
        streamedBoards.insert(incoming.gameId)
        let old = boards.first { $0.gameId == incoming.gameId }
        revision &+= 1; revisions[incoming.gameId] = revision
        hasLoaded = true
        let samePosition = old.map { FENIdentity.same($0.fen, incoming.fen) } ?? false
        // PGN contains time after a move, not time at download. Never restart that clock from
        // a historical snapshot. Matching JSON already includes the provider's thinkTime.
        let preserveClock = samePosition && (update.isInitial || old?.status != incoming.status)
        let players = incoming.players.enumerated().map { index, player in
            let previous = old?.players.indices.contains(index) == true ? old?.players[index] : nil
            let clock = preserveClock ? (incoming.isOngoing ? previous?.clockMs : elapsedClock(previous, board: old, index: index, now: now)) : player.clockMs
            return BroadcastPlayer(name: player.name, title: player.title ?? previous?.title,
                rating: player.rating ?? previous?.rating, federation: player.federation ?? previous?.federation,
                clockMs: clock, fideId: player.fideId ?? previous?.fideId,
                // The PGN stream carries no pictures, so a streamed update must not drop the
                // portrait the round JSON already gave this board.
                photo: player.photo ?? previous?.photo)
        }
        replace(BroadcastBoard(gameId: incoming.gameId, name: incoming.name, fen: incoming.fen,
                               lastMove: incoming.lastMove, status: incoming.status, players: players))
        if !preserveClock || !incoming.isOngoing { anchors[incoming.gameId] = now }
        if preserveClock, incoming.isOngoing, old?.isOngoing == false {
            // A result taken back: the clock kept from the finished board was frozen at the
            // result, so it cannot tick from the anchor of that result. Anchor it now and let a
            // JSON refresh supply the real remaining time.
            anchors[incoming.gameId] = now
            timedBoards.remove(incoming.gameId)
        }
        if !preserveClock {
            if update.isInitial || samePosition { timedBoards.remove(incoming.gameId) }
            else { timedBoards.insert(incoming.gameId) }
        }
    }

    func connectionChanged(_ state: ConnectionState, now: ContinuousClock.Instant) {
        if state == .live { isConnected = true; errorMessage = nil; return }
        if isConnected {
            boards = boards.map { board in
                let players = board.players.enumerated().map { index, player in
                    BroadcastPlayer(name: player.name, title: player.title, rating: player.rating,
                        federation: player.federation, clockMs: elapsedClock(player, board: board, index: index, now: now),
                        fideId: player.fideId, photo: player.photo)
                }
                return BroadcastBoard(gameId: board.gameId, name: board.name, fen: board.fen,
                    lastMove: board.lastMove, status: board.status, players: players)
            }
            for board in boards { anchors[board.gameId] = now }
            timedBoards.removeAll()
        }
        isConnected = false; frozenAt = now
    }

    private func elapsedClock(_ player: BroadcastPlayer?, board: BroadcastBoard?, index: Int,
                              now: ContinuousClock.Instant) -> Int? {
        guard let milliseconds = player?.clockMs else { return nil }
        guard let board, canTick(board: board),
              let position = try? Position(fen: board.fen),
              position.sideToMove == (index == 0 ? .white : .black) else { return milliseconds }
        let duration = clockAnchor(for: board.gameId).duration(to: now).components
        let elapsed = max(0, Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
        return max(0, milliseconds - Int(min(Double(Int.max / 2), elapsed)))
    }
    private func replace(_ board: BroadcastBoard) {
        if let index = boards.firstIndex(where: { $0.gameId == board.gameId }) { boards[index] = board }
        else { boards.append(board) }
    }
}
