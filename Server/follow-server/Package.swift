// swift-tools-version: 6.2
import PackageDescription

// The follow server. Runs on the owner's VPS behind Caddy; builds on macOS for development and on
// Linux for the box.
//
// Dependencies are the four the plan allows plus what they drag in. Note what is *not* here:
// LichessKit. The package is Apple-only today — `os.Logger` and `URLSession.bytes(for:)` — so the
// server keeps its own small broadcast client over AsyncHTTPClient instead, and shares the part
// that matters (PGN parsing, replay, FEN) through ChessCore, which is pure Swift.
let package = Package(
    name: "follow-server",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "follow-server", targets: ["follow-server"]),
        .library(name: "FollowServer", targets: ["FollowServer"]),
    ],
    dependencies: [
        .package(path: "../../Packages/ChessCore"),
        .package(path: "../../Packages/FollowKit"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.26.0"),
        .package(url: "https://github.com/swift-server-community/APNSwift.git", from: "5.1.0"),
        .package(url: "https://github.com/vapor/sqlite-nio.git", from: "1.13.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.36.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.97.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.15.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.12.0"),
    ],
    targets: [
        .target(
            name: "FollowServer",
            dependencies: [
                .product(name: "ChessCore", package: "ChessCore"),
                .product(name: "FollowKit", package: "FollowKit"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "APNS", package: "APNSwift"),
                .product(name: "APNSCore", package: "APNSwift"),
                .product(name: "SQLiteNIO", package: "sqlite-nio"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(name: "follow-server", dependencies: ["FollowServer"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(
            name: "FollowServerTests",
            dependencies: [
                "FollowServer",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
