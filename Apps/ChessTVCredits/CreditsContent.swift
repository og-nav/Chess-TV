// What Chess TV is built out of, and who it belongs to.
//
// One list, compiled into both apps, because the Apple TV and the phone owe the same people the
// same acknowledgement and a credit that drifts between two screens is a credit nobody trusts.
// Pure data: no SwiftUI here, so the tvOS view and the iOS view can each lay it out the way
// their remote or their thumb wants it.
//
// The licence texts are bundled rather than linked. The Apple TV cannot open a web page at all,
// and a licence that is only a URL is a licence the user cannot read — which, for GPL'd code we
// ship (Stockfish, two of the three piece sets), is the one part of this that is an obligation
// and not a courtesy.
import Foundation

enum Credits {

    /// Where the source lives. The owner fills this in before the first public build; it is
    /// spelled out rather than hidden so an unfilled placeholder is visible on the screen itself
    /// instead of quietly shipping as an empty line.
    static let sourceURL = "https://github.com/og-nav/Chess-TV"

    /// A licence text carried in the app bundle, shown on its own scrollable screen.
    enum Licence: String, CaseIterable, Identifiable, Sendable {
        case gpl3, gpl2, apache2, agpl3

        public var id: String { rawValue }

        /// What the row and the screen's title call it.
        var title: String {
            switch self {
            case .gpl3: "GNU General Public License, version 3"
            case .gpl2: "GNU General Public License, version 2"
            case .apache2: "Apache License, version 2.0"
            case .agpl3: "GNU Affero General Public License, version 3"
            }
        }

        /// The short form used inside a sentence.
        var shortTitle: String {
            switch self {
            case .gpl3: "GPLv3"
            case .gpl2: "GPLv2"
            case .apache2: "Apache 2.0"
            case .agpl3: "AGPLv3"
            }
        }

        var resourceName: String {
            switch self {
            case .gpl3: "GPL-3.0"
            case .gpl2: "GPL-2.0"
            case .apache2: "Apache-2.0"
            case .agpl3: "AGPL-3.0"
            }
        }

        /// The verbatim text from gnu.org / apache.org, as bundled.
        ///
        /// Read on demand: GPLv3 alone is 35 KB, and none of it is wanted until somebody opens
        /// the screen. A missing file says so rather than showing an empty page, because an
        /// empty licence screen looks like a rendering bug and is in fact a packaging one.
        func text(bundle: Bundle = .main) -> String {
            guard let url = bundle.url(forResource: resourceName, withExtension: "txt"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                return "This build does not carry the text of the \(title). It is published at "
                    + canonicalURL + "."
            }
            return text
        }

        /// Where the canonical text lives, for the phone (the TV cannot open a link).
        var canonicalURL: String {
            switch self {
            case .gpl3: "https://www.gnu.org/licenses/gpl-3.0.html"
            case .gpl2: "https://www.gnu.org/licenses/old-licenses/gpl-2.0.html"
            case .apache2: "https://www.apache.org/licenses/LICENSE-2.0"
            case .agpl3: "https://www.gnu.org/licenses/agpl-3.0.html"
            }
        }
    }

    /// Cuts a licence into chunks a remote can step through.
    ///
    /// The Apple TV has no scroll gesture: a `ScrollView` full of plain text cannot be moved at
    /// all, because nothing in it can take focus. So the text is broken on its own paragraph
    /// breaks and each chunk becomes a focusable block, and pressing down walks the licence one
    /// screenful at a time. Paragraphs are never split, and short ones are grouped up to roughly
    /// `targetLength` characters so the GPL is forty stops rather than a hundred and thirty.
    static func blocks(of text: String, targetLength: Int = 900) -> [String] {
        var blocks: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n\n") {
            let paragraph = paragraph.trimmingCharacters(in: .newlines)
            guard !paragraph.isEmpty else { continue }
            if current.isEmpty {
                current = paragraph
            } else if current.count + paragraph.count + 2 <= targetLength {
                current += "\n\n" + paragraph
            } else {
                blocks.append(current)
                current = paragraph
            }
        }
        if !current.isEmpty { blocks.append(current) }
        return blocks
    }

    /// One block of the credits screen.
    struct Entry: Identifiable, Sendable {
        let id: String
        let title: String
        /// Paragraphs, in the order they are read.
        let lines: [String]
        /// A web address worth naming. Shown as a plain line on the TV, which cannot open one,
        /// and as a link on the phone, which can.
        let link: String?
        /// Licence texts this entry is answerable to, offered as their own screens.
        let licences: [Licence]

        init(id: String, title: String, lines: [String], link: String? = nil, licences: [Licence] = []) {
            self.id = id
            self.title = title
            self.lines = lines
            self.link = link
            self.licences = licences
        }
    }

    /// The credits, in the order the owner asked for them.
    ///
    /// The piece-set line names all three sets `PieceSet.allCases` offers in Settings
    /// (`Packages/ChessUI/Contracts.swift`): cburnett, merida, chessnut. If a fourth is ever
    /// added, this line is the other half of adding it.
    static let entries: [Entry] = [
        Entry(
            id: "lichess",
            title: "Lichess",
            lines: [
                "Live games, arenas and broadcasts come from the Lichess public API. Chess TV is not affiliated with Lichess.",
                "Lichess is free software, run as a charity and funded by its players.",
            ],
            link: "lichess.org"
        ),
        Entry(
            id: "fide",
            title: "FIDE",
            lines: [
                "Player portraits and profiles come from the FIDE player database, as Lichess republishes it.",
                "Where FIDE names the photographer, the credit is shown beside the portrait.",
            ]
        ),
        Entry(
            id: "stockfish",
            title: "Stockfish 19",
            lines: [
                "Analysis is Stockfish 19, running on this device and never on a server, with its NNUE neural network.",
                "Stockfish is free software under the GNU General Public License, version 3.",
                "Its neural network, nn-1a298aa575a0.nnue, is published by the Stockfish project at tests.stockfishchess.org under the same licence.",
                "Chess TV is under the same licence. Its source is available at \(sourceURL).",
            ],
            link: "stockfishchess.org",
            licences: [.gpl3]
        ),
        Entry(
            id: "pieces",
            title: "Piece sets",
            lines: [
                "Classic is cburnett, by Colin M. L. Burnett, under the GNU General Public License, version 2 or later.",
                "Merida is by Armando Hernandez Marroquin, under the GNU General Public License, version 2 or later.",
                "Chessnut is by Alexis Luengas, under the Apache License, version 2.0.",
                "Federation flags are Unicode characters, not artwork.",
            ],
            licences: [.gpl2, .apache2]
        ),
        Entry(
            id: "sounds",
            title: "Sounds",
            lines: [
                "Wooden chess sounds by el_boss on Freesound, released under CC0 1.0.",
                "Adapted from Piece Placement (546119) and Piece Capture (546120).",
                "Soft Felt and the game-over chime were made for Chess TV.",
                "Lichess Piano, NES and SFX by Enigmahack and the Lichess authors, released under AGPLv3 or later.",
                "Adapted by Chess TV with matched levels and WAV conversion; Muted Wood also lowers pitch and filters the high frequencies.",
                "Original recordings and processing scripts are included in the app's source at \(sourceURL).",
            ],
            link: "https://github.com/lichess-org/lila/tree/master/public/sound",
            licences: [.agpl3]
        ),
        Entry(
            id: "thanks",
            title: "Thank you",
            lines: ["To the Lichess community, who made all of this public in the first place."]
        ),
    ]
}
