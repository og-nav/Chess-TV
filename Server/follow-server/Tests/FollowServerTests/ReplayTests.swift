import Foundation
import FollowKit
import Testing
@testable import FollowServer

/// The plan's acceptance test for the watcher: a recorded stream in, the exact list of pushes out,
/// and the same stream again after a restart producing nothing.
@Suite("Replay")
struct ReplayTests {

    private func stream() throws -> (pgn: String, round: BroadcastRoundDetail) {
        (try Fixture.text("stream-round-22.pgn"), try Fixture.round("replay-round.json"))
    }

    @Test("The recorded stream produces the expected events")
    func events() async throws {
        let (pgn, round) = try stream()
        let result = try await ReplayRunner().run(pgn: pgn, roundId: round.round.id, roundDetail: round)

        // Four blocks: the first is the baseline, the next three are moves.
        #expect(result.events.map(\.kind) == [.move, .move, .move])
        #expect(result.events.map(\.snapshot.ply) == [38, 39, 40])
        #expect(result.events.map(\.snapshot.san) == ["g5", "Qb3", "g4"])
    }

    @Test("A game follow with move alerts gets one push per move and none for the baseline")
    func pushes() async throws {
        let (pgn, round) = try stream()
        var seed = ReplaySeed()
        seed.follows = [Follow(id: "", target: .game(roundId: round.round.id, gameId: "kbp34ERp"), alerts: FollowAlerts(game: [.start, .move, .end]))]
        let result = try await ReplayRunner().run(pgn: pgn, roundId: round.round.id, roundDetail: round, seed: seed)

        #expect(result.pushes.count == 3)
        #expect(result.pushes.allSatisfy { $0.entry.category == .gameMove })
        #expect(result.pushes.allSatisfy { $0.entry.collapseId == "kbp34ERp" })
        #expect(result.pushes.allSatisfy { $0.entry.threadId == round.round.id })

        let titles = result.pushes.map(\.entry.title)
        #expect(titles == [
            "Wasp 7.16 played 19... g5",
            "Avalanche 4.0.0 played 20. Qb3",
            "Wasp 7.16 played 20... g4",
        ])
        let body = result.pushes[0].entry.body
        #expect(body.contains("TCEC S30"))
        #expect(body.contains("Round 22"))

        // The payload is what the extension will decode, and it carries the position.
        let push = try FollowJSON.pushDecoder.decode(MovePush.self, from: Data(result.pushes[0].entry.payloadJSON.utf8))
        #expect(push.ply == 38)
        #expect(push.pushKind == .move)
        #expect(push.fen.contains(" w "))
        #expect(push.lastMove != nil)
    }

    @Test("The replay report is one JSON line per push")
    func report() async throws {
        let (pgn, round) = try stream()
        var seed = ReplaySeed()
        seed.follows = [Follow(target: .game(roundId: round.round.id, gameId: "kbp34ERp"), alerts: FollowAlerts(game: [.move]))]
        let result = try await ReplayRunner().run(pgn: pgn, roundId: round.round.id, roundDetail: round, seed: seed)
        let lines = ReplayRunner.report(result).split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines.allSatisfy { $0.contains("\"category\":\"GAME_MOVE\"") })
    }

    @Test("A device that follows nothing relevant gets nothing")
    func noFollowers() async throws {
        let (pgn, round) = try stream()
        var seed = ReplaySeed()
        seed.follows = [Follow(target: .tournament(tourId: "some-other-event"), alerts: .tournamentDefaults)]
        let result = try await ReplayRunner().run(pgn: pgn, roundId: round.round.id, roundDetail: round, seed: seed)
        #expect(result.events.count == 3)       // the watcher still saw them
        #expect(result.pushes.isEmpty)          // nobody asked
    }
}

/// The same stream, but driven through the pipeline by hand so that a *restart* can be simulated:
/// the same store, a second pass, and the baseline rule doing its job.
@Suite("Restart and corrections")
struct RestartTests {

    @Test("Replaying the same stream against stored state emits nothing")
    func restartIsSilent() async throws {
        let round = try Fixture.round("replay-round.json")
        let context = RoundContext(round)
        let blocks = PGNStreamSplitter.blocks(in: try Fixture.text("stream-round-22.pgn"))

        let rig = try await TestRig.make()
        defer { Task { await rig.close() } }
        _ = try await rig.device(follows: [Follow(target: .game(roundId: round.round.id, gameId: "kbp34ERp"), alerts: FollowAlerts(game: [.move]))])

        for block in blocks {
            let snapshot = try #require(PGNSnapshot.snapshot(block: block, roundId: round.round.id, context: context))
            _ = try await rig.pipeline.ingest(snapshot: snapshot, context: context, now: rig.clock.value())
            rig.clock.advance(by: 60)
        }
        await rig.outbox.drain()
        let afterFirstPass = await rig.delivery.record().count
        #expect(afterFirstPass == 3)

        // The restart: every game's current PGN arrives again, from the top.
        for block in blocks {
            let snapshot = try #require(PGNSnapshot.snapshot(block: block, roundId: round.round.id, context: context))
            _ = try await rig.pipeline.ingest(snapshot: snapshot, context: context, now: rig.clock.value())
            rig.clock.advance(by: 60)
        }
        await rig.outbox.drain()
        #expect(await rig.delivery.record().count == afterFirstPass)
    }

