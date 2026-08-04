// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Resonant",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMinor(from: "0.14.8")),
        .package(url: "https://github.com/PostHog/posthog-ios.git", from: "3.47.0"),
        .package(url: "https://github.com/sindresorhus/Defaults", from: "7.0.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin", from: "5.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "8.0.0"),
    ],
    targets: [
        .target(
            name: "ObjCExceptionCatcher",
            path: "Sources/ObjCExceptionCatcher",
            publicHeadersPath: "include"
        ),
        .binaryTarget(
            name: "CNemoTextProcessing",
            path: "Vendor/NemoTextProcessing.xcframework"
        ),
        .executableTarget(
            name: "Resonant",
            dependencies: [
                "ObjCExceptionCatcher",
                "CNemoTextProcessing",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "PostHog", package: "posthog-ios"),
                .product(name: "Defaults", package: "Defaults"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Sentry", package: "sentry-cocoa"),
            ],
            path: "Sources/Resonant",
            exclude: ["Info.plist"],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "ResonantTests",
            dependencies: ["Resonant"],
            path: "Tests/ResonantTests"
        )
    ]
)
