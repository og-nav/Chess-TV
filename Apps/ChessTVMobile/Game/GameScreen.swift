// The game screen: board, players, clocks, move list, engine, and the Follow button.
//
// Portrait on a phone is a column — opponent, board with the eval bar down its left edge, the
// player to move, then the controls and the move list. Anything wider (landscape, an iPad, an
// iPad in Split View) puts the board on the left and a panel on the right, as the TV does.
import SwiftUI
import ChessCore
import ChessUI
import GameSessionKit
import LichessKit

struct GameScreen: View {
    let destination: GameDestination

    @Environment(AppEnvironment.self) private var app
    @Environment(Navigator.self) private var navigator

    private var session: GameSession { app.session }
    private var game: GameState { app.session.game }

    /// The width at which the side panel earns its place. Below it the panel would squeeze the
    /// board to less than half the screen, which is the wrong trade on a phone.
    private static let sidePanelWidth: Double = 320
    private static let sideBySideThreshold: Double = 700

    var body: some View {
        GeometryReader { proxy in
            let sideBySide = proxy.size.width >= Self.sideBySideThreshold
            Group {
                if sideBySide {
                    HStack(alignment: .top, spacing: Metrics.panelGap) {
                        ScrollView {
                            boardColumn
                                .frame(maxWidth: GameLayout.boardColumnWidth(
                                    availableWidth: proxy.size.width - Self.sidePanelWidth - Metrics.panelGap - 32,
                                    availableHeight: proxy.size.height - 32
                                ))
                                .frame(maxWidth: .infinity)
                        }
                        ScrollView {
                            panel(isVertical: true)
                        }
                        .frame(width: Self.sidePanelWidth)
                    }
                    .padding(16)
                } else {
                    ScrollView {
                        VStack(spacing: 14) {
                            boardColumn
                            panel(isVertical: false)
                        }
                        .padding(16)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Palette.ground)
        .navigationTitle(session.sourceTitle.isEmpty ? "Game" : session.sourceTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                FollowButton(followability: followability) { target in
                    navigator.push(.followDetail(target: target))
                }
            }
        }
        .onAppear {
            guard !AppEnvironment.isUnderTest else { return }
            session.open(destination)
            session.noteScreenAppeared()
        }
        .onDisappear {
            // Opening another board replaces the stack, and SwiftUI runs the new screen's
            // onAppear before this one's onDisappear. Closing unconditionally here would close
            // the feed the new screen just opened, leaving it stuck on "Connecting".
            if session.openDestination?.source == destination.source { session.close() }
        }
        // While this board is pinned, the phone pushes each move into the Live Activity itself.
        // The server does the same when the app is closed; ActivityKit takes the newer of the two.
        .onChange(of: game.revision) { _, _ in updatePinnedActivity() }
        .onChange(of: game.finished) { _, _ in updatePinnedActivity() }
        .overlay(alignment: .top) { toast }
    }

    private func updatePinnedActivity() {
        guard case .broadcastBoard(_, let gameId) = destination.source,
              LiveActivityController.shared.pinned?.gameId == gameId,
              let state = PinnedActivity.state(of: session) else { return }
        Task {
            await LiveActivityController.shared.update(state)
            app.syncWatch()
        }
    }

    // MARK: - Board

    private func fideID(for color: PieceColor) -> Int? {
        (color == .white ? destination.whiteFideId : destination.blackFideId)
            ?? session.fidePlayer(for: color)?.id
    }

    private var boardColumn: some View {
        VStack(spacing: 10) {
            statusLine
            PlayerRow(color: session.topColor, session: session, fideID: fideID(for: session.topColor))
            HStack(alignment: .top, spacing: 8) {
                if session.showsEvalBar {
                    EvalBarView(
                        whiteShare: session.viewedWhiteShare ?? 0.5,
                        orientation: session.boardOrientation
                    )
                    .frame(width: Metrics.evalBarWidth)
                    .accessibilityLabel("Evaluation bar")
                    .accessibilityValue(session.viewedEvaluationText ?? "no evaluation yet")
                }
                // `viewedPosition` and `viewedLastMove` already answer "the live one" when
                // nothing is being scrubbed, and ply 0 deliberately has no last move to draw.
                AccessibleBoard(
                    position: session.viewedPosition,
                    lastMove: session.viewedLastMove,
                    theme: app.settings.boardTheme,
                    pieceSet: app.settings.pieceSet,
                    orientation: session.boardOrientation,
                    showCoordinates: app.settings.coordinates
                )
            }
            .fixedSize(horizontal: false, vertical: true)
            PlayerRow(color: session.bottomColor, session: session, fideID: fideID(for: session.bottomColor))
            ScrubBar(session: session)
        }
    }

    /// The header line: the connection, the replay notice, the arena's countdown and the result.
    private var statusLine: some View {
        HStack(spacing: 8) {
            ConnectionDot(color: connectionColor)
                .decorative()
            Text(connectionText)
                .font(.footnote)
                .foregroundStyle(Palette.muted)
            Spacer(minLength: 0)
            if let left = session.arenaTimeLeftText {
                Chip(text: "Ends in \(left)", tint: Palette.amber)
            }
            if let finished = game.finished {
                Chip(text: finished.text, tint: Palette.accent, filled: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(UIID.Game.status)
    }

    private var connectionColor: Color {
        if game.finished != nil { return Palette.faint }
        switch game.connection {
        case .live: return Palette.accent
        case .connecting: return Palette.amber
        case .reconnecting: return Palette.amber
        case .failed: return Palette.alert
        }
    }

    private var connectionText: String {
        if game.finished != nil { return "Finished" }
        if session.isReplayingHistory { return "Catching up\u{2026}" }
        switch game.connection {
        case .live: return "Live"
        case .connecting: return "Connecting\u{2026}"
        case .reconnecting(let attempt, _): return "Reconnecting (attempt \(attempt))"
        case .failed: return "Offline \u{00B7} retrying"
        }
    }

    // MARK: - Panel

    private func panel(isVertical: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            EvaluationLine(session: session)
            MoveList(session: session, isVertical: isVertical)
            GameControls(session: session, destination: destination)
            if let standings = session.arenaStandings {
                StandingsPanel(standings: standings, highlighting: session.boardPlayerNames)
            }
            OfflineFollowNote()
        }
    }

    // MARK: - Follow

    private var followability: Followability {
        FollowCapability.followability(of: destination.source)
    }

    // MARK: - Toast

    @ViewBuilder
    private var toast: some View {
        if let alert = session.toast {
            Text(alert.text)
                .font(.subheadline)
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .panelCard(corner: 12)
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityAddTraits(.isStaticText)
        }
    }
}

/// Reserve room for status, both clocks and the scrub controls on a landscape phone. At large
/// accessibility sizes the column still scrolls, so text is never clipped to meet this estimate.
enum GameLayout {
    static func boardColumnWidth(availableWidth: Double, availableHeight: Double) -> Double {
        min(max(0, availableWidth), max(160, availableHeight - 222))
    }
}
