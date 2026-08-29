// swift-tools-version:5.9

// uTerm vendored copy of SwiftTerm.
//
// Upstream:  https://github.com/migueldeicaza/SwiftTerm
// Revision:  464df5207fc2432e16c9a23abe538187196daf5f (tag v1.19.0)
// Why:       minimum-contrast rendering needs hooks inside the renderer
//            (getAttributes/mapColor are internal). See UTERM-PATCHES.md
//            for the list of local patches before updating.
//
// Manifest is trimmed to the library target only: upstream's fuzzer,
// termcast, tests and benchmarks (plus their swift-argument-parser /
// swift-docc-plugin dependencies) are dropped.
//
// Also dropped: upstream's SwiftTermBuildInfoGenerator target and its
// SwiftTermBuildInfoPlugin build tool plugin. The vendored copy ships a
// hand-written Sources/SwiftTerm/SwiftTermBuildInfo.swift instead — see
// UTERM-PATCHES.md §3 for why generating it here would be wrong.

import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .tvOS(.v13),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "SwiftTerm",
            targets: ["SwiftTerm"]
        ),
    ],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: ["Mac/README.md"],
            resources: [
                .process("Apple/Metal/Shaders.metal")
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
