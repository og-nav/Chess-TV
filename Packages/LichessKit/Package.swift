// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LichessKit",
    platforms: [.tvOS(.v26), .macOS(.v15), .iOS(.v26), .watchOS(.v26)],
    products: [
        .library(name: "LichessKit", targets: ["LichessKit"]),
        .executable(name: "lichess-probe", targets: ["lichess-probe"]),
    ],
    dependencies: [.package(path: "../ChessCore")],
    targets: [
        .target(name: "LichessKit", dependencies: ["ChessCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "lichess-probe", dependencies: ["LichessKit"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "LichessKitTests", dependencies: ["LichessKit", .product(name: "ChessCore", package: "ChessCore")], resources: [.copy("Fixtures")], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
