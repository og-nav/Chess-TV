// One follow's alerts, and the button that ends it.
import SwiftUI
import FollowKit

struct FollowDetailScreen: View {
    let target: FollowTarget

    @Environment(AppEnvironment.self) private var app
    @Environment(Navigator.self) private var navigator
    @Environment(\.dismiss) private var dismiss

    private var follow: Follow? { app.follows.follow(for: target) }

    var body: some View {
        Form {
            if let follow, let binding = alertsBinding {
                Section {
                    LabeledContent("Following", value: follow.followKind.singular.capitalized)
                        .listRowBackground(Palette.panel)
                    LabeledContent("Since", value: follow.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .listRowBackground(Palette.panel)
                } footer: {
                    if !app.follows.hasServer {
                        Text("These switches are saved on this phone. The alert service is unavailable, so nothing will be sent.")
                            .foregroundStyle(Palette.amber)
                    }
                }

                AlertSwitchList(alerts: binding, kind: follow.followKind)

                Section {
                    Button("Unfollow", systemImage: "bell.slash", role: .destructive) {
                        InteractionFeedback.confirmation()
                        app.follows.remove(target)
                        dismiss()
                    }
                    .listRowBackground(Palette.panel)
                    .accessibilityIdentifier(UIID.FollowDetail.unfollow)
                }
            } else {
                ContentUnavailableView(
                    "This follow is gone",
                    systemImage: "bell.slash",
                    description: Text("This item is no longer in your follows.")
                )
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .navigationTitle(follow.map { "\($0.followKind.singular.capitalized) alerts" } ?? "Follow")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Reads and writes the store, which is `@Observable`: no second copy to go stale, so a
    /// change made on the watch and reconciled while this screen is open just appears.
    private var alertsBinding: Binding<FollowAlerts>? {
        guard let follow else { return nil }
        return Binding(
            get: { app.follows.follow(for: target)?.alerts ?? follow.alerts },
            set: { alerts in
                guard let current = app.follows.follow(for: target) else { return }
                app.follows.setAlerts(alerts, for: current.id)
            }
        )
    }
}
