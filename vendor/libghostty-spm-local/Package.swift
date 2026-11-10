// swift-tools-version: 6.2
// 本地副本：Lakr233/libghostty-spm tag 2.2.2026110702（1d84cf66）的 GhosttyKit / GhosttyTerminal 两个 Swift target，
// 源码未改；只把 binaryTarget 换成本地路径，好接我们自己编的 GhosttyKit.xcframework（0022 对比度、0023 平滑滚动…）。
// 换版本：改 build/ghostty-kit/current 这个软链指向的 xcframework，见同目录 README.md。Ghostty 评估分支临时用，不进 main。
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "GhosttyKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v15), .macOS(.v13), .macCatalyst(.v15), .visionOS(.v1)],
    products: [
        .library(name: "GhosttyKit", targets: ["GhosttyKit"]),
        .library(name: "GhosttyTerminal", targets: ["GhosttyTerminal"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/DisplayLink.git", from: "3.0.1"),
    ],
    targets: [
        .target(
            name: "GhosttyKit",
            dependencies: ["libghostty"],
            path: "Sources/GhosttyKit",
            swiftSettings: swiftSettings,
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "GhosttyTerminal",
            dependencies: ["GhosttyKit", "DisplayLink"],
            path: "Sources/GhosttyTerminal",
            resources: [
                .copy("Resources/Ghostty"),
                .copy("Resources/terminfo"),
                .process("Resources/Localization"),
            ],
            swiftSettings: swiftSettings
        ),
        // 软链：BinaryTarget/GhosttyKit.xcframework → ../../../build/ghostty-kit/current（gitignore 的 build/ 下，再软链到实际的 xcframework）。
        .binaryTarget(name: "libghostty", path: "BinaryTarget/GhosttyKit.xcframework"),
    ],
    swiftLanguageModes: [.v6]
)
