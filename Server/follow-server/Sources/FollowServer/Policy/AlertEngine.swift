// Who gets told what.
//
// A pure function from (events, follows, preferences, cooldowns) to a list of outbox rows. No
// database, no clock, no network — so every rule the plan argues about (the top-boards cap, the
// cooldown, coalescing overlapping follows, mute and quiet hours, and the one exemption) is a
// test with three values in it.
//
// The four rules that matter, in the order they are applied:
//
//   1. **Matching.** A follow only hears about an event its target covers and its switches ask
//      for. A tournament follow additionally has to pass the top-boards rule.
//   2. **Cooldown.** `minMinutesBetweenMoveAlerts` per follow and game.
//   3. **Coalescing.** All the follows of one device that matched one board event produce **one**
//      push, worded by the most specific of them: game beats player beats tournament. Following
//      both Carlsen and his tournament is the obvious thing to do and must not double every move.
//   4. **Preferences.** Mute and quiet hours, with the game-end exemption. Live Activity updates
//      are not alerts and skip this step entirely.

import Foundation
import FollowKit

/// One cooldown to write back after the plan is accepted.
public struct CooldownTouch: Sendable, Equatable {
    public var followId: String
    public var gameId: String
    public var at: Date
}

public struct AlertPlan: Sendable, Equatable {
    public var entries: [OutboxEntry] = []
    public var cooldowns: [CooldownTouch] = []

    public var isEmpty: Bool { entries.isEmpty && cooldowns.isEmpty }
}

public struct AlertEngine: Sendable {

    public init() {}

    /// The key a `minMinutesBetweenMoveAlerts` cooldown is held under.
    public static func cooldownKey(followId: String, gameId: String) -> String { "\(followId)|\(gameId)" }

    // MARK: - Board events

    public func plan(
        events: [MoveEvent],
        context: RoundContext,
        devices: [DeviceContext],
        cooldowns: [String: Date],
        activities: [ActivityRecord],
        now: Date
    ) -> AlertPlan {
        var plan = AlertPlan()
        var cooldowns = cooldowns

        for event in events {
            for device in devices {
                guard device.device.isActive else { continue }
                guard let choice = select(event: event, context: context, device: device, cooldowns: cooldowns, now: now) else { continue }

                let push = movePush(for: event, kind: choice.pushKind, context: context)
                guard device.preferences.allowsAlert(kind: choice.pushKind, at: now) else {
                    // Suppressed, and deliberately *not* recorded as a cooldown: a muted device
                    // that unmutes should get the next move, not wait out an interval it never
                    // saw the start of.
                    continue
                }
                guard let payload = try? FollowJSON.pushEncoder.encode(push) else { continue }

                plan.entries.append(
                    OutboxEntry(
                        deviceId: device.device.id,
                        dedupeKey: Self.dedupeKey(for: event),
                        // The plan's rule: the newest move replaces the previous one in the
                        // notification centre, so a game never stacks up.
                        collapseId: event.snapshot.gameId,
                        category: .gameMove,
                        payloadJSON: String(decoding: payload, as: UTF8.self),
                        title: PushWording.title(for: push, thinkSeconds: event.thinkSeconds),
                        body: PushWording.body(for: push),
                        threadId: context.roundId,
                        relevance: PushWording.relevance(for: choice.pushKind),
                        reference: event.snapshot.gameId,
                        queuedAt: now
                    )
                )

                if event.kind == .move || event.kind == .longThink {
                    for followId in choice.followIds {
                        plan.cooldowns.append(CooldownTouch(followId: followId, gameId: event.snapshot.gameId, at: now))
                        cooldowns[Self.cooldownKey(followId: followId, gameId: event.snapshot.gameId)] = now
                    }
                }
            }

            plan.entries.append(contentsOf: activityEntries(for: event, activities: activities, now: now))
        }
        return plan
    }

