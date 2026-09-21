// The complete position, both clocks and SAN fit together in the initial viewport.
// The Crown reveals event details and the flip control below that core group.
import SwiftUI
import ChessCore
import FollowKit
import LichessKit

struct WatchBoardView: View {
    private let seed: WatchFollowsModel.Row
    @State private var detail: WatchGameDetailModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isFlipped = false
    @ScaledMetric(relativeTo: .caption2) private var playerFontSize: CGFloat = 12

    init(row: WatchFollowsModel.Row) {
        seed = row
        _detail = State(initialValue: WatchGameDetailModel(row: row))
    }

    private var row: WatchFollowsModel.Row { detail.row }

    private var appearance: BoardAppearance {
        var appearance = BoardAppearance.fromAppGroup()
        appearance.showsCoordinates = false
        appearance.orientation = isFlipped ? .black : .white
        return appearance
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                if let board = row.board {
                    let top: PieceColor = isFlipped ? .white : .black
                    let coreHeight = max(100, geometry.size.height - 8)
                    let boardSize = max(40, min(geometry.size.width - 8, coreHeight - 52))
                    VStack(spacing: 8) {
                        VStack(spacing: 2) {
                            playerLine(board, color: top)
                                .frame(height: 16)
                            PositionBoard(fen: board.fen, lastMoveUCI: board.lastMove, appearance: appearance)
                                .frame(width: boardSize, height: boardSize)
                                .accessibilityAction(named: Text("Flip the board")) { InteractionFeedback.tap(); isFlipped.toggle() }
                            playerLine(board, color: top.opposite)
                                .frame(height: 16)
                            moveSummary(board)
                                .frame(height: 14)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: coreHeight, alignment: .top)
                        footer(board)
                            .padding(.bottom, 14)
                    }
                    .padding(.horizontal, 4)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "clock")
                            .foregroundStyle(ChessTVPalette.accent)
                        Text("Waiting for this game")
                            .font(.footnote)
                        if let subtitle = row.subtitle {
                            Text(subtitle).font(.caption2).foregroundStyle(ChessTVPalette.muted)
                        }
                    }
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                }
            }
            .scrollIndicators(.visible)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { if scenePhase == .active { detail.start() } }
        .onDisappear { detail.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { detail.start() } else { detail.stop() }
        }
        .onChange(of: seed) { _, row in detail.updateSeed(row) }
    }

    @ViewBuilder
    private func playerLine(_ board: BroadcastBoard, color: PieceColor) -> some View {
        if let player = color == .white ? board.white : board.black {
            let running = board.isOngoing && !row.isStale && row.clockRunningFor == (color == .white ? "white" : "black")
            HStack(spacing: 5) {
                Circle()
                    .fill(color == .white ? ChessTVPalette.ink : ChessTVPalette.panel)
                    .overlay(Circle().stroke(ChessTVPalette.muted, lineWidth: 0.7))
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(color == .white ? "White" : "Black")
                Text(player.surname)
                    .font(.system(size: playerFontSize, weight: .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ClockChip(seconds: player.clockSeconds,
                    deadline: running ? ChessFormat.deadline(seconds: player.clockSeconds, asOf: row.asOf) : nil,
                    compact: true)
            }
            .foregroundStyle(ChessTVPalette.ink)
            .accessibilityElement(children: .combine)
        }
    }

    private func moveSummary(_ board: BroadcastBoard) -> some View {
            HStack(alignment: .center, spacing: 8) {
                if let move = lastMoveLabel(board) {
                    Text(move)
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 2)
                Text(ChessFormat.result(status: board.status) ?? (row.isStale ? "Saved" : "Live"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(board.isOngoing && !row.isStale ? ChessTVPalette.accent : ChessTVPalette.muted)
                    .accessibilityLabel(row.isStale && board.isOngoing ? "Saved position. Clocks paused while reconnecting." : (ChessFormat.result(status: board.status) ?? "Live"))
            }
    }

    private func footer(_ board: BroadcastBoard) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(row.roundName ?? row.tourName ?? "Broadcast")
                    .font(.system(size: 11))
                    .foregroundStyle(ChessTVPalette.muted)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button { InteractionFeedback.tap(); isFlipped.toggle() } label: {
                    Label("Flip", systemImage: "arrow.up.arrow.down")
                        .font(.system(size: 11))
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ChessTVPalette.accent)
                .accessibilityLabel("Flip the board")
            }
        }
    }

    private func lastMoveLabel(_ board: BroadcastBoard) -> String? {
        guard let san = row.san, !san.isEmpty else { return nil }
        guard let position = try? Position(fen: board.fen) else { return san }
        let whiteMoved = position.sideToMove == .black
        let number = whiteMoved ? position.fullmoveNumber : max(1, position.fullmoveNumber - 1)
        return whiteMoved ? "\(number). \(san)" : "\(number)… \(san)"
    }
}
