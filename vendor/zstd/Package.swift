// swift-tools-version:5.9
//
// Vendored zstd，只有解压部分：读 Codex CLI 压缩过的会话记录（`~/.codex/sessions/…/rollout-*.jsonl.zst`）。
// Apple 的 Compression 框架只有 LZ4 / zlib / LZMA / LZFSE / Brotli，没有 zstd；依赖闭包里也没有。
//
// 来源：facebook/zstd v1.5.7（提交 f8745da6ff1ad1e7bab384bd1f9d742439278e99），BSD 许可（上游双许可 BSD / GPLv2，这里取 BSD）。
// 只取 `lib/common`、`lib/decompress` 里解压要用的文件和 `lib/zstd.h`、`lib/zstd_errors.h`，目录结构不变，代码未改动
// （`MANIFEST.sha256` 逐个核对）。没有压缩器、字典生成器、旧格式（v0.x）解码器、多线程、x86_64 汇编。
// 升级步骤见 UTERM-PATCHES.md。

import PackageDescription

let package = Package(
    name: "uTermVendoredZstd",
    products: [
        .library(name: "CZstd", targets: ["CZstd"]),
    ],
    targets: [
        .target(
            name: "CZstd",
            path: ".",
            exclude: ["LICENSE", "UTERM-PATCHES.md", "MANIFEST.sha256"],
            sources: [
                "lib/common/entropy_common.c",
                "lib/common/error_private.c",
                "lib/common/fse_decompress.c",
                "lib/common/xxhash.c",
                "lib/common/zstd_common.c",
                "lib/decompress/huf_decompress.c",
                "lib/decompress/zstd_ddict.c",
                "lib/decompress/zstd_decompress.c",
                "lib/decompress/zstd_decompress_block.c",
            ],
            publicHeadersPath: "include",
            cSettings: [
                // 只编 C 实现：`huf_decompress_amd64.S` 没拷进来（只给 x86_64 用）。
                .define("ZSTD_DISABLE_ASM", to: "1"),
                // 不认 v0.x 的旧帧，`lib/legacy/` 没拷进来。
                .define("ZSTD_LEGACY_SUPPORT", to: "0"),
                // 上游代码，不在这里改，也别让它的警告混进工程的零警告。
                .unsafeFlags(["-w"]),
            ]
        ),
    ]
)
