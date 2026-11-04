// swift-tools-version:6.0
// steamac-vm: AppKit/Metal launcher for libkrun v1.19.6 (C API).
// libkrun headers/dylib location is supplied by build.sh (-Xcc -I / -Xlinker -L / rpath).
import PackageDescription

let package = Package(
    name: "steamac-vm",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Crash/error reporting (CrashReporting.swift). Static Sentry.xcframework (binary target).
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", exact: "9.30.0"),
        // In-app updates of release builds (SparkleUpdates.swift). Sparkle.framework (dynamic binary
        // target): build.sh copies it next to the dev launcher, bundle.sh embeds it, dist.sh signs it.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.1"),
    ],
    targets: [
        .systemLibrary(name: "CKrun", path: "Sources/CKrun"),
        // zstd decoder (sources fetched by fetch-zstd.sh into Sources/CZstd/zstd, included by czstd.c).
        .target(name: "CZstd", path: "Sources/CZstd", exclude: ["zstd"]),
        // ENet for the Moonlight host's control stream (fetch-enet.sh: sources into Sources/CEnet/enet,
        // headers into Sources/CEnet/include/enet).
        .target(
            name: "CEnet",
            path: "Sources/CEnet",
            exclude: ["enet/LICENSE", "enet/VERSION"],
            sources: ["enet"],
            cSettings: [.unsafeFlags(["-w"])]
        ),
        // nanors Reed-Solomon for the Moonlight host's video/audio FEC (fetch-nanors.sh into
        // Sources/CNanors/nanors, included by cnanors.c).
        .target(
            name: "CNanors",
            path: "Sources/CNanors",
            exclude: ["nanors"],
            sources: ["cnanors.c"],
            cSettings: [.headerSearchPath("nanors"), .headerSearchPath("nanors/deps/obl"), .unsafeFlags(["-w"])]
        ),
        .executableTarget(
            name: "steamac-vm",
            dependencies: ["CKrun", "CZstd", "CEnet", "CNanors", .product(name: "Sentry", package: "sentry-cocoa"),
                           .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/steamac-vm",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("GameController"),
                .linkedFramework("ImageIO"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Security"),
                // Moonlight streaming host (Stream/): listeners and Bonjour, hardware encoding, Opus.
                .linkedFramework("Network"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
