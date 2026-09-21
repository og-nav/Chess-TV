// Drawing a board into a bitmap, inside a notification service extension's budget.
//
// The extension gets roughly 24 MB and 30 seconds. The plan's first idea was to run `ImageRenderer`
// over ChessUI's `BoardView`; that means handing SwiftUI a view with 32 image layers and hoping.
// What this does instead:
//
//   * the **squares, highlights and coordinates** are drawn straight into one `CGContext` — no
//     SwiftUI, no view tree, one allocation whose size is known before it happens;
//   * the **pieces** are rasterised one at a time through `ImageRenderer` at exactly the square's
//     pixel size and cached, so at most twelve small bitmaps exist (12 × 75 × 75 × 4 ≈ 270 KB at
//     the default size) rather than one giant composited surface;
//   * if `ImageRenderer` gives nothing back — which it may, and there is no documented guarantee
//     it will not — the piece is drawn as its Unicode glyph with Core Text, and the board is still
//     a board;
//   * before any of that, `os_proc_available_memory()` is consulted and the whole thing is
//     abandoned if the headroom is not there.
//
// The abandonment path matters more than the fast path. Every caller treats `nil` as "send the
// text notification", which is a notification the user can still read.
import CoreGraphics
import CoreText
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import ChessCore
import ChessUI

#if canImport(UIKit)
import UIKit
#endif

#if canImport(os)
import os
#endif

@MainActor
public enum BoardImageRenderer {

    /// 600 px is the plan's number: crisp in an expanded notification on a Pro Max, and 1.44 MB of
    /// bitmap. The floor keeps a caller from asking for something that would be unreadable.
    /// `nonisolated`, all three: they are the default values of `Options.init`, which is a
    /// nonisolated context even though this type is `@MainActor` for `ImageRenderer`'s sake.
    nonisolated public static let defaultPixelSize = 600
    nonisolated public static let minimumPixelSize = 96
    nonisolated public static let maximumPixelSize = 600

    /// The bitmap alone is `side² × 4`. Refuse to start unless several times that is free, because
    /// the context is not the only allocation: the piece rasters, the PNG encode and whatever
    /// `ImageRenderer` does internally all land on top of it.
    nonisolated static let memoryHeadroomMultiplier = 6

    public struct Options: Sendable {
        public var pixelSize: Int
        public var appearance: BoardAppearance

        nonisolated public init(pixelSize: Int = BoardImageRenderer.defaultPixelSize, appearance: BoardAppearance) {
            self.pixelSize = pixelSize
            self.appearance = appearance
        }
    }

    // MARK: - Entry points

    /// The board as a bitmap, or nil if it could not be drawn for any reason at all.
    public static func render(fen: String, lastMoveUCI: String?, options: Options) -> CGImage? {
        let side = min(maximumPixelSize, max(minimumPixelSize, options.pixelSize))

        guard let position = try? Position(fen: fen) else {
            pushLog.notice("Board not drawn: the payload's FEN did not parse")
            return nil
        }
        guard hasMemoryHeadroom(forSide: side) else {
            pushLog.notice("Board not drawn: not enough memory headroom for a \(side)×\(side) bitmap")
            return nil
        }

        let lastMove = lastMoveUCI.flatMap { LastMove(uci: $0, position: position) }
        return draw(position: position, lastMove: lastMove, side: side, appearance: options.appearance)
    }

    /// The board as a PNG on disk, ready for `UNNotificationAttachment`.
    ///
    /// The file goes in the extension's temporary directory; the system moves it into the
    /// notification's own storage when the attachment is created, so nothing here has to clean up
    /// after a successful attach. A failed attach leaves a file the system reaps with the
    /// container.
    public static func pngFile(
        fen: String, lastMoveUCI: String?, options: Options, named name: String
    ) -> URL? {
        guard let image = render(fen: fen, lastMoveUCI: lastMoveUCI, options: options) else { return nil }
        return writePNG(image, named: name)
    }

