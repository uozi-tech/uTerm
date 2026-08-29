// swift-tools-version:5.10

// uTerm vendored copy of swift-nio-ssh.
//
// Upstream:  https://github.com/Wellz26/swift-nio-ssh (Citadel's fork)
// Revision:  a05e6bbe6b141ee68da3030e00275504c0595d4d (tag 0.3.6)
// Why:       fixes a precondition crash ("Sent channel window adjust on
//            channel in invalid state") during channel teardown. The fork
//            is a pre-fix snapshot of swift-nio-ssh and is missing the
//            `!self.state.sentClose` guard Apple later added. Pulled in
//            transitively by Citadel; vendored as a local package so the
//            patch overrides Citadel's remote dependency. See
//            UTERM-PATCHES.md for the patch and the upgrade/replay steps.
//
// Manifest is trimmed to the NIOSSH library target only: upstream's
// NIOSSHClient / NIOSSHServer / NIOSSHPerformanceTester executables, the
// test target, and the swift-docc-plugin dependency are dropped.

import PackageDescription

let strictConcurrencySettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency"),
    .enableUpcomingFeature("InferSendableFromCaptures"),
]

let package = Package(
    name: "swift-nio-ssh",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .watchOS(.v6),
        .tvOS(.v13),
    ],
    products: [
        .library(name: "NIOSSH", targets: ["NIOSSH"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.0.2"),
    ],
    targets: [
        .target(
            name: "NIOSSH",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            swiftSettings: strictConcurrencySettings
        ),
    ]
)

// ---    STANDARD CROSS-REPO SETTINGS DO NOT EDIT   --- //
for target in package.targets {
    switch target.type {
    case .regular, .test, .executable:
        var settings = target.swiftSettings ?? []
        // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0444-member-import-visibility.md
        settings.append(.enableUpcomingFeature("MemberImportVisibility"))
        target.swiftSettings = settings
    case .macro, .plugin, .system, .binary:
        ()  // not applicable
    @unknown default:
        ()  // we don't know what to do here, do nothing
    }
}
