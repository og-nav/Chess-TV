// Shared furniture: the connection chip, the focus ring and the home-screen card style.
import SwiftUI
import ChessUI
import LichessKit

/// Green dot Live, amber ring Reconnecting, red dot Offline.
struct StatusChip: View {
    let connection: ConnectionState

    var body: some View {
        HStack(spacing: 12) {
            marker
            Text(label)
                .font(.system(size: 24))
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var marker: some View {
        switch connection {
        case .reconnecting, .connecting:
            Circle().strokeBorder(color, lineWidth: 3).frame(width: 12, height: 12)
        default:
            Circle().fill(color).frame(width: 12, height: 12)
        }
    }

    private var color: Color {
        switch connection {
        case .live: Palette.accent
        case .connecting, .reconnecting: Palette.amber
        case .failed: Palette.alert
        }
    }

    private var label: String {
        switch connection {
        case .live: "Live"
        case .connecting: "Connecting"
        case .reconnecting(_, let nextRetryIn):
            "Reconnecting \u{00B7} retry in \(max(1, Int(nextRetryIn.inSeconds.rounded())))s"
        case .failed: "Offline"
        }
    }
}

/// A tournament alert in the game header: accent dot, "Board 3", then what happened.
struct ToastChip: View {
    let alert: TournamentAlert

    var body: some View {
        HStack(spacing: 14) {
            Circle().fill(Palette.accent).frame(width: 12, height: 12)
            Text(alert.headline)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .fixedSize()
            Text(alert.detail)
                .font(.system(size: 24))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(Capsule(style: .continuous).fill(Palette.panel))
        .overlay(Capsule(style: .continuous).strokeBorder(Palette.accent.opacity(0.7), lineWidth: 2))
        .frame(maxWidth: 900, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(alert.text)
    }
}

/// tvOS focus styling for a plain button: a ring in the accent color and a small lift.
struct TVFocusButtonStyle: ButtonStyle {
    var cornerRadius: Double = 16
    var padded: Double = 8

    func makeBody(configuration: Configuration) -> some View {
        FocusRing(configuration: configuration, cornerRadius: cornerRadius, padded: padded)
    }

    private struct FocusRing: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: Double
        let padded: Double
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .padding(padded)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(isFocused ? Palette.line : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(isFocused ? Palette.accent : .clear, lineWidth: 4)
                )
                .scaleEffect(configuration.isPressed ? 0.98 : (isFocused ? 1.03 : 1))
                .animation(.easeOut(duration: 0.15), value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}


/// A small pulsing-free "live" marker: an accent dot plus a label.
struct LiveDot: View {
    var label: String = "LIVE"
    var color: Color = Palette.accent

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 12, height: 12)
            Text(label)
                .font(.system(size: 20, weight: .semibold))
                .tracking(2)
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

/// tvOS shelf-card styling: the card lifts and takes the accent ring when the remote lands on it.
struct HomeCardButtonStyle: ButtonStyle {
    var cornerRadius: Double = 18

    func makeBody(configuration: Configuration) -> some View {
        Card(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct Card: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: Double
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(isFocused ? Palette.line : Palette.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(isFocused ? Palette.accent : Palette.line, lineWidth: isFocused ? 4 : 2)
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .scaleEffect(configuration.isPressed ? 1.0 : (isFocused ? 1.06 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: 18, y: 8)
                .animation(.easeOut(duration: 0.15), value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .zIndex(isFocused ? 1 : 0)
        }
    }
}

/// One titled block of the Settings screen: a rule, a title, the current value on the right,
/// and whatever controls the block owns.
struct SettingsSection<Content: View>: View {
    let title: String
    let value: String
    /// An identifier for the value on the right, so a UI test can read what the block is set to.
    var valueID: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 28))
                Spacer()
                Text(value).font(.system(size: 22)).foregroundStyle(Palette.muted).lineLimit(1)
                    .accessibilityIdentifier(valueID ?? "")
            }
            content
        }
        .padding(.vertical, 16)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 2) }
    }
}
