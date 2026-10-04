// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalPort",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Self-updates. The bundle embeds Sparkle.framework (scripts/build.sh).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "LocalPort",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources",
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        )
    ]
)
