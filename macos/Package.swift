// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DevSpace",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DevSpace",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        )
    ]
)
