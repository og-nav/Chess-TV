// The switch list for one set of alerts.
//
// Used twice: once for a single follow, and once for "what new follows send by default". Both
// edit a `FollowAlerts`, so both get the same rows and the same rules about which pickers are
// worth showing — an interval under a switch that is off is a control with no effect.
import SwiftUI
import FollowKit

struct AlertSwitchList: View {
    @Binding var alerts: FollowAlerts
    let kind: FollowKind
    /// False when this install already has `FollowAlerts.maximumEvalSwingFollows` other follows
    /// with swings on: the switch can then be turned off but not on, as the server would refuse it.
    var swingsAvailable = true

    var body: some View {
        if kind.isBoardShaped {
            gameSection
        } else {
            tournamentSection
        }
    }

    // MARK: - Players and games

    @ViewBuilder
    private var gameSection: some View {
        Section("Alerts") {
            ForEach(AlertCatalogue.gameAlerts, id: \.self) { alert in
                Toggle(isOn: binding(for: alert).withSelectionFeedback()) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AlertCatalogue.title(for: alert))
                        Text(AlertCatalogue.detail(for: alert))
                            .font(.caption)
                            .foregroundStyle(Palette.muted)
                    }
                }
                .listRowBackground(Palette.panel)
                .accessibilityIdentifier(UIID.FollowDetail.toggle(alert.rawValue))
            }
        }

        if AlertCatalogue.movePacingApplies(to: alerts, kind: kind) {
            Section {
                Picker("Move alerts", selection: $alerts.minMinutesBetweenMoveAlerts.withSelectionFeedback()) {
                    ForEach(AlertCatalogue.moveIntervalChoices, id: \.self) { minutes in
                        Text(AlertCatalogue.moveIntervalText(minutes)).tag(minutes)
                    }
                }
                .listRowBackground(Palette.panel)
                .accessibilityIdentifier(UIID.FollowDetail.moveInterval)
            } footer: {
                Text("A classical game plays about one move every ten minutes; a rapid game plays several a minute.")
            }
        }

        swingSection

        if AlertCatalogue.longThinkApplies(to: alerts) {
            Section {
                Picker("Long think after", selection: $alerts.longThinkMinutes.withSelectionFeedback()) {
                    ForEach(AlertCatalogue.longThinkChoices, id: \.self) { minutes in
                        Text(AlertCatalogue.longThinkText(minutes)).tag(minutes)
                    }
                }
                .listRowBackground(Palette.panel)
                .accessibilityIdentifier(UIID.FollowDetail.longThink)
            } footer: {
                Text("One alert when a player has been on the same move for this long \u{2014} usually the critical moment of the game.")
            }
        }
    }

    // MARK: - Tournaments

    @ViewBuilder
    private var tournamentSection: some View {
        Section("Alerts") {
            ForEach(AlertCatalogue.tournamentAlerts, id: \.self) { alert in
                Toggle(isOn: binding(for: alert).withSelectionFeedback()) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AlertCatalogue.title(for: alert))
                        Text(AlertCatalogue.detail(for: alert))
                            .font(.caption)
                            .foregroundStyle(Palette.muted)
                    }
                }
                .listRowBackground(Palette.panel)
                .accessibilityIdentifier(UIID.FollowDetail.toggle(alert.rawValue))
            }
        }

        swingSection

        if alerts.tournament.contains(.startingSoon) {
            Section {
                Picker("Heads-up", selection: $alerts.startingSoonMinutes.withSelectionFeedback()) {
                    ForEach(AlertCatalogue.startingSoonChoices, id: \.self) { minutes in
                        Text(AlertCatalogue.startingSoonText(minutes)).tag(minutes)
                    }
                }
                .listRowBackground(Palette.panel)
                .accessibilityIdentifier(UIID.FollowDetail.startingSoon)
            } footer: {
                Text("Rounds often start late. This alert comes from the schedule; the round-live alert comes from the round actually starting.")
            }
        }

        if alerts.tournament.contains(.gameResults) || alerts.tournament.contains(.topBoardMoves) || alerts.evalSwings {
            Section {
                Picker("Boards watched", selection: $alerts.topBoards.withSelectionFeedback()) {
                    ForEach(Array(AlertCatalogue.topBoardsRange), id: \.self) { boards in
                        Text(AlertCatalogue.topBoardsText(boards)).tag(boards)
                    }
                }
                .listRowBackground(Palette.panel)
                .accessibilityIdentifier(UIID.FollowDetail.topBoards)
            } footer: {
                Text("Results, moves and big swings cover these boards plus any board with a player you follow. Everything else is covered by the round summary \u{2014} which is what keeps a hundred-board open from sending a hundred alerts.")
            }
        }

        if alerts.tournament.contains(.topBoardMoves) {
            Section {
                Picker("Move alerts", selection: $alerts.minMinutesBetweenMoveAlerts.withSelectionFeedback()) {
                    ForEach(AlertCatalogue.moveIntervalChoices, id: \.self) { minutes in
                        Text(AlertCatalogue.moveIntervalText(minutes)).tag(minutes)
                    }
                }
                .listRowBackground(Palette.panel)
                .accessibilityIdentifier(UIID.FollowDetail.moveInterval)
            } footer: {
                Text("This is the noisy switch. An interval of a few minutes keeps a classical round to a handful of alerts.")
            }
        }
    }

    // MARK: - Engine

    @ViewBuilder
    private var swingSection: some View {
        let locked = !alerts.evalSwings && !swingsAvailable
        Section {
            Toggle(isOn: $alerts.evalSwings.withSelectionFeedback()) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(AlertCatalogue.swingTitle)
                    Text(AlertCatalogue.swingDetail)
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                }
            }
            .disabled(locked)
            .listRowBackground(Palette.panel)
            .accessibilityIdentifier(UIID.FollowDetail.toggle("evalSwings"))
        } footer: {
            Text(locked ? AlertCatalogue.swingLimitText : AlertCatalogue.swingFooter)
        }
    }

    // MARK: - Bindings

    private func binding(for alert: GameAlert) -> Binding<Bool> {
        Binding(
            get: { alerts.game.contains(alert) },
            set: { isOn in
                if isOn { alerts.game.insert(alert) } else { alerts.game.remove(alert) }
            }
        )
    }

    private func binding(for alert: TourAlert) -> Binding<Bool> {
        Binding(
            get: { alerts.tournament.contains(alert) },
            set: { isOn in
                if isOn { alerts.tournament.insert(alert) } else { alerts.tournament.remove(alert) }
            }
        )
    }
}
