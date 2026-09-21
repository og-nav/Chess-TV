// swift-tools-version: 6.2
import PackageDescription

// FollowKit is the only package the apps, the extensions, the watch app and the push server all
// share, so it carries no dependency of its own: Foundation and the standard library only. The
// server builds it on Linux, which is why nothing here may import os, Security or UIKit outside a
// `canImport` guard.
let package = Package(
    name: "FollowKit",
    platforms: [.tvOS(.v26), .macOS(.v15), .iOS(.v26), .watchOS(.v26)],
    products: [.library(name: "FollowKit", targets: ["FollowKit"])],
    targets: [
        .target(name: "FollowKit", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "FollowKitTests", dependencies: ["FollowKit"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
