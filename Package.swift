// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "EnhancedNativePlayer",
    platforms: [
        // macOS is supported so the engine can be built and tested on a Mac.
        .tvOS(.v17),
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "EnhancedNativePlayer", targets: ["EnhancedNativePlayer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/superuser404notfound/FFmpegBuild", from: "3.11.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.11.0"),
    ],
    targets: [
        .target(
            name: "EnhancedNativePlayer",
            dependencies: [
                .product(name: "AetherFFmpegBuild", package: "FFmpegBuild"),
                .product(name: "AetherLibavformat", package: "FFmpegBuild"),
                .product(name: "AetherLibavcodec", package: "FFmpegBuild"),
                .product(name: "AetherLibavutil", package: "FFmpegBuild"),
                .product(name: "AetherLibswresample", package: "FFmpegBuild"),
                .product(name: "Logging", package: "swift-log"),
                "Libass",
                "PixelInterleave",
            ],
            // libass finds system fonts through CoreText; HarfBuzz is C++.
            linkerSettings: [.linkedFramework("CoreText"), .linkedLibrary("c++"), .linkedLibrary("iconv")]
        ),
        // libass with its assembly, and the FreeType, FriBidi and HarfBuzz it needs, in one
        // static library per platform. Built by scripts/build-libass.sh.
        .binaryTarget(name: "Libass", path: "Frameworks/Libass.xcframework"),
        // Plane interleaving for decoded video frames, in C with NEON so it is fast in a debug build too.
        .target(name: "PixelInterleave"),
        .testTarget(
            name: "EnhancedNativePlayerTests",
            dependencies: ["EnhancedNativePlayer"]
        ),
    ]
)