    public static func writePNG(_ image: CGImage, named name: String) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("board-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            pushLog.error("Could not open a PNG destination for the board image")
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            pushLog.error("Could not finalise the board PNG")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    // MARK: - Drawing

    private static func draw(position: Position, lastMove: LastMove?, side: Int, appearance: BoardAppearance) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else {
            pushLog.error("Could not create a \(side)×\(side) bitmap context")
            return nil
        }

        let squareSide = Double(side) / 8
        let light = cgColor(appearance.theme.light)
        let dark = cgColor(appearance.theme.dark)
        let lastLight = cgColor(appearance.theme.lastMoveLight)
        let lastDark = cgColor(appearance.theme.lastMoveDark)

        context.interpolationQuality = .high
        context.setShouldAntialias(true)

        // Squares first, in one pass. Rects are snapped outward so neighbouring fills always meet;
        // a hairline seam is very visible on a 600 px board.
        for square in allSquares {
            let rect = rect(for: square, orientation: appearance.orientation, squareSide: squareSide, side: side)
            let highlighted = lastMove?.highlights(square) ?? false
            let color: CGColor = highlighted
                ? (square.isDark ? lastDark : lastLight)
                : (square.isDark ? dark : light)
            context.setFillColor(color)
            context.fill(rect)
        }

        if appearance.showsCoordinates {
            drawCoordinates(in: context, orientation: appearance.orientation, squareSide: squareSide, side: side, appearance: appearance)
        }

        // Pieces second, so a highlight never paints over one.
        var missingArtwork = 0
        for square in allSquares {
            guard let piece = position.piece(at: square) else { continue }
            let rect = rect(for: square, orientation: appearance.orientation, squareSide: squareSide, side: side)
            if let raster = pieceRaster(set: appearance.pieceSet, piece: piece, pixels: Int(squareSide.rounded())) {
                context.draw(raster, in: rect)
            } else {
                missingArtwork += 1
                drawGlyph(for: piece, in: rect, context: context, theme: appearance.theme)
            }
        }
        if missingArtwork > 0 {
            pushLog.notice("Drew \(missingArtwork) piece(s) as Unicode glyphs: the piece artwork did not rasterise")
        }

        return context.makeImage()
    }

    private static func drawCoordinates(
        in context: CGContext, orientation: PieceColor, squareSide: Double, side: Int, appearance: BoardAppearance
    ) {
        let fontSize = squareSide * 0.2
        for square in allSquares {
            let rect = rect(for: square, orientation: orientation, squareSide: squareSide, side: side)
            let color = cgColor(square.isDark ? appearance.theme.light : appearance.theme.dark)
            let column = orientation == .white ? square.file : 7 - square.file
            let rowFromBottom = orientation == .white ? square.rank : 7 - square.rank

            if column == 0 {
                // Ranks up the left edge, in the square's top-left corner.
                drawText(
                    String(square.rank + 1), at: CGPoint(x: rect.minX + fontSize * 0.5, y: rect.maxY - fontSize * 1.3),
                    fontSize: fontSize, color: color, context: context, centered: false
                )
            }
            if rowFromBottom == 0 {
                // Files along the bottom edge, in the square's bottom-right corner.
                drawText(
                    String(square.algebraic.prefix(1)),
                    at: CGPoint(x: rect.maxX - fontSize * 1.1, y: rect.minY + fontSize * 0.4),
                    fontSize: fontSize, color: color, context: context, centered: false
                )
            }
        }
    }

    // MARK: - Pieces

    /// Twelve entries at most per size; the cache is keyed by name and pixel size and lives as
    /// long as the extension process, which is seconds.
    private static var rasterCache: [String: CGImage] = [:]

    /// One piece, rendered through SwiftUI at exactly the size it will be drawn.
    ///
    /// `ImageRenderer` is `@MainActor`, which is why this whole type is. `scale = 1` makes the
    /// point frame a pixel frame, so nothing is rendered larger than it is used.
    static func pieceRaster(set: PieceSet, piece: Piece, pixels: Int) -> CGImage? {
        let pixels = max(8, pixels)
        let key = "\(PieceAssets.imageName(set: set, piece: piece))@\(pixels)"
        if let hit = rasterCache[key] { return hit }
        guard PieceAssets.imageExists(set: set, piece: piece) else { return nil }

        let renderer = ImageRenderer(
            content: PieceAssets.image(set: set, piece: piece)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .frame(width: CGFloat(pixels), height: CGFloat(pixels))
        )
        renderer.scale = 1
        renderer.isOpaque = false
        guard let image = renderer.cgImage else { return nil }
        rasterCache[key] = image
        return image
    }

