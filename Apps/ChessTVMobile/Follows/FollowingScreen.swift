// Following: two sections, players and single games above, tournaments below.
//
// Tapping a row opens the thing; the bell opens its switches. Both are needed, and a single
// menu would bury one of them — a follow now has up to six switches, so it deserves a screen.
import SwiftUI
import FollowKit
import GameSessionKit
import ImageryKit
import LichessKit

struct FollowingScreen: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(Navigator.self) private var navigator
    @State private var model = FollowingModel()

    var body: some View {
        List {
            if app.follows.follows.isEmpty {
                emptyState
            } else {
                if !app.follows.boardFollows.isEmpty {
                    Section("Players and games") {
                        ForEach(app.follows.boardFollows) { follow in
                            row(follow)
                        }
                    }
                }
                if !app.follows.tournamentFollows.isEmpty {
                    Section("Tournaments") {
                        ForEach(app.follows.tournamentFollows) { follow in
                            row(follow)
                        }
                    }
                }
            }
            if !app.follows.failedEdits.isEmpty {
                Section("Changes that could not sync") {
                    ForEach(app.follows.failedEdits) { failure in
                        VStack(alignment: .leading) {
                            Text(failure.summary.capitalized)
                            Text(failure.reason).font(.caption).foregroundStyle(Palette.muted)
                        }
                    }
                    Button("Dismiss notices") { InteractionFeedback.selection(); app.follows.dismissFailures() }
                        .accessibilityIdentifier(UIID.Following.dismissNotices)
                }
            }
            Section { syncFooter }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .navigationTitle("Following")
        .refreshable {
            await app.follows.reconcileAndWait()
            await model.refresh(follows: app.follows.follows, events: app.home.events.value ?? [])
        }
        .task {
            guard !AppEnvironment.isUnderTest else { return }
            model.didRefresh = { app.cacheFollowText(model.rowText(for: app.follows.follows)) }
            await model.run(
                follows: { app.follows.follows },
                events: { app.home.events.value ?? [] }
            )
        }
    }

    // MARK: - Rows

    private func row(_ follow: Follow) -> some View {
        FollowRow(follow: follow, model: model) {
            open(follow)
        } openAlerts: {
            navigator.push(.followDetail(target: follow.target))
        }
        .listRowBackground(Palette.panel)
        .swipeActions(edge: .trailing) {
            Button("Unfollow", systemImage: "bell.slash", role: .destructive) {
                InteractionFeedback.confirmation()
                app.follows.remove(id: follow.id)
            }
        }
        .swipeActions(edge: .leading) {
            Button("Alerts", systemImage: "slider.horizontal.3") {
                InteractionFeedback.tap()
                navigator.push(.followDetail(target: follow.target))
            }
            .tint(Palette.accent)
        }
    }

    private func open(_ follow: Follow) {
        switch follow.target {
        case .player(let fideId):
            guard let (board, roundId) = model.liveBoard(forFideID: fideId) else { return }
            navigator.openBoard(
                roundId: roundId,
                gameId: board.gameId,
                tournamentName: model.round(id: roundId)?.name,
                destination: GameDestination(
                    source: .broadcastBoard(roundId: roundId, gameId: board.gameId),
                    title: model.round(id: roundId)?.name,
                    whiteFederation: board.white?.federation,
                    blackFederation: board.black?.federation,
                    whiteFideId: board.white?.fideId,
                    blackFideId: board.black?.fideId,
                    whitePhoto: board.white?.photo,
                    blackPhoto: board.black?.photo
                )
            )
        case .game(let roundId, let gameId):
            let board = model.board(gameId: gameId)
            navigator.openBoard(
                roundId: roundId,
                gameId: gameId,
                tournamentName: model.round(id: roundId)?.name,
                destination: GameDestination(
                    source: .broadcastBoard(roundId: roundId, gameId: gameId),
                    title: model.round(id: roundId)?.name,
                    whiteFederation: board?.white?.federation,
                    blackFederation: board?.black?.federation,
                    whiteFideId: board?.white?.fideId,
                    blackFideId: board?.black?.fideId,
                    whitePhoto: board?.white?.photo,
                    blackPhoto: board?.black?.photo
                )
            )
        case .tournament(let tourId):
            navigator.openTournament(tourId: tourId, name: model.tour(id: tourId)?.name)
        }
    }

    // MARK: - Chrome

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing followed yet", systemImage: "bell")
        } description: {
            Text("Open a broadcast board, a player or an event and tap Follow. Alerts arrive even when Chess TV is closed.")
        } actions: {
            Button("Browse events") { InteractionFeedback.tap(); navigator.tab = .home }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .accessibilityIdentifier(UIID.Following.browse)
        }
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var syncFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ConnectionDot(color: syncColor).decorative()
                Text(syncText)
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
            }
            if app.follows.pendingCount > 0 {
                Text("\(app.follows.pendingCount) change\(app.follows.pendingCount == 1 ? "" : "s") waiting to reach the server. They are saved on this phone.")
                    .font(.caption)
                    .foregroundStyle(Palette.amber)
            }
        }
        .listRowBackground(Palette.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(UIID.Following.syncLine)
    }

    private var syncColor: Color {
        switch app.follows.state {
        case .synced: Palette.accent
        case .syncing, .neverSynced: Palette.amber
        case .failed: Palette.alert
        case .noServer: Palette.faint
        }
    }

    private var syncText: String {
        switch app.follows.state {
        case .noServer: "No push server configured \u{00B7} follows are kept on this phone"
        case .neverSynced: "Not synced yet"
        case .syncing: "Syncing\u{2026}"
        case .synced(let date): "Synced \(date.formatted(date: .omitted, time: .shortened))"
        case .failed(let message): message
        }
    }
}

