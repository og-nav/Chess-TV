import SwiftUI
import ChessCore
import LichessKit
import GameSessionKit
import UIKit

/// TV platform services wrap the shared, observable game session.
@Observable @MainActor @dynamicMemberLookup
final class AppModel {
    let session: GameSession
    let music: MusicController
    var showingSettings = false
    init(settings: AppSettings = AppSettings(), streamer: any SourceStreaming = GameSourceStreamer(), arenas: any ArenaDetailing = ArenaClient()) {
        session = GameSession(settings: settings, streamer: streamer, arenas: arenas)
        music = MusicController(settings: settings)
    }
    subscript<T>(dynamicMember keyPath: KeyPath<GameSession, T>) -> T { session[keyPath: keyPath] }
    func start() {
        showingSettings = ProcessInfo.processInfo.arguments.contains("-showSettings")
        applyIdleTimer(); session.start(); music.start()
    }
    func teardown() { session.teardown(); music.teardown() }
    func applyIdleTimer() { UIApplication.shared.isIdleTimerDisabled = session.settings.keepTVOn }
    func scenePhaseChanged(to phase: ScenePhase) {
        session.scenePhaseChanged(to: phase)
        if phase == .background { music.enterBackground() }
        if phase == .active { music.becameActive() }
    }
    func open(_ destination: GameDestination) { session.open(destination) }
    func open(source: GameSource, title: String? = nil) { session.open(source: source, title: title) }
    func close() { session.close() }
    func enqueue(_ alerts: [TournamentAlert]) { session.enqueue(alerts) }
    func toggleEngine() { session.toggleEngine() }
    func setEngineDepth(_ depth: EngineDepth) { session.setEngineDepth(depth) }
    func toggleFlipBoard() { session.toggleFlipBoard() }
    func shutdownEngine() async { await session.shutdownEngine() }
    func displayedClock(_ color: PieceColor) -> String? { session.displayedClock(color) }
    func clockIsEstimated(_ color: PieceColor) -> Bool { session.clockIsEstimated(color) }
    func federation(for color: PieceColor) -> String? { session.federation(for: color) }
    func flag(for color: PieceColor) -> String? { session.flag(for: color) }
    func fidePlayer(for color: PieceColor) -> FIDEPlayer? { session.fidePlayer(for: color) }
    func portraitURL(for color: PieceColor) -> URL? { session.portraitURL(for: color) }
    func photoCredit(for color: PieceColor) -> String? { session.photoCredit(for: color) }
    func arenaTimeLeftText(at now: ContinuousClock.Instant) -> String? { session.arenaTimeLeftText(at: now) }
    var arenaTimeLeftText: String? { session.arenaTimeLeftText }
    static let arenaStandingsMaxInterval = GameSession.arenaStandingsMaxInterval
    static func arenaStandingsDelay(afterFailures failures: Int) -> Duration { GameSession.arenaStandingsDelay(afterFailures: failures) }
}
