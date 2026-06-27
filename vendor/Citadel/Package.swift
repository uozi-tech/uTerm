// swift-tools-version:5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

// uTerm vendored copy of Citadel.
//
// Upstream:  https://github.com/orlandos-nl/Citadel
// Revision:  ae8562f895de06ccb86fdb1cbb65fd99c8976e12 (tag 0.12.1)
// Why:       Citadel pins swift-nio-ssh to the remote fork
//            `github.com/Wellz26/swift-nio-ssh`. We ship a patched local copy
//            of that fork in `vendor/swift-nio-ssh` (see its UTERM-PATCHES.md
//            for the channel-teardown crash fix). Citadel is vendored only so
//            its swift-nio-ssh dependency can point at that local path instead
//            of the remote URL — which removes the "Conflicting identity for
//            swift-nio-ssh" SwiftPM diagnostic that the identity-override trick
//            otherwise produces. No Citadel source is patched. See
//            UTERM-PATCHES.md for the manifest diff and the upgrade/replay steps.
//
// Manifest is trimmed to the Citadel library only: upstream's
// CitadelServerExample executable (and its ColorizeSwift dependency) and the
// CitadelTests test target are dropped.

import PackageDescription

let package = Package(
    name: "Citadel",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "Citadel",
            targets: ["Citadel"]
        ),
    ],
    dependencies: [
        .package(path: "../swift-nio-ssh"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.2.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
    ],
    targets: [
        .target(name: "CCitadelBcrypt"),
        .target(
            name: "Citadel",
            dependencies: [
                .target(name: "CCitadelBcrypt"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "BigInt", package: "BigInt"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
    ]
)