    @Test("A correction that lowers the ply emits nothing, and the next real move still does")
    func correction() async throws {
        let context = RoundContext.make()
        let rig = try await TestRig.make()
        defer { Task { await rig.close() } }
        _ = try await rig.device(follows: [Follow(target: .game(roundId: "WCHr0002", gameId: "wchGam01"), alerts: FollowAlerts(game: [.move]))])

        _ = try await rig.pipeline.ingest(snapshot: .make(ply: 40), context: context, now: rig.clock.value())
        rig.clock.advance(by: 60)
        _ = try await rig.pipeline.ingest(snapshot: .make(ply: 41), context: context, now: rig.clock.value())
        rig.clock.advance(by: 60)
        _ = try await rig.pipeline.ingest(snapshot: .make(ply: 40), context: context, now: rig.clock.value())   // taken back
        rig.clock.advance(by: 60)
        await rig.outbox.drain()
        #expect(await rig.delivery.record().count == 1)

        // The corrected move is a different move, so it is a different position and a different
        // event. Had the operator retyped the *same* move, the dedupe key would be the same and
        // the device would rightly hear nothing.
        _ = try await rig.pipeline.ingest(
            snapshot: .make(ply: 41, fen: "r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/2N2N2/PPPP1PPP/R1BQK2R b KQkq - 5 4", san: "Nc3"),
            context: context,
            now: rig.clock.value()
        )
        await rig.outbox.drain()
        #expect(await rig.delivery.record().count == 2)
    }

    @Test("A long think is raised once per ply, however many ticks pass")
    func longThinkOncePerPly() async throws {
        let context = RoundContext.make()
        let rig = try await TestRig.make()
        defer { Task { await rig.close() } }
        var follow = Follow(target: .game(roundId: "WCHr0002", gameId: "wchGam01"), alerts: FollowAlerts(game: [.longThink]))
        follow.alerts.longThinkMinutes = 10
        _ = try await rig.device(follows: [follow])

        // Two observed plies, so the second is eligible.
        _ = try await rig.pipeline.ingest(snapshot: .make(ply: 40), context: context, now: rig.clock.value())
        rig.clock.advance(by: 30)
        _ = try await rig.pipeline.ingest(snapshot: .make(ply: 41), context: context, now: rig.clock.value())

        rig.clock.advance(by: 300)
        _ = try await rig.pipeline.longThinkTick(snapshots: [.make(ply: 41)], context: context, now: rig.clock.value())
        await rig.outbox.drain()
        #expect(await rig.delivery.record().isEmpty)      // five minutes is not ten

        rig.clock.advance(by: 400)
        for _ in 0..<5 {
            _ = try await rig.pipeline.longThinkTick(snapshots: [.make(ply: 41)], context: context, now: rig.clock.value())
            rig.clock.advance(by: 30)
        }
        await rig.outbox.drain()
        let pushes = await rig.delivery.record()
        #expect(pushes.count == 1)
        #expect(pushes[0].entry.title.contains("has been thinking"))
    }

    @Test("A restart cannot invent a long think for a ply it did not watch arrive")
    func longThinkAfterRestart() async throws {
        let context = RoundContext.make()
        let rig = try await TestRig.make()
        defer { Task { await rig.close() } }
        var follow = Follow(target: .game(roundId: "WCHr0002", gameId: "wchGam01"), alerts: FollowAlerts(game: [.longThink]))
        follow.alerts.longThinkMinutes = 10
        _ = try await rig.device(follows: [follow])

        // First sight only: the player may have moved into this position an hour ago.
        _ = try await rig.pipeline.ingest(snapshot: .make(ply: 41), context: context, now: rig.clock.value())
        rig.clock.advance(by: 3600)
        _ = try await rig.pipeline.longThinkTick(snapshots: [.make(ply: 41)], context: context, now: rig.clock.value())
        await rig.outbox.drain()
        #expect(await rig.delivery.record().isEmpty)
    }

    @Test("A dead token disables the device and stops the next push")
    func tokenGone() async throws {
        let context = RoundContext.make()
        let rig = try await TestRig.make()
        defer { Task { await rig.close() } }
        let token = String(repeating: "a", count: 64)
        _ = try await rig.device(apnsToken: token, follows: [Follow(target: .game(roundId: "WCHr0002", gameId: "wchGam01"), alerts: FollowAlerts(game: [.move]))])
        await rig.delivery.markDead(token)

        _ = try await rig.pipeline.ingest(snapshot: .make(ply: 40), context: context, now: rig.clock.value())
        rig.clock.advance(by: 60)
        _ = try await rig.pipeline.ingest(snapshot: .make(ply: 41), context: context, now: rig.clock.value())
        await rig.outbox.drain()

        #expect(await rig.delivery.record().isEmpty)
        let devices = try await rig.store.deviceContexts()
        #expect(devices.isEmpty)
    }
}
