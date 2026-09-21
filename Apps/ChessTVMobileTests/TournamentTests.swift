import Testing
import Foundation
import FollowKit
import LichessKit
@testable import ChessTVMobile

@Suite("Live games stay above results without changing board numbers")
@MainActor
struct BoardOrderingTests {
    private func board(_ id: String, status: String) -> BroadcastBoard {
        BroadcastBoard(gameId: id, name: id, fen: "", lastMove: nil, status: status, players: [])
    }

    @Test("Mixed results retain tournament order within each group")
    func mixedRound() {
        let ordered = BoardsWallModel.liveFirst([
            board("a", status: "1-0"), board("b", status: "*"),
            board("c", status: "½-½"), board("d", status: ""),
        ])
        #expect(ordered.map(\.id) == ["b", "d", "a", "c"])
        #expect(ordered.map(\.number) == [2, 4, 1, 3])
    }

    @Test("A newly finished game leaves the live group and keeps its original number")
    func newlyFinished() {
        let ordered = BoardsWallModel.liveFirst([
            board("a", status: "1-0"), board("b", status: "0-1"),
            board("c", status: "*"),
        ])
        #expect(ordered.map(\.id) == ["c", "a", "b"])
        #expect(ordered.map(\.number) == [3, 1, 2])
        #expect(BoardsWallModel.liveFirst([]).isEmpty)
    }
}

@Suite("Rounds, and which one a screen opens on")
@MainActor
struct TournamentRoundTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func round(_ id: String, ongoing: Bool = false, finished: Bool = false, startsInHours: Double? = nil) -> BroadcastRound {
        BroadcastRound(
            id: id,
            name: "Round \(id)",
            ongoing: ongoing,
            finished: finished,
            startsAt: startsInHours.map { now.addingTimeInterval($0 * 3600) }
        )
    }

    private func model(_ rounds: [BroadcastRound]) -> TournamentModel {
        let model = TournamentModel(tourId: "wcc")
        model.acceptForTesting(BroadcastTour(id: "wcc", name: "World Championship", rounds: rounds))
        return model
    }

    @Test("The round being played is the one to open")
    func ongoingWins() {
        let subject = model([
            round("1", finished: true),
            round("2", ongoing: true),
            round("3", startsInHours: 24),
        ])
        #expect(subject.highlightedRound?.id == "2")
    }

    @Test("With nothing live, the next one to start is the one to open")
    func soonestUpcoming() {
        let subject = model([
            round("1", finished: true),
            round("3", startsInHours: 48),
            round("2", startsInHours: 24),
        ])
        #expect(subject.highlightedRound?.id == "2")
    }

    @Test("A finished event opens on its last round rather than nothing")
    func allFinished() {
        let subject = model([round("1", finished: true), round("2", finished: true)])
        #expect(subject.highlightedRound?.id == "2")
    }

    @Test("A round with no schedule says so rather than inventing a time")
    func statusWording() {
        #expect(TournamentModel.status(for: round("5", ongoing: true), now: now) == "Live")
        #expect(TournamentModel.status(for: round("1", finished: true), now: now) == "Finished")
        #expect(TournamentModel.status(for: round("6"), now: now) == "Starts after the previous round")
    }
}

@Suite("What a follow row says")
@MainActor
struct FollowPresentationTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func tour(_ rounds: [BroadcastRound]) -> BroadcastTour {
        BroadcastTour(id: "tata", name: "Tata Steel Masters", rounds: rounds)
    }

    @Test("A live round names itself, with the board count when there is one")
    func liveRound() {
        let status = FollowPresentation.tournamentStatus(
            tour([BroadcastRound(id: "r5", name: "Round 5", ongoing: true)]),
            boardCount: 14,
            now: now
        )
        #expect(status == "Round 5 \u{00B7} live \u{00B7} 14 boards")
    }

    @Test("With nothing live, the next scheduled round and its time")
    func nextRound() {
        let status = FollowPresentation.tournamentStatus(
            tour([
                BroadcastRound(id: "r5", name: "Round 5", finished: true),
                BroadcastRound(id: "r6", name: "Round 6", startsAt: now.addingTimeInterval(3 * 86_400)),
            ]),
            now: now
        )
        #expect(status.hasPrefix("Round 6 \u{00B7} "))
        #expect(!status.contains("live"))
    }

    @Test("An event whose rounds have all finished says Finished")
    func finishedEvent() {
        let status = FollowPresentation.tournamentStatus(
            tour([BroadcastRound(id: "r1", name: "Round 1", finished: true)]),
            now: now
        )
        #expect(status == "Finished")
    }

    @Test("An event with no schedule yet says that, rather than pretending")
    func unscheduled() {
        let status = FollowPresentation.tournamentStatus(
            tour([BroadcastRound(id: "r1", name: "Round 1")]),
            now: now
        )
        #expect(status == "Rounds not scheduled yet")
    }

    @Test("The watch gets something readable even before a name has been resolved")
    func watchFallback() {
        let follow = Follow(id: "f1", target: .player(fideId: 1_503_014), alerts: .playerDefaults, createdAt: now)
        let text = WatchFollowText.fallback(for: follow)
        #expect(text.title == "FIDE 1503014")
        #expect(text.subtitle == "Game starts \u{00B7} Game ends")
    }
}

@Suite("Values are kept inside the ranges the server enforces")
@MainActor
struct ClampingTests {

    @Test("A default outside the range is clamped when a follow inherits it")
    func newFollowIsClamped() {
        var wild = FollowAlerts.tournamentDefaults
        wild.topBoards = 9
        wild.startingSoonMinutes = 5_000
        var preferences = NotificationPreferences.mobileDefault()
        preferences.setDefaults(wild, for: .tournament)

        let follow = FollowFactory.make(target: .tournament(tourId: "t"), preferences: preferences)
        #expect(follow.alerts.topBoards == 5)
        #expect(follow.alerts.startingSoonMinutes <= 720)
    }

    @Test("A switch list writing an out-of-range value stores the clamped one")
    func setAlertsClamps() {
        let store = FollowStore(storage: InMemoryFollowStore())
        let follow = store.add(.tournament(tourId: "t"))
        var wild = follow.alerts
        wild.topBoards = 100
        store.setAlerts(wild, for: follow.id)
        #expect(store.follow(id: follow.id)?.alerts.topBoards == 5)
    }
}

@Suite("Pointing the app at a different server")
struct ServerIdentityTests {

    @Test("Scheme, host, port and path together decide whether it is the same server")
    func identity() throws {
        let a = try #require(URL(string: "https://chess.example.com"))
        let b = try #require(URL(string: "https://chess.example.com"))
        let c = try #require(URL(string: "https://chess.example.com:8443"))
        let d = try #require(URL(string: "https://other.example.com"))

        #expect(ServerURL.identity(of: a) == ServerURL.identity(of: b))
        #expect(ServerURL.identity(of: a) != ServerURL.identity(of: c))
        #expect(ServerURL.identity(of: a) != ServerURL.identity(of: d))
        #expect(ServerURL.identity(of: nil) != ServerURL.identity(of: a))
    }

    @Test("Setting the same address twice is not a change, so the install token survives")
    @MainActor
    func settingTheSameURLTwice() throws {
        let suite = "chesstv.mobile.serveridentity"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let configuration = ServerConfiguration(defaults: defaults)
        let url = try #require(URL(string: "https://chess.example.com"))
        #expect(configuration.set(url) == true)
        #expect(configuration.set(url) == false)
        #expect(configuration.set(URL(string: "https://other.example.com")) == true)
    }
}
