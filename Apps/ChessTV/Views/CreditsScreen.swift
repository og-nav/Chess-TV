// Credits on the Apple TV, and the licence texts under it.
//
// Two tvOS facts shape this screen. The TV cannot open a web page, so a licence that is only a
// URL is a licence nobody here can read — the texts are bundled and shown in full. And nothing
// on tvOS scrolls unless something in it can take focus, so every block on both screens is
// focusable: walking down with the remote is what moves the page.
//
// The list itself is `Credits.entries`, shared with the phone.
import SwiftUI

struct CreditsScreen: View {
    /// Back to Settings. Owned by `SettingsScreen`, which shows this in its own place rather than
    /// stacking a second full-screen cover on the first.
    let close: () -> Void

    @State private var licence: Credits.Licence?

    var body: some View {
        VStack(spacing: 24) {
            header
            Group {
                if let licence {
                    LicenceReader(licence: licence)
                } else {
                    list
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, Metrics.extraHorizontalPadding)
        .foregroundStyle(Palette.ink)
        // Back / Menu steps out of a licence first, then out of Credits, and only then reaches
        // the Settings screen's own handler.
        .onExitCommand(perform: goBack)
    }

    private func goBack() {
        if licence != nil { licence = nil } else { close() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 24) {
            Text("Chess TV")
                .font(.system(size: 40, weight: .semibold))
                .tracking(-1.5)
            Rectangle().fill(Palette.line).frame(width: 2, height: 28)
            Text(licence?.shortTitle.uppercased() ?? "CREDITS")
                .font(.system(size: 24))
                .tracking(3.84)
                .foregroundStyle(Palette.muted)
            Spacer()
            Button(action: goBack) {
                Text(licence == nil ? "Done" : "Back")
                    .font(.system(size: 26))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 10)
                    .frame(minHeight: 52)
                    .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 2))
            }
            .buttonStyle(TVFocusButtonStyle(cornerRadius: 40, padded: 4))
            .accessibilityLabel(licence == nil ? "Done" : "Back")
            .accessibilityIdentifier(UIID.Credits.done)
        }
        .frame(height: Metrics.headerHeight)
        // Its own section, so "up" from the list always reaches the button.
        .focusSection()
    }

    // MARK: - The list

    private var list: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(Credits.entries) { entry in
                    FocusableBlock {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(entry.title)
                                .font(.system(size: 36, weight: .semibold))
                            ForEach(Array(entry.lines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 24))
                                    .foregroundStyle(Palette.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let link = entry.link {
                                // Not a link: tvOS has no browser. It is printed so it can be
                                // typed into a phone, which is what a TV credit is for.
                                Text(link)
                                    .font(.system(size: 24))
                                    .foregroundStyle(Palette.accent)
                            }
                        }
                    }
                    .accessibilityIdentifier(UIID.Credits.entry(entry.id))

                    ForEach(entry.licences) { licence in
                        Button {
                            self.licence = licence
                        } label: {
                            HStack(spacing: 14) {
                                Text("Read the \(licence.title)")
                                    .font(.system(size: 24))
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.system(size: 20))
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.panel))
                        }
                        .buttonStyle(TVFocusButtonStyle(cornerRadius: 16, padded: 6))
                        .accessibilityLabel(licence.title)
                        .accessibilityIdentifier(UIID.Credits.licence(licence.rawValue))
                    }
                }
            }
            .padding(.vertical, 16)
            .frame(maxWidth: 1400, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - One licence

/// A bundled licence, verbatim, in blocks the remote can walk down.
///
/// Monospaced because the canonical texts are hard-wrapped at seventy columns: reflowing them
/// turns the Apache header and the GPL's indented clauses into porridge, and a licence should be
/// exactly what gnu.org and apache.org publish.
private struct LicenceReader: View {
    let licence: Credits.Licence

    @State private var blocks: [String] = []

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    FocusableBlock {
                        Text(block)
                            .font(.system(size: 22, design: .monospaced))
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.vertical, 16)
            .frame(maxWidth: 1500, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier(UIID.Credits.licenceText)
        .task { if blocks.isEmpty { blocks = Credits.blocks(of: licence.text()) } }
    }
}

// MARK: - A block the remote can land on

/// A card that takes focus and does nothing else.
///
/// tvOS gives `.focusable()` no appearance of its own, and a `ScrollView` whose contents cannot
/// be focused cannot be scrolled with the Siri Remote at all. So a block of text that has to be
/// readable on a TV has to be focusable, and has to show that it is.
private struct FocusableBlock<Content: View>: View {
    @ViewBuilder let content: Content
    @FocusState private var focused: Bool

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(focused ? Palette.line : Palette.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(focused ? Palette.accent : .clear, lineWidth: 4)
            )
            .focusable()
            .focused($focused)
            .animation(.easeOut(duration: 0.15), value: focused)
            .accessibilityElement(children: .combine)
    }
}
