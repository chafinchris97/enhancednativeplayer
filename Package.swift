// swift-tools-version: 6.0

import Foundation
import PackageDescription

// The prebuilt libraries. scripts/build-ffmpeg.sh and scripts/build-libass.sh build them into
// Frameworks/, and when they are there the package uses them. Otherwise they come from the
// releases below, which scripts/release-binaries.sh uploads and writes in here.
// FFMPEG_RELEASE_BEGIN
let ffmpegRelease = "https://github.com/chafinchris97/enhancednativeplayer/releases/download/ffmpeg-8.1.3-1"
let ffmpegChecksums = [
    "EPLibavutil": "4ab85f53e7e17a13d57fbeafa580117e2e6bbcb40b22e4c56c6cffa1d2acb0fc",
    "EPLibswresample": "f8ab35070997739f4a8ee203d8cdf7274e31c0aabb23d1ec5fa304fecf1b92db",
    "EPLibavcodec": "ec805c6f626ac27471fac4e8c63ce26abf7f5e37a4afbd46657f0ebcb94ddfe7",
    "EPLibavformat": "45d61808ebfe1c6b83239c0923ba5b56bdf09fa20db0ff073b1a6657386d3919",
]
// FFMPEG_RELEASE_END
// LIBASS_RELEASE_BEGIN
let libassRelease = "https://github.com/chafinchris97/enhancednativeplayer/releases/download/libass-0.17.5-1"
let libassChecksums = [
    "EPLibass": "6b1cd08aea077e2b55d1375da17bff2fa7ad5278e8ab56131ef3f5f9f51f5634",
]
// LIBASS_RELEASE_END

func binary(_ name: String, release: String, checksums: [String: String]) -> Target {
    let local = "Frameworks/\(name).xcframework"
    if FileManager.default.fileExists(atPath: "\(Context.packageDirectory)/\(local)") {
        return .binaryTarget(name: name, path: local)
    }
    return .binaryTarget(name: name, url: "\(release)/\(name).xcframework.zip", checksum: checksums[name]!)
}

func ffmpeg(_ name: String) -> Target { binary(name, release: ffmpegRelease, checksums: ffmpegChecksums) }

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
            ],
            // libass finds system fonts through CoreText; HarfBuzz is C++.
            linkerSettings: [.linkedFramework("CoreText"), .linkedLibrary("c++"), .linkedLibrary("iconv")]
        ),
        // libass with its assembly, and the FreeType, FriBidi and HarfBuzz it needs, in one
        // static library per platform.
        binary("EPLibass", release: libassRelease, checksums: libassChecksums),
        // FFmpeg, with dav1d inside libavcodec, as dynamic frameworks (it is LGPL).
        ffmpeg("EPLibavformat"),
        ffmpeg("EPLibavcodec"),
        ffmpeg("EPLibavutil"),
        ffmpeg("EPLibswresample"),
        // Plane interleaving for decoded video frames, in C with NEON so it is fast in a debug build too.
        .target(name: "PixelInterleave"),
        .testTarget(
            name: "EnhancedNativePlayerTests",
            dependencies: ["EnhancedNativePlayer"]
        ),
    ]
)
