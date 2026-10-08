// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Still",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "Still", targets: ["Still"]),
        .executable(name: "StillCheck", targets: ["StillCheck"]),
        .library(name: "StillKit", targets: ["StillKit"])
    ],
    targets: [
        .target(
            name: "StillKit",
            path: "Sources/StillKit"
        ),
        .executableTarget(
            name: "Still",
            dependencies: ["StillKit"],
            path: "Sources/Still"
        ),
        .executableTarget(
            name: "StillCheck",
            dependencies: ["StillKit"],
            path: "Sources/StillCheck"
        )
    ]
)
