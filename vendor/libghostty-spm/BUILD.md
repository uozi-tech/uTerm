# 出包：从上游 tag 编出 GhosttyKit 和 ghostty-vt

`ENGINE.lock` 记的两个 zip 是照这里的步骤编出来的（最近一次 2026-11-17，换到上游 `2.2.2026111701`；第一次是 2026-11-09 的 M17 出包演练）。平时不用重编：`make engine` 从现成的 zip 取。
换 Ghostty 提交、换上游 tag、加减引擎补丁时才走一遍，完了按 `UTERM-PATCHES.md` 的「升级步骤」改清单和版本串。

**下面第 1、2 步和第 3 步的核对已经写成脚本**：`scripts/build-ghostty-engine.sh`（`make engine-build`，自测
`scripts/build-ghostty-engine.test.sh`）。它按 `ENGINE.lock` 的「来源」几行取 tag、核提交和 `Ghostty.ref`、没有 Zig 就下载并核
sha256、绕开全局 gitconfig 的 `url.*` 改写、接上我们的补丁（编号和上游撞了会停）、编两份、核版本串 / slice / 导出表。
- 取不到 zip 时 `make engine` 自动退到它，只编 macOS + iOS，装进 `BinaryTarget/`，stamp 记 `local-build <engine_version>`。
- 出正式 zip：`make engine-build ENGINE_BUILD_ARGS='--platforms macos,ios,maccatalyst,visionos --pack <目录> --no-install'`，
  打印两个 sha256。
- 工作目录 `~/Library/Caches/uTerm/ghostty-engine-build`（`UTERM_GHOSTTY_BUILD_DIR` 可改），Zig 工具链和包缓存留在那里；
  源码树编完删掉，`--keep-source` 留着（重切补丁时用）。

下面保留手工步骤，是讲每一步为什么这样做、以及读数。

读数来自 `docs/ghostty-eval/measure-build-consistency.md`（M17）和 `docs/ghostty-eval/vt-snapshot-and-build.md`（任务二）。
整理这份文档时**没有重新编过**，命令是那两份报告里跑通的原样。

## 要准备的

| 东西 | 版本 | 说明 |
|---|---|---|
| Zig | **0.17.1**，`zig-aarch64-macos-0.17.1.tar.xz`（54,001,240 字节，sha256 `75f1bc7a…dd8d`，与 `ziglang.org/download/index.json` 对一下） | Ghostty `5ebe501a` 要求 0.17.1（`build.zig.zon` 的 `minimum_zig_version`）；0.17.1 编 iOS / visionOS 不再需要上游的 Zig std 补丁 |
| libghostty-spm | tag `2.2.2026111701`（`b9694b50`） | 带 `build.sh`、`Script/`、上游的 `Patches/ghostty/0001`–`0022`、`Patches/zig/`、`Ghostty.ref` |
| Ghostty | `5ebe501a63425b13d9952e8c54682c046386e5af` | `build.sh` 自己按 `Ghostty.ref` 完整克隆（`.git` 约 100 MB）；完整克隆才能得到 9 位短哈希的版本串 `1.4.1-HEAD+5ebe501a6` |
| Xcode | 当前发版用的那一版 | `xcodebuild -create-xcframework`、`ld -r`、`lipo` |
| 磁盘 | 预留 5 GB | `build/cache` 编完 4.0 GB，Zig 全局缓存 249 MB，源码树 774 MB |

网络：`github.com`（libghostty-spm、Ghostty、Zig 包 `vancluever/z2d` 的 tarball）、`deps.files.ghostty.org`（35 个 Zig 包）、`ziglang.org`。
本机全局 gitconfig 把 GitHub 的 HTTPS 改写成 SSH，而代理会掐 SSH：克隆时用一份不带这条改写的 gitconfig
（`GIT_CONFIG_GLOBAL=<那份文件>`）。要离线重编，把 Zig 工具链（54 MB）、Zig 全局缓存（约 270 MB）和 Ghostty 源码一起归档，
`ZIG_GLOBAL_CACHE_DIR` 指过去。

## 1. GhosttyKit.xcframework

