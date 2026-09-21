// Piece artwork: Lichess SVGs compiled into Resources/Pieces.xcassets as vector-preserving image
// sets named "<set>_<piece>", e.g. "cburnett_wN". See LICENSES.md for the licenses.
import SwiftUI
import ChessCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public enum PieceAssets {
    /// The two-letter code Lichess uses for a piece file: "wK", "bQ", …
    public static func code(for piece: Piece) -> String {
        let color = piece.color == .white ? "w" : "b"
        let kind: String
        switch piece.kind {
        case .king: kind = "K"
        case .queen: kind = "Q"
        case .rook: kind = "R"
        case .bishop: kind = "B"
        case .knight: kind = "N"
        case .pawn: kind = "P"
        }
        return color + kind
    }

    /// The asset-catalog name for a piece in a set, e.g. `.cburnett` + white knight → "cburnett_wN".
    public static func imageName(set: PieceSet, piece: Piece) -> String {
        "\(set.rawValue)_\(code(for: piece))"
    }

    /// All 12 pieces, white first, in a stable order.
    public static let allPieces: [Piece] = {
        let kinds: [PieceKind] = [.king, .queen, .rook, .bishop, .knight, .pawn]
        return [PieceColor.white, .black].flatMap { color in
            kinds.map { Piece(kind: $0, color: color) }
        }
    }()

    /// All 36 asset names (3 sets × 12 pieces). Used by the tests to check the catalog is complete.
    public static let allImageNames: [String] = PieceSet.allCases.flatMap { set in
        allPieces.map { imageName(set: set, piece: $0) }
    }

    /// The SwiftUI image for a piece, resolved from this package's bundle.
    public static func image(set: PieceSet, piece: Piece) -> Image {
        Image(imageName(set: set, piece: piece), bundle: .module)
    }

    /// Whether the named image actually exists in this package's asset catalog. The board draws
    /// nothing rather than a question-mark placeholder if an asset is ever missing.
    public static func imageExists(named name: String) -> Bool {
        #if canImport(UIKit)
        return UIImage(named: name, in: .module, with: nil) != nil
        #elseif canImport(AppKit)
        return Bundle.module.image(forResource: name) != nil
        #else
        return false
        #endif
    }

    /// Whether the artwork for a piece in a set is present.
    public static func imageExists(set: PieceSet, piece: Piece) -> Bool {
        imageExists(named: imageName(set: set, piece: piece))
    }
}
