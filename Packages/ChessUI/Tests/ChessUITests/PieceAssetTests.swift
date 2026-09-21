import Testing
import ChessCore
@testable import ChessUI

@Test func thereAre36PieceImageNames() {
    #expect(PieceAssets.allImageNames.count == 36)
    #expect(Set(PieceAssets.allImageNames).count == 36)
    #expect(PieceAssets.allImageNames.contains("cburnett_wN"))
    #expect(PieceAssets.allImageNames.contains("merida_bQ"))
    #expect(PieceAssets.allImageNames.contains("chessnut_wP"))
}

@Test func imageNamesFollowTheLichessCode() {
    #expect(PieceAssets.imageName(set: .cburnett, piece: Piece(kind: .knight, color: .white)) == "cburnett_wN")
    #expect(PieceAssets.imageName(set: .merida, piece: Piece(kind: .king, color: .black)) == "merida_bK")
    #expect(PieceAssets.imageName(set: .chessnut, piece: Piece(kind: .pawn, color: .black)) == "chessnut_bP")
    #expect(PieceAssets.code(for: Piece(kind: .queen, color: .white)) == "wQ")
}

@Test(arguments: PieceAssets.allImageNames)
func everyPieceImageResolvesFromTheBundle(name: String) {
    #expect(PieceAssets.imageExists(named: name), "missing asset \(name)")
}

@Test func everySetIsComplete() {
    for set in PieceSet.allCases {
        for piece in PieceAssets.allPieces {
            #expect(PieceAssets.imageExists(set: set, piece: piece), "\(set.rawValue) is missing \(PieceAssets.code(for: piece))")
        }
    }
    #expect(!PieceAssets.imageExists(named: "cburnett_wX"))
}
