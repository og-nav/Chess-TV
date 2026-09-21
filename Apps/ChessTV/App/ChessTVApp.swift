import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@main
struct ChessTVApp: App {
    @State private var model: AppModel
    /// The navigation stack above the home screen. Back (Menu) pops it, which is the default.
    @State private var path: [Route] = []
    @Environment(\.scenePhase) private var scenePhase

    /// The `User-Agent` is set before `AppModel` is built, because the model's clients take a
    /// shared `URLSession` as a default argument and so create one the moment it exists. That
    /// is also why `model` has no inline default: a stored property's default value would be
    /// evaluated before anything in here runs.
    init() {
        // Fixture mode first: it has to be in place before any client builds a URLSession.
        FixtureMode.activateIfRequested()
        AppIdentity.configurePackages()
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.environment["CHESSTV_TESTING"] == "1" {
                // Hosted unit tests own their injected sessions. Starting the real engine
                // here would redirect the test process's stdout into Stockfish's UCI pipe.
                Color.clear
            } else {
            NavigationStack(path: $path) {
                HomeScreen()
                    .navigationDestination(for: Route.self) { route in
                        switch route {
                        case .boards(let roundId, let tournamentName):
                            BoardListScreen(roundId: roundId, tournamentName: tournamentName)
                        case .game(let destination):
                            GameScreen(destination: destination)
                        }
                    }
            }
            .environment(model)
            .task {
                model.start()
                let routes = LaunchArguments.routes()
                if !routes.isEmpty, path.isEmpty { path = routes }
            }
            .task { await waitForTermination() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(to: phase)
        }
    }

    /// The streamer is retired once, and Stockfish is stopped, when the app is actually going
    /// away. The engine matters here: its UCI loop is a C++ thread, and a process that exits
    /// with one still running aborts instead of quitting.
    private func waitForTermination() async {
        #if canImport(UIKit)
        for await _ in NotificationCenter.default.notifications(named: UIApplication.willTerminateNotification) {
            model.teardown()
            await model.shutdownEngine()
            return
        }
        #endif
    }
}
