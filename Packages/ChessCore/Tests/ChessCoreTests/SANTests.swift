import Testing
import Foundation
import ChessCore

@Suite("SAN writes the move list the way a chess player reads it")
struct SANTests {

    private func position(_ fen: String) throws -> Position { try Position(fen: fen) }

    private func san(_ uci: String, _ fen: String) throws -> String? {
        SAN.notation(for: uci, in: try position(fen))
    }

    @Test("Pawn and piece moves from the starting position")
    func openingMoves() throws {
        let start = Position.standard
        #expect(SAN.notation(for: "e2e4", in: start) == "e4")
        #expect(SAN.notation(for: "g1f3", in: start) == "Nf3")
        #expect(SAN.notation(for: "b1c3", in: start) == "Nc3")
    }

    @Test("A capture takes an x, a pawn capture takes its file")
    func captures() throws {
        // 1. e4 d5: exd5, and the queen can take back on d5.
        let p = try position("rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 2")
        #expect(SAN.notation(for: "e4d5", in: p) == "exd5")

        let afterExd5 = try position("rnbqkbnr/ppp1pppp/8/3P4/8/8/PPPP1PPP/RNBQKBNR b KQkq - 0 2")
        #expect(SAN.notation(for: "d8d5", in: afterExd5) == "Qxd5")
    }

    @Test("Two knights on the same rank are told apart by file")
    func fileDisambiguation() throws {
        // Knights b1 and f3 both reach d2, which the d-pawn has left.
        let p = try position("r1bqkb1r/pppp1ppp/2n2n2/4p3/3PP3/5N2/PPP2PPP/RNBQKB1R w KQkq - 0 5")
        #expect(SAN.notation(for: "b1d2", in: p) == "Nbd2")
        #expect(SAN.notation(for: "f3d2", in: p) == "Nfd2")

        // The brief's example, from Black's side: knights b8 and f6 both reach d7.
        let black = try position("rnbqkb1r/ppp2ppp/5n2/3pp3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 0 4")
        #expect(SAN.notation(for: "b8d7", in: black) == "Nbd7")
    }

    @Test("Two knights on the same file are told apart by rank")
    func rankDisambiguation() throws {
        // Knights g1 and g5 both reach f3; the file cannot separate them.
        let p = try position("4k3/8/8/6N1/8/8/8/4K1N1 w - - 0 1")
        #expect(SAN.notation(for: "g5f3", in: p) == "N5f3")
        #expect(SAN.notation(for: "g1f3", in: p) == "N1f3")
    }

    @Test("A third queen forces the full square")
    func fullDisambiguation() throws {
        // Queens a1, a4 and d1 all reach d4: a1 shares its file with a4 and its rank with d1.
        let p = try position("8/8/7k/8/Q7/8/8/Q2Q3K w - - 0 1")
        #expect(SAN.notation(for: "a1d4", in: p) == "Qa1d4")
        #expect(SAN.notation(for: "a4d4", in: p) == "Q4d4")   // shares its file with a1, not its rank
        #expect(SAN.notation(for: "d1d4", in: p) == "Qdd4")
    }

    @Test("A pinned piece is not an alternative worth disambiguating")
    func pinnedPieceIsNotAnAlternative() throws {
        // White knights on c3 and g1 both look like they reach e2, but the c3 knight is pinned
        // to the king on e1 by the bishop on a5, so no disambiguation is needed.
        let p = try position("4k3/8/8/b7/8/2N5/8/4K1N1 w - - 0 1")
        let knightMoves = p.legalMoves().filter {
            $0.to == Square(algebraic: "e2")! && p.piece(at: $0.from)?.kind == .knight
        }
        #expect(knightMoves.map(\.uci) == ["g1e2"])
        #expect(SAN.notation(for: "g1e2", in: p) == "Ne2")
    }

    @Test("En passant is a capture: exd6")
    func enPassant() throws {
        let p = try position("rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3")
        #expect(SAN.notation(for: "e5d6", in: p) == "exd6")
    }

    @Test("A promotion with check")
    func promotionWithCheck() throws {
        let p = try position("k7/4P3/8/8/8/8/8/4K3 w - - 0 1")
        #expect(SAN.notation(for: "e7e8q", in: p) == "e8=Q+")
        #expect(SAN.notation(for: "e7e8n", in: p) == "e8=N")

        // A capturing promotion keeps the pawn's file and the x.
        let capture = try position("1r6/P6k/8/8/8/8/8/4K3 w - - 0 1")
        #expect(SAN.notation(for: "a7b8q", in: capture) == "axb8=Q")
    }

