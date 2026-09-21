import Foundation
import FollowKit
import Testing
@testable import FollowServer

@Suite("Alert policy")
struct AlertEngineTests {

    private let engine = AlertEngine()
    private let now = Fixture.now
    private let context = RoundContext.make()

    private func moveEvent(ply: Int = 41, kind: MoveEvent.Kind = .move, gameId: String = "wchGam01", status: String = "*", think: Int? = nil) -> MoveEvent {
        MoveEvent(kind: kind, snapshot: GameSnapshot.make(gameId: gameId, ply: ply, status: status), at: now, thinkSeconds: think)
    }

    // MARK: Coalescing

    @Test("Following a player and that player's tournament sends one push, worded by the player follow")
    func coalescing() {
        var playerFollow = Follow(id: "f_player", target: .player(fideId: 1_503_014), alerts: .playerDefaults)
        playerFollow.alerts.game = [.start, .move, .end]
        var tournamentFollow = Follow(id: "f_tour", target: .tournament(tourId: "WCHtour1"), alerts: .tournamentDefaults)
        tournamentFollow.alerts.tournament.insert(.topBoardMoves)

        let device = DeviceContext.make(follows: [playerFollow, tournamentFollow])
        let plan = engine.plan(events: [moveEvent()], context: context, devices: [device], cooldowns: [:], activities: [], now: now)

        #expect(plan.entries.count == 1)
        // Both follows had their cooldown moved: one push satisfied both.
        #expect(Set(plan.cooldowns.map(\.followId)) == ["f_player", "f_tour"])
        let push = try! FollowJSON.pushDecoder.decode(MovePush.self, from: Data(plan.entries[0].payloadJSON.utf8))
        #expect(push.pushKind == .move)
        #expect(plan.entries[0].collapseId == "wchGam01")
        #expect(plan.entries[0].threadId == "WCHr0002")
    }

    @Test("A game follow outranks a tournament follow for the wording of a result")
    func specificity() {
        let gameFollow = Follow(id: "f_game", target: .game(roundId: "WCHr0002", gameId: "wchGam01"), alerts: .gameDefaults)
        let tournamentFollow = Follow(id: "f_tour", target: .tournament(tourId: "WCHtour1"), alerts: .tournamentDefaults)
        let device = DeviceContext.make(follows: [gameFollow, tournamentFollow])

        let plan = engine.plan(events: [moveEvent(kind: .gameEnd, status: "1-0")], context: context, devices: [device], cooldowns: [:], activities: [], now: now)
        #expect(plan.entries.count == 1)
        let push = try! FollowJSON.pushDecoder.decode(MovePush.self, from: Data(plan.entries[0].payloadJSON.utf8))
        // The tournament follow alone would have said "Carlsen 1–0 Nepomniachtchi"; the game
        // follow says "Game over".
        #expect(push.pushKind == .gameEnd)
        #expect(plan.entries[0].title == "Game over: 1–0")
    }

    @Test("Without the game follow, the tournament's own wording is used")
    func tournamentWordingAlone() {
        let device = DeviceContext.make(follows: [Follow(id: "f_tour", target: .tournament(tourId: "WCHtour1"), alerts: .tournamentDefaults)])
        let plan = engine.plan(events: [moveEvent(kind: .gameEnd, status: "1-0")], context: context, devices: [device], cooldowns: [:], activities: [], now: now)
        #expect(plan.entries.count == 1)
        #expect(plan.entries[0].title == "Carlsen, Magnus 1–0 Nepomniachtchi, Ian")
    }

    // MARK: Switches

    @Test("A switch that is off is silence")
    func switchesOff() {
        let follow = Follow(id: "f", target: .player(fideId: 1_503_014), alerts: .playerDefaults)   // no move alerts
        let device = DeviceContext.make(follows: [follow])
        #expect(engine.plan(events: [moveEvent()], context: context, devices: [device], cooldowns: [:], activities: [], now: now).entries.isEmpty)
        // …and the switches that are on still fire.
        #expect(engine.plan(events: [moveEvent(kind: .gameEnd, status: "1-0")], context: context, devices: [device], cooldowns: [:], activities: [], now: now).entries.count == 1)
    }

    @Test("A tournament follow says nothing about a game starting or a player thinking")
    func tournamentIgnoresBoardChatter() {
        var follow = Follow(id: "f", target: .tournament(tourId: "WCHtour1"), alerts: .tournamentDefaults)
        follow.alerts.tournament.insert(.topBoardMoves)
        let device = DeviceContext.make(follows: [follow])
        for kind in [MoveEvent.Kind.gameStart, .longThink] {
            let plan = engine.plan(events: [moveEvent(ply: 41, kind: kind, think: 3600)], context: context, devices: [device], cooldowns: [:], activities: [], now: now)
            #expect(plan.entries.isEmpty, "a tournament follow should not send \(kind)")
        }
    }