    /// The fallback that keeps a board a board when the artwork will not rasterise.
    ///
    /// Core Text finds these glyphs by cascading from the system font, so no font is named and no
    /// font has to be bundled. A white piece is drawn as the *outlined* glyph filled light with a
    /// dark stroke, so it reads on both square colours.
    private static func drawGlyph(for piece: Piece, in rect: CGRect, context: CGContext, theme: BoardTheme) {
        let glyphs: [PieceKind: (white: String, black: String)] = [
            .king: ("♔", "♚"), .queen: ("♕", "♛"), .rook: ("♖", "♜"),
            .bishop: ("♗", "♝"), .knight: ("♘", "♞"), .pawn: ("♙", "♟"),
        ]
        guard let pair = glyphs[piece.kind] else { return }
        let text = piece.color == .white ? pair.white : pair.black
        let color = cgColor(piece.color == .white ? theme.light : Color(hex: 0x111111))
        drawText(
            text, at: CGPoint(x: rect.midX, y: rect.midY - rect.height * 0.32),
            fontSize: rect.height * 0.82, color: color, context: context, centered: true,
            strokeColor: piece.color == .white ? cgColor(Color(hex: 0x111111)) : cgColor(theme.light)
        )
    }

    // MARK: - Text

    private static func drawText(
        _ text: String, at point: CGPoint, fontSize: Double, color: CGColor,
        context: CGContext, centered: Bool, strokeColor: CGColor? = nil
    ) {
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        if let strokeColor {
            // A negative width means "fill and stroke", which is what gives a white glyph its edge.
            attributes[.strokeColor] = strokeColor
            attributes[.strokeWidth] = -4.0
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var origin = point
        if centered {
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            origin.x -= bounds.width / 2
        }
        context.textMatrix = .identity
        context.textPosition = origin
        CTLineDraw(line, context)
    }

    // MARK: - Geometry and colour

    private static let allSquares: [Square] = (0..<8).flatMap { rank in (0..<8).map { Square(file: $0, rank: rank) } }

    /// Core Graphics' origin is the bottom-left, so the rank maps straight to y when White is at
    /// the bottom and inverts when Black is. Snapped outward so the fills meet.
    private static func rect(for square: Square, orientation: PieceColor, squareSide: Double, side: Int) -> CGRect {
        let column = orientation == .white ? square.file : 7 - square.file
        let rowFromBottom = orientation == .white ? square.rank : 7 - square.rank
        let minX = (Double(column) * squareSide).rounded(.down)
        let minY = (Double(rowFromBottom) * squareSide).rounded(.down)
        let maxX = min(Double(side), (Double(column + 1) * squareSide).rounded(.up))
        let maxY = min(Double(side), (Double(rowFromBottom + 1) * squareSide).rounded(.up))
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// SwiftUI's own resolution rather than `UIColor(_:)`, so this file needs no UIKit and can be
    /// exercised on the Mac — which is how the rendering proof in the report was produced.
    /// `Color.Resolved`'s components are sRGB-encoded, which is the space asked for here.
    static func cgColor(_ color: Color) -> CGColor {
        let resolved = color.resolve(in: EnvironmentValues())
        return CGColor(
            srgbRed: CGFloat(resolved.red),
            green: CGFloat(resolved.green),
            blue: CGFloat(resolved.blue),
            alpha: CGFloat(resolved.opacity)
        )
    }

    // MARK: - Memory

    /// `os_proc_available_memory()` is how much this process may still allocate before the system
    /// kills it. It is 0 when the platform does not report it (the Mac, and a few simulator
    /// configurations), which is read as "unknown, go ahead" — the size cap above is then the only
    /// guard, and it is the reason the cap exists.
    nonisolated static func hasMemoryHeadroom(forSide side: Int) -> Bool {
        let needed = side * side * 4 * memoryHeadroomMultiplier
        #if os(iOS) || os(watchOS) || os(tvOS)
        let available = Int(os_proc_available_memory())
        guard available > 0 else { return true }
        return available > needed
        #else
        return true
        #endif
    }
}
