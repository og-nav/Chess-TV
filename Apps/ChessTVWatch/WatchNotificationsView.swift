// Silencing an event from the wrist.
//
// The switches here write to the same endpoints the phone writes to, with the same install token
// — the one the phone handed over in the application context and that lives in this watch's own
// Keychain. The phone sees the change on its next refresh; nothing is sent back over
// WatchConnectivity, because the server is the single source of truth for what will be delivered
// and two devices reconciling with each other is a worse design than two devices reconciling with
// it.
//
// Every switch moves at once and is corrected if the server refuses, rather than spinning: a
// watch screen that waits on a network is a watch screen nobody uses twice.
import SwiftUI
import FollowKit

struct WatchNotificationsView: View {
    let sync: WatchSyncStore

    @State private var isWorking = false
    @State private var failure: String?

    private var preferences: NotificationPreferences {
        sync.payload.preferences ?? NotificationPreferences()
    }

    private var canWrite: Bool {
        sync.payload.serverBaseURL != nil && sync.hasCredential
    }

    var body: some View {
        List {
            Section {
                Toggle(isOn: muteBinding.withSelectionFeedback()) {
                    Label {
                        Text("Mute everything", comment: "Watch switch that silences all alerts")
                    } icon: {
                        Image(systemName: "bell.slash")
                    }
                }
                .disabled(!canWrite || isWorking)
            } footer: {
                if !canWrite {
                    Text("Connect to your iPhone once to change alerts from here.", comment: "Watch footer when there is no credential yet")
                } else if let failure {
                    Text(failure)
                } else if preferences.muteAll {
                    Text("No alerts will be delivered to any of your devices.", comment: "Watch footer explaining a global mute")
                }
            }

            if !sync.payload.follows.isEmpty {
                Section {
                    ForEach(sync.payload.follows) { follow in
                        NavigationLink {
                            WatchFollowAlertsView(sync: sync, follow: follow)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(follow.title).font(.footnote).lineLimit(1)
                                alertSummary(follow)
                                    .font(.caption2)
                                    .foregroundStyle(ChessTVPalette.muted)
                                    .lineLimit(1)
                            }
                        }
                        .navigationFeedback()
                        .disabled(!canWrite)
                    }
                } header: {
                    Text("Per follow", comment: "Watch section header over the follow list")
                }
            }
        }
        .navigationTitle(Text("Notifications", comment: "Watch screen title"))
    }

    private var muteBinding: Binding<Bool> {
        Binding(
            get: { preferences.muteAll },
            set: { newValue in
                var updated = preferences
                updated.muteAll = newValue
                write(updated)
            }
        )
    }

    private func write(_ updated: NotificationPreferences) {
        let previous = preferences
        sync.applyLocally(preferences: updated)          // optimistic: the switch moves now
        failure = nil
        guard let client = sync.makeClient(userAgent: WatchIdentity.userAgent) else {
            sync.applyLocally(preferences: previous)
            failure = String(localized: "No connection to the alert server.", comment: "Watch error when there is no server")
            return
        }
        isWorking = true
        Task {
            do {
                try await client.setPreferences(updated.sanitized())
                watchLog.notice("Preferences written from the watch")
            } catch {
                sync.applyLocally(preferences: previous)  // put the switch back where it was
                failure = String(localized: "Could not reach the alert server.", comment: "Watch error after a failed write")
                watchLog.error("Preferences write failed: \(logLabel(for: error), privacy: .public)")
            }
            isWorking = false
        }
    }

    /// Returns `Text`, not `String`: automatic grammar agreement (`^[…](inflect: true)`) is
    /// resolved by the `Text`/`LocalizedStringKey` pipeline. Run through `String(format:)` the
    /// markup is not interpreted and the user reads the markup itself.
    private func alertSummary(_ follow: WatchFollow) -> Text {
        let count = follow.isTournament ? follow.alerts.tournament.count : follow.alerts.game.count
        guard count > 0 else {
            return Text("No alerts", comment: "Watch summary for a follow with everything off")
        }
        return Text("^[\(count) alert](inflect: true)", comment: "Watch summary: how many alert kinds are on")
    }
}

