import Foundation
import Testing
import ChessCore
import FollowKit
@testable import ChessTVMobile

private final class SurfaceBundleMarker: NSObject {}

@Suite("Push surfaces use the server wire contract")
struct PushSurfaceTests {
    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try #require(Bundle(for: SurfaceBundleMarker.self).url(forResource: name, withExtension: "apns"))
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    @Test(arguments: ["push-start", "push-move", "push-longthink", "push-end"])
    func boardAlertsDecode(_ name: String) throws {
        let dictionary = try fixture(name)
        let push = try #require(ChessPush.decode(userInfo: dictionary))
        guard case .game(let move) = push else { Issue.record("Expected board alert"); return }
        #expect((try? Position(fen: move.fen)) != nil)
        #expect(move.sentAt.timeIntervalSince1970 > 1_700_000_000)
        #expect(!PushWordingBuilder.wording(for: push).title.isEmpty)
    }

    @Test(arguments: ["push-tournament-soon", "push-round-live", "push-round-finished", "push-tournament-finished"])
    func tournamentAlertsDecode(_ name: String) throws {
        let push = try #require(ChessPush.decode(userInfo: fixture(name)))
        guard case .tournament(let event) = push else { Issue.record("Expected tournament alert"); return }
        #expect(!event.tourId.isEmpty)
        #expect(!PushWordingBuilder.wording(for: push).title.isEmpty)
    }

    @Test(arguments: ["activity-update", "activity-end"])
    func activityDatesAgreeWithAPNSTimestamp(_ name: String) throws {
        let dictionary = try fixture(name)
        let aps = try #require(dictionary["aps"] as? [String: Any])
        let content = try #require(aps["content-state"] as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: content)
        let serverState = try FollowJSON.activityDecoder.decode(LiveActivityState.self, from: data)
        let systemState = try JSONDecoder().decode(ChessGameActivityState.self, from: data)
        #expect(systemState.asOf == serverState.asOf)
        #expect(systemState.fen == serverState.fen)
        #expect(serverState.asOf.timeIntervalSince1970 == (aps["timestamp"] as? Double))
    }

    @Test func bannerHostRulesRejectSuffixAndCleartext() throws {
        #expect(BannerDownloader.isAllowed(try #require(URL(string: "https://image.lichess1.org/banner.webp"))))
        for value in ["http://image.lichess1.org/a", "https://image.lichess1.org.evil.example/a", "https://127.0.0.1/a"] {
            #expect(!BannerDownloader.isAllowed(try #require(URL(string: value))))
        }
    }

    @Test @MainActor func boundedBoardRenderingAndInvalidFENFallback() throws {
        let options = BoardImageRenderer.Options(pixelSize: 96, appearance: .fallback)
        let board = try #require(BoardImageRenderer.render(fen: Position.standard.fen, lastMoveUCI: nil, options: options))
        #expect(board.width == 96 && board.height == 96)
        #expect(BoardImageRenderer.render(fen: "invalid", lastMoveUCI: nil, options: options) == nil)
    }
}

@Suite("Durable activity registration")
struct ActivityQueueTests {
    private let host = "https://chesstv.zzzlabs.dev"

    @Test func rotationDuringAwaitDoesNotAcknowledgeNewToken() {
        var queue = ActivityWorkQueue()
        let old = PendingActivityWork(kind: .register, roundId: "round", gameId: "game", activityToken: "old", server: host)
        queue.enqueue(old)
        let newer = PendingActivityWork(kind: .register, roundId: "round", gameId: "game", activityToken: "new", server: host)
        queue.enqueue(newer)
        queue.remove(old)
        #expect(queue.items.count == 1)
        #expect(queue.items.first?.activityToken == "new")
        let oldWasCurrent = queue.recordFailure(of: old)
        #expect(!oldWasCurrent)
        #expect(queue.items.first?.attempts == 0)
    }

    @Test func transientFailureNeverDiscardsAnEnd() {
        var queue = ActivityWorkQueue()
        let end = PendingActivityWork(kind: .end, gameId: "game", server: host)
        queue.enqueue(end)
        for _ in 0..<30 {
            let kept = queue.recordFailure(of: end)
            #expect(kept)
        }
        #expect(queue.items.count == 1)
        #expect(queue.items.first?.attempts == 30)
    }

    @Test func unpinSupersedesInFlightRegistrationAndSurvivesRelaunch() throws {
        var queue = ActivityWorkQueue()
        let registration = PendingActivityWork(kind: .register, roundId: "round", gameId: "game", activityToken: "token", server: host)
        queue.enqueue(registration)
        queue.enqueue(PendingActivityWork(kind: .end, gameId: "game", server: host))
        queue.remove(registration)
        let restored = try FollowJSON.decoder.decode(ActivityWorkQueue.self, from: FollowJSON.encoder.encode(queue))
        #expect(restored.items.count == 1)
        #expect(restored.items.first?.kind == .end)
        #expect(restored.contains(queue.items[0]))
        #expect(!restored.contains(registration))
    }

    @Test func hostChangeCannotReplayOldTokens() {
        var queue = ActivityWorkQueue()
        queue.enqueue(PendingActivityWork(kind: .register, roundId: "round", gameId: "game", activityToken: "token", server: host))
        queue.keep(server: "https://other.example")
        #expect(queue.isEmpty)
    }

    @Test func manyOfflineUnpinsRemainDurable() {
        var queue = ActivityWorkQueue()
        for index in 0..<20 { queue.enqueue(PendingActivityWork(kind: .end, gameId: "game-\(index)", server: host)) }
        #expect(queue.items.count == 20)
    }

    @Test func bannerRedirectsRevalidateEveryHop() async throws {
        let allowed = try #require(URL(string: "https://image.lichess1.org/a"))
        let refused = try #require(URL(string: "https://example.com/a"))
        let collector = CappedDownload(cap: 32)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: allowed)
        let response = try #require(HTTPURLResponse(url: allowed, statusCode: 302, httpVersion: nil, headerFields: nil))
        let result = await collector.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: refused))
        #expect(result == nil)

        let chain = CappedDownload(cap: 32)
        for _ in 0..<BannerDownloader.maximumRedirects {
            let next = await chain.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: allowed))
            #expect(next != nil)
        }
        let excessive = await chain.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: allowed))
        #expect(excessive == nil)
    }

    @Test func activityExpiryRenewalRespectsDismissalAndGameEnd() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let expiry = start.addingTimeInterval(8 * 60 * 60)
        #expect(LiveActivityController.mayRenew(systemEnded: true, finished: false, startedAt: start, now: expiry))
        #expect(!LiveActivityController.mayRenew(systemEnded: true, finished: false, startedAt: start, now: expiry.addingTimeInterval(-1)))
        #expect(!LiveActivityController.mayRenew(systemEnded: false, finished: false, startedAt: start, now: expiry))
        #expect(!LiveActivityController.mayRenew(systemEnded: true, finished: true, startedAt: start, now: expiry))
        #expect(!LiveActivityController.mayRenew(systemEnded: true, finished: false, startedAt: nil, now: expiry))
    }

    @Test func alreadyCancelledBannerResumesWithoutDownloading() async throws {
        let url = try #require(URL(string: "https://image.lichess1.org/a"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await CappedDownload.body(of: url, cap: 32, userAgent: "ChessTV-tests")
        }
        #expect(await task.value == nil)
    }
}