```sh
git clone --depth 1 --branch 2.2.2026111701 https://github.com/Lakr233/libghostty-spm
cd libghostty-spm

# 我们的引擎补丁接在上游 0001–0022 后面，build.sh 每个 target 都会自动打上。
# 补丁脚本按仓库里的相对路径找辅助脚本（Script/support），必须放进这个检出的 Patches/ghostty/，不能另指目录。
cp <uTerm>/vendor/libghostty-spm/Patches/ghostty/0023-uterm-minimum-contrast.patch Patches/ghostty/

# PATH 里要有 Zig 0.17.1；Homebrew 的 rsync 排在前面时组装 xcframework 那步可能出错，干脆用系统的
PATH=<zig 目录>:/usr/bin:/bin:/usr/sbin:/sbin ./build.sh --platforms macos,ios,maccatalyst,visionos --skip-tests
```

- 产物在 `BinaryTarget/GhosttyKit.xcframework`，6 个 slice：`ios-arm64`、`ios-arm64_x86_64-simulator`、`ios-arm64_x86_64-maccatalyst`、
  `macos-arm64_x86_64`、`xros-arm64`、`xros-arm64_x86_64-simulator`。uTerm 只用 macOS 和 iOS 的三个，其余是上游脚本默认带的。
- 耗时：不带我们的补丁 **973 s（16.2 分钟）**，其中 10 个 Zig target 的编译约 15 分钟（每个 68–121 s），克隆 10 s，打补丁 6 s，
  补丁 0017 拉 37 个 Zig 包 44 s，组装和 zip 8 s。带 0022 时 924–1,097 s，带到 0023、0024 的那一版 809 s。机器上同时有别的编译在跑，
  单独跑会快一些。2026-11-15 换到 `2.2.2026111501`（上游 0001–0022 + 我们的 0023）那一次约 17 分钟；2026-11-17 换到 `2.2.2026111701`（Ghostty `5ebe501a`）用 `make engine-build` 编四组平台约 22 分钟。
- 补丁集一变，脚本按戳记清缓存、全量重编，只改一行 shader 也一样，没有增量的捷径。
- 改过的补丁要在**没打过旧版**的树上重跑，否则 `git apply` 的三种尝试都对不上、构建停住；先 `git apply -R` 退掉旧版再放新版。
- `--skip-tests`：上游自己的 `Script/test.sh` 和 `swift test` 没跑过。
- 头文件 `Headers/libghostty/ghostty.h`（模块名 `libghostty`）。带 0011 的 `ghostty_surface_write_buffer_replay` 和
  0022 的 `ghostty_surface_set_smooth_scroll` / `ghostty_surface_smooth_scroll` / `ghostty_surface_smooth_scroll_by`。

打 zip（文件名带上 Ghostty 短哈希和补丁的最大编号，和 `ENGINE.lock` 对应；对象传上去不再覆盖，换二进制 = 换文件名）：

```sh
ditto -c -k --keepParent BinaryTarget/GhosttyKit.xcframework GhosttyKit-5ebe501a-0023.xcframework.zip
shasum -a 256 GhosttyKit-5ebe501a-0023.xcframework.zip
```

## 2. ghostty-vt.xcframework

vt 必须在**打完全部补丁的同一棵树**上编：上游的 0014（resize 不结束 DEC 2026 同步输出）和 0015（resize 擦掉提示符后的
`prompt_redraw` 标记）改的是终端核心，0022 给 `src/terminal/PageList.zig` 加了视口移动计数，官方发布的 libghostty-vt 不带它们，
影子终端和画面在 resize 上会分叉。第 1 步跑完之后，`References/ghostty-upstream` 就是那棵树（现在这份 vt 就是在打完 0001–0023 的树上编的）。

```sh
cd References/ghostty-upstream
zig build --prefix /tmp/vt -Demit-lib-vt -Demit-xcframework=true -Doptimize=ReleaseFast

<uTerm>/vendor/libghostty-spm/Scripts/prelink-vt.sh /tmp/vt/lib/ghostty-vt.xcframework <输出目录>/ghostty-vt.xcframework

cd <输出目录>
ditto -c -k --keepParent ghostty-vt.xcframework ghostty-vt-5ebe501a-0023.xcframework.zip
shasum -a 256 ghostty-vt-5ebe501a-0023.xcframework.zip
```

- git 检出的树没有 `LIB_VERSION`，必须带 `-Demit-lib-vt`。
- 耗时：`zig build` **43 s**（Zig 包缓存第 1 步已经拉好），预链接 3 个 slice **2 s**。2026-11-15 那次 83 s（同时在编 App）。
- 三个 slice：`macos-arm64_x86_64`、`ios-arm64`、`ios-arm64-simulator`（只有 arm64）。头文件 `Headers/ghostty/vt.h` 和
  `Headers/ghostty/vt/*.h`，模块名 `GhosttyVt`。