// MARK: - One row

struct FollowRow: View {
    let follow: Follow
    let model: FollowingModel
    let open: () -> Void
    let openAlerts: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                InteractionFeedback.tap()
                open()
            } label: {
                HStack(spacing: 10) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 3) {
                        Text(FollowPresentation.title(for: follow, model: model))
                            .font(.body.weight(.medium))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Text(FollowPresentation.status(for: follow, model: model))
                            .font(.subheadline)
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                        Text(follow.alerts.summary(for: follow.followKind))
                            .font(.caption)
                            .foregroundStyle(Palette.faint)
                            .lineLimit(1)
                        // The thumbnail is a FIDE portrait; where FIDE names the photographer,
                        // the name goes with it.
                        if let credit = photoCredit {
                            Text(credit)
                                .font(.caption2)
                                .foregroundStyle(Palette.faint)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(UIID.Following.row(follow.target.kind, follow.target.key))

            Button {
                InteractionFeedback.tap()
                openAlerts()
            } label: {
                Image(systemName: "bell.badge")
                    .foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Alerts for this follow")
            .accessibilityIdentifier(UIID.Following.alerts(follow.target.kind, follow.target.key))
        }
        .padding(.vertical, 2)
    }

    /// The photographer FIDE credits for the portrait in this row, if this row has one.
    private var photoCredit: String? {
        guard case .player(let fideId) = follow.target, let player = model.player(fideId: fideId) else { return nil }
        guard player.photoMediumURL != nil, let credit = player.photoCredit, !credit.isEmpty else { return nil }
        return "Photo: \(credit)"
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch follow.target {
        case .player(let fideId):
            RemoteImage(
                portraitURL: model.player(fideId: fideId)?.photoMediumURL,
                maxPixelSize: 160,
                name: model.player(fideId: fideId)?.name ?? ""
            )
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .decorative()
        case .tournament:
            Image(systemName: "trophy")
                .font(.title3)
                .foregroundStyle(Palette.accent)
                .frame(width: 44, height: 44)
                .decorative()
        case .game:
            Image(systemName: "square.grid.3x3")
                .font(.title3)
                .foregroundStyle(Palette.accent)
                .frame(width: 44, height: 44)
                .decorative()
        }
    }

    private var accessibilityLabel: String {
        [
            FollowPresentation.title(for: follow, model: model),
            FollowPresentation.status(for: follow, model: model),
            follow.alerts.summary(for: follow.followKind),
        ].joined(separator: ", ")
    }
}
