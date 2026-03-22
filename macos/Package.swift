// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalPort",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LocalPort",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        )
    ]
)
