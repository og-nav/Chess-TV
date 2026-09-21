// The list: every game the phone told us to care about, plus a way into the alert switches.
import SwiftUI
import ChessCore
import FollowKit
import LichessKit

struct WatchRootView: View {
    let sync: WatchSyncStore
    let model: WatchFollowsModel

    /// Driven by `-open`; see `LaunchArguments` at the bottom of this file.
    @State private var path: [WatchFollowsModel.Row] = []
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsNotifications = false

    var body: some View {
        NavigationStack(path: $path.withSelectionFeedback()) {
            List {
                if !sync.hasSynced {
                    WaitingForPhoneRow()
                } else if model.rows.isEmpty {
                    NothingFollowedRow()
                } else {
                    ForEach(model.rows) { row in
                        NavigationLink(value: row) {
                            FollowRowView(row: row)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
                    }
                }

                Section {
                    NavigationLink {
                        WatchNotificationsView(sync: sync)
                    } label: {
                        Label {
                            Text("Notifications", comment: "Row into the watch's alert switches")
                        } icon: {
                            Image(systemName: sync.payload.preferences?.muteAll == true ? "bell.slash" : "bell")
                        }
                        .font(.system(size: 13))
                    }
                    .navigationFeedback()
                } footer: {
                    FooterText(model: model)
                }
            }
            .navigationTitle(Text("Chess TV", comment: "Watch app title"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: WatchFollowsModel.Row.self) { row in
                WatchBoardView(row: model.rows.first(where: { $0.id == row.id }) ?? row)
            }
            .onChange(of: sync.payload) { _, payload in
                // A new follow list from the phone: adopt it without waiting for the next tick.
                if scenePhase == .active { model.start(with: payload) }
            }
            .onChange(of: model.rows) { _, rows in
                guard LaunchArguments.openScreen == .board, path.isEmpty,
                      let first = rows.first(where: { $0.board != nil })
                else { return }
                path = [first]
            }
            .navigationDestination(isPresented: $showsNotifications) {
                WatchNotificationsView(sync: sync)
            }
            .task {
                if scenePhase == .active { model.start(with: sync.payload) }
                showsNotifications = LaunchArguments.openScreen == .notifications
            }
        }
    }
}

private struct FollowRowView: View {
    let row: WatchFollowsModel.Row
    @ScaledMetric(relativeTo: .caption2) private var nameSize: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let board = row.board, let white = board.white, let black = board.black {
                player(white, color: .white)
                player(black, color: .black)
                HStack(spacing: 5) {
                    if row.followId == "pinned" {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .accessibilityHidden(true)
                    }
                    Text(shortSubtitle)
                        .lineLimit(1)
                    Spacer(minLength: 3)
                    Text(ChessFormat.result(status: board.status) ?? (row.isStale ? "Saved" : "Live"))
                        .foregroundStyle(board.isOngoing && !row.isStale ? ChessTVPalette.accent : ChessTVPalette.muted)
                        .fixedSize()
                }
                .font(.system(size: 10))
                .foregroundStyle(ChessTVPalette.muted)
                .padding(.top, 2)
            } else {
                Text(row.title)
                    .font(.system(size: nameSize, weight: .regular))
                    .lineLimit(2)
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(ChessTVPalette.muted)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var shortSubtitle: String {
        let round = row.roundName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if row.followId == "pinned" {
            return round.flatMap { $0.isEmpty ? nil : $0 } ?? "Pinned"
        }
        return round.flatMap { $0.isEmpty ? nil : $0 } ?? "Broadcast"
    }

    private func player(_ player: BroadcastPlayer, color: PieceColor) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color == .white ? ChessTVPalette.ink : ChessTVPalette.panel)
                .overlay(Circle().stroke(ChessTVPalette.muted, lineWidth: 0.7))
                .frame(width: 6, height: 6)
                .accessibilityLabel(color == .white ? "White" : "Black")
            Text(player.surname)
                .font(.system(size: nameSize, weight: .regular))
                .foregroundStyle(ChessTVPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }
}

private struct WaitingForPhoneRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Waiting for your iPhone", comment: "Watch empty state before the first sync")
                .font(.footnote.weight(.medium))
            Text("Open Chess TV on your iPhone once, and your follows will appear here.", comment: "Watch empty state detail")
                .font(.caption2)
                .foregroundStyle(ChessTVPalette.muted)
        }
        .padding(.vertical, 4)
    }
}

private struct NothingFollowedRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nothing followed yet", comment: "Watch empty state with a synced but empty follow list")
                .font(.footnote.weight(.medium))
            Text("Follow a player or an event on your iPhone.", comment: "Watch empty state detail")
                .font(.caption2)
                .foregroundStyle(ChessTVPalette.muted)
        }
        .padding(.vertical, 4)
    }
}

/// The honest line at the bottom: when this was last true, and whether anything failed.
private struct FooterText: View {
    let model: WatchFollowsModel

    var body: some View {
        if let error = model.lastError {
            Text(error)
        } else if let updated = model.lastUpdated {
            Text(
                String(
                    format: String(localized: "Updated %@", comment: "Watch list footer with a time"),
                    updated.formatted(date: .omitted, time: .standard)
                )
            )
        } else {
            Text("Not updated yet", comment: "Watch list footer before the first poll")
        }
    }
}

/// `-open <screen>`, the same argument the tvOS app takes: a way to land a simulator run on the
/// screen you want to look at without a hand on the crown. Read from `ProcessInfo`, so a shipping
/// launch never sees one.
enum LaunchArguments {
    enum Screen: String {
        /// The first row that actually has a position.
        case board
        case notifications
    }

    static var openScreen: Screen? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-open"), index + 1 < arguments.count else { return nil }
        return Screen(rawValue: arguments[index + 1])
    }
}