### 导出表怎么收窄（`Scripts/prelink-vt.sh`）

libghostty-vt 和 GhosttyKit 的 `.a` 都带 Zig 打包进来的 ubsan 运行时、`memset`、simdutf、highway、compiler_rt，
两份一起链、不开 dead strip 就重复符号。脚本对每个 slice 的每个架构：

1. `ar -x` 拆出全部 `.o`；
2. `nm -gU` 取出所有 `_ghostty_` 开头的全局符号，写成导出表；
3. `ld -r -exported_symbols_list <导出表>` 并成一个 `.o`，表外的全局符号全部变成私有；
4. `ar rcs` 包回 `.a`，多架构的用 `lipo -create` 合回去，最后 `xcodebuild -create-xcframework` 重新组装。

结果是每个 slice 只导出 **209 个 `ghostty_*`**。核对：

```sh
nm -gU ghostty-vt.xcframework/ios-arm64/libghostty-vt.a | grep -c ' _ghostty_'     # 209
nm -gU ghostty-vt.xcframework/ios-arm64/libghostty-vt.a | grep -v ' _ghostty_'     # 只剩一个空行和成员名「ghostty-vt.o:」
```

和 GhosttyKit 仍有 6 个同名导出（`ghostty_hwy_detect_targets` 和 5 个 `ghostty_simd_*`），常规链接不撞，
`-all_load` / `-force_load` 会撞，见 `UTERM-PATCHES.md` 的「GhosttyVt」一节。要彻底去掉，在第 2 步生成导出表时把这 6 个滤掉
（没做过，滤掉之后 vt 内部对它们的引用仍然解析得到，但没验证）。

## 3. 核对产物

- 版本串：`strings -a GhosttyKit.xcframework/macos-arm64_x86_64/libghostty.a | grep '1.4.1-HEAD'` 应当是 `1.4.1-HEAD+5ebe501a6`（9 位短哈希）。
- 和官方发布比不会逐字节相同（构建路径进了调试信息）。上一轮不带补丁自编时，各 slice 的导出符号与官方完全相同，
  136 个成员里 135 个 `__text` 逐字节相同，差的那个是嵌了路径和版本串的 `ghostty_zcu.o`。binaryTarget 认的是我们自己算的 sha256。
- 链进 App 的体积（iOS arm64，strip 后的上限）：GhosttyKit +9.9 MB，vt +1.5–1.9 MB，一起 +11.7 MB（zip 后约 5.0 MB）。

## 4. 放进仓库

1. 两个 zip 放到 artifacts 目录（`UTERM_GHOSTTY_ARTIFACTS` 指向的地方；公开下载地址还没有，占位在 `ENGINE.lock` 里。
   对象传上去就不再覆盖）。
2. 改 `ENGINE.lock`：两个 zip 的文件名与 sha256、`engine_version`、来源几行。
3. 改 `uTerm/Features/Terminal/Shadow/TerminalEngineVersion.swift` 的 `TerminalEngineVersion.current`，和 `engine_version` 一字不差。
4. `make engine`，两端重编，按 `UTERM-PATCHES.md`「升级步骤」第 8 条跑回归。

整套（编译 16 分钟 + vt 1 分钟 + 回归）演练时约 30 分钟，几乎都在编译。

## 评估期用过、没带进来的工具

在评估分支 `worktree-agent-a6bb31349ee21df46` 的 `Spikes/GhosttyVT/` 里，要用时从那里取：

- `vtsnap.c` + `build.sh`：纯 C 的快照往返工具（语料 × 切点、密集切点、合成用例、吞吐）。
- `SurfaceCheck/`：SwiftPM 测试包，同时链 GhosttyKit 和 vt，核影子与画面一致（M4）、快照回放（M5）、对比度像素（M13）、
  平滑滚动（0023）、交换链（0024）。

它们核的性质现在由工程里的用例覆盖（`GhosttySpikeTests`、`TerminalSnapshotTests`、`TerminalContrastTests`、`GhosttyMacScrollTests`），
密集切点扫描（33,243 个切点，单线程约 10 分钟）没有对应的常规用例。