    /// `(gameId, ply, fen)` plus the event kind, per the plan's "event identity".
    ///
    /// The kind is in the key because a game-end can land on the same ply as a move that was
    /// already pushed, and dropping the second would lose the only alert the user actually
    /// wanted. Everything else about the key is what makes two follows one push.
    static func dedupeKey(for event: MoveEvent) -> String {
        "g:\(event.snapshot.gameId):\(event.snapshot.ply):\(event.kind.rawValue):\(event.snapshot.fen)"
    }

    private struct Choice {
        var pushKind: MovePushKind
        /// Every follow that matched, so all their cooldowns move together: one push satisfies
        /// all of them, and only one of them should not be able to reopen the others' intervals.
        var followIds: [String]
    }

    private func select(
        event: MoveEvent,
        context: RoundContext,
        device: DeviceContext,
        cooldowns: [String: Date],
        now: Date
    ) -> Choice? {
        let snapshot = event.snapshot
        var best: (specificity: Int, kind: MovePushKind)?
        var followIds: [String] = []
        // Only the oldest few swing switches count, whatever the stored rows say.
        let swingFollows = Set(device.follows.filter(\.alerts.evalSwings).prefix(Self.maximumSwingFollowsPerDevice).map(\.id))

        for follow in device.follows {
            if event.kind == .evalSwing, !swingFollows.contains(follow.id) { continue }
            var specificity = 0
            var kind: MovePushKind

            switch follow.target {
            case .game(let roundId, let gameId):
                guard gameId == snapshot.gameId, roundId.isEmpty || roundId == snapshot.roundId else { continue }
                guard Self.wants(event, follow) else { continue }
                specificity = 3
                kind = Self.pushKind(for: event.kind)

            case .player(let fideId):
                guard snapshot.whiteFideId == fideId || snapshot.blackFideId == fideId else { continue }
                guard Self.wants(event, follow) else { continue }
                specificity = 2
                kind = Self.pushKind(for: event.kind)

            case .tournament(let tourId):
                guard tourId == context.tourId else { continue }
                // A tournament follow says nothing about a game starting or a player thinking;
                // "the round is live" already covered the first and the second is a board-level
                // interest. Results and top-board moves are all it has.
                switch event.kind {
                case .gameEnd:
                    guard follow.alerts.tournament.contains(.gameResults) else { continue }
                    kind = .gameResult
                case .move:
                    guard follow.alerts.tournament.contains(.topBoardMoves) else { continue }
                    kind = .move
                case .evalSwing:
                    guard follow.alerts.evalSwings else { continue }
                    kind = .evalSwing
                case .gameStart, .longThink:
                    continue
                }
                guard covers(board: snapshot, follow: follow, context: context, device: device) else { continue }
                specificity = 1
            }

            // The cooldown is per follow, so a five-minute follow and a zero-minute follow on the
            // same board behave as each was asked to.
            if event.kind == .move || event.kind == .longThink {
                let interval = TimeInterval(follow.alerts.minMinutesBetweenMoveAlerts * 60)
                if interval > 0, let last = cooldowns[Self.cooldownKey(followId: follow.id, gameId: snapshot.gameId)],
                   now.timeIntervalSince(last) < interval {
                    continue
                }
            }
            // A long think is only interesting past *this* follow's threshold; the watcher raised
            // the event at the lowest threshold any follow asked for.
            if event.kind == .longThink {
                let elapsed = event.thinkSeconds ?? 0
                guard elapsed >= follow.alerts.longThinkMinutes * 60 else { continue }
            }

            followIds.append(follow.id)
            if best == nil || specificity > best!.specificity {
                best = (specificity, kind)
            }
        }

        guard let best else { return nil }
        return Choice(pushKind: best.kind, followIds: followIds)
    }

    static func pushKind(for kind: MoveEvent.Kind) -> MovePushKind {
        switch kind {
        case .gameStart: .gameStart
        case .move: .move
        case .longThink: .longThink
        case .gameEnd: .gameEnd
        case .evalSwing: .evalSwing
        }
    }

