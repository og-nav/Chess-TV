import Testing
@testable import ImageryKit

/// Initials for the name forms the feeds actually use. SwiftUI layout is not unit-tested here;
/// what is worth pinning down is the "Last, First" rule, which is easy to get backwards.
@Suite("Placeholders")
struct PlaceholderTests {

    @Test(
        "Initials read in the order a person would say the name",
        arguments: [
            ("Carlsen, Magnus", "MC"),          // FIDE and most broadcast PGNs
            ("Lynch, Mark O", "ML"),
            ("Nepomniachtchi, Ian", "IN"),
            ("Magnus Carlsen", "MC"),           // Lichess display names
            ("Erigaisi Arjun", "EA"),           // surname first, no comma: taken as written
            ("Vachier-Lagrave, Maxime", "MV"),
            ("van Foreest, Jorden", "JV"),
            ("Praggnanandhaa R", "PR"),
            ("Stockfish", "S"),                 // an engine has one name
            ("Maia1", "M"),
            ("", "?"),
            ("   ", "?"),
            ("123", "?"),                       // nothing to take an initial from
        ]
    )
    func initials(name: String, expected: String) {
        #expect(PlayerPlaceholder.initials(for: name) == expected)
    }

    @Test("Punctuation is skipped rather than used as an initial")
    func skipsPunctuation() {
        #expect(PlayerPlaceholder.initials(for: "O'Brien, Seamus") == "SO")
        // The leading apostrophe of the Dutch "'t" is skipped, not taken as the initial.
        #expect(PlayerPlaceholder.initials(for: "'t Hooft, Gerard") == "GT")
    }
}
