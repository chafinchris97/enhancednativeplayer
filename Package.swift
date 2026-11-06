// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "EnhancedNativePlayer",
    platforms: [
        // Hummingbird 2 sets the floor at tvOS / iOS 17 and macOS 14.
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
        .package(url: "https://github.com/hummingbird-project/hummingbird", from: "2.28.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.11.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services", from: "1.28.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle", from: "2.6.0"),
        // libass 0.17 with FreeType, HarfBuzz and FriBidi as static xcframeworks, tvOS slices included.
        .package(url: "https://github.com/mihai8804858/swift-libass", from: "1.4.0"),
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
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "SwiftLibass", package: "swift-libass"),
            ],
            // libass finds system fonts through CoreText, which swift-libass doesn't link itself.
            linkerSettings: [.linkedFramework("CoreText")]
        ),
        .testTarget(
            name: "EnhancedNativePlayerTests",
            dependencies: ["EnhancedNativePlayer"]
        ),
    ]
)
