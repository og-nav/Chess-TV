import Testing
@testable import ImageryKit

/// The federation table: the codes Lichess actually sends, and the four that have no flag of
/// their own. The FIDE list is not ISO alpha-3, so the cases that catch a careless mapping are
/// the ones where the two disagree.
@Suite("Federations")
struct FederationsTests {

    @Test(
        "FIDE codes map to the right flag",
        arguments: [
            ("NOR", "🇳🇴", "Norway"),
            ("USA", "🇺🇸", "United States of America"),
            ("NED", "🇳🇱", "Netherlands"),        // not NLD
            ("GER", "🇩🇪", "Germany"),            // not DEU
            ("PHI", "🇵🇭", "Philippines"),        // not PHL
            ("IRI", "🇮🇷", "Iran"),               // not IRN
            ("SUI", "🇨🇭", "Switzerland"),        // not CHE
            ("RSA", "🇿🇦", "South Africa"),       // not ZAF
            ("IND", "🇮🇳", "India"),
            ("CHN", "🇨🇳", "China"),
            ("UZB", "🇺🇿", "Uzbekistan"),
            ("ARG", "🇦🇷", "Argentina"),
            ("POL", "🇵🇱", "Poland"),
            ("AZE", "🇦🇿", "Azerbaijan"),
            ("TPE", "🇹🇼", "Chinese Taipei"),
            ("KOS", "🇽🇰", "Kosovo"),
        ]
    )
    func mapsCodes(code: String, flag: String, name: String) {
        #expect(Federations.flag(for: code) == flag)
        #expect(Federations.name(for: code) == name)
    }

    @Test("The home nations use subdivision tag sequences, not a GB flag")
    func homeNations() {
        #expect(Federations.flag(for: "ENG") == "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}")
        #expect(Federations.flag(for: "SCO") == "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}")
        #expect(Federations.flag(for: "WLS") == "\u{1F3F4}\u{E0067}\u{E0062}\u{E0077}\u{E006C}\u{E0073}\u{E007F}")
        #expect(Federations.name(for: "ENG") == "England")
        #expect(Federations.name(for: "SCO") == "Scotland")
        #expect(Federations.name(for: "WLS") == "Wales")
        // Each is one grapheme, so it lays out as a single flag rather than a row of letters.
        #expect(Federations.flag(for: "ENG")?.count == 1)
    }

    @Test("Players under the FIDE flag get a neutral white flag, not nothing")
    func neutralFlag() {
        #expect(Federations.flag(for: "FID") == "\u{1F3F3}\u{FE0F}")
        #expect(Federations.flag(for: "AIN") == "\u{1F3F3}\u{FE0F}")
        #expect(Federations.name(for: "FID") == "FIDE")
    }

    @Test("The disability federations are real codes with no flag")
    func disabilityFederations() {
        #expect(Federations.name(for: "IBCA") == "International Braille Chess Association")
        #expect(Federations.flag(for: "IBCA") == nil)
        #expect(Federations.name(for: "IPCA") != nil)
        #expect(Federations.name(for: "ICCD") != nil)
    }

    @Test("Lookups tolerate case and stray whitespace from broadcast organisers")
    func normalizesInput() {
        #expect(Federations.flag(for: "nor") == "🇳🇴")
        #expect(Federations.flag(for: " NOR ") == "🇳🇴")
        #expect(Federations.flag(for: "Nor") == "🇳🇴")
    }

    @Test("An unknown code is nil rather than a wrong flag")
    func unknownCodes() {
        #expect(Federations.flag(for: "ZZZ") == nil)
        #expect(Federations.name(for: "ZZZ") == nil)
        #expect(Federations.flag(for: "") == nil)
        #expect(Federations.flag(for: "NORWAY") == nil)
    }

    @Test("The table is the whole FIDE list and every entry resolves to something")
    func tableIsComplete() {
        // FIDE lists a little over two hundred federations; a table that has quietly lost half
        // of itself should fail here rather than silently drop flags on screen.
        #expect(Federations.allCodes.count > 200)
        for code in Federations.allCodes {
            #expect(Federations.name(for: code)?.isEmpty == false, "\(code) has no name")
            // Either an alpha-2 that yields a flag, or one of the documented literal/no-flag cases.
            if let alpha2 = Federations.entry(for: code)?.alpha2 {
                #expect(alpha2.count == 2, "\(code) alpha-2 is \(alpha2)")
                #expect(Federations.flag(for: code) != nil, "\(code) has no flag")
            }
        }
        // Spot-check that no two federations were given the same country.
        let alpha2s = Federations.allCodes.compactMap { Federations.entry(for: $0)?.alpha2 }
        #expect(Set(alpha2s).count == alpha2s.count)
    }
}
