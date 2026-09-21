// Settings → Notifications: the one screen that answers "what will this app send me".
//
// Everything here is enforced on the server, in the device's own time zone, so a muted phone
// costs no push at all and the watch agrees with the phone without a second copy of the rules.
// The screen's job is to be honest: permission, reachability, and a count of what actually
// arrived, so a silent failure and an over-eager follow are both visible.
import SwiftUI
import FollowKit

struct NotificationSettingsScreen: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(Navigator.self) private var navigator

    /// What "Reset push notifications" is doing, and what it ended up saying.
    private enum ResetState: Equatable {
        case idle
        case working
        case finished(String, ok: Bool)
    }

    @State private var reset: ResetState = .idle

    var body: some View {
        Form {
            permissionSection
            resetSection
            serverSection
            muteSection
            quietHoursSection
            defaultsSection
            activitySection
        }
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !AppEnvironment.isUnderTest else { return }
            await app.registrar.refreshPermission()
            await app.alerts.refresh(client: app.client)
            app.server.probe(using: app.client)
        }
    }

    // MARK: - Permission

    private var permissionSection: some View {
        Section {
            LabeledContent("Permission") {
                Text(app.registrar.permission.title)
                    .foregroundStyle(app.registrar.permission.allowsPush ? Palette.accent : Palette.amber)
            }
            .listRowBackground(Palette.panel)

            switch app.registrar.permission {
            case .notDetermined:
                Button("Allow notifications") {
                    InteractionFeedback.tap()
                    Task { await app.registrar.requestPermission() }
                }
                .listRowBackground(Palette.panel)
                .accessibilityIdentifier(UIID.Notifications.allow)
            case .denied:
                Button("Open iOS Settings") { InteractionFeedback.tap(); app.registrar.openSystemSettings() }
                    .listRowBackground(Palette.panel)
                    .accessibilityIdentifier(UIID.Notifications.openSystemSettings)
            case .authorized, .provisional, .unavailable:
                EmptyView()
            }

            LabeledContent("This install") {
                Text(registrationText)
                    .foregroundStyle(registrationColor)
            }
            .listRowBackground(Palette.panel)
        } header: {
            Text("Permission")
        } footer: {
            Text(app.registrar.permission.detail)
        }
    }

    private var registrationText: String {
        switch app.registrar.status {
        case .idle: "Not registered"
        case .noServer: "No server"
        case .waitingForToken: "Waiting for a push token"
        case .registering: "Registering\u{2026}"
        case .registered: "Registered"
        case .failed(let message): message
        }
    }

    private var registrationColor: Color {
        switch app.registrar.status {
        case .registered: Palette.accent
        case .failed: Palette.alert
        default: Palette.muted
        }
    }

    // MARK: - Starting again

    /// The one button for "alerts stopped arriving".
    ///
    /// Everything that can go stale between this phone and the server is one thing: the identity.
    /// iOS can issue a new device token the app never noticed, the server can lose or rotate the
    /// row this install registered as, and a follow list synced against the old row means nothing
    /// to the new one. So this drops the lot and builds it back in order -- permission, identity,
    /// token, follow list -- rather than offering four half-cures nobody can choose between.
    private var resetSection: some View {
        Section {
            Button {
                startReset()
            } label: {
                HStack {
                    Text("Reset push notifications")
                    Spacer(minLength: 8)
                    if reset == .working {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(reset == .working)
            .listRowBackground(Palette.panel)
            .accessibilityIdentifier(UIID.Notifications.resetPush)

            if case .finished(let message, let ok) = reset {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(ok ? Palette.accent : Palette.alert)
                    .listRowBackground(Palette.panel)
                    .accessibilityIdentifier(UIID.Notifications.resetPushResult)
            }
        } footer: {
            Text("Use this if alerts stop arriving.")
        }
    }

    private func startReset() {
        InteractionFeedback.tap()
        reset = .working
        Task {
            let status = await app.resetPushRegistration()
            reset = .finished(
                Self.resultLine(for: status, permission: app.registrar.permission),
                ok: status == .registered
            )
        }
    }

    /// The one line the button leaves behind. A failure is quoted as the registrar worded it:
    /// "an error occurred" is the sentence that makes people delete the app.
    static func resultLine(for status: DeviceRegistrar.Status, permission: PushPermission) -> String {
        switch status {
        case .registered:
            "Registered again"
        case .failed(let message):
            message
        case .registering:
            "Still waiting for the alert service. Registration will retry automatically."
        case .waitingForToken:
            "Still waiting for a push token from iOS"
        case .noServer:
            "There is no push server to register with"
        case .idle:
            permission.allowsPush
                ? "Still waiting for a push token from iOS"
                : "Notifications are off for Chess TV, so there is nothing to register"
        }
    }

    // MARK: - Server

    /// Not a setting any more: the address is built in. The line stays because a service that
    /// cannot be reached is the difference between "no alerts yet" and "no alerts ever", and
    /// that is worth saying out loud.
    private var serverSection: some View {
        Section {
            LabeledContent("Alert service") {
                Text(app.server.reachabilityText)
                    .foregroundStyle(healthColor)
            }
            .listRowBackground(Palette.panel)
        } footer: {
            Text("Alerts are sent by the Chess TV service. If it cannot be reached, nothing will arrive \u{2014} which is why this line is here.")
        }
    }

    private var healthColor: Color {
        switch app.server.reachability {
        case .reachable: Palette.accent
        case .unreachable: Palette.alert
        default: Palette.muted
        }
    }

    // MARK: - Mute and quiet hours

    private var muteSection: some View {
        Section {
            Toggle("Mute everything", isOn: preference(\.muteAll).withSelectionFeedback())
                .listRowBackground(Palette.panel)
                .accessibilityIdentifier(UIID.Notifications.muteAll)
        } footer: {
            Text("Muting is held on the server, so a muted phone costs no push at all.")
        }
    }

    private var quietHoursSection: some View {
        Section {
            Toggle("Quiet hours", isOn: quietHoursEnabled.withSelectionFeedback())
                .listRowBackground(Palette.panel)
                .accessibilityIdentifier(UIID.Notifications.quietHours)

            if app.follows.preferences.hasQuietHours {
                DatePicker("From", selection: quietTime(\.quietHoursStart).withSelectionFeedback(), displayedComponents: .hourAndMinute)
                    .listRowBackground(Palette.panel)
                    .accessibilityIdentifier(UIID.Notifications.quietFrom)
                DatePicker("To", selection: quietTime(\.quietHoursEnd).withSelectionFeedback(), displayedComponents: .hourAndMinute)
                    .listRowBackground(Palette.panel)
                    .accessibilityIdentifier(UIID.Notifications.quietTo)
                Toggle("Let game results through", isOn: preference(\.gameEndIgnoresQuietHours).withSelectionFeedback())
                    .listRowBackground(Palette.panel)
                    .accessibilityIdentifier(UIID.Notifications.resultsThrough)
            }
        } header: {
            Text("Quiet hours")
        } footer: {
            if let start = app.follows.preferences.quietHoursStart, let end = app.follows.preferences.quietHoursEnd, QuietHours.wrap(start) == QuietHours.wrap(end) {
                Text("The two times are the same, so no window is quiet. Move one of them to set the hours.")
            } else if let start = app.follows.preferences.quietHoursStart, let end = app.follows.preferences.quietHoursEnd {
                Text("Nothing is sent between \(QuietHours.rangeText(start: start, end: end)) in \(app.follows.preferences.timeZoneIdentifier).")
            } else {
                Text("A window each night when nothing is sent, in this phone\u{2019}s time zone.")
            }
        }
    }

    // MARK: - Defaults

    private var defaultsSection: some View {
        Section {
            ForEach(FollowKind.allCases, id: \.self) { kind in
                NavigationLink(value: MobileRoute.followDefaults(kind: kind)) {
                    LabeledContent(kind.title, value: app.follows.preferences.defaults(for: kind).summary(for: kind))
                }
                .listRowBackground(Palette.panel)
                .accessibilityIdentifier(UIID.Notifications.defaults(kind.rawValue))
            }
        } header: {
            Text("What new follows send")
        } footer: {
            Text("These are the switches a follow starts with. Each follow can then be changed on its own, and the per-follow switches win.")
        }
    }

    // MARK: - Activity

    private var activitySection: some View {
        Section {
            LabeledContent("Recent alerts", value: AlertLog.summary(count: app.alerts.last24Hours))
                .listRowBackground(Palette.panel)
            Button("Open Following") { InteractionFeedback.tap(); navigator.tab = .following }
                .listRowBackground(Palette.panel)
                .accessibilityIdentifier(UIID.Notifications.openFollowing)
        } footer: {
            Text("Server count reflects accepted sends; delivery depends on iOS. When the server is unavailable, this uses the alerts recorded on this phone.")
        }
    }

    // MARK: - Bindings

    /// Every write goes through the store, which saves it and queues the `PUT`.
    private func preference(_ keyPath: WritableKeyPath<NotificationPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { app.follows.preferences[keyPath: keyPath] },
            set: { newValue in
                var preferences = app.follows.preferences
                preferences[keyPath: keyPath] = newValue
                preferences.timeZoneIdentifier = TimeZone.current.identifier
                app.follows.setPreferences(preferences)
            }
        )
    }

    private var quietHoursEnabled: Binding<Bool> {
        Binding(
            get: { app.follows.preferences.hasQuietHours },
            set: { isOn in
                var preferences = app.follows.preferences
                preferences.quietHoursStart = isOn ? QuietHours.defaultStart : nil
                preferences.quietHoursEnd = isOn ? QuietHours.defaultEnd : nil
                preferences.timeZoneIdentifier = TimeZone.current.identifier
                app.follows.setPreferences(preferences)
            }
        )
    }

    private func quietTime(_ keyPath: WritableKeyPath<NotificationPreferences, Int?>) -> Binding<Date> {
        Binding(
            get: { QuietHours.date(fromMinutes: app.follows.preferences[keyPath: keyPath] ?? 0) },
            set: { date in
                var preferences = app.follows.preferences
                preferences[keyPath: keyPath] = QuietHours.minutes(from: date)
                preferences.timeZoneIdentifier = TimeZone.current.identifier
                app.follows.setPreferences(preferences)
            }
        )
    }
}
