// The settings screen, laid out like design/mockups/Settings.dc.html.
// Everything on the right is a real Button so the Siri Remote can reach it.
import SwiftUI
import ChessCore
import ChessUI

struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Focus opens on the first board swatch, keyed by theme name; Done sits in its own section above.
    @FocusState private var focusedSwatch: String?
    /// Credits take this screen's place rather than stacking a second full-screen cover on the
    /// one Settings is already presented in: one presentation, and Back steps back through it.
    @State private var showingCredits = false

    private var settings: AppSettings { model.settings }

    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            if showingCredits {
                CreditsScreen(close: { showingCredits = false })
            } else {
                VStack(spacing: Metrics.sectionGap) {
                    header
                    HStack(alignment: .center, spacing: 96) {
                        preview
                        controls
                    }
                    .frame(maxHeight: .infinity)
                    footer
                }
                .padding(.horizontal, Metrics.extraHorizontalPadding)
            }
        }
        .foregroundStyle(Palette.ink)
        .defaultFocus($focusedSwatch, BoardTheme.all.first?.name)
        // Back / Menu returns to the game, exactly like Done. Credits handle their own first.
        .onExitCommand { close() }
    }

    private func close() {
        model.showingSettings = false
        dismiss()
    }

    // MARK: - Header and footer

    private var header: some View {
        HStack(spacing: 24) {
            Text("Chess TV")
                .font(.system(size: 40, weight: .semibold))
                .tracking(-1.5)
            Rectangle().fill(Palette.line).frame(width: 2, height: 28)
            Text("SETTINGS")
                .font(.system(size: 24))
                .tracking(3.84)
                .foregroundStyle(Palette.muted)
            Spacer()
            Button(action: close) {
                Text("Done")
                    .font(.system(size: 26))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 10)
                    .frame(minHeight: 52)
                    .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 2))
            }
            .buttonStyle(TVFocusButtonStyle(cornerRadius: 40, padded: 4))
            .accessibilityLabel("Done")
            .accessibilityIdentifier(UIID.Settings.done)
        }
        .frame(height: Metrics.headerHeight)
        // Its own section, so "up" from the controls column always reaches Done.
        .focusSection()
    }

    private var footer: some View {
        HStack {
            Text("Press Back or choose Done to return to the game")
            Spacer()
            Text("Lichess piece sets (GPL) \u{00B7} Stockfish 19 (GPLv3) \u{00B7} Chess TV 0.1")
        }
        .font(.system(size: 24))
        .foregroundStyle(Palette.muted)
        .frame(height: Metrics.footerHeight)
    }

    // MARK: - Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 18) {
            BoardView(
                position: model.game.position ?? .standard,
                lastMove: model.game.position == nil ? nil : model.game.lastMove,
                theme: settings.boardTheme,
                pieceSet: settings.pieceSet,
                orientation: model.boardOrientation,
                showCoordinates: settings.coordinates
            )
            .frame(width: 600, height: 600)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(summary)
                .font(.system(size: 24))
                .foregroundStyle(Palette.muted)
                .lineLimit(2)
                .frame(width: 600, alignment: .leading)
                .accessibilityIdentifier(UIID.Settings.summary)
        }
        .frame(width: 600)
    }

    private var summary: String {
        "Preview \u{00B7} \(settings.boardTheme.name) board, \(settings.pieceSet.displayName) pieces, "
            + "Stockfish \(settings.engineEnabled ? "on (\(settings.engineDepth.displayName))" : "off"), "
            + "keep TV \(settings.keepTVOn ? "on" : "off")"
    }

    // MARK: - Controls

    private var controls: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings")
                    .font(.system(size: 56, weight: .semibold))
                    .tracking(-1.5)
                Text("Saved on this Apple TV. Reach this screen from the Settings button under the board, "
                    + "where the button beside it turns the board around.")
                    .font(.system(size: 24))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .padding(.bottom, 16)

                SettingsSection(title: "Board colors", value: settings.boardTheme.name, valueID: UIID.Settings.boardTheme) {
                    HStack(spacing: 20) {
                        ForEach(BoardTheme.all, id: \.name) { theme in
                            swatch(theme)
                        }
                    }
                }

                SettingsSection(title: "Pieces", value: settings.pieceSet.displayName, valueID: UIID.Settings.pieces) {
                    HStack(spacing: 20) {
                        ForEach(PieceSet.allCases, id: \.self) { set in
                            pieceButton(set)
                        }
                    }
                }

                SettingsSection(title: "Engine depth", value: settings.engineDepth.displayName, valueID: UIID.Settings.depth) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 20) {
                            ForEach(EngineDepth.allCases, id: \.self) { depth in
                                depthButton(depth)
                            }
                        }
                        Text("Deeper search runs the Apple TV hotter and may slow it down. "
                            + "Standard is fine for most games.")
                            .font(.system(size: 20))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                MusicSettingsSection()

                SettingsSection(title: "Credits", value: "Lichess, FIDE, Stockfish", valueID: UIID.Settings.credits + ".value") {
                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            showingCredits = true
                        } label: {
                            HStack(spacing: 14) {
                                Text("Credits and licences")
                                    .font(.system(size: 24))
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.system(size: 20))
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(minHeight: 72)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.panel))
                        }
                        .buttonStyle(TVFocusButtonStyle(cornerRadius: 16, padded: 6))
                        .accessibilityLabel("Credits and licences")
                        .accessibilityIdentifier(UIID.Settings.credits)
                        Text("Who the games, the portraits, the engine and the pieces come from, "
                            + "with the full licence texts \u{2014} this Apple TV cannot open a link.")
                            .font(.system(size: 20))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Two columns, as the mockup lays them out. The column scrolls, so focus brings
                // the lower toggles up as the remote walks down them.
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 48), GridItem(.flexible())], spacing: 14) {
                    toggle("Keep TV on", "No screensaver or sleep", settings.keepTVOn, id: UIID.Settings.keepTVOn) {
                        settings.keepTVOn.toggle()
                        model.applyIdleTimer()
                    }
                    toggle("Stockfish evaluation", "Eval bar and score, on this TV", settings.engineEnabled, id: UIID.Settings.engine) {
                        model.toggleEngine()
                    }
                    toggle("Coordinates", "Files and ranks on the board", settings.coordinates, id: UIID.Settings.coordinates) {
                        settings.coordinates.toggle()
                    }
                    toggle("Move sounds", "Move, capture and check", settings.sounds, id: UIID.Settings.sounds) {
                        settings.sounds.toggle()
                    }
                    toggle("Follow the featured player", "Flip so they play upward", settings.followFeaturedPlayer, id: UIID.Settings.followFeatured) {
                        settings.followFeaturedPlayer.toggle()
                    }
                    toggle("Tournament alerts", "Results and time scrambles on other boards", settings.tournamentAlerts, id: UIID.Settings.tournamentAlerts) {
                        settings.tournamentAlerts.toggle()
                    }
                }
                .padding(.vertical, 16)
                .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 2) }
            }
            .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity)
    }

    private func swatch(_ theme: BoardTheme) -> some View {
        let isOn = theme.name == settings.boardThemeName
        return Button {
            settings.boardThemeName = theme.name
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) { theme.light; theme.dark }
                    HStack(spacing: 0) { theme.dark; theme.light }
                }
                .frame(height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isOn ? Palette.accent : .clear, lineWidth: 4)
                )
                Text(theme.name)
                    .font(.system(size: 22))
                    .foregroundStyle(isOn ? Palette.ink : Palette.muted)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(TVFocusButtonStyle(cornerRadius: 14, padded: 6))
        .focused($focusedSwatch, equals: theme.name)
        .accessibilityLabel("\(theme.name) board")
        .accessibilityIdentifier(UIID.Settings.theme(theme.name))
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private func pieceButton(_ set: PieceSet) -> some View {
        let isOn = set == settings.pieceSet
        return Button {
            settings.pieceSet = set
        } label: {
            HStack(spacing: 16) {
                PieceAssets.image(set: set, piece: Piece(kind: .knight, color: .white))
                    .resizable().aspectRatio(contentMode: .fit).frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(set.displayName).font(.system(size: 24))
                    Text(note(for: set)).font(.system(size: 19)).foregroundStyle(Palette.muted)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 88)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.panel))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isOn ? Palette.accent : .clear, lineWidth: 4)
            )
        }
        .buttonStyle(TVFocusButtonStyle(cornerRadius: 16, padded: 6))
        .accessibilityLabel("\(set.displayName) pieces")
        .accessibilityIdentifier(UIID.Settings.pieceSet(set.rawValue))
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private func depthButton(_ depth: EngineDepth) -> some View {
        let isOn = depth == settings.engineDepth
        return Button {
            model.setEngineDepth(depth)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(depth.displayName).font(.system(size: 24))
                Text(note(for: depth)).font(.system(size: 19)).foregroundStyle(Palette.muted)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 88)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.panel))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isOn ? Palette.accent : .clear, lineWidth: 4)
            )
        }
        .buttonStyle(TVFocusButtonStyle(cornerRadius: 16, padded: 6))
        .accessibilityLabel("\(depth.displayName) engine depth")
        .accessibilityIdentifier(UIID.Settings.depth(depth.rawValue))
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private func note(for depth: EngineDepth) -> String {
        switch depth {
        case .light: "Depth 18, coolest"
        case .standard: "Depth 24"
        case .deep: "Depth 32"
        case .maximum: "Depth 40, runs hottest"
        }
    }

    private func note(for set: PieceSet) -> String {
        switch set {
        case .cburnett: "Lichess default"
        case .merida: "Traditional"
        case .chessnut: "Modern outlines"
        }
    }

    private func toggle(_ title: String, _ note: String, _ isOn: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 26))
                    Text(note).font(.system(size: 19)).foregroundStyle(Palette.muted).lineLimit(1)
                }
                Spacer(minLength: 12)
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? Palette.accent : Palette.line)
                    Circle().fill(Palette.ink).frame(width: 38, height: 38).padding(5)
                }
                .frame(width: 84, height: 48)
                .animation(.easeOut(duration: 0.15), value: isOn)
            }
            .frame(minHeight: 56)
        }
        .buttonStyle(TVFocusButtonStyle(cornerRadius: 12, padded: 8))
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}