/// The switch list for one follow, in the terms its target kind actually uses.
struct WatchFollowAlertsView: View {
    let sync: WatchSyncStore
    let follow: WatchFollow

    @State private var failure: String?

    /// Read live from the store, so an optimistic change or a rollback is reflected here too.
    private var current: FollowAlerts {
        sync.payload.follows.first { $0.id == follow.id }?.alerts ?? follow.alerts
    }

    var body: some View {
        List {
            if follow.isTournament {
                ForEach(TournamentAlert.allCases, id: \.self) { alert in
                    Toggle(isOn: tournamentBinding(alert).withSelectionFeedback()) { Text(label(alert)) }
                }
            } else {
                ForEach(GameAlert.allCases, id: \.self) { alert in
                    Toggle(isOn: gameBinding(alert).withSelectionFeedback()) { Text(label(alert)) }
                }
            }
            if let failure {
                Text(failure).font(.caption2).foregroundStyle(ChessTVPalette.muted)
            }
        }
        .navigationTitle(follow.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func gameBinding(_ alert: GameAlert) -> Binding<Bool> {
        Binding(
            get: { current.game.contains(alert) },
            set: { isOn in
                var alerts = current
                if isOn { alerts.game.insert(alert) } else { alerts.game.remove(alert) }
                write(alerts)
            }
        )
    }

    private func tournamentBinding(_ alert: TournamentAlert) -> Binding<Bool> {
        Binding(
            get: { current.tournament.contains(alert) },
            set: { isOn in
                var alerts = current
                if isOn { alerts.tournament.insert(alert) } else { alerts.tournament.remove(alert) }
                write(alerts)
            }
        )
    }

    private func write(_ alerts: FollowAlerts) {
        let previous = current
        sync.applyLocally(alerts: alerts, forFollow: follow.id)
        failure = nil
        guard let client = sync.makeClient(userAgent: WatchIdentity.userAgent) else {
            sync.applyLocally(alerts: previous, forFollow: follow.id)
            failure = String(localized: "No connection to the alert server.", comment: "Watch error when there is no server")
            return
        }
        // `PATCH /v1/follows/{id}` takes the alert set; `update(_:)` on the client sends exactly
        // that, so only `id` and `alerts` of this value reach the wire.
        let updated = Follow(id: follow.id, target: follow.target, alerts: alerts.clamped(), createdAt: Date())
        Task {
            do {
                _ = try await client.update(updated)
                watchLog.notice("Alerts written from the watch for follow \(follow.id, privacy: .public)")
            } catch {
                sync.applyLocally(alerts: previous, forFollow: follow.id)
                failure = String(localized: "Could not reach the alert server.", comment: "Watch error after a failed write")
                watchLog.error("Follow write failed: \(logLabel(for: error), privacy: .public)")
            }
        }
    }

    private func label(_ alert: GameAlert) -> String {
        switch alert {
        case .start: String(localized: "Game starts", comment: "Alert switch")
        case .move: String(localized: "Every move", comment: "Alert switch")
        case .longThink: String(localized: "Long think", comment: "Alert switch")
        case .end: String(localized: "Game ends", comment: "Alert switch")
        }
    }

    private func label(_ alert: TournamentAlert) -> String {
        switch alert {
        case .startingSoon: String(localized: "Starting soon", comment: "Alert switch")
        case .roundLive: String(localized: "Round goes live", comment: "Alert switch")
        case .gameResults: String(localized: "Results", comment: "Alert switch")
        case .roundSummary: String(localized: "Round summary", comment: "Alert switch")
        case .finished: String(localized: "Event finishes", comment: "Alert switch")
        case .topBoardMoves: String(localized: "Top-board moves", comment: "Alert switch")
        }
    }
}
