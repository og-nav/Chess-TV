// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ChessUI",
    platforms: [.tvOS(.v26), .macOS(.v15), .iOS(.v26), .watchOS(.v26)],
    products: [.library(name: "ChessUI", targets: ["ChessUI"])],
    dependencies: [.package(path: "../ChessCore")],
    targets: [
        .target(name: "ChessUI", dependencies: ["ChessCore"], resources: [.process("Resources")], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "ChessUITests", dependencies: ["ChessUI"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
