// swift-tools-version: 6.2
// uTerm 的 fork：上游 Lakr233/libghostty-spm，基线 tag 2.2.2026110702（1d84cf66），Ghostty 042b16b6。
// 带 GhosttyKit / GhosttyTerminal 两个 Swift target（GhosttyTerminal 有 uTerm 的本地补丁）和两个二进制：
//   - libghostty（GhosttyKit.xcframework）：上游 21 个补丁 + uTerm 的 0022 保色相最低对比度、0023 逐像素平滑滚动；
//   - GhosttyVt（ghostty-vt.xcframework）：libghostty-vt，影子终端用，和 GhosttyKit 同一棵打过补丁的源码树编的预链接静态库。
// 二进制不进版本库：`make engine` 按 ENGINE.lock 取 zip、校验 sha256、解到 BinaryTarget/。
// 相对上游 manifest 的改动、补丁清单、升级步骤见 UTERM-PATCHES.md，出包见 BUILD.md。
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
        // libghostty-vt 的 C API（模块名 GhosttyVt）。要链 libc++：GhosttyKit 那个 target 已经带了，两者总是一起用。
        .library(name: "GhosttyVt", targets: ["GhosttyVt"]),
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
        // 两个目录都由 `make engine` 放进来（.gitignore），哪一份由 ENGINE.lock 定。路径不存在 = 还没跑过 make engine。
        .binaryTarget(name: "libghostty", path: "BinaryTarget/GhosttyKit.xcframework"),
        .binaryTarget(name: "GhosttyVt", path: "BinaryTarget/ghostty-vt.xcframework"),
    ],
    swiftLanguageModes: [.v6]
)
