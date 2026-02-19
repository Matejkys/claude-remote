// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ClaudeRemote",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeRemote",
            path: ".",
            exclude: ["Package.swift", "Info.plist", "Makefile", "build", "AppIcon.icns"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
            ]
        ),
    ]
)
