// Credits: what this app is built out of, and the licences that come with it.
//
// The list itself is `Credits.entries`, shared with the Apple TV app, so the two screens cannot
// drift. What is phone-specific is here: a Form, real links (the TV has none), and a licence
// text on a pushed screen rather than a second full-screen cover.
import SwiftUI

struct CreditsScreen: View {

    var body: some View {
        Form {
            ForEach(Credits.entries) { entry in
                Section {
                    ForEach(Array(entry.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .listRowBackground(Palette.panel)
                    }
                    if let link = entry.link, let url = URL(string: "https://" + link) {
                        Link(link, destination: url)
                            .listRowBackground(Palette.panel)
                    }
                    ForEach(entry.licences) { licence in
                        NavigationLink(value: MobileRoute.licence(licence)) {
                            Text(licence.title)
                        }
                        .listRowBackground(Palette.panel)
                        .accessibilityIdentifier(UIID.Credits.licence(licence.rawValue))
                    }
                } header: {
                    Text(entry.title)
                        .accessibilityIdentifier(UIID.Credits.entry(entry.id))
                }
            }

            Section {
                ForEach(Credits.Licence.allCases) { licence in
                    NavigationLink(value: MobileRoute.licence(licence)) {
                        Text(licence.title)
                    }
                    .listRowBackground(Palette.panel)
                }
            } header: {
                Text("Licences")
            } footer: {
                Text("The full texts travel with the app, so they can be read with no connection.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .navigationTitle("Credits")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One bundled licence, verbatim.
///
/// Monospaced and scrollable both ways, because the canonical texts are hard-wrapped at seventy
/// columns and reflowing them into a phone's width turns the Apache header and the GPL's indented
/// clauses into soup. A licence is reference material: it should be exactly what gnu.org and
/// apache.org publish, and legible enough to check that it is.
struct LicenceScreen: View {
    let licence: Credits.Licence

    @State private var text: String = ""

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(16)
                .accessibilityIdentifier(UIID.Credits.licenceText)
        }
        .background(Palette.ground)
        .navigationTitle(licence.shortTitle)
        .navigationBarTitleDisplayMode(.inline)
        // Off the main thread would be nicer; 35 KB from the bundle is under a millisecond, and
        // doing it in `task` rather than in `body` keeps it off every re-render.
        .task { if text.isEmpty { text = licence.text() } }
    }
}
