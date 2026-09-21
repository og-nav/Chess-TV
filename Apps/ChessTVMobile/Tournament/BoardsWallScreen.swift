// Every board of a round, as mini boards.
//
// Two columns on a phone, four to six on an iPad — an adaptive grid rather than a size-class
// switch, so a Split View window half the width of an iPad gets the right number by itself.
import SwiftUI
import ChessCore
import ChessUI
import GameSessionKit
import LichessKit

struct BoardsWallScreen: View {
    let roundId: String
    let tournamentName: String?

    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppEnvironment.self) private var app
    @Environment(Navigator.self) private var navigator
    @State private var model: BoardsWallModel

    init(roundId: String, tournamentName: String?) {
        self.roundId = roundId
        self.tournamentName = tournamentName
        _model = State(initialValue: BoardsWallModel(roundId: roundId))
    }

    var body: some View {
        ScrollView {
            switch model.state {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Loading games…")
                        .font(.subheadline)
                        .foregroundStyle(Palette.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            case .failed(let message):
                ShelfPlaceholder(text: message, isError: true).padding(.top, 20)
            case .loaded(let boards):
                if boards.isEmpty {
                    ShelfPlaceholder(text: "This round has no boards yet. They appear when the round starts.")
                        .padding(.top, 20)
                } else {
                    grid
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground)
        .navigationTitle(model.round?.roundName ?? tournamentName ?? "Boards")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let tourId = model.round?.tourId {
                    FollowButton(followability: .followable(.tournament(tourId: tourId)), identifier: UIID.Boards.follow) { target in
                        navigator.push(.followDetail(target: target))
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let round = model.round {
                    Button {
                        InteractionFeedback.tap()
                        navigator.push(.tournament(tourId: round.tourId, name: round.name))
                    } label: {
                        Label("All rounds", systemImage: "list.bullet")
                    }
                    .accessibilityIdentifier(UIID.Boards.allRounds)
                }
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active, !AppEnvironment.isUnderTest else { return }
            await model.run()
        }
        .refreshable { await model.refresh() }
        .safeAreaInset(edge: .top) { header }
    }

    @ViewBuilder
    private var header: some View {
        if let round = model.round {
            VStack(alignment: .leading, spacing: 4) {
                Text(round.name)
                    .font(.headline)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if round.roundOngoing {
                        Chip(text: model.monitor.isConnected ? "Live" : "Reconnecting…", filled: model.monitor.isConnected)
                    }
                    Text("\(model.boards.count) boards")
                        .font(.subheadline)
                        .foregroundStyle(Palette.muted)
                }
                OfflineFollowNote()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Metrics.minimumMiniBoard, maximum: 260), spacing: 12)],
            spacing: 14
        ) {
            ForEach(model.orderedBoards) { item in
                Button {
                    InteractionFeedback.tap()
                    navigator.push(.game(model.destination(for: item.board, boardNumber: item.number)))
                } label: {
                    MiniBoardCell(
                        board: item.board,
                        boardNumber: item.number,
                        receivedAt: model.monitor.clockAnchor(for: item.board.gameId),
                        clockNow: model.monitor.clockNow,
                        canTick: model.monitor.canTick(board: item.board),
                        theme: app.settings.boardTheme,
                        pieceSet: app.settings.pieceSet
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(UIID.Boards.card(item.board.gameId))
            }
        }
        .padding(16)
    }
}

// MARK: - One cell

struct MiniBoardCell: View {
    let board: BroadcastBoard
    let boardNumber: Int
    let receivedAt: ContinuousClock.Instant
    var clockNow: ContinuousClock.Instant = .now
    var canTick: Bool = true
    let theme: BoardTheme
    let pieceSet: PieceSet

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            playerLine(board.black, color: .black)
            BoardView(
                position: try? Position(fen: board.fen),
                lastMove: lastMove,
                theme: theme,
                pieceSet: pieceSet,
                orientation: .white,
                showCoordinates: false
            )
            .decorative()
            playerLine(board.white, color: .white)
        }
        .padding(8)
        .panelCard(corner: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var lastMove: LastMove? {
        guard let uci = board.lastMove, let position = try? Position(fen: board.fen) else { return nil }
        return LastMove(uci: uci, position: position)
    }

    @ViewBuilder
    private func playerLine(_ player: BroadcastPlayer?, color: PieceColor) -> some View {
        HStack(spacing: 6) {
            if let title = player?.title, !title.isEmpty {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Palette.accent)
            }
            Text(player?.name ?? "\u{2014}")
                .font(.caption.weight(.medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 2)
            if board.isOngoing {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    if !canTick { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 8)).foregroundStyle(Palette.faint).accessibilityLabel("Updating clock") }
                    Text(WallClock.text(for: color, board: board, receivedAt: receivedAt, now: canTick ? .now : clockNow, isConnected: canTick) ?? "\u{2013}")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(color == WallClock.sideToMove(of: board) ? Palette.ink : Palette.faint)
                }
            } else {
                Text(resultText(for: color))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Palette.muted)
            }
        }
    }

    /// A finished board shows each side's half of the result beside their name: "1", "0", "½".
    private func resultText(for color: PieceColor) -> String {
        let parts = board.status.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return board.status }
        return color == .white ? parts[0] : parts[1]
    }

    private var accessibilityLabel: String {
        let white = board.white?.name ?? "White"
        let black = board.black?.name ?? "Black"
        let state = board.isOngoing ? "in progress" : "finished \(board.status)"
        return "Board \(boardNumber), \(white) versus \(black), \(state)"
    }
}
