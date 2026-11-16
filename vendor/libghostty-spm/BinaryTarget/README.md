# BinaryTarget

这里放终端引擎的两个二进制，`Package.swift` 的两个 binaryTarget 指向它们：

- `GhosttyKit.xcframework`（完整的 libghostty：解析 + 渲染）
- `ghostty-vt.xcframework`（libghostty-vt，影子终端用）

它们不进版本库。在仓库根跑 `make engine`（`scripts/fetch-ghostty-engine.sh`）：按 `../ENGINE.lock` 取 zip、校验 sha256、
解到这个目录，旁边各留一个 `.stamp` 记着解的是哪一份。Xcode 报这两个路径不存在，就是还没跑过它。
取不到 zip 时它自动改为从上游源码现编（`make engine-build`，约 15 分钟、要联网），这时 `.stamp` 写的是
`local-build <engine_version>`。

版本、补丁和升级步骤见 `../UTERM-PATCHES.md`，怎么从源码编出这两份见 `../BUILD.md`。
