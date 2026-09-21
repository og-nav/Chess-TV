// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ChessCore",
    platforms: [.tvOS(.v26), .macOS(.v15), .iOS(.v26), .watchOS(.v26)],
    products: [.library(name: "ChessCore", targets: ["ChessCore"])],
    targets: [
        .target(name: "ChessCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "ChessCoreTests", dependencies: ["ChessCore"], resources: [.copy("Fixtures")], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
