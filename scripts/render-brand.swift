// Reproducible vector artwork for the suite's app icons. No external artwork/font dependency.
//
//   swift scripts/render-brand.swift                 # every asset below, paths relative to the repo root
//   swift scripts/render-brand.swift --icon out.png  # only the flat 1024 mark (iOS + watchOS)
//   swift scripts/render-brand.swift --tv <dir.brandassets>  # only the tvOS App Icon & Top Shelf Image stack
//
// Outputs:
//   assets/Brand.xcassets/AppIcon.appiconset/AppIcon.png            1024x1024, no alpha (iOS + watchOS marketing icon)
//   Apps/ChessTV/Resources/Assets.xcassets/App Icon & Top Shelf Image.brandassets/
//     App Icon.imagestack               400x240 @1x and @2x, four parallax layers
//     App Icon - App Store.imagestack   1280x768 @1x, the same four layers
//     Top Shelf Image.imageset          1920x720 @1x, 3840x1440 @2x
//     Top Shelf Image Wide.imageset     2320x720 @1x, 4640x1440 @2x
// The tvOS layers (Ground, Tiles, Signal, Dot; Dot in front) are the same mark cut apart, so every
// platform shows one identity.
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(red: r/255, green: g/255, blue: b/255, alpha: 1) }
let ground = rgb(22, 25, 22)
let tileDark = rgb(39, 47, 35)
let tileLight = rgb(48, 59, 41)
let ivory = rgb(222, 215, 197)
let live = rgb(196, 212, 156)

enum Layer: String, CaseIterable { case ground = "Ground", tiles = "Tiles", signal = "Signal", dot = "Dot" }

// The mark lives in a 1024x1024 design space (Core Graphics axes, origin bottom-left); `rect` says
// where that square lands on the canvas. "Signal Square": a 2x2 block of board tiles at 63% of the
// icon, broadcast arcs radiating from its bottom-left corner and clipped to the block, and a sage
// live dot on that corner. Chosen on 2026-09-20 from the icon directions canvas.
let block = CGRect(x: 192, y: 192, width: 640, height: 640)
let origin = CGPoint(x: block.minX, y: block.minY)

func drawMark(_ c: CGContext, in rect: CGRect, layers: Set<Layer>) {
    c.saveGState()
    c.translateBy(x: rect.minX, y: rect.minY)
    c.scaleBy(x: rect.width / 1024, y: rect.height / 1024)
    if layers.contains(.tiles) {
        // Top-left tile is the darker one (row 1 in Core Graphics is the top row).
        for row in 0..<2 { for col in 0..<2 {
            c.setFillColor((row + col) % 2 == 1 ? tileDark : tileLight)
            c.fill(CGRect(x: block.minX + CGFloat(col) * 320, y: block.minY + CGFloat(row) * 320, width: 320, height: 320))
        }}
    }
    if layers.contains(.signal) {
        c.saveGState()
        c.clip(to: block)
        c.setStrokeColor(live); c.setLineWidth(60); c.setLineCap(.round)
        for radius in [267.0, 467.0] as [CGFloat] {
            c.addArc(center: origin, radius: radius, startAngle: 0, endAngle: .pi / 2, clockwise: false)
            c.strokePath()
        }
        c.restoreGState()
    }
    if layers.contains(.dot) {
        // The live dot sits on the source corner, in front of everything, unclipped.
        c.setFillColor(live); c.fillEllipse(in: CGRect(x: origin.x - 84, y: origin.y - 84, width: 168, height: 168))
    }
    c.restoreGState()
}

func context(width: Int, height: Int, opaque: Bool) -> CGContext {
    let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
    if opaque { c.setFillColor(ground); c.fill(CGRect(x: 0, y: 0, width: width, height: height)) }
    return c
}

func writePNG(_ c: CGContext, to path: String) {
    let dir = (path as NSString).deletingLastPathComponent
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let url = URL(fileURLWithPath: path)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, c.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination), "could not write \(path)")
}

func writeJSON(_ object: Any, to path: String) {
    let dir = (path as NSString).deletingLastPathComponent
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: URL(fileURLWithPath: path))
}
let xcodeInfo: [String: Any] = ["author": "xcode", "version": 1]

// MARK: flat 1024 icon (iOS, watchOS): opaque, the whole mark.
func renderFlatIcon(to path: String) {
    let c = context(width: 1024, height: 1024, opaque: true)
    drawMark(c, in: CGRect(x: 0, y: 0, width: 1024, height: 1024), layers: Set(Layer.allCases))
    writePNG(c, to: path)
}

