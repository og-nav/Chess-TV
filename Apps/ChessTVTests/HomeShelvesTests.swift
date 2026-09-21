import Testing
import Foundation
import LichessKit
@testable import ChessTV

@Suite("What each home shelf shows, in what order")
struct HomeShelvesTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func arena(
        _ id: String,
        players: Int,
        startsInMinutes: Double,
        minutes: Int = 60,
        started: Bool,
        finished: Bool = false
    ) -> ArenaSummary {
        ArenaSummary(
            id: id,
            fullName: "\(id) Arena",
            perfKey: "blitz",
            variantKey: "standard",
            nbPlayers: players,
            startsAt: now.addingTimeInterval(startsInMinutes * 60),
            minutes: minutes,
            secondsToFinish: nil,          // the list endpoint never sends this
            isStarted: started,
            isFinished: finished
        )
    }

    private func event(_ id: String, tier: Int?, ongoing: Bool, startsInMinutes: Double? = nil) -> BroadcastTournament {
        BroadcastTournament(
            tourId: "t-\(id)",
            name: "\(id) Open",
            tier: tier,
            roundId: id,
            roundName: "Round 3",
            roundOngoing: ongoing,
            roundStartsAt: startsInMinutes.map { now.addingTimeInterval($0 * 60) },
            format: "9-round swiss",
            location: "Oslo",
            isActive: true
        )
    }

    // MARK: - Arenas

    @Test("Live arenas come first, most players first, then the soonest upcoming ones")
    func arenaOrder() {
        let started = [
            arena("a", players: 40, startsInMinutes: -20, started: true),
            arena("b", players: 900, startsInMinutes: -10, started: true),
            arena("c", players: 120, startsInMinutes: -5, started: true),
        ]
        let upcoming = [
            arena("y", players: 0, startsInMinutes: 90, started: false),
            arena("x", players: 0, startsInMinutes: 15, started: false),
        ]
        let items = HomeShelves.arenaItems(started: started, upcoming: upcoming)
        #expect(items.map(\.id) == ["b", "c", "a", "x", "y"])
        #expect(items.prefix(3).allSatisfy { $0.isLive })
        #expect(items.suffix(2).allSatisfy { !$0.isLive })
    }

    @Test("At most twelve live and eight upcoming arenas, and nothing finished")
    func arenaLimits() {
        let started = (0..<30).map { arena("s\($0)", players: 100 - $0, startsInMinutes: -30, started: true) }
            + [arena("done", players: 5000, startsInMinutes: -120, started: true, finished: true)]
        let upcoming = (0..<20).map { arena("u\($0)", players: 0, startsInMinutes: Double($0 + 1) * 10, started: false) }
        let items = HomeShelves.arenaItems(started: started, upcoming: upcoming)
        #expect(items.filter(\.isLive).count == 12)
        #expect(items.filter { !$0.isLive }.count == 8)
        #expect(!items.contains { $0.id == "done" })
        #expect(items.first?.id == "s0")               // the most players
        #expect(items.last?.id == "u7")                // the eighth-soonest
    }

    // MARK: - Events

    @Test("Ongoing rounds first, then the rest of the active ones, then upcoming")
    func eventOrder() {
        let active = [
            event("a1", tier: 4, ongoing: false, startsInMinutes: 60),
            event("a2", tier: 5, ongoing: true),
            event("a3", tier: 3, ongoing: true),
        ]
        let upcoming = [event("u1", tier: 5, ongoing: false, startsInMinutes: 600)]
        let items = HomeShelves.eventItems(active: active, upcoming: upcoming)
        #expect(items.map(\.roundId) == ["a2", "a3", "a1", "u1"])
    }

    @Test("Club-level and untiered broadcasts are dropped, and the shelf is capped at twenty")
    func eventFilter() {
        let active = [event("low", tier: 2, ongoing: true), event("none", tier: nil, ongoing: true)]
            + (0..<25).map { event("ok\($0)", tier: 4, ongoing: true) }
        let items = HomeShelves.eventItems(active: active, upcoming: [])
        #expect(items.count == 20)
        #expect(!items.contains { $0.roundId == "low" || $0.roundId == "none" })
    }

    @Test("The event badge is Live, or the round and its local start time")
    func eventStatus() {
        #expect(HomeShelves.eventStatus(event("a", tier: 4, ongoing: true), now: now) == "Live")
        let soon = event("b", tier: 4, ongoing: false, startsInMinutes: 45)
        #expect(HomeShelves.eventStatus(soon, now: now).hasPrefix("Round 3 \u{00B7} starts "))
        let noTime = event("c", tier: 4, ongoing: false)
        #expect(HomeShelves.eventStatus(noTime, now: now) == "Round 3")
    }

    // MARK: - Status lines

    @Test("Ends in is startsAt plus minutes, because the list sends no secondsToFinish")
    func endsIn() {
        let startsAt = now.addingTimeInterval(-18 * 60)
        #expect(HomeShelves.endsIn(startsAt: startsAt, minutes: 60, now: now) == "Ends in 42m")
        #expect(HomeShelves.endsIn(startsAt: startsAt, minutes: 90, now: now) == "Ends in 1h 12m")
        #expect(HomeShelves.endsIn(startsAt: startsAt, minutes: 18, now: now) == "Finishing")
        #expect(HomeShelves.endsIn(startsAt: startsAt, minutes: 10, now: now) == "Finishing")
    }

    @Test("Starts in counts minutes while it is close, and shows the clock time later")
    func startsIn() {
        #expect(HomeShelves.startsIn(startsAt: now.addingTimeInterval(12 * 60), now: now) == "Starts in 12m")
        #expect(HomeShelves.startsIn(startsAt: now.addingTimeInterval(5), now: now) == "Starting")
        let later = now.addingTimeInterval(4 * 3600)
        #expect(HomeShelves.startsIn(startsAt: later, now: now) == "Starts at " + HomeShelves.time(later))
    }

    @Test("Source titles name the thing on screen")
    func titles() {
        #expect(SourceTitle.text(for: .tvChannel(.blitz)) == "Blitz \u{00B7} Lichess TV")
        #expect(SourceTitle.arena(arena("h", players: 300, startsInMinutes: -5, started: true)) == "h Arena \u{00B7} Lichess")
        #expect(SourceTitle.board(tournament: "TCEC S30", round: "Round 21", boardNumber: 3) == "TCEC S30 \u{00B7} Round 21 \u{00B7} Board 3")
        #expect(SourceTitle.board(tournament: "TCEC S30", round: "Round 21", boardNumber: nil) == "TCEC S30 \u{00B7} Round 21")
    }
}
