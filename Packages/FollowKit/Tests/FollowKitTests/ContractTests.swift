import Foundation
import Testing
@testable import FollowKit

@Suite("Follow contracts")
struct ContractTests {

    @Test("A follow target round-trips through JSON in the readable shape")
    func targetCoding() throws {
        let targets: [FollowTarget] = [
            .player(fideId: 1503014),
            .game(roundId: "q7gOEObq", gameId: "ZD7czPL6"),
            .tournament(tourId: "L2ydImaD"),
        ]
        for target in targets {
            let data = try FollowJSON.encoder.encode(target)
            let text = String(decoding: data, as: UTF8.self)
            #expect(text.contains("\"kind\":\"\(target.kind)\""))
            #expect(try FollowJSON.decoder.decode(FollowTarget.self, from: data) == target)
            #expect(FollowTarget(kind: target.kind, key: target.key) == target)
        }
    }

    @Test("An unknown target kind is a decoding error, not a silent default")
    func unknownTargetKind() {
        let data = Data(#"{"kind":"arena","arenaId":"x"}"#.utf8)
        #expect(throws: (any Error).self) { try FollowJSON.decoder.decode(FollowTarget.self, from: data) }
        #expect(FollowTarget(kind: "arena", key: "x") == nil)
        #expect(FollowTarget(kind: "game", key: "no-slash") == nil)
    }

    @Test("Alert defaults are the ones the plan names")
    func alertDefaults() {
        #expect(FollowAlerts.playerDefaults.game == [.start, .end])
        #expect(FollowAlerts.gameDefaults.game == [.start, .longThink, .end])
        #expect(FollowAlerts.tournamentDefaults.tournament == [.startingSoon, .roundLive, .gameResults, .roundSummary, .finished])
        #expect(FollowAlerts.tournamentDefaults.tournament.contains(.topBoardMoves) == false)
        #expect(FollowAlerts().longThinkMinutes == 10)
        #expect(FollowAlerts().startingSoonMinutes == 15)
        #expect(FollowAlerts().topBoards == 1)
    }

    @Test("A partial alerts body decodes into the defaults instead of failing")
    func partialAlerts() throws {
        let alerts = try FollowJSON.decoder.decode(FollowAlerts.self, from: Data(#"{"game":["move"]}"#.utf8))
        #expect(alerts.game == [.move])
        #expect(alerts.tournament.isEmpty)
        #expect(alerts.longThinkMinutes == 10)
        #expect(alerts.topBoards == 1)
    }

    @Test("Out-of-range numbers are clamped, not honoured")
    func clamping() {
        let wild = FollowAlerts(minMinutesBetweenMoveAlerts: -5, longThinkMinutes: 0, startingSoonMinutes: 100_000, topBoards: 99).clamped()
        #expect(wild.minMinutesBetweenMoveAlerts == 0)
        #expect(wild.longThinkMinutes == 1)
        #expect(wild.startingSoonMinutes == 720)
        #expect(wild.topBoards == 5)
    }

    @Test("A follow made without alerts takes its kind's defaults")
    func followDefaults() {
        #expect(Follow(target: .player(fideId: 1)).alerts == .playerDefaults)
        #expect(Follow(target: .game(roundId: "r", gameId: "g")).alerts == .gameDefaults)
        #expect(Follow(target: .tournament(tourId: "t")).alerts == .tournamentDefaults)
    }

    @Test("A registration with a token that is not hex is not well formed")
    func registrationValidation() {
        #expect(DeviceRegistration(apnsToken: String(repeating: "a", count: 64)).isWellFormed)
        #expect(DeviceRegistration(apnsToken: "short").isWellFormed == false)
        #expect(DeviceRegistration(platform: "android", apnsToken: String(repeating: "a", count: 64)).isWellFormed == false)
        #expect(DeviceRegistration(environment: "staging", apnsToken: String(repeating: "a", count: 64)).isWellFormed == false)
        #expect(DeviceRegistration(apnsToken: String(repeating: "z", count: 64)).isWellFormed == false)
    }
}

@Suite("Quiet hours")
struct QuietHoursTests {

    private func date(_ hour: Int, _ minute: Int, zone: String) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: hour, minute: minute))!
    }

