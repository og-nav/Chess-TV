import Testing
import Foundation
import FollowKit
import LichessKit
@testable import ChessTVMobile

@Suite("Quiet hours")
struct QuietHoursTests {

    @Test("A window that wraps past midnight is quiet on both sides of it")
    func wrapsMidnight() {
        let start = 22 * 60, end = 7 * 60
        #expect(QuietHours.isQuiet(minute: 23 * 60, start: start, end: end))
        #expect(QuietHours.isQuiet(minute: 0, start: start, end: end))
        #expect(QuietHours.isQuiet(minute: 6 * 60 + 59, start: start, end: end))
        #expect(!QuietHours.isQuiet(minute: 7 * 60, start: start, end: end))
        #expect(!QuietHours.isQuiet(minute: 12 * 60, start: start, end: end))
        #expect(!QuietHours.isQuiet(minute: 21 * 60 + 59, start: start, end: end))
    }

    @Test("A window inside one day is the plain case")
    func sameDay() {
        let start = 9 * 60, end = 17 * 60
        #expect(!QuietHours.isQuiet(minute: 8 * 60, start: start, end: end))
        #expect(QuietHours.isQuiet(minute: 9 * 60, start: start, end: end))
        #expect(QuietHours.isQuiet(minute: 16 * 60 + 59, start: start, end: end))
        #expect(!QuietHours.isQuiet(minute: 17 * 60, start: start, end: end))
    }

    @Test("Dragging both pickers together means the whole day, which is what it looks like")
    func wholeDay() {
        // The server (NotificationPreferences.isQuiet) treats equal times as no window; the phone
        // must say the same or the Settings footer lies about what will be sent.
        #expect(!QuietHours.isQuiet(minute: 0, start: 600, end: 600))
        #expect(!QuietHours.isQuiet(minute: 1439, start: 600, end: 600))
        #expect(QuietHours.lengthMinutes(start: 600, end: 600) == 0)
        var preferences = NotificationPreferences(timeZoneIdentifier: "UTC")
        preferences.quietHoursStart = 600
        preferences.quietHoursEnd = 600
        #expect(!preferences.isQuiet(at: Date(timeIntervalSince1970: 0)))
    }

    @Test("The window's length is the same arithmetic the server will do")
    func lengths() {
        #expect(QuietHours.lengthMinutes(start: 22 * 60, end: 7 * 60) == 9 * 60)
        #expect(QuietHours.lengthMinutes(start: 9 * 60, end: 17 * 60) == 8 * 60)
    }

    @Test("Minutes survive a round trip through the date a picker binds to")
    func roundTrip() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam") ?? .gmt
        for minutes in [0, 1, 7 * 60 + 30, 22 * 60, 23 * 60 + 59] {
            let date = QuietHours.date(fromMinutes: minutes, on: Date(timeIntervalSince1970: 1_700_000_000), calendar: calendar)
            #expect(QuietHours.minutes(from: date, calendar: calendar) == minutes)
        }
    }

    @Test("Minutes outside a day wrap rather than escaping")
    func wrapping() {
        #expect(QuietHours.wrap(-60) == 23 * 60)
        #expect(QuietHours.wrap(25 * 60) == 60)
    }
}

@Suite("Counting the alerts that arrived")
struct AlertLogTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Only the last 24 hours are counted")
    func windows() {
        let entries = [
            AlertEntry(id: "a", date: now.addingTimeInterval(-60)),
            AlertEntry(id: "b", date: now.addingTimeInterval(-23 * 3600)),
            AlertEntry(id: "c", date: now.addingTimeInterval(-25 * 3600)),
        ]
        #expect(AlertLog.count(entries, since: now.addingTimeInterval(-24 * 3600)) == 2)
    }

    @Test("The same push seen by the app and by Notification Center is counted once")
    func deduplicates() {
        let logged = [AlertEntry(id: "round:game", date: now.addingTimeInterval(-120))]
        let delivered = [
            AlertEntry(id: "round:game", date: now.addingTimeInterval(-118)),
            AlertEntry(id: "other", date: now.addingTimeInterval(-100)),
        ]
        let merged = AlertLog.merging(logged, with: delivered)
        #expect(merged.count == 2)
        #expect(merged.first { $0.id == "round:game" }?.date == now.addingTimeInterval(-118))
    }

    @Test("Entries older than the retention window are dropped on every write")
    func pruning() {
        let entries = [
            AlertEntry(id: "fresh", date: now.addingTimeInterval(-3600)),
            AlertEntry(id: "stale", date: now.addingTimeInterval(-72 * 3600)),
        ]
        let kept = AlertLog.pruning(entries, now: now)
        #expect(kept.map(\.id) == ["fresh"])
    }

    @Test("The summary reads as a sentence at nought, one and many")
    func summary() {
        #expect(AlertLog.summary(count: 0) == "No alerts in the last 24 hours")
        #expect(AlertLog.summary(count: 1) == "1 alert in the last 24 hours")
        #expect(AlertLog.summary(count: 7) == "7 alerts in the last 24 hours")
    }
}

