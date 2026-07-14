// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "USSHKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "USSHKit", targets: ["USSHKit"]),
    ],
    dependencies: [
        .package(path: "../../vendor/Citadel"),
        .package(path: "../../vendor/swift-nio-ssh"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "USSHKit",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "Logging", package: "swift-log"),
            ],
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "USSHKitTests",
            dependencies: ["USSHKit"]
        ),
    ]
)