    /// Whether a player or game follow's switches ask for this event.
    private static func wants(_ event: MoveEvent, _ follow: Follow) -> Bool {
        guard let alert = event.gameAlert else { return event.kind == .evalSwing && follow.alerts.evalSwings }
        return follow.alerts.game.contains(alert)
    }

    /// The most follows on one install that can ask for swings. Enforced where the demand is
    /// counted, so a script with a hundred follows per install pulls no more engine time than a
    /// person with ten.
    public static let maximumSwingFollowsPerDevice = FollowAlerts.maximumEvalSwingFollows

    /// Whether anyone who would be told about a swing on this board is listening right now. The
    /// pipeline asks before it offers a move to the engine: no listener, no search.
    ///
    /// The same matching as a real swing — follow targets, the top-boards rule, mute and quiet
    /// hours — so the engine never searches a position whose verdict nobody could receive.
    public func wantsSwings(snapshot: GameSnapshot, context: RoundContext, devices: [DeviceContext], now: Date) -> Bool {
        let probe = MoveEvent(kind: .evalSwing, snapshot: snapshot, at: now)
        for device in devices where device.device.isActive {
            guard device.preferences.allowsAlert(kind: .evalSwing, at: now) else { continue }
            if select(event: probe, context: context, device: device, cooldowns: [:], now: now) != nil { return true }
        }
        return false
    }

    /// The top-boards rule: a tournament follow covers the first `topBoards` boards in round
    /// order, plus any board holding a player that same device follows.
    ///
    /// This is the cap that keeps a hundred-board open from being a hundred pushes. Everything it
    /// excludes is covered once, at the end, by the round summary.
    private func covers(board snapshot: GameSnapshot, follow: Follow, context: RoundContext, device: DeviceContext) -> Bool {
        let followed = device.followedFideIds
        if let white = snapshot.whiteFideId, followed.contains(white) { return true }
        if let black = snapshot.blackFideId, followed.contains(black) { return true }
        guard let board = context.board(of: snapshot.gameId) else { return false }
        return board <= max(1, follow.alerts.topBoards)
    }

    private func movePush(for event: MoveEvent, kind: MovePushKind, context: RoundContext) -> MovePush {
        let snapshot = event.snapshot
        return MovePush(
            kind: kind,
            roundId: context.roundId.isEmpty ? snapshot.roundId : context.roundId,
            gameId: snapshot.gameId,
            tourName: context.tourName,
            roundName: context.roundName,
            white: snapshot.white,
            black: snapshot.black,
            fen: snapshot.fen,
            lastMove: snapshot.lastMove,
            san: snapshot.san,
            ply: snapshot.ply,
            whiteClock: snapshot.whiteClock,
            blackClock: snapshot.blackClock,
            status: snapshot.status,
            sentAt: event.at,
            swing: event.swing.map { PushSwing(kind: $0.kind.rawValue, before: $0.before.display, after: $0.after.display) }
        )
    }

    // MARK: - Live Activities

    /// Updates for every device with this game pinned.
    ///
    /// Deliberately outside the preference check. A Live Activity is on screen because the user
    /// put it there; mute means "do not interrupt me", not "freeze the thing I am watching". A
    /// long think changes no position, so it produces no update.
    /// Corrected/reconnected view state must reach pinned cards without creating an alert.
    public func planActivity(snapshot: GameSnapshot, activities: [ActivityRecord], now: Date) -> AlertPlan {
        let event = MoveEvent(kind: snapshot.isFinished ? .gameEnd : .move, snapshot: snapshot, at: now)
        var plan = AlertPlan()
        plan.entries = activityEntries(for: event, activities: activities, now: now)
        return plan
    }

