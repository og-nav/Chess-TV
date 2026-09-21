// The Follow control, used on the game screen, the boards wall and the tournament screen.
//
// Three states worth distinguishing, and the button says which one it is in:
//   * not followable — a Lichess TV channel has no lasting board, and saying so is better than
//     a disabled button with no explanation;
//   * followed — tapping opens the switch list rather than silently unfollowing, because a
//     follow now has six switches and losing them to a fat thumb would be rude;
//   * followed with no server — the follow is kept, and the caption says no alert will arrive.
import SwiftUI
import FollowKit

struct FollowButton: View {
    let followability: Followability
    /// The accessibility identifier for whichever button is showing, so a UI test finds it in
    /// every state.
    var identifier: String = UIID.Game.follow
    /// Called with the stable follow target after a tap that opened or created one.
    var onOpenDetail: ((FollowTarget) -> Void)?

    @Environment(AppEnvironment.self) private var app
    @State private var showingUnsupported = false

    var body: some View {
        switch followability {
        case .unsupported(let reason):
            Button {
                InteractionFeedback.tap()
                showingUnsupported = true
            } label: {
                Label("Follow", systemImage: "bell.slash")
            }
            .buttonStyle(.bordered)
            .tint(Palette.faint)
            .accessibilityHint(reason)
            .accessibilityIdentifier(identifier)
            .alert("Can\u{2019}t follow this", isPresented: $showingUnsupported) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(reason)
            }

        case .followable(let target):
            if let follow = app.follows.follow(for: target) {
                Button {
                    InteractionFeedback.tap()
                    onOpenDetail?(follow.target)
                } label: {
                    Label("Following", systemImage: "bell.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .foregroundStyle(Palette.ground)
                .accessibilityHint("Opens the alerts for this follow")
                .accessibilityIdentifier(identifier)
                .contextMenu {
                    Button("Unfollow", systemImage: "bell.slash", role: .destructive) {
                        InteractionFeedback.confirmation()
                        app.follows.remove(id: follow.id)
                    }
                }
            } else {
                Button {
                    InteractionFeedback.confirmation()
                    let follow = app.follows.add(target)
                    askForPermissionIfThisIsTheFirstFollow()
                    onOpenDetail?(follow.target)
                } label: {
                    Label("Follow", systemImage: "bell")
                }
                .buttonStyle(.bordered)
                .tint(Palette.accent)
                .accessibilityHint(app.follows.hasServer
                    ? "Sends alerts for this to your phone"
                    : "Saves this on the phone. No push server is configured, so no alerts will arrive.")
                .accessibilityIdentifier(identifier)
            }
        }
    }

    /// The one moment asking for notification permission makes sense: the user has just said they
    /// want to be told about something. Asking at launch, before there is anything to be told
    /// about, is the prompt everyone refuses.
    ///
    /// Not asked when there is no server, because nothing could arrive even if they said yes.
    private func askForPermissionIfThisIsTheFirstFollow() {
        guard app.follows.hasServer, app.registrar.permission == .notDetermined else { return }
        Task { await app.registrar.requestPermission() }
    }
}

/// The line under a Follow button when there is nowhere to send an alert, so nobody waits all
/// evening for a push that was never going to come.
///
/// The address is built in now, so this is no longer something the user can fix by typing; it
/// shows only when the client could not be built at all, and it says what is true rather than
/// offering a screen that no longer exists.
struct OfflineFollowNote: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        if !app.follows.hasServer {
            Text("Follows are kept on this phone. The alert service is unavailable, so nothing will be sent.")
                .font(.caption)
                .foregroundStyle(Palette.amber)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
