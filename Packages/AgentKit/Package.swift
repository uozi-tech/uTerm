// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "AgentKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "AgentKit", targets: ["AgentKit"]),
    ],
    targets: [
        .target(
            name: "AgentKit"
        ),
        .testTarget(
            name: "AgentKitTests",
            dependencies: ["AgentKit"]
        ),
    ]
)
