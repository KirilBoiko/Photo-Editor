// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PhotoEditor",
    platforms: [
        .macOS(.v14)  // Requires macOS 14+ for SwiftUI features used
    ],
    targets: [
        .executableTarget(
            name: "PhotoEditor",
            path: "PhotoEditor",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__entitlements",
                    "-Xlinker", "PhotoEditor.entitlements"
                ])
            ]
        )
    ]
)
