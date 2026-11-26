// swift-tools-version: 6.0

import Foundation
import PackageDescription

// The prebuilt frameworks. scripts/build-ffmpeg.sh and scripts/build-libass.sh build them into
// Frameworks/, and when they are there the package uses them. Otherwise they come from the
// package release below, which scripts/release.sh uploads and writes in here.
// BINARIES_RELEASE_BEGIN
let binariesRelease = "https://github.com/chafinchris97/enhancednativeplayer/releases/download/0.2.0"
let binaryChecksums = [
    "EPLibavutil": "80f2f7b4fd3a3da6501a4ed16a9568487e328dbf2ad098eca26fe751bcf48879",
    "EPLibswresample": "64c905839d43e0f92f9f48080ec3a4060c7d1e6d27120a3411b741e6684b9f68",
    "EPLibavcodec": "0174afc8008d534896cea74a419de3733eceadd208a57cb2e82b926378943414",
    "EPLibavformat": "abfe235a35d5e73454ba1c079596617bb17c0526ff9798650edb60142942972e",
    "EPLibass": "73aeb82cd26000e2497a76a1518d25940b670d99492a61894270598860e80249",
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
