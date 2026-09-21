// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ImageryKit",
    platforms: [.tvOS(.v26), .macOS(.v15), .iOS(.v26), .watchOS(.v26)],
    products: [.library(name: "ImageryKit", targets: ["ImageryKit"])],
    // Deliberately no dependency on LichessKit: the cache, the Wikipedia lookup and the
    // placeholders are about pictures, not about chess, and the app wires the two together.
    dependencies: [],
    targets: [
        .target(name: "ImageryKit", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "ImageryKitTests", dependencies: ["ImageryKit"], resources: [.copy("Fixtures")], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
