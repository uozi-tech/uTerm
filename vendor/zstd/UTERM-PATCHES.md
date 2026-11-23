# vendor/zstd

上游：<https://github.com/facebook/zstd>，当前 v1.5.7（提交 `f8745da6ff1ad1e7bab384bd1f9d742439278e99`）。

## 为什么要带一份

Codex CLI 会把 7 天没动过的会话记录压成 `rollout-*.jsonl.zst`（它自己的后台任务，zstd 等级 3、单帧、帧头写着原始大小；
见上游 `codex-rs/rollout/src/compression.rs`）。「历史会话」要在 App 里读这些记录，而 Apple 的 Compression 框架没有 zstd，
依赖闭包里也没有别的 zstd。

## 带了什么

只有解压：`lib/common/` 与 `lib/decompress/` 里解压用到的 `.c` / `.h`，加上 `lib/zstd.h`、`lib/zstd_errors.h`、`LICENSE`，
目录结构与上游一致，**文件未改动**（`MANIFEST.sha256` 是对 `lib/` 下每个文件的 SHA-256，`cd lib && shasum -a 256 -c ../MANIFEST.sha256`）。
本目录自己的文件只有 `Package.swift`、`include/CZstd.h`（模块的伞头文件，只引 `zstd.h`）、`MANIFEST.sha256` 和这份说明。

没带：压缩器（`lib/compress/`）、字典生成器（`lib/dictBuilder/`）、旧格式解码器（`lib/legacy/`，编译时 `ZSTD_LEGACY_SUPPORT=0`）、
多线程（`pool.c` / `threading.c`，解压用不到）、`huf_decompress_amd64.S`（编译时 `ZSTD_DISABLE_ASM=1`，只用 C 实现）。
arm64 `-Os` 下代码段约 63 KB。

## 本地补丁

没有。

## 升级

1. 在上游新 tag 的检出里，按 `Package.swift` 的 `sources` 与本目录 `lib/` 下现有的头文件逐个拷过来（目录结构不变）。
2. 新版本的解压代码要是多引了别的文件，链接或编译会直接报缺符号 / 缺头文件，照着补，别整目录拷。
3. 重算 `MANIFEST.sha256`，改 `Package.swift` 头注释与本文的版本号、提交号。
4. 跑 `CodexZstdTests`（压缩夹具是 zstd 命令行现压的字节常量）与 `make test-fast`。

## 合规

- BSD-3-Clause（上游双许可，取 BSD），发版的第三方声明要列上它（`THIRD_PARTY_NOTICES.md`）。
- 不含密码学（`xxhash` 只是校验和）。
