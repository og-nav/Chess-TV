// The Music row on the Settings screen: what Apple Music is doing, the playlists on offer and
// the two transport buttons. Focusable throughout, so the Siri Remote can reach all of it.
import SwiftUI
import MusicKit

struct MusicSettingsSection: View {
    @Environment(AppModel.self) private var model

    private var music: MusicController { model.music }

    var body: some View {
        SettingsSection(title: "Music", value: music.selectedPlaylistName ?? "None") {
            VStack(alignment: .leading, spacing: 18) {
                Text(statusText)
                    .font(.system(size: 22))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)

                if music.readiness == .notDetermined {
                    connectButton
                }
                if !music.playlists.isEmpty {
                    playlistRow
                    transportRow
                }
            }
        }
    }

    // MARK: - State line

    private var statusText: String {
        if let error = music.lastError { return error }
        switch music.readiness {
        case .notDetermined:
            return "Connect Apple Music to play one of your playlists while you watch, started and stopped with Play/Pause on the Siri Remote."
        case .denied:
            return "Apple Music is turned off for Chess TV. Turn it back on in the tvOS Settings app, under General \u{203A} Privacy."
        case .restricted:
            return "Apple Music is restricted on this Apple TV."
        case .checking:
            return "Checking your Apple Music subscription\u{2026}"
        case .noSubscription:
            return "Apple Music subscription needed on this Apple TV."
        case .ready:
            if music.isLoadingPlaylists { return "Finding your playlists\u{2026}" }
            if music.playlists.isEmpty { return "No playlists to offer yet." }
            return "Plays in the background, shuffled, while the game is on screen. Play/Pause on the Siri Remote starts and stops it from any screen."
        }
    }

    private var connectButton: some View {
        Button {
            Task { await music.requestAuthorization() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "music.note")
                Text("Connect Apple Music").fixedSize()
            }
            .font(.system(size: 26))
            .padding(.horizontal, 28)
            .padding(.vertical, 10)
            .frame(minHeight: 56)
            .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 2))
        }
        .buttonStyle(TVFocusButtonStyle(cornerRadius: 40, padded: 4))
        .accessibilityIdentifier(UIID.Settings.musicConnect)
    }

    // MARK: - Playlists

    private var playlistRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 20) {
                ForEach(music.playlists) { item in
                    card(item)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
        .scrollClipDisabled()
        // Its own section, so leaving the row goes straight up or down instead of walking
        // through every card.
        .focusSection()
    }

    private func card(_ item: MusicPlaylistItem) -> some View {
        let isOn = music.isSelected(item)
        return Button {
            music.select(item)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                artwork(item)
                    .frame(width: 160, height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isOn ? Palette.accent : .clear, lineWidth: 4)
                    )
                HStack(spacing: 8) {
                    if isOn {
                        Image(systemName: "checkmark").font(.system(size: 18)).foregroundStyle(Palette.accent)
                    }
                    Text(item.name)
                        .font(.system(size: 22))
                        .foregroundStyle(isOn ? Palette.ink : Palette.moveText)
                        .lineLimit(1)
                }
                Text(item.subtitle ?? (item.origin == .library ? "Your library" : "Apple Music"))
                    .font(.system(size: 18))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            .frame(width: 160, alignment: .leading)
        }
        .buttonStyle(TVFocusButtonStyle(cornerRadius: 14, padded: 6))
        .accessibilityLabel(item.name)
        .accessibilityIdentifier(UIID.Settings.playlist(item.id))
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    @ViewBuilder
    private func artwork(_ item: MusicPlaylistItem) -> some View {
        if let artwork = item.artwork {
            ArtworkImage(artwork, width: 160, height: 160)
        } else {
            ZStack {
                Palette.panel
                Image(systemName: "music.note.list")
                    .font(.system(size: 44))
                    .foregroundStyle(Palette.faint)
            }
        }
    }

    // MARK: - Transport

    private var transportRow: some View {
        HStack(spacing: 20) {
            transportButton(
                music.isPlaying ? "Pause" : "Play",
                systemImage: music.isPlaying ? "pause.fill" : "play.fill"
            ) {
                Task { await music.toggle() }
            }
            .accessibilityIdentifier(UIID.Settings.musicPlay)
            transportButton("Next", systemImage: "forward.fill") {
                Task { await music.next() }
            }
            .accessibilityIdentifier(UIID.Settings.musicNext)
            if let line = music.nowPlayingLine {
                Text(line)
                    .font(.system(size: 20))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .focusSection()
    }

    private func transportButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                Text(title).fixedSize()
            }
            .font(.system(size: 24))
            .padding(.horizontal, 26)
            .padding(.vertical, 8)
            .frame(minHeight: 52)
            .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 2))
        }
        .buttonStyle(TVFocusButtonStyle(cornerRadius: 36, padded: 4))
        .accessibilityLabel(title)
    }
}
