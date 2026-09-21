// Turning a follow list of bare ids into rows a person can read.
//
// A `Follow` carries a FIDE id, a round-and-game pair, or a tour id — and nothing else, because
// that is all the server needs. The Following tab has to show a name, a portrait, an opponent
// and a clock, so this object resolves them and caches what it learns.
//
// Where a player is playing right now is a question only the server can really answer, since it
// watches every round all day. The phone does the bounded version: it looks through the rounds
// of the events already on the Home shelf, which costs one request per ongoing round and no
// more than `roundLookupLimit` of them, and says plainly when it has not found the player rather
// than implying they are not playing.
import Foundation
import FollowKit
import GameSessionKit
import LichessKit

@MainActor
@Observable
final class FollowingModel {

    /// At most this many ongoing rounds are searched for followed players on one refresh.
    static let roundLookupLimit = 6
    static let refreshInterval: Duration = .seconds(60)

    private(set) var fidePlayers: [Int: FIDEPlayer] = [:]
    /// Boards keyed by game id, from every round we looked at this refresh.
    private(set) var boards: [String: BroadcastBoard] = [:]
    /// Which round a board came from, so a row can open it.
    private(set) var roundOfBoard: [String: String] = [:]
    /// The round entries we fetched, keyed by round id.
    private(set) var rounds: [String: BroadcastTournament] = [:]
    /// Tours behind tournament follows, keyed by tour id.
    private(set) var tours: [String: BroadcastTour] = [:]
    private(set) var isRefreshing = false

    @ObservationIgnored private let broadcasts: BroadcastClient
    @ObservationIgnored private let fideClient: FIDEPlayerClient
    /// Called after every refresh, so the screen can hand the names it resolved to the watch.
    @ObservationIgnored var didRefresh: (@MainActor () -> Void)?

    init(broadcasts: BroadcastClient = BroadcastClient(), fideClient: FIDEPlayerClient = .shared) {
        self.broadcasts = broadcasts
        self.fideClient = fideClient
    }

    /// Keeps the rows current while the Following tab is on screen.
    func run(follows: @escaping @MainActor () -> [Follow], events: @escaping @MainActor () -> [BroadcastTournament]) async {
        while !Task.isCancelled {
            await refresh(follows: follows(), events: events())
            do { try await Task.sleep(for: Self.refreshInterval) } catch { return }
        }
    }

    func refresh(follows: [Follow], events: [BroadcastTournament]) async {
        guard !follows.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        await resolvePlayers(in: follows)
        await resolveTours(in: follows)
        await resolveRounds(in: follows, events: events)
        didRefresh?()
    }

    /// The two lines each follow shows, keyed by follow id — what the watch is handed.
    func rowText(for follows: [Follow]) -> [String: FollowRowText] {
        var text: [String: FollowRowText] = [:]
        for follow in follows {
            text[follow.id] = FollowRowText(
                title: FollowPresentation.title(for: follow, model: self),
                subtitle: FollowPresentation.status(for: follow, model: self)
            )
        }
        return text
    }

    // MARK: - Players

    private func resolvePlayers(in follows: [Follow]) async {
        let ids = follows.compactMap(\.target.fideId).filter { fidePlayers[$0] == nil }
        for id in ids {
            guard let player = try? await fideClient.player(fideId: id) else { continue }
            fidePlayers[id] = player
        }
    }

    // MARK: - Tournaments

    private func resolveTours(in follows: [Follow]) async {
        for tourId in follows.compactMap(\.target.tourId) {
            guard let tour = try? await broadcasts.tournament(id: tourId) else { continue }
            tours[tourId] = tour
        }
    }

    // MARK: - Rounds and boards

