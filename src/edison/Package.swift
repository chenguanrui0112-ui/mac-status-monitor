// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "edison",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "edison", targets: ["EdisonApp"])
    ],
    targets: [
        .executableTarget(
            name: "EdisonApp",
            path: "Sources/EdisonApp",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("EventKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)
