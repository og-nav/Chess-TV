// What a new follow of one kind starts with, and the offer to apply it to the ones already made.
//
// The offer only appears once something on this screen has actually changed, and it says how
// many follows it would rewrite. Applying it is a normal edit: it goes through the same queue as
// a switch flipped by hand, one `PATCH` per follow, collapsed if the phone is offline.
import SwiftUI
import FollowKit

struct FollowDefaultsScreen: View {
    let kind: FollowKind

    @Environment(AppEnvironment.self) private var app
    /// True once a switch on this screen has been touched, which is what the offer waits for.
    @State private var hasEdited = false
    @State private var appliedCount: Int?

    var body: some View {
        Form {
            AlertSwitchList(alerts: alertsBinding, kind: kind)

            if hasEdited, affectedCount > 0 {
                Section {
                    Button {
                        InteractionFeedback.confirmation()
                        appliedCount = app.follows.applyDefaults(app.follows.preferences.defaults(for: kind), toExisting: kind)
                    } label: {
                        Label(
                            "Apply to \(affectedCount) existing \(kind.singular) follow\(affectedCount == 1 ? "" : "s")",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .listRowBackground(Palette.panel)
                    .accessibilityIdentifier(UIID.FollowDetail.applyToExisting)
                } footer: {
                    Text("Without this, the change only affects \(kind.singular) follows you make from now on.")
                }
            }

            if let appliedCount {
                Section {
                    Label(
                        appliedCount == 0 ? "Nothing to change" : "Updated \(appliedCount) follow\(appliedCount == 1 ? "" : "s")",
                        systemImage: "checkmark.circle"
                    )
                    .foregroundStyle(Palette.accent)
                    .listRowBackground(Palette.panel)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var affectedCount: Int {
        app.follows.countAffectedByDefaults(app.follows.preferences.defaults(for: kind), kind: kind)
    }

    /// The store is the only copy: it is `@Observable`, so reading it back is how a change made
    /// on the watch or by a sync shows up here without a second piece of state to go stale.
    private var alertsBinding: Binding<FollowAlerts> {
        Binding(
            get: { app.follows.preferences.defaults(for: kind) },
            set: { newValue in
                hasEdited = true
                appliedCount = nil
                var preferences = app.follows.preferences
                preferences.setDefaults(newValue, for: kind)
                preferences.timeZoneIdentifier = TimeZone.current.identifier
                app.follows.setPreferences(preferences)
            }
        )
    }
}