    // MARK: Cooldown

    @Test("A cooldown suppresses the second push and lets the one after the interval through")
    func cooldown() {
        var follow = Follow(id: "f", target: .game(roundId: "WCHr0002", gameId: "wchGam01"), alerts: .gameDefaults)
        follow.alerts.game = [.move]
        follow.alerts.minMinutesBetweenMoveAlerts = 5
        let device = DeviceContext.make(follows: [follow])

        let first = engine.plan(events: [moveEvent(ply: 41)], context: context, devices: [device], cooldowns: [:], activities: [], now: now)
        #expect(first.entries.count == 1)

        let cooldowns = [AlertEngine.cooldownKey(followId: "f", gameId: "wchGam01"): now]
        let tooSoon = engine.plan(events: [moveEvent(ply: 42)], context: context, devices: [device], cooldowns: cooldowns, activities: [], now: now.addingTimeInterval(120))
        #expect(tooSoon.entries.isEmpty)

        let later = engine.plan(events: [moveEvent(ply: 43)], context: context, devices: [device], cooldowns: cooldowns, activities: [], now: now.addingTimeInterval(301))
        #expect(later.entries.count == 1)
    }

    @Test("A game end is never held back by a move cooldown")
    func cooldownDoesNotHoldTheResult() {
        var follow = Follow(id: "f", target: .game(roundId: "WCHr0002", gameId: "wchGam01"), alerts: .gameDefaults)
        follow.alerts.game = [.move, .end]
        follow.alerts.minMinutesBetweenMoveAlerts = 60
        let device = DeviceContext.make(follows: [follow])
        let cooldowns = [AlertEngine.cooldownKey(followId: "f", gameId: "wchGam01"): now]

        let plan = engine.plan(events: [moveEvent(ply: 42, kind: .gameEnd, status: "1-0")], context: context, devices: [device], cooldowns: cooldowns, activities: [], now: now.addingTimeInterval(60))
        #expect(plan.entries.count == 1)
    }

    @Test("Each follow's own long-think threshold decides, not the watcher's")
    func longThinkThresholds() {
        var patient = Follow(id: "f_patient", target: .game(roundId: "WCHr0002", gameId: "wchGam01"), alerts: .gameDefaults)
        patient.alerts.longThinkMinutes = 30
        let device = DeviceContext.make(follows: [patient])

        // The watcher raised the event at the smallest threshold anyone asked for (10 minutes).
        let early = engine.plan(events: [moveEvent(kind: .longThink, think: 700)], context: context, devices: [device], cooldowns: [:], activities: [], now: now)
        #expect(early.entries.isEmpty)

        let late = engine.plan(events: [moveEvent(kind: .longThink, think: 1900)], context: context, devices: [device], cooldowns: [:], activities: [], now: now)
        #expect(late.entries.count == 1)
        #expect(late.entries[0].title.contains("has been thinking for 31 minutes"))
    }

    // MARK: Top boards

    @Test("A hundred-board round with topBoards = 1 is one result push, not a hundred")
    func topBoardsCap() {
        let boards = (1...100).map { String(format: "game%04d", $0) }
        let context = RoundContext(
            roundId: "openR1", roundName: "Round 1", tourId: "openTour", tourName: "A large open", boards: boards
        )
        let follow = Follow(id: "f", target: .tournament(tourId: "openTour"), alerts: .tournamentDefaults)
        let device = DeviceContext.make(follows: [follow])

        let events = boards.map { gameId in
            MoveEvent(
                kind: .gameEnd,
                snapshot: GameSnapshot.make(gameId: gameId, roundId: "openR1", ply: 80, status: "1-0", whiteFideId: nil, blackFideId: nil),
                at: now
            )
        }
        let plan = engine.plan(events: events, context: context, devices: [device], cooldowns: [:], activities: [], now: now)
        #expect(plan.entries.count == 1)
        #expect(plan.entries[0].dedupeKey.contains("game0001"))
    }

    @Test("A board holding a followed player is covered however far down it is")
    func followedPlayerBeatsTheCap() {
        let boards = (1...100).map { String(format: "game%04d", $0) }
        let context = RoundContext(roundId: "openR1", roundName: "Round 1", tourId: "openTour", tourName: "A large open", boards: boards)
        let follows = [
            Follow(id: "f_tour", target: .tournament(tourId: "openTour"), alerts: .tournamentDefaults),
            Follow(id: "f_player", target: .player(fideId: 1_503_014), alerts: FollowAlerts(game: [])),  // no game alerts of its own
        ]
        let device = DeviceContext.make(follows: follows)

        let event = MoveEvent(
            kind: .gameEnd,
            snapshot: GameSnapshot.make(gameId: "game0077", roundId: "openR1", ply: 80, status: "1-0"),
            at: now
        )
        let plan = engine.plan(events: [event], context: context, devices: [device], cooldowns: [:], activities: [], now: now)
        #expect(plan.entries.count == 1)
    }

