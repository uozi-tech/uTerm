// swift-tools-version:5.9

// uTerm vendored copy of SwiftTerm.
//
// Upstream:  https://github.com/migueldeicaza/SwiftTerm
// Revision:  c068a905c5aeab60852fb865bee05dc8a5af190c (2026-05-17)
// Why:       minimum-contrast rendering needs hooks inside the renderer
//            (getAttributes/mapColor are internal). See UTERM-PATCHES.md
//            for the list of local patches before updating.
//
// Manifest is trimmed to the library target only: upstream's fuzzer,
// termcast, tests and benchmarks (plus their swift-argument-parser /
// swift-docc-plugin dependencies) are dropped.

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