    private func activityEntries(for event: MoveEvent, activities: [ActivityRecord], now: Date) -> [OutboxEntry] {
        // A long think moves nothing, and a swing is about a position the move already sent.
        guard event.kind != .longThink, event.kind != .evalSwing else { return [] }
        let matching = activities.filter { $0.gameId == event.snapshot.gameId }
        guard !matching.isEmpty else { return [] }

        let push = MovePush(
            kind: Self.pushKind(for: event.kind),
            roundId: event.snapshot.roundId,
            gameId: event.snapshot.gameId,
            white: event.snapshot.white,
            black: event.snapshot.black,
            fen: event.snapshot.fen,
            lastMove: event.snapshot.lastMove,
            san: event.snapshot.san,
            ply: event.snapshot.ply,
            whiteClock: event.snapshot.whiteClock,
            blackClock: event.snapshot.blackClock,
            status: event.snapshot.status,
            sentAt: event.at
        )
        let state = LiveActivityState(push)
        // The one place `activityEncoder` is used: ActivityKit decodes a content state with a
        // stock JSONDecoder, so the date has to be a reference-date number, not ISO 8601.
        guard let payload = try? FollowJSON.activityEncoder.encode(state) else { return [] }
        let category: OutboxCategory = event.kind == .gameEnd ? .activityEnd : .activityUpdate

        return matching.map { activity in
            OutboxEntry(
                deviceId: activity.deviceId,
                dedupeKey: "a:\(event.snapshot.gameId):\(event.snapshot.ply):\(category.rawValue):\(event.snapshot.fen):\(event.at.timeIntervalSince1970)",
                collapseId: event.snapshot.gameId,
                category: category,
                payloadJSON: String(decoding: payload, as: UTF8.self),
                threadId: event.snapshot.roundId,
                relevance: 1.0,
                reference: event.snapshot.gameId,
                queuedAt: now
            )
        }
    }

    // MARK: - Tournament events

    public func plan(tournamentEvents: [TournamentEvent], devices: [DeviceContext], now: Date) -> AlertPlan {
        var plan = AlertPlan()

        for event in tournamentEvents {
            for device in devices {
                guard device.device.isActive else { continue }
                guard let follow = device.follows.first(where: { follow in
                    guard case .tournament(let tourId) = follow.target else { return false }
                    return tourId == event.tourId && follow.alerts.tournament.contains(event.tournamentAlert)
                }) else { continue }

                // The lead time is the follow's, so two devices watching the same event can want
                // ten minutes and an hour and both be right. A round that has already started is
                // never announced as starting soon.
                if event.kind == .startingSoon {
                    guard let startsAt = event.startsAt else { continue }
                    let lead = TimeInterval(follow.alerts.startingSoonMinutes * 60)
                    guard now < startsAt, startsAt.timeIntervalSince(now) <= lead else { continue }
                }

                let push = tournamentPush(for: event, at: now)
                guard device.preferences.allowsAlert(kind: push.pushKind ?? .roundLive, at: now) else { continue }
                guard let payload = try? FollowJSON.pushEncoder.encode(push) else { continue }

                plan.entries.append(
                    OutboxEntry(
                        deviceId: device.device.id,
                        dedupeKey: "t:\(event.tourId):\(event.roundId ?? "-"):\(event.kind.rawValue)",
                        collapseId: "\(event.tourId):\(event.roundId ?? "-"):\(event.kind.rawValue)",
                        category: .tournamentEvent,
                        payloadJSON: String(decoding: payload, as: UTF8.self),
                        title: PushWording.title(for: push),
                        body: PushWording.body(for: push),
                        threadId: event.roundId ?? event.tourId,
                        relevance: PushWording.relevance(for: push.pushKind ?? .roundLive),
                        reference: event.tourId,
                        queuedAt: now
                    )
                )
            }
        }
        return plan
    }

    private func tournamentPush(for event: TournamentEvent, at now: Date) -> TournamentPush {
        TournamentPush(
            kind: event.pushKind,
            tourId: event.tourId,
            tourName: event.tourName,
            roundId: event.roundId,
            roundName: event.roundName,
            startsAt: event.startsAt,
            boardCount: event.boardCount,
            results: event.results,
            leaders: nil,
            bannerURL: event.bannerURL,
            sentAt: now
        )
    }
}