    @Test("Raising topBoards widens the cap")
    func topBoardsThree() {
        let boards = (1...10).map { String(format: "game%04d", $0) }
        let context = RoundContext(roundId: "openR1", roundName: "Round 1", tourId: "openTour", tourName: "Open", boards: boards)
        var follow = Follow(id: "f", target: .tournament(tourId: "openTour"), alerts: .tournamentDefaults)
        follow.alerts.topBoards = 3
        let device = DeviceContext.make(follows: [follow])

        let events = boards.map {
            MoveEvent(kind: .gameEnd, snapshot: GameSnapshot.make(gameId: $0, roundId: "openR1", ply: 80, status: "1-0", whiteFideId: nil, blackFideId: nil), at: now)
        }
        #expect(engine.plan(events: events, context: context, devices: [device], cooldowns: [:], activities: [], now: now).entries.count == 3)
    }

    // MARK: Preferences

    @Test("Mute drops a move alert and quiet hours let a game end through only with the exemption")
    func muteAndQuietHours() {
        let follow = Follow(id: "f", target: .game(roundId: "WCHr0002", gameId: "wchGam01"), alerts: FollowAlerts(game: [.move, .end]))

        let muted = DeviceContext.make(preferences: NotificationPreferences(muteAll: true, timeZoneIdentifier: "UTC"), follows: [follow])
        #expect(engine.plan(events: [moveEvent()], context: context, devices: [muted], cooldowns: [:], activities: [], now: now).entries.isEmpty)

        // 02:00 UTC, inside a 22:00–07:00 window.
        let night = Date(timeIntervalSince1970: 1_790_042_400)
        var quiet = NotificationPreferences(quietHoursStart: 22 * 60, quietHoursEnd: 7 * 60, timeZoneIdentifier: "UTC")
        let asleep = DeviceContext.make(preferences: quiet, follows: [follow])
        #expect(engine.plan(events: [moveEvent()], context: context, devices: [asleep], cooldowns: [:], activities: [], now: night).entries.isEmpty)
        #expect(engine.plan(events: [moveEvent(kind: .gameEnd, status: "1-0")], context: context, devices: [asleep], cooldowns: [:], activities: [], now: night).entries.isEmpty)

        quiet.gameEndIgnoresQuietHours = true
        let exempt = DeviceContext.make(preferences: quiet, follows: [follow])
        #expect(engine.plan(events: [moveEvent(kind: .gameEnd, status: "1-0")], context: context, devices: [exempt], cooldowns: [:], activities: [], now: night).entries.count == 1)
        #expect(engine.plan(events: [moveEvent()], context: context, devices: [exempt], cooldowns: [:], activities: [], now: night).entries.isEmpty)
    }

    @Test("A suppressed alert does not start a cooldown the device never saw")
    func suppressionDoesNotStartACooldown() {
        var follow = Follow(id: "f", target: .game(roundId: "WCHr0002", gameId: "wchGam01"), alerts: FollowAlerts(game: [.move]))
        follow.alerts.minMinutesBetweenMoveAlerts = 30
        let muted = DeviceContext.make(preferences: NotificationPreferences(muteAll: true, timeZoneIdentifier: "UTC"), follows: [follow])
        let plan = engine.plan(events: [moveEvent()], context: context, devices: [muted], cooldowns: [:], activities: [], now: now)
        #expect(plan.cooldowns.isEmpty)
    }

    // MARK: Live Activities

    @Test("A muted device still gets its Live Activity updated")
    func muteDoesNotFreezeAnActivity() throws {
        let follow = Follow(id: "f", target: .game(roundId: "WCHr0002", gameId: "wchGam01"), alerts: FollowAlerts(game: [.move]))
        let muted = DeviceContext.make(preferences: NotificationPreferences(muteAll: true, timeZoneIdentifier: "UTC"), follows: [follow])
        let activity = ActivityRecord(deviceId: muted.device.id, roundId: "WCHr0002", gameId: "wchGam01", activityToken: "act_token")

        let plan = engine.plan(events: [moveEvent()], context: context, devices: [muted], cooldowns: [:], activities: [activity], now: now)
        #expect(plan.entries.count == 1)
        #expect(plan.entries[0].category == .activityUpdate)
        #expect(plan.entries[0].category.isAlert == false)

        // …and the state decodes the way ActivityKit will decode it.
        let state = try JSONDecoder().decode(LiveActivityState.self, from: Data(plan.entries[0].payloadJSON.utf8))
        #expect(state.ply == 41)
        #expect(state.clockRunningFor == "white")
    }