    @Test("An overnight window covers the small hours and nothing else")
    func overnight() {
        let preferences = NotificationPreferences(quietHoursStart: 22 * 60, quietHoursEnd: 7 * 60, timeZoneIdentifier: "Europe/Berlin")
        #expect(preferences.isQuiet(at: date(23, 30, zone: "Europe/Berlin")))
        #expect(preferences.isQuiet(at: date(3, 0, zone: "Europe/Berlin")))
        #expect(preferences.isQuiet(at: date(6, 59, zone: "Europe/Berlin")))
        #expect(preferences.isQuiet(at: date(7, 0, zone: "Europe/Berlin")) == false)
        #expect(preferences.isQuiet(at: date(14, 0, zone: "Europe/Berlin")) == false)
    }

    @Test("A same-day window is the plain interval")
    func sameDay() {
        let preferences = NotificationPreferences(quietHoursStart: 9 * 60, quietHoursEnd: 17 * 60, timeZoneIdentifier: "UTC")
        #expect(preferences.isQuiet(at: date(12, 0, zone: "UTC")))
        #expect(preferences.isQuiet(at: date(8, 59, zone: "UTC")) == false)
    }

    @Test("The window is read in the device's zone, not the server's")
    func zoneMatters() {
        let preferences = NotificationPreferences(quietHoursStart: 22 * 60, quietHoursEnd: 7 * 60, timeZoneIdentifier: "Asia/Tokyo")
        // 23:00 in Tokyo is 14:00 UTC; a server reading UTC would call this awake.
        #expect(preferences.isQuiet(at: date(23, 0, zone: "Asia/Tokyo")))
    }

    @Test("Mute drops everything; quiet hours let a game end through only with the exemption")
    func gating() {
        let night = date(2, 0, zone: "UTC")
        var preferences = NotificationPreferences(quietHoursStart: 22 * 60, quietHoursEnd: 7 * 60, timeZoneIdentifier: "UTC")

        #expect(preferences.allowsAlert(kind: .move, at: night) == false)
        #expect(preferences.allowsAlert(kind: .gameEnd, at: night) == false)
        preferences.gameEndIgnoresQuietHours = true
        #expect(preferences.allowsAlert(kind: .gameEnd, at: night))
        #expect(preferences.allowsAlert(kind: .gameResult, at: night))
        #expect(preferences.allowsAlert(kind: .move, at: night) == false)
        #expect(preferences.allowsAlert(kind: .roundLive, at: night) == false)

        preferences.muteAll = true
        #expect(preferences.allowsAlert(kind: .gameEnd, at: night) == false)
        #expect(preferences.allowsAlert(kind: .gameEnd, at: date(12, 0, zone: "UTC")) == false)
    }

    @Test("Half of a window is no window, and a nonsense zone becomes UTC")
    func sanitising() {
        let half = NotificationPreferences(quietHoursStart: 22 * 60, quietHoursEnd: nil).sanitized()
        #expect(half.quietHoursStart == nil)
        #expect(NotificationPreferences(timeZoneIdentifier: "Mars/Olympus").sanitized().timeZoneIdentifier == "UTC")
        #expect(NotificationPreferences(quietHoursStart: 1500, quietHoursEnd: 60).sanitized().quietHoursStart == 60)
    }
}

@Suite("Push payloads")
struct PushPayloadTests {

    @Test("A move push knows whose clock is running and how to write the move")
    func moveWording() {
        let white = MovePush(kind: .move, fen: "8/8/8/8/8/8/8/8 b - - 0 23", san: "Nf5", ply: 45)
        #expect(white.numberedSAN == "23. Nf5")
        #expect(white.sideToMove == "black")
        let black = MovePush(kind: .move, fen: "8/8/8/8/8/8/8/8 w - - 0 24", san: "Nf6", ply: 46)
        #expect(black.numberedSAN == "23... Nf6")
        #expect(black.sideToMove == "white")
        #expect(MovePush(status: "1-0").isFinished)
        #expect(MovePush(status: "*").isFinished == false)
    }

