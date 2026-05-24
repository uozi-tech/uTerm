// swift-tools-version:5.9
//
// Vendored tree-sitter grammar bundle.
//
// 上游各 grammar 自己的 Package.swift 用 `FileManager.fileExists("src/scanner.c")`
// 条件加 scanner — 这在 SPM manifest evaluation 阶段 cwd 不是包根、总是返回
// false，scanner 漏链。这里 vendor 化 C 源 + 自写硬编码 sources 的 Package.swift
// 一次性绕开。
//
// Sources pinned to (master HEAD as of 2026-05-24):
//   python:     tree-sitter/tree-sitter-python @ 26855eabccb19c6abf499fbc5b8dc7cc9ab8bc64
//   javascript: tree-sitter/tree-sitter-javascript @ 58404d8cf191d69f2674a8fd507bd5776f46cb11
//   yaml:       tree-sitter-grammars/tree-sitter-yaml @ a1c4812a73ec5e089de8e441fdea3a921e8d5079
//   toml:       tree-sitter-grammars/tree-sitter-toml @ 64b56832c2cffe41758f28e05c756a3a98d16f41
//   ini:        justinmk/tree-sitter-ini @ e4018b5176132b4f3c5d6e61cea383f42288d0f5
//
// 升级流程：重跑 `scripts/sync-vendored-grammars.sh`（pin commit 在脚本里）。

import PackageDescription

let package = Package(
    name: "uTermVendoredGrammars",
    products: [
        .library(name: "TreeSitterPython",     targets: ["TreeSitterPython"]),
        .library(name: "TreeSitterJavaScript", targets: ["TreeSitterJavaScript"]),
        .library(name: "TreeSitterYAML",       targets: ["TreeSitterYAML"]),
        .library(name: "TreeSitterTOML",       targets: ["TreeSitterTOML"]),
        .library(name: "TreeSitterINI",        targets: ["TreeSitterINI"]),
    ],
    targets: [
        .target(
            name: "TreeSitterPython",
            path: "python",
            sources: ["src/parser.c", "src/scanner.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src")]
        ),
        .target(
            name: "TreeSitterJavaScript",
            path: "javascript",
            sources: ["src/parser.c", "src/scanner.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src")]
        ),
        .target(
            name: "TreeSitterYAML",
            path: "yaml",
            // schema.core.c / schema.json.c / schema.legacy.c 是 scanner.c 用宏
            // `#include _file(YAML_SCHEMA)` 拉进来的 schema 模板，不能放进 sources（会
            // 重复定义符号）—— 显式 sources 只列 parser.c + scanner.c，SPM 不会
            // 把 schema.*.c 自动当 target source。core 是默认 YAML_SCHEMA。
            sources: ["src/parser.c", "src/scanner.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src")]
        ),
        .target(
            name: "TreeSitterTOML",
            path: "toml",
            sources: ["src/parser.c", "src/scanner.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src")]
        ),
        .target(
            name: "TreeSitterINI",
            path: "ini",
            // ini 没有外部 scanner —— grammar 无 conflict token，全 parser.c 处理。
            sources: ["src/parser.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src")]
        ),
    ],
    cLanguageStandard: .c11
)
