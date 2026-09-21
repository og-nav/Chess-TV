// swift-tools-version: 6.2
import PackageDescription

// Stockfish 19 (GPLv3) is vendored under Vendor/stockfish. Two C++ targets:
//
//   CStockfishEngine  the untouched upstream src/ tree minus main.cpp and the
//                     universal-binary launchers (they define their own main()).
//   CStockfish        the C bridge EngineKit talks to; it owns the only
//                     public header, so Swift never sees a C++ declaration.
//
// Architecture note: SwiftPM conditions settings on platform, not architecture,
// and an Apple simulator build compiles arm64 and x86_64 from one set of flags.
// SF_APPLE_ARCH_GATE moves the SIMD selection into misc.h, where __aarch64__ is
// known (see Vendor/PATCHES.md). arm64 gets NEON; the x86_64 simulator slice
// compiles the portable code paths.
let stockfishDefines: [CXXSetting] = [
    .define("NDEBUG"),
    .define("USE_PTHREADS"),
    .define("NNUE_EMBEDDING_OFF"),
    .define("IS_64BIT"),
    .define("USE_POPCNT"),
    .define("SF_APPLE_ARCH_GATE"),
    // Stockfish is unusable at -O0: 1500 ms on the start position reaches depth
    // 15 in SwiftPM's debug configuration and depth 24 with -O3. `unsafeFlags`
    // is accepted because EngineKit is only ever consumed as a local path
    // dependency; drop this line if the package is ever published by version.
    .unsafeFlags(["-O3"]),
]

let package = Package(
    name: "EngineKit",
    platforms: [.tvOS(.v26), .macOS(.v15), .iOS(.v26)],
    products: [.library(name: "EngineKit", targets: ["EngineKit"])],
    targets: [
        .target(
            name: "CStockfishEngine",
            path: "Vendor/stockfish",
            exclude: [
                "src/Makefile",
                "src/main.cpp",
                "src/universal",
                "src/incbin/UNLICENCE",
            ],
            sources: ["src"],
            publicHeadersPath: "src",
            cxxSettings: stockfishDefines
        ),
        .target(
            name: "CStockfish",
            dependencies: ["CStockfishEngine"],
            path: "Sources/CStockfish",
            sources: ["stockfish_bridge.cpp"],
            publicHeadersPath: "include",
            cxxSettings: stockfishDefines + [.headerSearchPath("../../Vendor/stockfish/src")]
        ),
        .target(
            name: "EngineKit",
            dependencies: ["CStockfish"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "EngineKitTests",
            dependencies: ["EngineKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
