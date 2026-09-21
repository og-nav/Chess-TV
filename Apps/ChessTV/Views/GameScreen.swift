// The live game. Board first, exactly as design/mockups/Main.dc.html lays it out.
import SwiftUI
import ChessCore
import ChessUI
import LichessKit

struct GameScreen: View {
    /// What to watch, and how to spell it in the header.
    let destination: GameDestination

    @Environment(AppModel.self) private var model
    /// The footer's Settings button takes focus first; the flip button sits beside it.
    @FocusState private var settingsFocused: Bool

    var body: some View {
        @Bindable var model = model
        ZStack {
            Palette.ground.ignoresSafeArea()
            content
        }
        .foregroundStyle(Palette.ink)
        .defaultFocus($settingsFocused, true)
        // Play/Pause is the one command that is not a focus move: it runs the music. The
        // engine is toggled from Settings only.
        .onPlayPauseCommand { Task { await model.music.toggleFromRemote() } }
        // No .onExitCommand: Back pops this screen and returns to the home screen.
        .task { model.open(destination); model.session.noteScreenAppeared() }
        .onDisappear { model.close() }
        .fullScreenCover(isPresented: $model.showingSettings) {
            SettingsScreen()
                .environment(model)
        }
        .onChange(of: model.showingSettings) { _, showing in
            if !showing { settingsFocused = true }
        }
    }

    // MARK: - Layout

    private var content: some View {
        VStack(spacing: Metrics.sectionGap) {
            header
            gameSection
            footer
        }
        .padding(.horizontal, Metrics.extraHorizontalPadding)
    }

    private var title: String {
        model.sourceTitle.isEmpty ? (destination.title ?? SourceTitle.text(for: destination.source)) : model.sourceTitle
    }

    private var header: some View {
        HStack(spacing: 40) {
            Text(title)
                .font(.system(size: 40, weight: .semibold))
                .tracking(-1)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityIdentifier(UIID.Game.title)
            Spacer(minLength: 12)
            // A tournament alert takes the chips' place for a few seconds, so it covers nothing.
            if let toast = model.toast {
                ToastChip(alert: toast)
                    .accessibilityIdentifier(UIID.Game.toast)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                HStack(spacing: 32) {
                    // Arenas only: how long the tournament itself has left.
                    if let timeLeft = model.arenaTimeLeftText {
                        endsInChip(timeLeft)
                    }
                    if let finished = model.game.finished {
                        gameOverChip(finished)
                            .accessibilityIdentifier(UIID.Game.status)
                    } else {
                        StatusChip(connection: model.game.connection)
                            .accessibilityIdentifier(UIID.Game.status)
                    }
                    Text(model.wallClock, format: .dateTime.hour().minute())
                        .font(.system(size: 24))
                        .monospacedDigit()
                        .foregroundStyle(Palette.muted)
                        .fixedSize()
                }
                .transition(.opacity)
            }
        }
        .frame(height: Metrics.headerHeight)
        .animation(.easeOut(duration: 0.35), value: model.toast)
    }

    /// "Ends in 34:05", in the connection chip's shape and height.
    private func endsInChip(_ timeLeft: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "hourglass")
                .font(.system(size: 22))
            Text("Ends in \(timeLeft)")
                .font(.system(size: 24))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(Palette.muted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Arena ends in \(timeLeft)")
        .accessibilityIdentifier(UIID.Game.endsIn)
    }

    private func gameOverChip(_ finished: GameState.Finished) -> some View {
        Text(finished.text)
            .font(.system(size: 24))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .background(Capsule(style: .continuous).fill(Palette.panel))
            .overlay(Capsule(style: .continuous).strokeBorder(Palette.line, lineWidth: 2))
            .foregroundStyle(Palette.amber)
            .accessibilityLabel(finished.text)
    }

    private var gameSection: some View {
        GeometryReader { proxy in
            // The mockup's 800 pt board, shrunk if a TV's overscan leaves us less room.
            let side = min(Metrics.boardSide, proxy.size.height)
            HStack(alignment: .top, spacing: Metrics.columnGap) {
                Group {
                    if model.showsEvalBar {
                        EvalBarView(whiteShare: model.game.whiteShare ?? 0.5, orientation: model.boardOrientation)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: Metrics.evalBarWidth, height: side)

                boardArea(side: side)

                SidePanel(model: model)
                    .frame(height: side)
                    .padding(.leading, Metrics.panelGap - Metrics.columnGap)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func boardArea(side: Double) -> some View {
        ZStack {
            if model.game.position == nil {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Palette.panel)
                VStack(spacing: 16) {
                    Text("Connecting to Lichess\u{2026}")
                        .font(.system(size: 36))
                        .foregroundStyle(Palette.muted)
                    Text(title)
                        .font(.system(size: 24))
                        .foregroundStyle(Palette.faint)
                        .lineLimit(1)
                }
            } else {
                BoardView(
                    position: model.game.position,
                    lastMove: model.game.lastMove,
                    theme: model.settings.boardTheme,
                    pieceSet: model.settings.pieceSet,
                    orientation: model.boardOrientation,
                    showCoordinates: model.settings.coordinates
                )
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
        .frame(width: side, height: side)
    }

    private var footer: some View {
        HStack(spacing: 32) {
            settingsButton
            flipButton
            Text("Back for the home screen \u{00B7} Play/Pause for music")
                .lineLimit(1)
            Spacer(minLength: 12)
            if let line = model.music.nowPlayingLine {
                Text(line)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 560, alignment: .trailing)
            }
            Text(model.showsEvalBar ? "Stockfish 19 on this Apple TV" : "Lichess")
                .lineLimit(1)
                .fixedSize()
        }
        .font(.system(size: 24))
        .foregroundStyle(Palette.muted)
        .frame(height: Metrics.footerHeight)
        .focusSection()
    }

    private var settingsButton: some View {
        Button {
            model.showingSettings = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "gearshape")
                Text("Settings")
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 2)
            .frame(minHeight: 36)
            .foregroundStyle(Palette.ink)
        }
        .buttonStyle(TVFocusButtonStyle(cornerRadius: 26, padded: 4))
        .focused($settingsFocused)
        .accessibilityLabel("Settings")
        .accessibilityIdentifier(UIID.Game.settings)
    }

    /// Names the side you would switch to, so the button reads as the move it makes.
    private var flipLabel: String {
        model.boardOrientation == .white ? "Watch as Black" : "Watch as White"
    }

    private var flipButton: some View {
        Button {
            model.toggleFlipBoard()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.up.arrow.down")
                Text(flipLabel)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 2)
            .frame(minHeight: 36)
            .foregroundStyle(Palette.ink)
        }
        .buttonStyle(TVFocusButtonStyle(cornerRadius: 26, padded: 4))
        .accessibilityLabel(flipLabel)
        .accessibilityIdentifier(UIID.Game.flip)
    }
}
