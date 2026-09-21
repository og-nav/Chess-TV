// The board. Square, focus-neutral, and crisp at 800 × 800 pt on a 1080p TV.
import SwiftUI
import ChessCore

/// Draws a position. `orientation` is the color at the bottom of the board.
public struct BoardView: View {
    public let position: Position?
    public let lastMove: LastMove?
    public let theme: BoardTheme
    public let pieceSet: PieceSet
    public let orientation: PieceColor
    public let showCoordinates: Bool

    public init(position: Position?, lastMove: LastMove?, theme: BoardTheme, pieceSet: PieceSet, orientation: PieceColor, showCoordinates: Bool) {
        self.position = position; self.lastMove = lastMove; self.theme = theme; self.pieceSet = pieceSet; self.orientation = orientation; self.showCoordinates = showCoordinates
    }

    public var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let squareSide = side / Double(BoardGeometry.files)
            ZStack(alignment: .topLeading) {
                Canvas(rendersAsynchronously: false) { context, size in
                    draw(in: &context, size: size)
                }
                pieceLayer(squareSide: squareSide)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .aspectRatio(1, contentMode: .fit)
        // The board is decoration, not a control: nothing inside it takes focus on tvOS. The
        // accessibility children below are VoiceOver elements only, one per square, and are not
        // focusable either.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibilityDescription))
        .accessibilityChildren {
            ForEach(accessibleSquares, id: \.self) { square in
                Text(squareDescription(square))
            }
        }
    }