    @Test("A game ending ends the activity, with the final position")
    func activityEnds() throws {
        let device = DeviceContext.make(follows: [Follow(id: "f", target: .game(roundId: "WCHr0002", gameId: "wchGam01"), alerts: .gameDefaults)])
        let activity = ActivityRecord(deviceId: device.device.id, roundId: "WCHr0002", gameId: "wchGam01", activityToken: "act_token")
        let plan = engine.plan(events: [moveEvent(kind: .gameEnd, status: "1-0")], context: context, devices: [device], cooldowns: [:], activities: [activity], now: now)

        let categories = Set(plan.entries.map(\.category))
        #expect(categories == [.gameMove, .activityEnd])
        let ending = try #require(plan.entries.first { $0.category == .activityEnd })
        let state = try JSONDecoder().decode(LiveActivityState.self, from: Data(ending.payloadJSON.utf8))
        #expect(state.isFinished)
        #expect(state.clockRunningFor == nil)
    }

    @Test("An activity for a different game is left alone")
    func activityIsPerGame() {
        let device = DeviceContext.make(follows: [Follow(id: "f", target: .game(roundId: "WCHr0002", gameId: "wchGam01"), alerts: .gameDefaults)])
        let elsewhere = ActivityRecord(deviceId: device.device.id, roundId: "WCHr0002", gameId: "wchGam02", activityToken: "act_token")
        let plan = engine.plan(events: [moveEvent()], context: context, devices: [device], cooldowns: [:], activities: [elsewhere], now: now)
        #expect(plan.entries.allSatisfy { $0.category == .gameMove })
    }

    // MARK: Tournament events

    @Test("The starting-soon window is each follow's own lead time")
    func startingSoonLead() {
        let startsAt = now.addingTimeInterval(20 * 60)
        let event = TournamentEvent(kind: .startingSoon, tourId: "WCHtour1", tourName: "World Championship 2026", roundId: "WCHr0003", roundName: "Round 3", startsAt: startsAt, at: now)

        var eager = Follow(id: "f_eager", target: .tournament(tourId: "WCHtour1"), alerts: .tournamentDefaults)
        eager.alerts.startingSoonMinutes = 30
        var patient = Follow(id: "f_patient", target: .tournament(tourId: "WCHtour1"), alerts: .tournamentDefaults)
        patient.alerts.startingSoonMinutes = 5

        let devices = [
            DeviceContext.make(id: "d_eager", follows: [eager]),
            DeviceContext.make(id: "d_patient", follows: [patient]),
        ]
        let plan = engine.plan(tournamentEvents: [event], devices: devices, now: now)
        #expect(plan.entries.map(\.deviceId) == ["d_eager"])
        #expect(plan.entries[0].title == "Round 3 starts in 20 minutes")
    }

    @Test("A round that has already started is never announced as starting soon")
    func startingSoonInThePast() {
        let event = TournamentEvent(kind: .startingSoon, tourId: "WCHtour1", tourName: "WCH", roundId: "WCHr0003", roundName: "Round 3", startsAt: now.addingTimeInterval(-60), at: now)
        let device = DeviceContext.make(follows: [Follow(id: "f", target: .tournament(tourId: "WCHtour1"), alerts: .tournamentDefaults)])
        #expect(engine.plan(tournamentEvents: [event], devices: [device], now: now).entries.isEmpty)
    }

    @Test("A round going live is one alert with the board count in it")
    func roundLive() {
        let event = TournamentEvent(kind: .roundLive, tourId: "WCHtour1", tourName: "World Championship 2026", roundId: "WCHr0002", roundName: "Round 2", boardCount: 14, at: now)
        let device = DeviceContext.make(follows: [Follow(id: "f", target: .tournament(tourId: "WCHtour1"), alerts: .tournamentDefaults)])
        let plan = engine.plan(tournamentEvents: [event], devices: [device], now: now)
        #expect(plan.entries.count == 1)
        #expect(plan.entries[0].title == "Round 2 is live")
        #expect(plan.entries[0].body == "14 boards · World Championship 2026")
        #expect(plan.entries[0].collapseId == "WCHtour1:WCHr0002:roundLive")
    }

    @Test("A tournament alert the device switched off is silence")
    func tournamentSwitchOff() {
        var follow = Follow(id: "f", target: .tournament(tourId: "WCHtour1"), alerts: .tournamentDefaults)
        follow.alerts.tournament.remove(.roundLive)
        let device = DeviceContext.make(follows: [follow])
        let event = TournamentEvent(kind: .roundLive, tourId: "WCHtour1", tourName: "WCH", roundId: "WCHr0002", roundName: "Round 2", at: now)
        #expect(engine.plan(tournamentEvents: [event], devices: [device], now: now).entries.isEmpty)
    }
}
