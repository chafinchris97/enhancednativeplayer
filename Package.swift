// swift-tools-version: 6.0

import Foundation
import PackageDescription

// The prebuilt frameworks. scripts/build-ffmpeg.sh and scripts/build-libass.sh build them into
// Frameworks/, and when they are there the package uses them. Otherwise they come from the
// package release below, which scripts/release.sh uploads and writes in here.
// BINARIES_RELEASE_BEGIN
let binariesRelease = "https://github.com/chafinchris97/enhancednativeplayer/releases/download/0.1.0"
let binaryChecksums = [
    "EPLibavutil": "54205b23cd466706d061b255b600660a196bcc61c3d72515389364eb5b24ca74",
    "EPLibswresample": "1342aab8de28607b0fb5f159168a89635ee73c15f1c97d914a369302ace7064b",
    "EPLibavcodec": "19cec4b6f697b9c532cfd5994ad82804b5b674929b595de9df04019cfe3b7cde",
    "EPLibavformat": "f36413aad9269640886619b5b6c1c7d27b88670b51465061525d5120fc45b419",
    "EPLibass": "306aaad56b7f2c544205a49f5728ff068a546b24e372bb7e7ec1f9cda11e6c3c",
]
// BINARIES_RELEASE_END

func binary(_ name: String) -> Target {
    let local = "Frameworks/\(name).xcframework"
    if FileManager.default.fileExists(atPath: "\(Context.packageDirectory)/\(local)") {
        return .binaryTarget(name: name, path: local)
    }
    return .binaryTarget(name: name, url: "\(binariesRelease)/\(name).xcframework.zip", checksum: binaryChecksums[name]!)
}

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
        .package(url: "https://github.com/apple/swift-log", from: "1.11.0"),
    ],
    targets: [
        .target(
            name: "EnhancedNativePlayer",
            dependencies: [
                "EPLibavformat",
                "EPLibavcodec",
                "EPLibavutil",
                "EPLibswresample",
                .product(name: "Logging", package: "swift-log"),
                "EPLibass",
                "PixelInterleave",
                "FFmpegLogBridge",
            ]
        ),
        // libass with its assembly, and the FreeType, FriBidi and HarfBuzz it needs, as one
        // dynamic framework (FriBidi is LGPL).
        binary("EPLibass"),
        // FFmpeg, with dav1d inside libavcodec, as dynamic frameworks (it is LGPL).
        binary("EPLibavformat"),
        binary("EPLibavcodec"),
        binary("EPLibavutil"),
        binary("EPLibswresample"),
        // Plane interleaving for decoded video frames, in C with NEON so it is fast in a debug build too.
        .target(name: "PixelInterleave"),
        // libav*'s log callback takes a va_list, which Swift can't receive; this formats the line in C.
        .target(name: "FFmpegLogBridge", dependencies: ["EPLibavutil"]),
        .testTarget(
            name: "EnhancedNativePlayerTests",
            dependencies: ["EnhancedNativePlayer"]
        ),
    ]
)