    // MARK: - Squares, highlights and coordinates

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let side = min(size.width, size.height)
        let squareSide = side / Double(BoardGeometry.files)
        let coordinateFont = Font.system(size: squareSide * 0.2, weight: .semibold, design: .rounded)

#if os(watchOS)
        // Individual square fills can smear into stripes in the Watch renderer. A single
        // checkerboard path keeps all eight ranks intact, including in its scroll view.
        context.fill(Path(CGRect(x: 0, y: 0, width: side, height: side)), with: .color(theme.light))
        var darkSquares = Path()
        for square in BoardGeometry.allSquares where square.isDark {
            let point = BoardGeometry.origin(of: square, orientation: orientation, squareSide: squareSide)
            darkSquares.addRect(CGRect(x: point.x, y: point.y, width: squareSide, height: squareSide))
        }
        context.fill(darkSquares, with: .color(theme.dark))
        if let lastMove {
            for square in lastMove.squares {
                let point = BoardGeometry.origin(of: square, orientation: orientation, squareSide: squareSide)
                context.fill(Path(CGRect(x: point.x, y: point.y, width: squareSide, height: squareSide)),
                             with: .color(color(of: square)))
            }
        }
#endif
        for square in BoardGeometry.allSquares {
            let point = BoardGeometry.origin(of: square, orientation: orientation, squareSide: squareSide)
            let rect = CGRect(x: point.x, y: point.y, width: squareSide, height: squareSide)
#if !os(watchOS)
            // Round outward so neighbouring fills always meet: no hairline seams at any size.
            let snapped = CGRect(
                x: rect.minX.rounded(.down),
                y: rect.minY.rounded(.down),
                width: rect.maxX.rounded(.up) - rect.minX.rounded(.down),
                height: rect.maxY.rounded(.up) - rect.minY.rounded(.down)
            )
            context.fill(Path(snapped), with: .color(color(of: square)))
#endif

            guard showCoordinates else { continue }
            let column = BoardGeometry.column(of: square, orientation: orientation)
            let row = BoardGeometry.row(of: square, orientation: orientation)
            let labelColor = square.isDark ? theme.light : theme.dark
            // Ranks 1–8 run up the left edge, files a–h along the bottom edge.
            if column == 0 {
                let text = Text(String(square.rank + 1)).font(coordinateFont).foregroundStyle(labelColor)
                context.draw(
                    context.resolve(text),
                    at: CGPoint(x: rect.minX + squareSide * 0.1, y: rect.minY + squareSide * 0.1),
                    anchor: .topLeading
                )
            }
            if row == BoardGeometry.ranks - 1 {
                let text = Text(String(square.algebraic.prefix(1))).font(coordinateFont).foregroundStyle(labelColor)
                context.draw(
                    context.resolve(text),
                    at: CGPoint(x: rect.maxX - squareSide * 0.1, y: rect.maxY - squareSide * 0.1),
                    anchor: .bottomTrailing
                )
            }
        }
    }

    private func color(of square: Square) -> Color {
        if let lastMove, lastMove.highlights(square) {
            return square.isDark ? theme.lastMoveDark : theme.lastMoveLight
        }
        return square.isDark ? theme.dark : theme.light
    }

    // MARK: - Pieces

    @ViewBuilder
    private func pieceLayer(squareSide: Double) -> some View {
        if let position {
            ForEach(BoardGeometry.allSquares, id: \.self) { square in
                if let piece = position.piece(at: square) {
                    let point = BoardGeometry.origin(of: square, orientation: orientation, squareSide: squareSide)
                    PieceAssets.image(set: pieceSet, piece: piece)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: squareSide, height: squareSide)
                        .offset(x: point.x, y: point.y)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private var accessibilityDescription: String {
        guard let position else { return "Empty chess board" }
        let side = position.sideToMove == .white ? "White" : "Black"
        return "Chess board, \(position.pieceCount) pieces, \(side) to move"
    }

    private var accessibleSquares: [Square] {
        BoardGeometry.allSquares.sorted {
            let a = BoardGeometry.row(of: $0, orientation: orientation) * 8 + BoardGeometry.column(of: $0, orientation: orientation)
            let b = BoardGeometry.row(of: $1, orientation: orientation) * 8 + BoardGeometry.column(of: $1, orientation: orientation)
            return a < b
        }
    }

    private func squareDescription(_ square: Square) -> String {
        guard let piece = position?.piece(at: square) else { return "\(square.algebraic), empty" }
        let color = piece.color == .white ? "White" : "Black"
        let kind: String
        switch piece.kind {
        case .king: kind = "king"
        case .queen: kind = "queen"
        case .rook: kind = "rook"
        case .bishop: kind = "bishop"
        case .knight: kind = "knight"
        case .pawn: kind = "pawn"
        }
        return "\(square.algebraic), \(color) \(kind)"
    }
}

/// Where each square sits on screen for a given orientation.
enum BoardGeometry {
    static let files = 8
    static let ranks = 8

    static let allSquares: [Square] = (0..<ranks).flatMap { rank in
        (0..<files).map { Square(file: $0, rank: rank) }
    }

    /// Column 0 is the left edge of the screen.
    static func column(of square: Square, orientation: PieceColor) -> Int {
        orientation == .white ? square.file : files - 1 - square.file
    }

    /// Row 0 is the top edge of the screen.
    static func row(of square: Square, orientation: PieceColor) -> Int {
        orientation == .white ? ranks - 1 - square.rank : square.rank
    }

    static func origin(of square: Square, orientation: PieceColor, squareSide: Double) -> CGPoint {
        CGPoint(
            x: Double(column(of: square, orientation: orientation)) * squareSide,
            y: Double(row(of: square, orientation: orientation)) * squareSide
        )
    }
}

#if DEBUG
/// The position the live blitz probe recorded in Fixtures/feed-blitz.ndjson.
private let blitzFixtureFEN = "r1b2rk1/pp2ppbp/6p1/4P3/6PN/2B4P/PPP1QPB1/2KR3q b - - 1 21"

#Preview("Board — White at the bottom") {
    BoardView(
        position: try? Position(fen: blitzFixtureFEN),
        lastMove: (try? Position(fen: blitzFixtureFEN)).flatMap { LastMove(uci: "f1g2", position: $0) },
        theme: .sage,
        pieceSet: .cburnett,
        orientation: .white,
        showCoordinates: true
    )
    .frame(width: 800, height: 800)
    .padding(40)
    .background(Color(hex: 0x161916))
}

#Preview("Board — Black at the bottom") {
    BoardView(
        position: try? Position(fen: blitzFixtureFEN),
        lastMove: (try? Position(fen: blitzFixtureFEN)).flatMap { LastMove(uci: "f1g2", position: $0) },
        theme: .brown,
        pieceSet: .merida,
        orientation: .black,
        showCoordinates: true
    )
    .frame(width: 800, height: 800)
    .padding(40)
    .background(Color(hex: 0x161916))
}

#Preview("Board and eval bar") {
    HStack(spacing: 24) {
        EvalBarView(whiteShare: EvalMapping.whiteShare(centipawns: 120), orientation: .white)
            .frame(width: 22, height: 800)
        BoardView(
            position: try? Position(fen: blitzFixtureFEN),
            lastMove: nil,
            theme: .green,
            pieceSet: .chessnut,
            orientation: .white,
            showCoordinates: false
        )
        .frame(width: 800, height: 800)
    }
    .padding(40)
    .background(Color(hex: 0x161916))
}
#endif
