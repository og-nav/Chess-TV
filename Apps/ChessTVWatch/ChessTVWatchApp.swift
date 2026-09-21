// Chess TV on the wrist.
//
// What this app is: a deliberate check on a game you follow. A list, a board, and the switches
// that silence an event without reaching for the phone.
//
// Follows arrive over WatchConnectivity; the list polls round snapshots and the open board
// streams one game's PGN for SAN and clock updates. Both stop when the app leaves the foreground.
// No engine or background stream runs on the Watch.
import SwiftUI
import UserNotifications
import LichessKit

@main
struct ChessTVWatchApp: App {

    private var sync: WatchSyncStore { WatchSyncStore.shared }
    @State private var follows = WatchFollowsModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        WatchIdentity.configurePackages()
        PushCategories.register()
        WatchSyncStore.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(sync: sync, model: follows)
                .tint(ChessTVPalette.accent)
        }
        .onChange(of: scenePhase) { _, phase in
            // Polling is a foreground-only thing: watchOS would not let us hold a connection
            // anyway, and a wrist-down watch asking Lichess for a round every ten seconds is
            // exactly the traffic the API policy asks apps not to make.
            switch phase {
            case .active: follows.start(with: sync.payload)
            default: follows.stop()
            }
        }
    }
}

/// The `User-Agent` this app sends, matching the phone and the TV.
enum WatchIdentity {
    static let contact = "zzzlabshq@gmail.com"

    static var version: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return "0.1" }
        return value
    }

    static var userAgent: String { "ChessTV/\(version) (\(contact))" }

    static func configurePackages() {
        LichessConfig.configure(userAgent: userAgent)
        watchLog.notice("Identifying as \(userAgent, privacy: .public)")
    }
}