    /// The rounds worth fetching: every round a game follow names, the live round of every
    /// followed tournament, and — only while a player is followed — the ongoing rounds from the
    /// Home shelf, so "where is Carlsen playing" has somewhere to look.
    private func resolveRounds(in follows: [Follow], events: [BroadcastTournament]) async {
        var roundIds: [String] = follows.compactMap(\.target.roundId)

        for tour in follows.compactMap({ $0.target.tourId }).compactMap({ tours[$0] }) {
            if let live = tour.rounds.first(where: { $0.ongoing }) { roundIds.append(live.id) }
        }

        if follows.contains(where: { $0.followKind == .player }) {
            let ongoing = events.filter(\.roundOngoing).map(\.roundId)
            roundIds.append(contentsOf: ongoing)
        }

        var seen = Set<String>()
        let unique = roundIds.filter { seen.insert($0).inserted }.prefix(Self.roundLookupLimit)

        for roundId in unique {
            guard let fetched = try? await broadcasts.round(id: roundId) else { continue }
            rounds[roundId] = fetched.round
            for board in fetched.boards {
                boards[board.gameId] = board
                roundOfBoard[board.gameId] = roundId
            }
        }
    }

    // MARK: - Lookups for the rows

    func player(fideId: Int) -> FIDEPlayer? { fidePlayers[fideId] }

    func board(gameId: String) -> BroadcastBoard? { boards[gameId] }

    func round(id: String) -> BroadcastTournament? { rounds[id] }

    func tour(id: String) -> BroadcastTour? { tours[id] }

    /// The board a followed player is sitting at right now, among the rounds we looked at.
    func liveBoard(forFideID fideId: Int) -> (board: BroadcastBoard, roundId: String)? {
        for (gameId, board) in boards where board.isOngoing {
            guard board.players.contains(where: { $0.fideId == fideId }) else { continue }
            guard let roundId = roundOfBoard[gameId] else { continue }
            return (board, roundId)
        }
        return nil
    }
}

// MARK: - Row wording

/// Everything the Following rows say, as pure functions on what was resolved.
@MainActor
enum FollowPresentation {

    /// The title of a row: the player's name, the two names on a board, or the event's name.
    static func title(for follow: Follow, model: FollowingModel) -> String {
        switch follow.target {
        case .player(let fideId):
            return model.player(fideId: fideId)?.name ?? "FIDE \(fideId)"
        case .game(_, let gameId):
            guard let board = model.board(gameId: gameId) else { return "Board \(gameId.prefix(6))" }
            return board.name.isEmpty
                ? "\(board.white?.name ?? "White") \u{2013} \(board.black?.name ?? "Black")"
                : board.name
        case .tournament(let tourId):
            return model.tour(id: tourId)?.name ?? "Event \(tourId)"
        }
    }

    /// The second line: what that follow is doing at this moment.
    static func status(for follow: Follow, model: FollowingModel, now: Date = .now) -> String {
        switch follow.target {
        case .player(let fideId):
            guard let (board, _) = model.liveBoard(forFideID: fideId) else {
                return "Not playing in an event on the Home shelf"
            }
            let opponent = board.players.first { $0.fideId != fideId }?.name ?? "an opponent"
            return "Playing \(opponent)"
        case .game(_, let gameId):
            guard let board = model.board(gameId: gameId) else { return "Waiting for the round" }
            return board.isOngoing ? "In progress" : "Finished \(board.status)"
        case .tournament(let tourId):
            guard let tour = model.tour(id: tourId) else { return "Waiting for the event" }
            return tournamentStatus(tour, now: now)
        }
    }

    /// "Round 5 · live · 14 boards" or "Round 6 · tomorrow 14:00".
    static func tournamentStatus(_ tour: BroadcastTour, boardCount: Int? = nil, now: Date = .now) -> String {
        if let live = tour.rounds.first(where: { $0.ongoing }) {
            let boards = boardCount.map { " \u{00B7} \($0) boards" } ?? ""
            return "\(live.name) \u{00B7} live\(boards)"
        }
        let upcoming = tour.rounds
            .filter { !$0.finished && $0.startsAt != nil }
            .sorted { ($0.startsAt ?? .distantFuture) < ($1.startsAt ?? .distantFuture) }
        if let next = upcoming.first, let startsAt = next.startsAt {
            if Calendar.current.isDateInToday(startsAt) { return "\(next.name) \u{00B7} today \(HomeShelves.time(startsAt))" }
            if Calendar.current.isDateInTomorrow(startsAt) { return "\(next.name) \u{00B7} tomorrow \(HomeShelves.time(startsAt))" }
            return "\(next.name) \u{00B7} \(startsAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return tour.rounds.allSatisfy(\.finished) ? "Finished" : "Rounds not scheduled yet"
    }
}
