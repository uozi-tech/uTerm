// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
// uTerm vendored copy of CodeEditTextView，基线 tag `0.12.1`
// （revision d7ac3f11f22ec2e820187acce8f3a3fb7aa8ddec）。
// 源码补丁与 manifest 裁剪见 UTERM-PATCHES.md —— 升级上游前必读，不要直接整目录覆盖。

import PackageDescription

let package = Package(
    name: "CodeEditTextView",
    platforms: [.macOS(.v13)],
    products: [
        // A Fast, Efficient text view for code.
        .library(
            name: "CodeEditTextView",
            targets: ["CodeEditTextView"]
        ),
    ],
    dependencies: [
        // Text mutation, storage helpers
        .package(
            url: "https://github.com/ChimeHQ/TextStory",
            from: "0.9.0"
        ),
        // Useful data structures
        .package(
            url: "https://github.com/apple/swift-collections.git",
            .upToNextMajor(from: "1.0.0")
        ),
        // uTerm 裁剪：删掉 SwiftLintPlugin 依赖（见 UTERM-PATCHES.md）
    ],
    targets: [
        // The main text view target.
        .target(
            name: "CodeEditTextView",
            dependencies: [
                "TextStory",
                .product(name: "Collections", package: "swift-collections"),
                "CodeEditTextViewObjC"
            ]
        ),

        // ObjC addons
        .target(
            name: "CodeEditTextViewObjC",
            publicHeadersPath: "include"
        ),

        // uTerm 裁剪：不 vendor Tests/，故删掉 testTarget（见 UTERM-PATCHES.md）
    ]
)