@Suite("What can be followed, and which switches it offers")
struct FollowCapabilityTests {

    @Test("A broadcast board is followable as a game")
    func broadcastBoard() {
        let followability = FollowCapability.followability(of: .broadcastBoard(roundId: "r1", gameId: "g1"))
        #expect(followability.target == .game(roundId: "r1", gameId: "g1"))
    }

    @Test("Lichess TV and arenas cannot be followed, and say why")
    func liveSourcesAreNotFollowable() {
        for source in [GameSource.tvChannel(.blitz), .arena(tournamentId: "abc")] {
            let followability = FollowCapability.followability(of: source)
            #expect(followability.target == nil)
            #expect(followability.reason?.isEmpty == false)
        }
    }

    @Test("A player with no FIDE id in the broadcast cannot be followed")
    func playerNeedsAFideID() {
        #expect(FollowCapability.followability(ofPlayerWithFideID: 1_503_014).target == .player(fideId: 1_503_014))
        #expect(FollowCapability.followability(ofPlayerWithFideID: nil).target == nil)
        #expect(FollowCapability.followability(ofPlayerWithFideID: 0).target == nil)
    }

    @Test("A tournament follow offers no move switches from the game list, and the other way round")
    func switchListsDoNotCross() {
        let game = FollowTarget.game(roundId: "r", gameId: "g")
        let tournament = FollowTarget.tournament(tourId: "t")

        #expect(FollowCapability.availableGameAlerts(for: game) == AlertCatalogue.gameAlerts)
        #expect(FollowCapability.availableTournamentAlerts(for: game).isEmpty)

        #expect(FollowCapability.availableGameAlerts(for: tournament).isEmpty)
        #expect(FollowCapability.availableTournamentAlerts(for: tournament) == AlertCatalogue.tournamentAlerts)
    }

    @Test("The move-pacing picker only appears while a move switch is on")
    func pacingFollowsTheSwitch() {
        var alerts = FollowAlerts.playerDefaults
        #expect(!AlertCatalogue.movePacingApplies(to: alerts, kind: .player))
        alerts.game.insert(.move)
        #expect(AlertCatalogue.movePacingApplies(to: alerts, kind: .player))

        var tournament = FollowAlerts.tournamentDefaults
        #expect(!AlertCatalogue.movePacingApplies(to: tournament, kind: .tournament))
        tournament.tournament.insert(.topBoardMoves)
        #expect(AlertCatalogue.movePacingApplies(to: tournament, kind: .tournament))
    }

    @Test("A follow with nothing switched on says so rather than showing an empty line")
    func emptySummary() {
        var alerts = FollowAlerts.playerDefaults
        alerts.game = []
        #expect(alerts.summary(for: .player) == "No alerts")
    }
}

@Suite("How often a screen polls, and how it gives up")
struct PollBackoffTests {

    @Test("While the polls land, the cadence is the plain interval")
    func healthy() {
        #expect(PollBackoff.boards.delay(afterFailures: 0) == .seconds(10))
    }

    @Test("Failures double the gap up to the ceiling and no further")
    func backingOff() {
        let policy = PollBackoff.boards
        #expect(policy.delay(afterFailures: 1) == .seconds(10))
        #expect(policy.delay(afterFailures: 2) == .seconds(20))
        #expect(policy.delay(afterFailures: 3) == .seconds(40))
        #expect(policy.delay(afterFailures: 4) == .seconds(80))
        #expect(policy.delay(afterFailures: 40) == .seconds(80))
    }

    @Test("A round list polls far less often than a board wall")
    func cadences() {
        #expect(PollBackoff.rounds.delay(afterFailures: 0) == .seconds(60))
        #expect(PollBackoff.rounds.delay(afterFailures: 30) == .seconds(300))
    }
}