    @Test("Castling, in the Lichess king-to-rook encoding and the plain one")
    func castling() throws {
        let white = try position("r3k2r/pppq1ppp/2npbn2/4p3/4P3/2NPBN2/PPPQ1PPP/R3K2R w KQkq - 4 8")
        #expect(SAN.notation(for: "e1h1", in: white) == "O-O")
        #expect(SAN.notation(for: "e1g1", in: white) == "O-O")
        #expect(SAN.notation(for: "e1a1", in: white) == "O-O-O")
        #expect(SAN.notation(for: "e1c1", in: white) == "O-O-O")

        let black = try position("r3k2r/pppq1ppp/2npbn2/4p3/4P3/2NPBN2/PPPQ1PPP/R4RK1 b kq - 5 8")
        #expect(SAN.notation(for: "e8a8", in: black) == "O-O-O")
        #expect(SAN.notation(for: "e8h8", in: black) == "O-O")
    }

    @Test("Check and checkmate suffixes")
    func checkSuffixes() throws {
        // Scholar's mate: Qxf7# is supported by the bishop on c4.
        let scholars = try position("r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5Q2/PPPP1PPP/RNB1K1NR w KQkq - 4 4")
        #expect(SAN.notation(for: "f3f7", in: scholars) == "Qxf7#")

        // The same queen move without the bishop is only a check.
        let noBishop = try position("r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5Q2/PPPP1PPP/RNB1K1NR w KQkq - 4 4")
        #expect(SAN.notation(for: "f3f7", in: noBishop) == "Qxf7+")
    }

    @Test("A move that is not legal in the position has no SAN")
    func rejectsIllegalMoves() throws {
        let start = Position.standard
        #expect(SAN.notation(for: "e2e5", in: start) == nil)
        #expect(SAN.notation(for: "e7e5", in: start) == nil)     // not White's pawn to move
        #expect(SAN.notation(for: "zzzz", in: start) == nil)
        #expect(SAN.notation(for: "e2", in: start) == nil)
    }

    @Test("The move-taking overload agrees with the UCI one")
    func moveOverload() throws {
        let p = try position("rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3")
        let move = Move(from: Square(algebraic: "e5")!, to: Square(algebraic: "d6")!)
        #expect(SAN.notation(for: move, in: p) == "exd6")
        #expect(move.uci == "e5d6")
    }
}

/// The castling fixture the app's tests drive, replayed move by move: every `lm` must produce a
/// SAN, and `Position.making` must land on exactly the placement the next line reports.
@Suite("The feed-castling fixture replays through making() and SAN")
struct FeedCastlingFixtureTests {

    private struct Line {
        var type: String
        var fen: String
        var lastMove: String?
    }

    private func fixtureLines() throws -> [Line] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ChessCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ChessCore
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // repository root
        let url = root.appendingPathComponent("Fixtures/feed-castling.ndjson")
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(whereSeparator: \.isNewline).map { raw in
            let object = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
            guard let object, let type = object["t"] as? String,
                  let payload = object["d"] as? [String: Any],
                  let fen = payload["fen"] as? String
            else { throw ChessCoreError.malformedFEN(String(raw)) }
            return Line(type: type, fen: fen, lastMove: payload["lm"] as? String)
        }
    }

    @Test("Every fixture move is legal, has a SAN, and lands on the FEN the feed reports")
    func replaysTheFixture() throws {
        let lines = try fixtureLines()
        #expect(lines.count == 5)

        var previous: Position?
        var notations: [String] = []
        for line in lines {
            let position = try Position(fen: line.fen)
            if line.type == "featured" {
                previous = position
                continue
            }
            let uci = try #require(line.lastMove)
            let before = try #require(previous)
            let move = try #require(SAN.move(forUCI: uci, in: before), "\(uci) is not legal in \(before.fen)")
            let notation = try #require(SAN.notation(for: uci, in: before))
            notations.append(notation)

            let made = before.making(move)
            #expect(made.placementFEN == position.placementFEN, "after \(notation)")
            #expect(made.sideToMove == position.sideToMove)
            #expect(made.castling == position.castling)
            #expect(made.fullmoveNumber == position.fullmoveNumber)
            previous = position
        }
        #expect(notations == ["O-O", "O-O-O", "e4"])
    }
}
