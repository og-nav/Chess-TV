// Settings: Board, Engine, Notifications, About.
//
// The board and engine rows are the TV's settings with the same names and the same defaults, so
// the two apps feel like one product; the depth row says what deeper search costs on a phone,
// as the TV's says what it costs a fanless box.
//
// About used to be a screen of its own. It said a handful of facts about the build and then
// repeated, less completely, what Credits now says properly on both platforms — so the facts
// moved here, where they are one scroll away, and the attributions moved to Credits. One place
// each.
import SwiftUI
import ChessUI
import GameSessionKit

struct SettingsScreen: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(Navigator.self) private var navigator

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section("Board") {
                Picker("Board colours", selection: $settings.boardThemeName.withSelectionFeedback()) {
                    ForEach(BoardTheme.all, id: \.name) { theme in
                        Text(theme.name).tag(theme.name)
                    }
                }
                .accessibilityIdentifier(UIID.Settings.boardTheme)
                Picker("Pieces", selection: $settings.pieceSet.withSelectionFeedback()) {
                    ForEach(PieceSet.allCases, id: \.self) { set in
                        Text(set.displayName).tag(set)
                    }
                }
                .accessibilityIdentifier(UIID.Settings.pieces)
                Toggle("Coordinates", isOn: $settings.coordinates.withSelectionFeedback())
                    .accessibilityIdentifier(UIID.Settings.coordinates)
                Toggle("Sounds", isOn: $settings.sounds.withSelectionFeedback())
                    .accessibilityIdentifier(UIID.Settings.sounds)
                Toggle("Follow the featured player", isOn: $settings.followFeaturedPlayer.withSelectionFeedback())
                    .accessibilityIdentifier(UIID.Settings.followFeatured)
            }
            .listRowBackground(Palette.panel)

            Section {
                Toggle("Stockfish", isOn: engineBinding.withSelectionFeedback())
                    .accessibilityIdentifier(UIID.Settings.engine)
                Picker("Search depth", selection: depthBinding.withSelectionFeedback()) {
                    ForEach(EngineDepth.allCases, id: \.self) { depth in
                        Text("\(depth.displayName) \u{00B7} \(depth.depth)").tag(depth)
                    }
                }
                .disabled(!app.settings.engineEnabled)
                .accessibilityIdentifier(UIID.Settings.depth)
            } header: {
                Text("Engine")
            } footer: {
                Text("Stockfish runs on this device. Deeper search is sharper and warms the phone; the search stops on its own when the app leaves the screen or the phone gets hot.")
            }
            .listRowBackground(Palette.panel)

            Section("Notifications") {
                NavigationLink(value: MobileRoute.notifications) {
                    LabeledContent("Alerts", value: notificationSummary)
                }
                .accessibilityIdentifier(UIID.Settings.notifications)
            }
            .listRowBackground(Palette.panel)

            Section {
                LabeledContent("Version", value: MobileIdentity.appVersion)
                LabeledContent("Identifies as", value: MobileIdentity.userAgent)
                LabeledContent("Contact", value: MobileIdentity.contact)
                NavigationLink("Credits", value: MobileRoute.credits)
                    .accessibilityIdentifier(UIID.Settings.credits)
            } header: {
                Text("About")
            } footer: {
                Text("Every request to Lichess carries that name and address, as their API policy asks.")
            }
            .listRowBackground(Palette.panel)

            Section {
                Text("No accounts, no ads, no analytics.")
                Link("Privacy policy", destination: PublishedService.privacyPolicy)
                Link("Support", destination: PublishedService.support)
            } header: {
                Text("Privacy")
            }
            .listRowBackground(Palette.panel)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .navigationTitle("Settings")
        // The notification extensions and the widget draw boards too, out of the app group, so a
        // colour chosen here has to reach them before the next push arrives.
        .onChange(of: app.settings.boardThemeName) { _, _ in app.publishAppearance() }
        .onChange(of: app.settings.pieceSet) { _, _ in app.publishAppearance() }
        .onChange(of: app.settings.coordinates) { _, _ in app.publishAppearance() }
    }

    private var notificationSummary: String {
        if app.follows.preferences.muteAll { return "Muted" }
        if !app.registrar.permission.allowsPush { return app.registrar.permission.title }
        return "\(app.follows.follows.count) follow\(app.follows.follows.count == 1 ? "" : "s")"
    }

    /// The engine switch goes through `GameSession` rather than the settings object, because
    /// turning it on has to start Stockfish and re-evaluate the board on screen.
    private var engineBinding: Binding<Bool> {
        Binding(
            get: { app.settings.engineEnabled },
            set: { _ in app.session.toggleEngine() }
        )
    }

    private var depthBinding: Binding<EngineDepth> {
        Binding(
            get: { app.settings.engineDepth },
            set: { app.session.setEngineDepth($0) }
        )
    }
}