    @Test("A push envelope decodes out of the userInfo an extension is handed")
    func envelope() throws {
        let push = MovePush(kind: .move, roundId: "q7gOEObq", gameId: "ZD7czPL6", san: "Nf5", ply: 45)
        let payload: [String: Any] = [
            "aps": [
                "alert": ["title": "Carlsen played 23. Nf5", "body": "Tata Steel · Round 5"],
                "category": PushCategory.gameMove,
                "thread-id": "q7gOEObq",
                "mutable-content": 1,
            ],
            "d": try JSONSerialization.jsonObject(with: FollowJSON.pushEncoder.encode(push)),
        ]
        let envelope = try #require(PushEnvelope<MovePush>.decode(payload))
        #expect(envelope.category == PushCategory.gameMove)
        #expect(envelope.threadId == "q7gOEObq")
        #expect(envelope.title == "Carlsen played 23. Nf5")
        #expect(envelope.payload.gameId == "ZD7czPL6")
        #expect(envelope.payload.pushKind == .move)
    }

    @Test("A payload that is not ours decodes to nil rather than throwing")
    func foreignPayload() {
        #expect(PushEnvelope<MovePush>.decode(["aps": ["alert": "hello"]]) == nil)
    }

    @Test("A tournament push keeps its banner URL and results")
    func tournamentPush() throws {
        let push = TournamentPush(
            kind: .roundFinished,
            tourId: "L2ydImaD",
            tourName: "Tata Steel",
            roundId: "q7gOEObq",
            roundName: "Round 5",
            boardCount: 14,
            results: ["Carlsen 1–0 Nepomniachtchi"],
            bannerURL: URL(string: "https://image.lichess1.org/display?h=400"),
            // Whole seconds: the API's ISO 8601 spelling carries no fractional part, so a date
            // with milliseconds would not survive the trip and that is by design.
            sentAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
        let data = try FollowJSON.pushEncoder.encode(push)
        let back = try FollowJSON.pushDecoder.decode(TournamentPush.self, from: data)
        #expect(back == push)
        #expect(back.pushKind == .roundFinished)
        #expect(String(decoding: data, as: UTF8.self).contains("https://image.lichess1.org"))
    }
}

@Suite("Live Activity content state")
struct LiveActivityStateTests {

    /// The bug this guards against is invisible on the server and total on the device: ActivityKit
    /// decodes the content state with a stock `JSONDecoder`, so an ISO 8601 `asOf` makes every
    /// update fail to decode and the activity simply stops moving.
    @Test("The activity encoder writes a reference-date number a stock decoder can read")
    func stockDecoderReadsIt() throws {
        let state = LiveActivityState(fen: "8/8/8/8/8/8/8/8 w - - 0 1", san: "Nf5", ply: 45, whiteClock: 600, blackClock: 540, clockRunningFor: "black", asOf: Date(timeIntervalSince1970: 1_790_000_000))
        let data = try FollowJSON.activityEncoder.encode(state)

        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["asOf"] is NSNumber)

        let back = try JSONDecoder().decode(LiveActivityState.self, from: data)
        #expect(back == state)
    }

    @Test("A state built from a push carries the clocks and the side to move")
    func fromPush() {
        let push = MovePush(kind: .move, fen: "8/8/8/8/8/8/8/8 b - - 0 23", san: "Nf5", ply: 45, whiteClock: 600, blackClock: 540)
        let state = LiveActivityState(push)
        #expect(state.clockRunningFor == "black")
        #expect(state.whiteClock == 600)
        #expect(state.isFinished == false)

        let end = MovePush(kind: .gameEnd, status: "1-0")
        #expect(LiveActivityState(end).clockRunningFor == nil)
        #expect(LiveActivityState(end).isFinished)
    }
}