// MARK: tvOS layered icon. The mark is scaled to the icon height and centred; the ground layer is
// opaque, the three layers above it are transparent PNGs so the parallax shows through.
func markRect(canvasWidth: Int, canvasHeight: Int, fraction: CGFloat = 1) -> CGRect {
    let side = CGFloat(canvasHeight) * fraction
    return CGRect(x: (CGFloat(canvasWidth) - side) / 2, y: (CGFloat(canvasHeight) - side) / 2, width: side, height: side)
}

func renderStack(at dir: String, width: Int, height: Int, scales: [Int]) {
    let order: [Layer] = [.dot, .signal, .tiles, .ground]   // front to back, as Xcode lists them
    writeJSON(["layers": order.map { ["filename": "\($0.rawValue).imagestacklayer"] }, "info": xcodeInfo],
              to: "\(dir)/Contents.json")
    for layer in order {
        let layerDir = "\(dir)/\(layer.rawValue).imagestacklayer"
        writeJSON(["info": xcodeInfo], to: "\(layerDir)/Contents.json")
        var images: [[String: String]] = []
        for scale in scales {
            let name = scale == 1 ? "\(layer.rawValue).png" : "\(layer.rawValue)@\(scale)x.png"
            let c = context(width: width * scale, height: height * scale, opaque: layer == .ground)
            if layer != .ground {
                drawMark(c, in: markRect(canvasWidth: width * scale, canvasHeight: height * scale), layers: [layer])
            }
            writePNG(c, to: "\(layerDir)/Content.imageset/\(name)")
            images.append(["idiom": "tv", "filename": name, "scale": "\(scale)x"])
        }
        writeJSON(["images": images, "info": xcodeInfo], to: "\(layerDir)/Content.imageset/Contents.json")
    }
}

// MARK: top shelf. The mark at the left of centre with the wordmark in the system font beside it.
func renderTopShelf(at dir: String, width: Int, height: Int) {
    var images: [[String: String]] = []
    for scale in [1, 2] {
        let w = width * scale, h = height * scale
        let c = context(width: w, height: h, opaque: true)
        let side = CGFloat(h) * 0.72
        let titleFont = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, side * 0.34, nil)
        let title = NSAttributedString(string: "Chess TV", attributes: [
            kCTFontAttributeName as NSAttributedString.Key: titleFont,
            kCTForegroundColorAttributeName as NSAttributedString.Key: ivory])
        let line = CTLineCreateWithAttributedString(title)
        let titleWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let gap = side * 0.22
        let total = side + gap + titleWidth
        let x0 = (CGFloat(w) - total) / 2
        drawMark(c, in: CGRect(x: x0, y: (CGFloat(h) - side) / 2, width: side, height: side), layers: Set(Layer.allCases))
        c.textPosition = CGPoint(x: x0 + side + gap, y: CGFloat(h) / 2 - side * 0.12)
        CTLineDraw(line, c)
        let name = scale == 1 ? "TopShelf\(width).png" : "TopShelf\(width)@2x.png"
        writePNG(c, to: "\(dir)/\(name)")
        images.append(["idiom": "tv", "filename": name, "scale": "\(scale)x"])
    }
    writeJSON(["images": images, "info": xcodeInfo], to: "\(dir)/Contents.json")
}

func renderBrandAssets(at dir: String) {
    try? FileManager.default.removeItem(atPath: dir)
    writeJSON(["assets": [
        ["filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"],
        ["filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"],
        ["filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"],
        ["filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"],
    ], "info": xcodeInfo], to: "\(dir)/Contents.json")
    renderStack(at: "\(dir)/App Icon - App Store.imagestack", width: 1280, height: 768, scales: [1])
    renderStack(at: "\(dir)/App Icon.imagestack", width: 400, height: 240, scales: [1, 2])
    renderTopShelf(at: "\(dir)/Top Shelf Image.imageset", width: 1920, height: 720)
    renderTopShelf(at: "\(dir)/Top Shelf Image Wide.imageset", width: 2320, height: 720)
}

let args = Array(CommandLine.arguments.dropFirst())
let scriptDir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
let repo = ((scriptDir.isEmpty ? "." : scriptDir) as NSString).appendingPathComponent("..")
let defaultIcon = (repo as NSString).appendingPathComponent("assets/Brand.xcassets/AppIcon.appiconset/AppIcon.png")
let defaultTV = (repo as NSString).appendingPathComponent("Apps/ChessTV/Resources/Assets.xcassets/App Icon & Top Shelf Image.brandassets")
switch args.first {
case "--icon": renderFlatIcon(to: args.dropFirst().first ?? defaultIcon)
case "--tv": renderBrandAssets(at: args.dropFirst().first ?? defaultTV)
case nil: renderFlatIcon(to: defaultIcon); renderBrandAssets(at: defaultTV)
default: FileHandle.standardError.write("usage: render-brand.swift [--icon out.png | --tv dir.brandassets]\n".data(using: .utf8)!); exit(2)
}
