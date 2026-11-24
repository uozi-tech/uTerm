# uTerm 对 libghostty-spm 的 fork

上游：`https://github.com/Lakr233/libghostty-spm`，基线 tag `2.2.2026112301`（revision `1f378020`）。
它钉的 Ghostty 提交（`Ghostty.ref`）是 `5ebe501a63425b13d9952e8c54682c046386e5af`（2026-11-16，版本串 `+5ebe501a6`），Zig 0.17.1。

上一个基线是 `2.2.2026111701`（`b9694b50`，同一个 Ghostty 提交）。2026-11-23 换到现在这个，上游这两个 tag 之间的变化：
- [#123](https://github.com/Lakr233/libghostty-spm/pull/123)：我们提的滚动修复。Swift 层第 18、19 条整条进了上游，第 20、21 条进了一部分（见各条）；
  原来我们的引擎补丁 0024（滚动那一帧交到图层的信号）成了上游的 `0023-smooth-scroll-presented.sh`，我们的最低对比度从 0023 改号成 0024（文件内容没改）。
  维护者合并前加了两处修正，一起带进来了：按住一段从静止起步的吸附再抬手，接着它原来的方向走、不掉头
  （`TerminalSmoothScrollSettler.touchFollowsTravel`）；iOS 慢松手的速度按视图自己的坐标取（`velocity(in: self)`，滚动视图不滚，两者数值相同）。
- [#122](https://github.com/Lakr233/libghostty-spm/pull/122)：`TerminalSurfaceOptions.scrollBehavior`（`.settlesOnRow` 默认 / `.restsAnywhere` / `.rowAtATime`），uTerm 用默认值。
- [#121](https://github.com/Lakr233/libghostty-spm/pull/121)：`TerminalSurface` 的只读格子区间读取（公开 API，uTerm 没用）。
- [#124](https://github.com/Lakr233/libghostty-spm/pull/124) 只改上游自己的测试（没带进来）。
- Ghostty 提交、Zig 都没换，补丁只多了 0023。引擎是同一个 Ghostty 提交、同一组补丁，**版本串不变，这次升级不算协议变更**；
  只是换了二进制（zip 文件名带上游 tag 的日期 `-2026112301-`）。
- 协调器（`TerminalSurfaceCoordinator`）和 `systemScrollDidScroll` 没有改用上游的版本：上游的 tick 是「wakeup 的 tick 整个跳过 refresh 和 draw、欠一帧」，
  我们的第 2 条把 Mac 定成「wakeup 永不同步重画、refresh 照做」，两个模型对不上；对照测量用的几种做法和打点（第 8、20 条）也在这里。
  续 display link 的入口用了上游的名字 `holdDisplayLinkForScroll`。
- 验证（新二进制）：`make test-fast` 4349 条、`make test-mobile-fast` 751 条，串行复核后全过；iPhone Duo 真机滚动相关 45 条里
  `testUIKitReleasePremises`（量普通 `UIScrollView` 自己的减速，不经过终端）有一次 1.2548 对上限 1.25 擦线没过，单独重跑 3 遍都过，其余全过。
  没重跑 `zig build test-lib-vt`（Ghostty 提交没换，补丁只多了动渲染的 0023）。

再上一个基线是 `2.2.2026111501`（Ghostty `cf5519b2`，Zig 0.17.0）。2026-11-17 换到 `2.2.2026111701`，上游这两个 tag 之间的变化：
- Swift 层只动了 `UITerminalView+Keyboard.swift`（我们没改过这个文件，原样取上游）：硬件键盘交给输入法的按键各自等
  0.25 s 的认领窗口，窗口没过不会被别的键的 flush 当成没人认领而原样重放（原来会打两遍）；校准时转交按键带上它的
  `UIPressesEvent`（不带的话 iOS 27 的拼音不认进程的第一个延后按键）。代价：转交模式下没有输入法认领的键要等满 0.25 s 才原样补发。
- 补丁 0014 改了一条 C API 测试的期望（resize 不再结束 2026 的 render hold，那条测试此前每一版都是挂的，上游流水线不跑 Ghostty 自己的测试）；
  0015 改成在 resize **之前**量提示符（Ghostty `8ad3f607` 起列数变化的回流自己会把提示符那几行写空）。
- Zig 0.17.1 不再需要 iOS / visionOS 的 std 补丁（`Patches/zig/` 空了）。
- Ghostty `cf5519b2..5ebe501a` 91 个提交，和我们有关的：回流时提示符标记只留在第一行、resize 后不再残留旧提示符（`8ad3f607`，p10k 最明显）；
  恢复快照时最后一页按池子给足行容量，恢复后第一次写不再新开一页（`9b848b0f`，快照格式没变，所以串尾仍是 `snapshot-1`）；
  按行数修剪回滚时留着被修剪那页的内存（`d0addb9c`）；`clone` 的补齐行按页宽清（越界写，`dcdb1674`）；
  调高窗口时滚在历史里 Debug 构建断言崩（`f4830b2f`）；回退字体加载失败时不再整行空白（`efd4a82b`）；
  kitty 图片分块传输期间留着旧图（`c4b91fe4`）；几处解析 / 清格子的性能改动。vt 的 C 头文件只有 `version.h` 变了，`ShadowTerminal.swift` 不用改。
  `copy-on-select` 在 macOS 上的默认值从 `none` 改成 `primary`：Mac 端的 `GhosttyTerminalConfig` 总是显式写这一项，iOS 不受影响。
- 验证：在打完 `0001`–`0023` 的树上跑 `zig build test-lib-vt`，`ghostty-vt-test` / `ghostty-vt-c-test` 各 18 个分片全过。

再往前一个基线是 `2.2.2026110702`（Ghostty `042b16b6`）。2026-11-15 换到 `2.2.2026111501` 时，我们提给上游的三个 PR 都合进了那一版——
[#108](https://github.com/Lakr233/libghostty-spm/pull/108)（回放入口 `receiveReplay` / `discardPendingOutput`）、
[#109](https://github.com/Lakr233/libghostty-spm/pull/109)（iOS 惯性 display link 跟屏幕刷新率、AppKit 精确滚动乘屏幕倍率、
iOS 输入法候选框上移一行）、[#110](https://github.com/Lakr233/libghostty-spm/pull/110)（逐像素平滑滚动：引擎补丁、
停下吸附整行的 settler、iOS 单指滚动交给 UIScrollView）。原来的引擎补丁 0023 和 Swift 层第 3、4、7 条整条删掉，
第 1、5、8、13 条只剩上游没收的那部分（见各条）。

uTerm 的终端引擎只有这一套：画面由 GhosttyKit（完整的 libghostty）画，读状态由 libghostty-vt 的影子终端提供
（`uTerm/Features/Terminal/Shadow/ShadowTerminal.swift`）。两个二进制、Swift 层、引擎补丁都在这个目录里一起管。

## 为什么 fork

三件事都改不到包外：

1. **引擎要带我们的补丁。** 最低对比度要保色相（官方是直接换成黑或白），改 Ghostty 的 shader，只能自己编
   `GhosttyKit.xcframework`。上游的包用 `binaryTarget(url:)` 指向它自己发布的那份。（逐像素平滑滚动、滚动那一帧交到图层的信号原来也是我们的补丁，
   现在是上游的 0022、0023。）
2. **Swift 层要改 internal 的东西。** surface 生灭的回调、`TerminalSurfaceCoordinator` 的 tick、惯性的参数、按键过滤，
   都是 internal 或者写在不可覆写的扩展里，子类和包外扩展够不着。
3. **vt 要和 GhosttyKit 同一棵树编。** 影子终端和画面吃同一份字节，必须逐格一致。上游的补丁里有几个改终端核心
   （0014、0015，以及 0022 给 `PageList` 加的视口移动计数），官方发布的 libghostty-vt 不带它们，resize 时两边会分叉。所以 vt 也自己编，和 GhosttyKit 放在同一个包里一起换版本。

## 目录里有什么

| 路径 | 内容 |
|---|---|
| `Sources/GhosttyKit`、`Sources/GhosttyTerminal` | 上游的两个 Swift target。`GhosttyKit` 没改；`GhosttyTerminal` 改了 25 个文件、加了 7 个文件，见「Swift 层补丁」 |
| `Package.swift` | 见「manifest 改动」 |
| `ENGINE.lock` | 两个二进制的清单：引擎版本串、zip 文件名、sha256 |
| `BinaryTarget/` | `GhosttyKit.xcframework`、`ghostty-vt.xcframework` 解在这里，**不进版本库**（`.gitignore`），由 `make engine` 放进来 |
| `Patches/ghostty/` | 我们加的引擎补丁 `0024`（接在上游的 `0001`–`0023` 后面） |
| `Scripts/prelink-vt.sh` | vt 的预链接：每个 slice 并成一个 `.o`、只导出 `ghostty_*` |
| `BUILD.md` | 怎么从上游 tag 编出这两个二进制 |

没带进来的上游内容：`Sources/GhosttyTheme`、`Sources/ShellCraftKit`、`Tests/`、`Example/`、`build.sh` 与 `Script/`、
上游自己的 `Patches/ghostty/0001`–`0023` 和 `Patches/zig/`。出包时从上游 tag 取（`BUILD.md`）。

## 二进制：`ENGINE.lock` 与 `make engine`

二进制不进版本库（GhosttyKit 解开 197 MB，vt 14 MB）。`ENGINE.lock` 记着要哪两份：

```
engine_version=ghostty-5ebe501a+p0024/snapshot-1
ghosttykit_zip=GhosttyKit-5ebe501a-2026112301-0024.xcframework.zip     sha256 001bf8fe…8342
ghosttyvt_zip=ghostty-vt-5ebe501a-2026112301-0024.xcframework.zip      sha256 ef6f8c0b…7fbe
```

`make engine`（`scripts/fetch-ghostty-engine.sh`）按它从本地目录取 zip、校验 sha256、解到 `BinaryTarget/`，旁边各留一个
`.stamp` 记着解的是哪一份；已经是清单要的那一份就什么都不做。`make build` / `archive` / `test*` / `archive-mobile` 等会编工程的
目标都先依赖它。`make clean` 只清 `build/`，不动这里。`make check-engine` 只核不取。

- zip 所在目录由 `UTERM_GHOSTTY_ARTIFACTS=<目录> make engine` 指定（维护者的目录在 `internal/config.mk`）。
- **不发布二进制**（已定）：zip 只在维护者本机，脚本不联网下载；别人的机器上走下面的现编。
- **取不到 zip 时现编**：新克隆的仓库、换了机器，`make engine` 找不到 zip（fetch 脚本退出码 3）就自动改跑
  `scripts/build-ghostty-engine.sh`：按 `ENGINE.lock` 的「来源」几行克隆上游 tag、核对提交和 `Ghostty.ref`、接上我们的
  `Patches/ghostty/`、编 GhosttyKit（默认只编 macOS + iOS）和 vt、核版本串与导出表，装进 `BinaryTarget/`，stamp 写成
  `local-build <engine_version>`（编出来不逐字节等于 zip，不核 sha256；engine_version 一样，远控两端照样互认）。要联网，
  约 15 分钟。手动跑是 `make engine-build`，`UTERM_GHOSTTY_NO_BUILD=1` 关掉自动退路。**发版用测过的 zip，不用现编的。**
- 新克隆的仓库在跑 `make engine` 之前，Xcode 会报 binaryTarget 的路径不存在。
- 脚本自测：`bash scripts/fetch-ghostty-engine.test.sh`、`bash scripts/build-ghostty-engine.test.sh`（都全离线）。
- 换了二进制之后行为对不上时，删掉整个 DerivedData 重编（别只删 `SourcePackages/artifacts/`，见「升级步骤」第 6 步）。

## 引擎版本串

`engine_version` 和 `uTerm/Features/Terminal/Shadow/TerminalEngineVersion.swift` 的 `TerminalEngineVersion.current` 是同一个串：
Ghostty 提交 + 引擎补丁的最大编号 + 快照格式的修订号。远控握手带着它，两端快照格式不互认时镜像改发回放流（两端都声明 `terminal-replay` 才行，否则拒绝镜像终端）；holder 检查点的版本头里也有它，
对不上就丢弃检查点。vt 自己报的版本只有 `0.1.0-dev`，区分不了提交和补丁，所以手写。

两处必须一字不差，两端各有一条单测拦着：`uTermTests/Features/Terminal/TerminalEngineLockTests.swift`、
`uTermMobileTests/TerminalEngineLockTests.swift`（读 `ENGINE.lock`，和常量比）。

**换二进制算协议变更**，除非只改了渲染：
- 快照格式没变（补丁只动 GhosttyKit 的 `src/renderer`、`Surface.zig`、`apprt`，没动 `src/terminal`，Ghostty 提交没换）：把旧串记进
  `TerminalEngineVersion.sameSnapshotFormat`（旧 → 新；表里原有的条目值也改成新串，或者留着让它一路走到新串）。之后新旧两版
  远控照常镜像，旧版本存的 holder 检查点照常接回。`TerminalEngineLockTests.testSnapshotCompatibilityTableOnlyBridgesPatchLevels`
  核每一条只差补丁编号、走得到 `current`。0024 就是这样记的（2026-11-23，p0023 → p0024）。
  同一天换到上游 `2.2.2026112301` 时补丁只是换了编号和出处（上游的 0023 + 我们的 0024，内容就是原来的 0024 + 0023），版本串没动，表也不用加。
- 快照格式可能变了（换 Ghostty 提交、动了 `src/terminal`、快照修订号加一）：不记表，表清空。新旧版本之间远控镜像改发回放流
  （`RemoteTerminalReplay`：设备按本机引擎重画；两端都要是认得 `terminal-replay` 的版本，否则接不上终端、提示两端更新到同一版本）；Mac 本机终端重启后二进制快照解不开，改用检查点里退出时另存的回放流（`TerminalCheckpointBlob`
  第 3 版，VT 字节、最近 2000 行回滚）重画那一屏；iOS 经主机上的保持进程接回同理（那边每张检查点都带回放流）。
  只有回放流本身也没有的（这个机制上线之前存的、Mac 上退出前就崩溃了的）才只剩 holder 里那段字节。

## 引擎补丁（`Patches/ghostty/`）

上游 `Patches/ghostty/` 里的 `0001`–`0023` 原样用。我们加的一个接在后面，放进上游检出的同一个目录后 `build.sh` 会自动打上。
这个文件和编出现在这份二进制时用的逐字节相同，不要改（改了就对不上 `ENGINE.lock` 记的那份产物）。

写我们自己的补丁要注意：上游的 `.sh` 补丁靠「自己加的那段文字原样还在」判断打没打过（`Script/support/anchored_edit.py`），
`build.sh` 每个平台都把整个补丁栈再跑一遍。我们的补丁只要改到上游某个补丁加的文字里面，它下一遍就认不出自己、把那段再插一次
（滚动信号那个补丁的第一版改了 0022 加的 `smoothScrollBy`，第二个平台起整份 `Surface.zig` 的平滑滚动函数全部重复，编不过）。
所以只在上游原文旁边加，不动别的补丁加的内容；出包前在打完的树上把 `Script/apply-patches.sh` 再跑两遍，树不变才算数。

### 上游的 0022 逐像素平滑滚动（原来是我们的 0023）

`0022-pixel-smooth-scrolling.sh`，[#110](https://github.com/Lakr233/libghostty-spm/pull/110) 合进上游的版本。和我们原来那份的区别：
要 surface 自己打开（`ghostty_surface_set_smooth_scroll`，`TerminalSurfaceCoordinator` 给它建的每个 surface 都打开）；
视口位置由引擎报（`ghostty_surface_smooth_scroll` 读首行、最远行、小数、格子高，`ghostty_surface_smooth_scroll_by` 按像素挪），
Swift 侧不再记镜像；小数记着它属于哪个视口（屏、滚动条行号、`PageList` 的视口移动计数、格子高、网格），换了就作废，
不会把半行偏移留在错的行上。原来的 `ghostty_surface_set_overscroll` 没了（Swift 层本来就没调）。

为什么：整行滚动在手机上是一顿一顿的，user 在真机上验收的滚动手感以它为前提。读数见 `docs/ghostty-eval/measure-ios.md` 的 M16。

回归用例：`uTermTests/Features/Terminal/GhosttyMacScrollTests.swift`、`GhosttyMagicMouseScrollTests.swift`、
`uTermMobileTests/Probes/GhosttySmoothScrollPixelTests.swift`、`GhosttyScrollEdgeTests.swift`、`GhosttySystemScrollJitterTests.swift`。

### 上游的 0023 滚动那一帧交到图层的信号（原来是我们的 0024）

`0023-smooth-scroll-presented.sh`，[#123](https://github.com/Lakr233/libghostty-spm/pull/123) 合进上游的版本：同一组改动改写成上游的锚点脚本
（只贴在上游原文和 0022 加的行旁边，连跑几遍源码树不变），C 接口同名：`ghostty_surface_smooth_scroll_by_tracked`、
`ghostty_surface_smooth_scroll_presented`。动的文件：`src/Surface.zig`（`smoothScrollByTracked`、`smoothScrollPresented`）、
`src/renderer/State.zig`（`scroll_seq`）、`src/renderer/generic.zig`（`frame_scroll_seq`、`scroll_presented`、`scrollFramePresented`）、
`src/renderer/metal/Frame.zig`（完成回调带序号）、`src/apprt/embedded.zig` 与 `include/ghostty.h`。只动渲染，快照格式不变。

做什么：`smoothScrollByTracked` 同 0022 的 `smoothScrollBy`，另外给这一步编号（和位置在同一个临界区里写）；渲染线程 `updateFrame`
在读位置的同一个临界区里读到序号，画出来的那一帧把序号带进 Metal 的完成回调，回调交完帧（iOS 上是把设 contents 的块排进主队列）
之后把序号记成「已交」（原子取大）。`smoothScrollPresented` = 已交的序号追上了最新一步的序号，无锁。

为什么：iOS 的系统滚动每个显示帧在主线程的 `scrollViewDidScroll` 里把位置交给引擎，渲染线程异步画、画完把交帧排回主队列——
这时 UIKit 这一拍的提交已经走了，画面只能下一拍上屏。Duo 上按换屏表量：UIKit 写位置到上玻璃 34.0 ms，原生 UIKit 内容约 25.5 ms，
正好多一帧；手指来回拖时拐弯处画面慢一拍（user 2026-11-23：「好一点了，但感觉还有进步空间」，不足在手指拖着的时候）。
主线程在 `scrollViewDidScroll` 里等到这一帧交出来再返回，交帧块排在这次回调后面、同一轮 run loop 里跑，和 UIKit 这一拍一起提交
（Swift 层第 21 条）。这个时刻只有引擎知道：Swift 层拿不到「带着这一步的那一帧画完了」。盲等固定的 4 ms 也能把延迟降到 25.7 ms，
但 1200 pt/s 以上每帧跨行、渲染更久，47% 的帧停一拍再走两倍，系统记的掉帧从 7 次涨到 57 次。

读数（Duo，App 内合成手指按脚本滚，xctrace 的提交表 + 换屏表 + 出帧探针对上屏内容）：上屏落后 UIKit 34.0 → 25.7 ms（p95 25.9）；
减速 ≥150 pt/s 屏上速度偏离 30% 以上的帧 ≤ 1%；每帧主线程等 2.4 ms（p99 4.6）；3008 帧里 5 帧没等到，全是手指刚落下的第一帧。

（评估时编过另一个也叫 0024 的补丁——交换链不画进还在屏上或等着上屏的 IOSurface。它在 iPhone 真机上是负收益：换帧率默认 81 → 71%、
不同步重画 97 → 90%，晚一拍以上的帧从 4 涨到 10–19（`docs/ghostty-eval/measure-ios.md` 的 M16），没有带进来，编号后来给过上面这个（现在是最低对比度的）。
补丁文件留在评估分支 `worktree-agent-a6bb31349ee21df46` 的 `Spikes/GhosttyPatches/`。）

### 0024 保色相的最低对比度（2026-11-23 之前是 0023）

`0024-uterm-minimum-contrast.patch`。2026-11-23 上游占了 0023，文件改名成 0024，内容逐字节没变（文件头里还写着 0023 和原来的切点）；
叠在上游的 0023 之后 `git apply` 只是行号偏移 29 行。

文件：`src/renderer/shaders/shaders.metal`（`contrasted_color`、`cell_text_vertex`）、`src/renderer/generic.zig`。
切在 libghostty-spm `2.2.2026111501` 打完 `0001`–`0022` 的树上（Ghostty `cf5519b2`）；在那之前它是 0022，切在 `042b16b6` 上，
换基线时代码一行没改，只改了编号和注释里那句已经删掉的 SwiftTerm 出处。2026-11-17 换到 `2.2.2026111701`（Ghostty `5ebe501a`）时
文件原样打得上（两版之间 Ghostty 没动 `src/renderer/`），文件头里写的切点仍是 `2.2.2026111501`。

官方的 `minimum-contrast` 达不到目标比就把前景色换成纯黑或纯白，彩色的 prompt 段被洗成黑白；盒线、块字符、Powerline 字形还被豁免。
补丁改成：在 OKLCH 里只调明度、朝背景的反方向走到 WCAG 目标比，色相不动，饱和度只按原值和 sRGB 色域收；装饰字形不再豁免；
`minimum-contrast > 1` 时整格块字符（U+2588）不再把自己的前景色当底色。配置里用 `minimum-contrast = 3`。

为什么：远端按深色背景写死的 256 色 / 真彩色在浅色配色下读不出来（p10k、oh-my-posh 的 prompt 最明显），这是换引擎之前就有的要求。
读数：188 个样本最大逐通道差 2/255；整屏 3 万个字形都要调时每帧多 0.09–0.25 ms（`docs/ghostty-eval/measure-build-consistency.md` 的 M13）。

回归用例：`uTermTests/Features/Terminal/TerminalContrastTests.swift`（读真的 surface 画出来的像素）、
`uTermMobileTests/Probes/GhosttyColorParityTests.swift`（测量门控，`UTERM_MEASURE=1` 才跑）。

## GhosttyVt（libghostty-vt）

- 和 GhosttyKit 同一棵打过 `0001`–`0024` 的源码树编出来（上游的 0022 给 `src/terminal/PageList.zig` 加了视口移动计数，
  所以 vt 也必须带上它；0023 只改 shader 和渲染器，0024 只改 surface 和渲染器）。
- 三个 slice：`ios-arm64`、`ios-arm64-simulator`（只有 arm64，Intel Mac 上的模拟器链不了）、`macos-arm64_x86_64`。
- 每个 slice 预链接成一个 `.o`（`Scripts/prelink-vt.sh`），只导出 209 个 `ghostty_*`，Zig 打包进来的 ubsan、memset、simdutf、
  highway、compiler_rt 都变成私有符号，否则和 GhosttyKit 一起链会重复。
- 和 GhosttyKit 仍有 6 个同名导出符号：`ghostty_hwy_detect_targets`、`ghostty_simd_base64_decode`、`ghostty_simd_base64_max_length`、
  `ghostty_simd_codepoint_width`、`ghostty_simd_decode_utf8_until_control_seq`、`ghostty_simd_index_of`。常规链接不撞（两端的 App 都链过，
  各只留一份定义，两份实现来自同一棵树）；**加 `-all_load` 或 `-force_load` 就报 duplicate symbol**。工程里现在没有这两个参数。
- 模块名 `GhosttyVt`，要链 libc++（`GhosttyKit` target 已经带了 `.linkedLibrary("c++")`，两者总是一起用）。
- 这是 Ghostty `5ebe501a` 时的 vt C API（和 `cf5519b2` 相比只有 `version.h` 变了），和官方 vt-1.0.0 的文档对不上：`ghostty_terminal_new` 只有 cols / rows，
  formatter 的选项一次传一个结构体，没有读当前画笔的接口。对着 `BinaryTarget/ghostty-vt.xcframework/*/Headers/ghostty/vt/` 写。
- 测试 target 不依赖这个 product（给测试 target 加包依赖会让 Xcode 换成动态的 PackageFrameworks），经 `@testable import` 用 App 里的类型。

## Swift 层补丁（`Sources/GhosttyTerminal`）

C 接口不动。源码里每一处都标着「uTerm 本地补丁」，升级时搜这个词。和上游逐文件比对的结果是下面这些，没有别的。

### 1. 网格与第一次 resize（两端）

文件：`InMemory/InMemoryTerminalSession.swift`。

回放入口本身（`receiveReplay(_:)`、`discardPendingOutput()`、测试用的 `init(… surfaceReplay:)`）已经是上游的
（[#108](https://github.com/Lakr233/libghostty-spm/pull/108)），这里只剩宿主判断「什么时候能往新 surface 里灌回放」要的三样：

- `surfaceGrid`：surface 此刻的网格（主线程刚设下的尺寸），没挂 surface 时 nil。
- `reportedGrid`：surface 的终端最近一次报来的网格（IO 线程改网格之前在 resize 回调里报的那个）。远控主控端判断
  「回放会按哪个网格解析」用它：主线程设了新尺寸、IO 线程还没改过去时，`surfaceGrid` 已经是新的，这个还是旧的。
- `forcesNextResize`：新挂上的 surface 报来的第一次 resize 不去重。新 surface 的终端先是默认网格，宿主要等它报出和视图一致的网格
  才往里灌回放；网格没变时这次回调原本会被吞掉。

回归用例：`uTermMobileTests/GhosttyBackgroundTests.swift`、`uTermMobileTests/TerminalHiddenRenderingTests.swift`、
`uTermTests/Features/Terminal/TerminalOutputPumpTests.swift`、`uTermTests/Features/Terminal/TerminalMirrorSnapshotTests.swift`。

### 2. surface 生灭与网格的回调、wakeup 不同步重画（两端）

文件：`Surface/TerminalSurfaceCoordinator.swift`、`Controller/TerminalController.swift`。

- `onSurfaceAttached` / `onSurfaceDetached` / `onGridMetrics`：和 `TerminalSurfaceLifecycleDelegate` / `TerminalSurfaceGridResizeDelegate`
  同一时刻发，但不经 delegate。宿主靠它们决定什么时候往 surface 里灌字节，不能因为 delegate 被换成只关心滚动条的对象就收不到。
- 引擎 wakeup 触发的 tick 要不要在主线程同步整帧重画，由 `TerminalSurfaceCoordinator.wakeupDrawsSynchronously` 按平台定死：iOS true（user 在真机上
  说不同步时滚动发糊），Mac false（渲染线程自己会画，主线程每跨一行白画一帧 1.4–2.2 ms，还挡着渲染线程）。尺寸、度量、可见性、选区、
  首帧这些宿主侧的变化两端都照旧同步重画。实现是 `pendingSyncDraw` 和 `requestImmediateTick(syncDraw:)`。
  例外是第 20 条：iOS 上系统滚动动着时，wakeup 先不同步重画（`wakeupDefersSyncDraw`），慢下来以后也不开 display link（`wakeupDefersDisplayLink`）。
- 几处 trace 打点（`tick-app` / `tick-refresh` / `tick-draw` / `wakeup-tick`），trace 关着时零开销。

回归用例：`uTermMobileTests/TerminalHiddenRenderingTests.swift`（surface 放掉 / 重建）、`uTermMobileTests/Probes/GhosttyFrameBudgetTests.swift`、
`uTermTests/Features/Terminal/GhosttyMacScrollTests.swift`。

### 3. （已删）滚动条回报的时刻与钩子

`scrollbarStamp`、`TerminalWakeupGate.isPending` 只给原来 Swift 侧的视口镜像用，上游的平滑滚动直接读引擎，镜像没了，它们也删了。
`onScrollbarChange` 上游有了。

### 4. （已进上游）iOS：单指滚动交给系统的 UIScrollView

[#110](https://github.com/Lakr233/libghostty-spm/pull/110) 合进去的就是这条（`TerminalScrollDriverView`、
`UITerminalView+SystemScroll*.swift`、`TerminalScrollOffsetMapping`）。和原来我们那份的区别：delegate 是单独的私有对象
（`TerminalScrollDriverDelegate`），`UITerminalView` 不再遵守 `UIScrollViewDelegate`——测试要伪造拖动 / 减速时经
`uTermSystemScrollDelegate` 调（第 8 条）；位置读引擎，不记镜像；越界露出的那条用终端背景色填上。

回归用例：`uTermMobileTests/Probes/GhosttyScrollEdgeTests.swift`、`GhosttySystemScrollJitterTests.swift`、`GhosttyScrollFeelTests.swift`、
`GhosttyOnScreenScrollTests.swift`。真机验收只在 iPhone Duo 上做。

### 5. iOS：自写惯性的减速率、程序抓着鼠标时的惯性

文件：`Platform/UIKit/UITerminalView+Scroll.swift`。

不归系统滚动的那几种拖动（程序抓鼠标、备用屏 / 没有回滚、双指整行滚动）还走自写的惯性，它们停下后由上游的 settler 对齐整行。
display link 跟屏幕刷新率走已经是上游的（#109）。留下的是：

- 减速改成 UIScrollView `.normal` 的每毫秒 0.998（上游每 1/60 s 0.92，只滑出去 40%）。
- 程序抓着鼠标（Claude 的全屏界面、tmux / vim 开 mouse）时松手也起惯性：上游把这种情况拦在外面，手指一离屏就停。只留主方向；
  慢到两行相隔 0.15 s 以上就停；途中程序放开或抓起鼠标就停。距离是 `.normal` 的 0.25（`UTermScrollTrace.programMomentumTravel`，
  user 在 Duo 上比过三档定的）。

原来的视口镜像（`modelRow` / `modelFrac`、`syncScrollModel`、`systemScrollAlign` 的那份实现）随上游的平滑滚动删掉了。

回归用例：`uTermMobileTests/Probes/GhosttyCapturedMomentumTests.swift`、`GhosttySmoothScrollPixelTests.swift`
（`testFlingMomentumRunsAtDisplayRate` 等）、`GhosttyScrollEdgeTests.swift`。

### 6. iOS：宿主要的入口

文件：`Platform/UIKit/UITerminalView+UTermHost.swift`（新）、`UITerminalView.swift`、`UITerminalView+TouchMenuActions.swift`。

- `uTermReleaseSurface()` / `uTermRestoreSurface()` / `uTermIsSurfaceReleased`：放掉 surface（交换链、网格、回滚都还），视图留在原处，
  放掉期间布局、回窗口都不重建（`core.isAttached` 多看一个 `uTermSurfaceReleased`）。隐藏的标签 `setSurfaceVisible(false)` 不还帧缓冲
  （每个约 14.5 MB），uTerm 隐藏 60 秒后放掉、露出来重建并从影子终端回放。
- `uTermSetFontSize(_:)`：按点数设这个 surface 的字号并当场重算网格。uTerm 的字号跟着窗格宽度走。
- `uTermOnSurfaceAttached` / `uTermOnSurfaceDetached` / `uTermSetGridExpectedHandler(_:)`：第 2 条那三个回调在视图上的入口。
- 长按菜单的「粘贴」改走可覆写的 `paste(_:)`（默认行为不变）：uTerm 把只有图片的剪贴板当贴图传到远端。
- `uTermSendsCommandChords`：没有绑定接的 ⌘ 组合发不发，见第 12 条。

回归用例：`uTermMobileTests/TerminalHiddenRenderingTests.swift`、`uTermMobileTests/GhosttyTrialWiringTests.swift`、
`uTermMobileTests/GhosttySpikeInputTests.swift`。

### 7. （已进上游）Mac：触控板平滑滚动的配套

[#109](https://github.com/Lakr233/libghostty-spm/pull/109)（精确位移乘屏幕倍率）和 [#110](https://github.com/Lakr233/libghostty-spm/pull/110)
（`TerminalSmoothScrollSettler`：抬手 0.08 s 等惯性、0.18 s 三次缓出吸附整行、惯性被下一次触碰掐断时顺着滚动方向补、绝不往回）
合进去的就是这条，`AppTerminalView+SmoothScroll.swift` 现在是上游的（吸附的曲线和「抬手时还在不在走」的判法后来由第 19 条改过）。另外上游在点击（`mouseDown` / `rightMouseDown` /
`otherMouseDown`）前先当场对齐。uTerm 的 `GhosttySurfaceView.rightMouseDown` 在弹菜单时不调 super，所以弹菜单前不对齐
（菜单里的动作不按格子命中，不影响）。

回归用例：`uTermTests/Features/Terminal/GhosttyMacScrollTests.swift`（造带 phase 的滚动事件，读 IOSurface 核行界）、
`GhosttyMagicMouseScrollTests.swift`（回放 `uTermTests/Support/MagicMouseScrollRecording.swift` 里的真实 Magic Mouse 事件）。

### 8. 测试与排查用的打点

文件：`Platform/UIKit/UTermScrollTrace.swift`（新；名字带 UIKit，Mac 也编）、`Platform/AppKit/AppTerminalView+UTermHost.swift`，
`UITerminalView+Scroll.swift` / `+Interaction.swift` / `+SystemScrollDelegate.swift` / `+SystemScrollSync.swift` 里各有几行打点。

- 滚动轨迹缓冲（`isEnabled` 默认关）：交给引擎的每步像素（`drag` / `momentum`）、越界平移（`overscroll`）、视口行号（`row`），
  以及 tick 的耗时（`tick-app` / `tick-refresh` / `tick-draw` / `wakeup-tick`）。`drag` / `momentum` 两处记：自写的拖动 / 惯性
  （`+Scroll.swift`），和上游系统滚动的 `systemScrollDidScroll`（`+SystemScrollDelegate.swift`，减速 / 回弹 / 对齐中记 `momentum`、
  手指拖着记 `drag`）。后一处换基线时漏过一次：真机上 `GhosttyOnScreenScrollTests` 的 mismatch 等于帧数、`GhosttyScrollFeelTests`
  读到 0 步、`GhosttyFrameBudgetTests` 每拍 0 行却照样通过（只在真机跑，模拟器跳过，所以模拟器全量看不出来）。
- signpost（`emitsSignposts` 默认关，subsystem `com.uozi.uTerm.glass`）：`touch`（按下 / 抬起）和 `scroll-offset`（系统滚动每次 didScroll
  的位置，字段顺序和以前一样，`docs/ghostty-eval/glass/` 的打分脚本照读）。原来系统滚动的 `sv-*`、`engine-bar` 随旧实现删了。
- 可调的 `programMomentumTravel`（第 5 条）。生产路径上只读它。
- 测试读状态的入口：两端的 `uTermScrollState`（视口首行、小数、在不在吸附 / 滑行 / 回弹；读引擎的
  `ghostty_surface_smooth_scroll`，不再是镜像）、`uTermScrollbarOffset`（Mac）、`uTermCellPixels`；iOS 另有
  `uTermTouchDownDuringMomentum()`、`uTermSystemScrollView`、`uTermSystemScrollDelegate`、`uTermSystemPanWouldBegin`。

### 9. Mac：按键

文件：`Platform/AppKit/TerminalKeyEventHandler@AppKit.swift`、`AppTerminalView+PublicInput.swift`、`AppTerminalView+Input.swift`。

- 方向键不带 Num Lock：macOS 给四个方向键的事件都带 `.numericPad`，上游把它翻成 Num Lock，程序开了 kitty 键盘协议时
  一个不带修饰键的 ← 被编成 `CSI 1;129D`。`buildKeyInput` 对方向键去掉 Num Lock（官方 Ghostty 的视图也不报）。
- `uTermSendsCommandChords`：没有绑定接的 ⌘ 组合发不发，见第 12 条（原来这里是公开的 `isKeyBinding(_:)`，宿主在 `keyDown` 里自己丢；
  已删，`keyIsBinding` 回到 private）。

回归用例：`uTermTests/Features/Terminal/TerminalKeyBindingTests.swift`（真 `NSEvent`，逐个组合核去向与字节）。

### 10. Mac：宿主要的入口（放掉 / 重建 surface、生灭与网格的回调）

文件：`Platform/AppKit/AppTerminalView+UTermHost.swift`（新）、`AppTerminalView.swift`（多一个存储属性 `uTermSurfaceReleased`，
`core.isAttached` 多看它一眼）。

和第 6 条 iOS 的同名同义：`uTermReleaseSurface()` / `uTermRestoreSurface()` / `uTermIsSurfaceReleased`、
`uTermOnSurfaceAttached` / `uTermOnSurfaceDetached` / `uTermSetGridExpectedHandler(_:)`。上游的 AppKit 视图离开窗口时不拆 surface
（为了 SwiftUI 来回挂载不丢回滚），切走的标签一直占着交换链、继续解析字节；uTerm 隐藏 60 秒后放掉、露出来重建并从影子终端回放。

另有只读的 `uTermCanRenderFrame`（引擎此刻会不会出帧；为此 `TerminalSurfaceCoordinator.canRenderFrame` 由 `private` 改为
`internal`），给测试判「surface 建着但不画」。注意可见声明（`setSurfaceVisible`）记在 coordinator 上、不随 `freeSurface` 清掉，
重建前宿主要先把它声明回来，否则新 surface 出生即被遮挡、整个跳过绘制（白屏）。

回归用例：`uTermTests/Features/Terminal/GhosttyHiddenSurfaceTests.swift`、`GhosttyTabSwitchTests.swift`。

### 11. 补尾巴、解析完的标记、清选区、读滚动条（两端）

文件：`InMemory/InMemoryTerminalPendingOperations.swift`、`InMemoryTerminalSurfaceAccess.swift`、`InMemoryTerminalSession.swift`、
`Surface/TerminalSurface.swift`、`Platform/AppKit/AppTerminalView+UTermHost.swift`、`Platform/UIKit/UITerminalView+UTermHost.swift`。

- `InMemoryTerminalSession.takePendingWrites()`：和 `discardPendingOutput()` 一样丢掉还没交给 surface 的输出，但把其中的实时字节按先后
  拼好交回来（夹着回放、或队列里留着进程退出时 `complete = false`）。宿主停喂 surface 时拿着它们，恢复时连同停喂期间的输出一起用
  `receiveReplay` 补进去，surface 只是晚一点解析同一串字节——不用整屏回放，往上翻着的视口和选区都留着。
- `InMemoryTerminalSession.afterPendingOutput(_:)`：队列里多一种操作 `.marker`，轮到它时（之前排的输出都交给 surface 解析完了）在输出
  队列上调宿主的闭包。宿主拿它知道「回放 / 擦屏已经被 surface 解析到了」。`discardPendingOutput`、`takePendingWrites` 都不丢标记。
- `TerminalSurface.clearSelectionWithoutInput(composing:)`：清 Ghostty 自己的选区。**C 接口没有清选区的函数，binding action 里也没有**
  （`clear_screen` 会连屏一起清、鼠标单击会报给抓鼠标的程序）。能清它、又不往程序发东西、不碰鼠标状态的入口只有 preedit：
  `Surface.preeditCallback` 收到非空预编辑时按 `selection-clear-on-typing`（默认开）清选区，而零宽字符 U+200B 算不出格子，不会留下预编辑。
  副作用是同时清掉正在显示的预编辑，所以输入法组字时不动。`selectionIsBlank()`：选区里只剩空白。
- 两个视图：`uTermScrollbar`（引擎最近报来的滚动条）、`uTermClearSelection(onlyIfBlank:)`（iOS 上连触摸选区一起：整屏的直接收起，
  擦掉一段的按触摸选区自己的规则当场复核一次）。

为什么：Ghostty 引擎清屏（ED 2）、擦回滚（ED 3）时不清选区，高亮留在擦空的格子上、拷贝拿到空白（从备用屏切回主屏、RIS 它自己会清）；
标签切回来时整屏回放的开头是复位，视口回到底部、选区没了。宿主（`TerminalOutputPump`、`TerminalSurfaceKeeper`）用上面这几样补。
**引擎下次重编时**可以加一个正经的 `ghostty_surface_clear_selection`（或者直接在 `Terminal.eraseDisplay` 的 `.complete` / `.scrollback`
分支里 `clearSelection()`），再加一个 `ghostty_surface_set_selection`——有了它，整屏回放之后连选区也能按内容恢复（现在恢复不了，
只能保证不留错位的高亮）。

回归用例：`uTermTests/Features/Terminal/GhosttySelectionEraseTests.swift`、`GhosttyHiddenSurfaceTests.swift`（视口那几条）、
`TerminalOutputPumpTests.swift`（`TerminalOutputPumpTailTests`）、`uTermMobileTests/GhosttySelectionViewportTests.swift`。

### 12. 没有绑定接的 ⌘ 组合（两端）

文件：`Surface/TerminalSurface.swift`（`sendsCommandChords`、`sendKeyEvent` 里的过滤）、`Surface/TerminalSurfaceCoordinator.swift`
（转给每个新 surface）、`Platform/AppKit/AppTerminalView+UTermHost.swift` 与 `Platform/UIKit/UITerminalView+UTermHost.swift`
（`uTermSendsCommandChords`）。

legacy 键盘模式下 Ghostty 会把没有绑定的 ⌘ 组合编成带 super 的序列（⌘↑ → `CSI 1;9A`、⌘↩ → `CSI 27;9;13~`），shell 不认，只会在
命令行里留下「;9A」这类残渣；换引擎之前、Terminal.app 都是丢掉。宿主给一个闭包（读影子终端：程序开了 kitty 键盘协议才收），
`sendKeyEvent` 在交给引擎前看：带 super、不是修饰键本身、闭包说不收、`ghostty_surface_key_is_binding` 也不认（拿的就是要发的那个
按键事件）的，丢掉并记下键码，它的重复、抬起也丢。所有按键路径（Mac 的键盘 / 输入法收字、iOS 的硬件键盘、两端宿主的 `sendKey`）
都经这里，两端各自在视图里判断、各自拼按键事件的写法（iOS 的数字小键盘判定已经和按下那一刻分叉过）就不要了。闭包为 nil 时照发（上游行为）。

Mac 的 ⌃↩ 不在这条里：它在 key equivalent 那一层就要截（宿主的 `onControlReturn`）。

回归用例：`uTermTests/Features/Terminal/TerminalKeyBindingTests.swift`（真 `NSEvent`）、
`uTermMobileTests/GhosttyHardwareKeyBindingTests.swift`。

### 13. iOS：输入法候选框的宽度

文件：`Platform/UIKit/UITerminalView+UITextInput.swift`（`imeRect()`）。

`ghostty_surface_ime_point` 的 y 是格子底边，这一半上游已经改了（#109，候选框上移一行）。宽度是像素（Ghostty 的 macOS 前端、本包
Mac 那份 `firstRect` 都按像素用），上游原样当点用，组字时的插入点按三倍宽往右走；这里除屏幕倍率。

回归用例：`uTermMobileTests/MobileTerminalKeyboardTests.swift`（`testDefaultsToEnglishAndComposesBeforeSending`）。

### 14. iOS：surface 一直聚焦（收起键盘后光标仍是实心块）

文件：`Surface/TerminalSurfaceCoordinator.swift`（`keepsSurfaceFocused`、`setFocus`、`tearDownSurface`）、
`Platform/UIKit/UITerminalView+UTermHost.swift`（`uTermKeepsSurfaceFocused`）。

Ghostty 的 surface 焦点（`ghostty_surface_set_focus`）同时管两件事：失焦时光标一律画成空心框、不闪（`renderer/cursor.zig`），
以及给开了 DEC 1004 的程序报 `CSI I` / `CSI O`。上游 `UITerminalView` 在放弃第一响应者时把 surface 置为失焦，于是 iOS 上
收起键盘后光标变空心——用户还在看这个终端，Claude Code 的输入指针就是终端真光标。换引擎之前（旧引擎的
`caretViewTracksFocus = false`）收键盘后光标是实心的。开关打开后：`setFocus` 交给 surface 的永远是 `true`（新 surface 出生就是
聚焦的），视图焦点变化仍照常通知 delegate；拆 surface 时不再先报失焦（上游会在这里给 1004 的程序补一个 `CSI O`）。
引擎因此只剩一处会报焦点：程序开 1004 的那一刻报一次「聚焦」（`CSI I`）。默认关，Mac 不开（Mac 失焦画空心是对的）。

宿主（`uTermMobile/.../GhosttyTerminalBridge.swift`）打开它，并照旧引擎的规则自己报 1004：成为 / 放弃第一响应者报 `CSI I` /
`CSI O`（模式读影子终端），引擎在程序开 1004 时报的那个 `CSI I` 换成宿主记着的状态。

回归用例：`uTermMobileTests/MobileTerminalCaretTests.swift`（读真 surface 画出来的像素；1004 的序列）。

### 15. 单个 surface 的行高调整、resize 回调带格子像素（两端）

文件：`Surface/TerminalSurfaceCoordinator+CellHeight.swift`（新）、`Surface/TerminalSurfaceCoordinator.swift`（`cellHeightAdjustment`、
`isApplyingSurfaceConfig`，`onConfigChange` 与拆 surface 时清零）、`Controller/TerminalController+Config.swift`（`uTermSurfaceConfig(appending:)`）、
`InMemory/InMemoryTerminalSession.swift`（`currentCellPixels`、`cellSource`，`suppressesPixelOnlyResizes` 的判定）、
`Platform/AppKit/AppTerminalView+UTermHost.swift` 与 `Platform/UIKit/UITerminalView+UTermHost.swift`
（`uTermCellHeightAdjustment`、`uTermSetCellHeightAdjustment(_:)`、`uTermScaleFactor`）。

- `uTermSetCellHeightAdjustment(_ pixels:)`：只给这一个 surface 推一份配置（app 此刻的配置 + `adjust-cell-height = N`，
  `ghostty_surface_update_config`），别的 surface 不受影响。引擎换一套字形网格、按新格子高重算尺寸。app 的配置之后整份推下来
  （切日夜、改设置）时这项归 0：`ghostty_surface_update_config` 里同步发的 CONFIG_CHANGE 是自己推的（`isApplyingSurfaceConfig`），
  其余的都是 app 推的。surface 重建时也归 0。
- resize 回调里的 `InMemoryTerminalViewport` 带上格子像素（上游恒为 0：引擎的回调只给行列数和终端区像素，没留白时推不出格子）：
  在 IO 线程上读 surface 此刻的尺寸（`ghostty_surface_size`，同 `readViewportText` 在任意线程读）。读用的 surface 指针单独一把锁、
  只做赋值，**不能**用 `InMemoryTerminalSurfaceAccess` 那把（IO 线程报 resize 时拿着引擎的终端锁，主线程可能拿着那把锁等一次
  正等着终端锁的写入）；拆 surface 之前先清掉它。读到的不会比这次回调旧：主线程每次改尺寸 / 格子都会再排一条 resize。
- `suppressesPixelOnlyResizes`：格子像素变了也报（只调行高时行列数不变）；拖分隔条那种只有视图像素变的照旧不报。

为什么：uTerm 的「按行填满」（窗格高度除不尽一行时把余量摊进行距，规则在 `uTerm/Features/Terminal/TerminalRowFill.swift`）
要按窗格逐个调格子高，app 级的配置做不到；影子终端要在 IO 线程的回调里同时跟上行列数和格子像素（尺寸查询、图片协议）。
代价与副作用：推一次要重新解析整份配置、建（或复用）一套字形网格，宿主只在尺寸停稳后推；配置里的其余项原样重放一遍
（和 app 改配置时一样：默认光标样式、默认配色、mode 2031 开着时的配色报告）。

回归用例：`uTermTests/Features/Terminal/TerminalRowFillSurfaceTests.swift`、`uTermMobileTests/TerminalRowFillMobileTests.swift`。

### 16. Mac：把所在显示器报给引擎（display link 没建成时靠它补建）

文件：`Platform/AppKit/AppTerminalView+DisplayID.swift`（新）、`AppTerminalView.swift`（多一个存储属性 `displayReport`）、
`AppTerminalView+Lifecycle.swift`（进窗口、布局、换屏、屏幕参数变化、窗口重新可见、窗口成为 key 时调）、
`AppTerminalView+UTermHost.swift`（重建 surface 后调）、`Surface/TerminalSurface.swift`（`setDisplayID`）。

渲染器在 surface 出生时建 CVDisplayLink；当时没有活动显示器（Mac 锁着、显示器睡着，终端是手机远控新开的或藏久了重建的）就建不成，
日志 `error creating display link; using fallback rendering`，之后不按屏幕刷新、渲染线程有消息就画。引擎自己不重试，唯一的重试
入口是 `ghostty_surface_set_display_id`（`setMacOSDisplayID` → `syncDisplayLink` 里补建）；官方 macOS App 在窗口换屏时调它，
这个包从没调过，所以那个 surface 一辈子没有 display link。现在：新 surface / 换了显示器时报一次（按「surface + 显示器」去重），
显示器可能刚回来的时刻（屏幕唤醒、会话重新激活、屏幕参数变化、换屏、窗口重新可见、窗口成为 key）每次都报。

回归用例：`uTermTests/Features/Terminal/GhosttyDisplayLinkTests.swift`（另有一条默认跳过的机制实验：`window-vsync = false`
造没有 display link 的 surface，同样的滚动上屏 155 帧、正常 37 帧，没抓到倒退帧）。

### 17. iOS：听写能连着说（文档留着已上屏的字，按范围改写）

文件：`Platform/Shared/TerminalCommittedTail.swift`（新，公开）、`Platform/Shared/TerminalInputDocument.swift`（`committedLength`、
`committedRange(of:)`）、`Platform/UIKit/TerminalTextInputHandler@UIKit.swift`（`sendCommittedText`、`replaceCommittedText`、
`performBackspace`、`resetCommittedText`，`text(in:)` 与 `document`）、`Platform/UIKit/UITerminalView+UITextInput.swift`
（`replace(_:withText:)` 按范围、`deleteBackward` 拆出 `sendBackspaceKey`）、`UITerminalView+Input.swift`（`sendInputKeyEvent` 里清）、
`UITerminalView+Lifecycle.swift`（失焦清）、`UITerminalView+PublicInput.swift`（粘贴清、`resetRewritableTextInput()`）、
`UITerminalView+Clipboard.swift` 与 `UITerminalView+Drop.swift`（粘贴、拖放清）、`Platform/UIKit/TerminalDictationInput.swift`
（新，公开：认出听写插进来的那一版）。

流式听写每出一版识别结果，UIKit 都要先在文档里找到上一版、再整段换成新的（iOS 27.2 的
`-[UIDictationController _updateLastHypothesis:WithNewHypothesis:]`：从选区末尾往前数上一版的长度，`text(in:)` 读出来找；
找不到就打日志 `Could not find the last hypothesis … Canceling dictation`、取消听写）。上游的文档只有一格占位加组字，字一上屏就清掉，
`replace(_:withText:)` 还忽略范围直接插入，所以听写每说一个词就停，就算不停也会打出「hellohello world」。

现在文档是「占位 + 已上屏的一段 + 组字」：
- 那一段由听写的第一版开头，之后的上屏接在后面。第一版落在光标处（空范围），UIKit 的 `UIKBInputDelegateManager` 这时调的是
  `insertText`、不是 `replace`（`replaceRange:oldText:withText:forReplaceAction:` 听写分支，范围空就 `insertText:`；Duo 真机日志核过）。
  `insertText` 本身分不出听写和打字：公开的 `UITextInputContext.isDictationInputExpected` 那一刻读到 false（真机实测），所以靠 UIKit
  插字前同步发的私有通知 `UIDictationWillInsertHypothesisNotification` 记一个一次性标记（`TerminalDictationInput`，下一次上屏认领，
  这一轮主线程结束作废）。2026-11-16 的第一版只在 `replace` 里开头，真机上听写照旧只剩第一个字，2026-11-18 补上。
  普通打字不会开头，键盘看到的前文照旧是空的，「双空格变句号」这类按前文起作用的功能不会多出来。
- `replace` 的范围落在那一段里：按字符算新旧相同的开头，先退格删掉其余部分（终端光标在末尾，范围之后的字也要退掉再打回去），
  再补打新字。留着那一段时不要占位（它已经让光标离开开头；占位没有字，范围一跨过它 `text(in:)` 就比范围短一格）。
- 不在组字时的退格跟着删掉那一段最后一个字符；别的按键（`sendInputKeyEvent` 里，自己发的改写不算）、粘贴、拖放、失焦清掉它，
  宿主绕过视图写字节时调 `resetRewritableTextInput()`。清掉时照常发 text / selection 的 will / did，听写进行中清掉会让 UIKit 结束这次听写。
- 上限 4096 个 UTF-16，超出只留尾部。

`TerminalCommittedTail` 公开是给 uTerm 远程桌面的键盘（`uTermMobile/Screens/Remote/RemoteKeyInputView.swift`）用，它的问题一模一样。
已知局限：退格按字符算，带 ZWJ 的表情在个别 shell 里可能退不干净；远端程序自己改了那一行（不经过任何按键）时那一段会过期，
只在紧接着又来一次改写时才用得上。

回归用例：`uTermMobileTests/GhosttyDictationTests.swift`（真 surface，`DictationSimulator` 照 UIKit 的做法驱动：先发通知，空范围走 `insertText`）、
`uTermMobileTests/TerminalCommittedTailTests.swift`、`uTermMobileTests/RemoteKeyDictationTests.swift`。真听写只能在真机上试。

### 18. （已进上游）iOS：系统滚动松手那一刻速度连续（慢松手不往回弹、对齐从静止起步）

[#123](https://github.com/Lakr233/libghostty-spm/pull/123) 合进去的就是这条：`TerminalScrollOffsetMapping`（`landingOffset(proposed:current:)`、
`restingRow(enginePixels:travel:)`）、`TerminalScrollAlignmentCurve`、`UITerminalView+SystemScrollAlign.swift`、`systemScrollWillEndDragging` /
`DidEndDragging` 里的松手速度。这几个文件现在和上游逐字节一致。和原来我们那份的区别：`.restsAnywhere` 时不对齐（#122 的滚动行为选项）；
松手速度按视图自己的坐标取；`SystemScrollState.lastOffset` 在宿主同步位置（`isSyncing`）时也更新，同步写的偏移不算手指的位移。

UIKit 把慢于约 250 pt/s 的松手当成停住（速度 0、落点 = 现在的位置）；原来把落点改到最近的一行，一半的时候在手指身后，内容往回弹最多 5 pt。
现在落点留在原处，对齐顺着手指的方向、按手指的速度走到前方的一行；被手指按停的滚动同理。读数在 PR 说明和维护者的内部测量记录里。

回归用例：`uTermMobileTests/Probes/GhosttySystemScrollVelocityTests.swift`（真触摸：`testReleaseKeepsDirectionAndSpeed`、
`testAlignmentStartsFromRest`、`testCatchAlignsAheadNotBack`，以及核 UIKit 前提的 `testUIKitReleasePremises`）、`uTermMobileTests/GhosttyScrollAlignmentMathTests.swift`
（落点、停靠行、曲线的纯算术），以及第 4 条那几条系统滚动探针。真机手感只在 iPhone Duo 上验。

### 19. （已进上游）Mac：吸附接着滚动的速度走（惯性收尾不加速、抬手不停顿、停住才取近的一行）

[#123](https://github.com/Lakr233/libghostty-spm/pull/123) 合进去的就是这条：`TerminalSmoothScrollSettler`（吸附的曲线换成 `TerminalScrollAlignmentCurve`、
起步速度取最近 50 ms 的、`snapLongestDuration`）和 `AppTerminalView+SmoothScroll.swift`（「还在走」按速度判，还在走就不等那 0.08 s）。
两个文件现在和上游逐字节一致。维护者合并前加了一处修正：按住一段从静止起步的吸附再抬手，接着它原来的方向走、不掉头
（`touchDown(moving:)` / `touchFollowsTravel`）；另外 #122 给 settler 加了 `settlesAutomatically`（`.restsAnywhere` 时不吸附）。

回归用例：`GhosttyMacScrollTests` 新加的 `testSnapAfterMomentumCarriesOnAtItsSpeed`（惯性 ~55 pt/s 收尾、补 12 pt：改前吸附 150 pt/s，
改后 64）、`testSlowLiftAtHighEventRateCarriesOnAtOnce`（改前往回 3 pt、停 80 ms）、`testHoldThenLiftSettlesOnTheNearerRow`（改前往前多走一行）、
`testCatchThenLiftCarriesOnInTheDirectionOfTravel`（改前退回近的那一行），四条在改前都红；`checkLift` 的两种抬手改成在抬手那一刻把手指的状态摆清楚（停住 = 停 0.12 s，还在走 = 抬手前再拨 3 步），
因为中间读画面那几十毫秒本身就是一次停顿。`GhosttyMagicMouseScrollTests` 照过（36 拨 0 拨往回）。
测量：`TEST_RUNNER_UTERM_SCROLLBENCH_DIR=<目录> xcodebuild test-without-building … -only-testing:uTermTests/GhosttyMacScrollBenchTests`
（默认跳过；CSV 写进测试宿主的临时目录，日志里有路径）。真触控板手感未验。

### 20. iOS：系统滚动动着时，引擎的 wakeup 不在主线程同步重画、不 refresh，display link 全程续着（慢滚每跨一行掉一帧、减速尾段发抖）

**和上游的关系（2026-11-23）**：默认做法（`hold`）已经随 [#123](https://github.com/Lakr233/libghostty-spm/pull/123) 进了上游，但实现不是同一份：
上游在协调器里用 `wakeupSkipsDraw` / `owesWakeupFrame`（wakeup 的 tick 滚动途中整个跳过 refresh 和 draw，欠的那一帧停下后补），
我们这份仍是下面写的 `wakeupDefersSyncDraw` + `pendingRefresh` / `owesRefresh`，因为第 2 条把 Mac 定成了另一种规则，另外带着对照测量用的
几种做法（`moving` / `touching` / `always`，只有 Debug 的开关会切）和打点。升级时协调器这几处冲突取我们的，再把上游在同一文件里的别的改动带进来；
`systemScrollMovedRecently`、`holdDisplayLinkForScroll` 用上游的定义。

文件：`Surface/TerminalSurfaceCoordinator.swift`（`wakeupDefersSyncDraw`、`wakeupDefersDisplayLink`）、`Platform/UIKit/UITerminalView.swift`
（接到 `systemScrollIsBusy` 与滚动速度）、`UITerminalView+SystemScroll*.swift`（`SystemScrollState.speed`）、`UTermScrollTrace.swift`
（`scrollWakeupSyncDraw` / `wakeupDisplayLinkMinimumSpeed`：A/B 与测试用的开关，生产路径只读）。

user 2026-11-22 在 Duo 上说慢慢拖着滚「有点卡」。真触摸（`SyntheticFinger`，每个显示帧一个 moved，发在引擎的 display link 之前）
匀速拖、逐帧解 IOSurface 条码量出来（`uTermMobileTests/Probes/GhosttySlowDragFrameTests.swift`，读数是维护者的内部测量记录）：

- **每跨一行掉一帧，次次对得上。** 视口一跨行，渲染器往 app 邮箱推一条滚动条消息 → wakeup → 下一拍主线程 `ghostty_surface_draw`
  同步整帧重画（第 2 条，iOS 定死要）。这次重画要等渲染线程手上那一帧，Duo 内屏（2670×1878 px）上 p50 8.4 ms、最长 10.4 ms ≈ 一拍：
  主线程整拍占满，那一拍画面不动、手指事件也晚到，下一拍补两到三步，参考 display link 跳一拍。慢的时候跨一行要 100–330 ms，
  所以是一下一下有节奏的顿。40 / 80 / 150 / 300 pt/s 下每秒 1.5 / 3.7 / 4.8 / 5.5 次，「画面落后」的帧 100% 紧跟在跨行与同步重画之后。
- 和第 18、19 条无关：没有它们的基线（`33fde4f2`）一样，每秒 1.9 / 5.4 / 6.7 / 7.2 次。
- 改法：系统滚动动着（手指按着 / 拖着、减速、回弹、对齐，`systemScrollIsBusy`）时 wakeup 只 app tick + refresh，不同步重画；
  滚动的每一步本来就是渲染线程画、主线程只设 contents（第六轮查过）。停下之后的 wakeup、宿主侧的变化照旧同步重画。
  第八轮在 Duo 上按上玻璃量过，「wakeup 不同步重画」甩动的换帧率 97%（同步重画 81%）；user 后来说两种都和 SwiftTerm 无异，
  默认留着同步重画。这条只把滚动途中那几次去掉。
- 改后同一组（4 个速度 × 两个方向 × 两次）：跨行的 wakeup 同步重画 0 次，画面落后 / 跳拍 / 顿住的帧 0，主线程每拍忙时 p95
  从 2.1–8.3 ms 降到 1.7–2.1 ms。

**第二步：减速慢下来以后不开 display link。** user 用上一步的包说慢滚顺了、甩出去减速时有顿。真触摸甩（`GhosttyFlickFrameTests`）、
xctrace 录换屏表按上玻璃对（上玻璃模式：减速期间测试自己不开 display link，不把屏幕钉在 120 Hz）：
- 上一步本身没让减速变差：App 侧逐帧、玻璃上都比改之前（每跨一行同步重画）好，前 1.2 s 几乎每拍都换新位置。
- 顿在减速后段：UIKit 的减速慢到约 400 pt/s 以下自己降到 60 Hz（普通 UIScrollView 一样），而每跨一行的 wakeup 开 display link、按
  120 Hz 要帧，屏幕被拽回 120 Hz 两拍（`16.7 16.7 8.3 8.3 16.7`），那两拍里 UIKit 只写一次 contentOffset，有一拍画面不动：
  一帧停 25 ms 夹在 16.7 ms 的帧中间，大约每 150 ms 一次（跨一行的间隔）。改之前（同步重画）也一样有，不是上一步带来的。
- 改法：`.deferWhileMoving` 下，系统滚动动着且慢于 `wakeupDisplayLinkMinimumSpeed`（400 pt/s）时，wakeup 就地 `refresh`、不开
  display link，开着的当场停掉（不等 30 个空帧）；app tick 在 `handleWakeup` 里本来就做了。停下之后补一次正常的 tick
  （`flushDeferredWakeupTick`，50 ms 一查）。快于它照旧开：那时 UIKit 每帧都写，留在 120 Hz 更顺（一律不开的话 2000–4000 pt/s
  的前段只有 60 Hz，和普通 UIScrollView 一样）。
- 玻璃上（工作区界面，300 / 800 / 2000 / 4000 pt/s 各两次）：减速后段停 ≥ 1.4 倍的帧 71 → 33（普通 UIScrollView 24），节奏乱
  （相邻两个换帧间隔不同）21–49% → 9–29%；前段 120 Hz 不变。

**静止时不留尾巴。** 两种推迟都只认「这会儿真在动」（`systemScrollMovedRecently`：最近 0.1 s 里有过 `scrollViewDidScroll`），
不认 `systemScrollIsBusy`：后者把越界停着、卡住没清的标志（`isUIKitMoving`、`panIsActive`）也算忙。第一版按它判，
contentOffset 越界停着时（改标题这类不改回滚长度的 wakeup 不会让 UIKit 把它拉回范围），每个 wakeup 都不同步重画、
50 ms 一次的轮询一直跑（`testStuckBusyStateDoesNotDeferWakeupsAtRest` 改前 5 个 wakeup 全推迟、0 次同步重画）。另外：
推迟的轮询最多 1 s（`deferredWakeupLimit`），到点补一次 tick（还在滚就就地 tick、不开 display link，停了走平常那条路）；画不了（surface 放掉、在后台）的时候不推迟，
照原路记下要 tick。轮询只捕获 weak self，视图没了就停；钩子挂在协调器上，surface 放掉 / 重建之后照旧。

**第三步（2026-11-23，现在的默认 `hold`）：全程续着 display link，不再按速度停。** user 用第二步的包说「松手之后的惯性又开始抖了，
慢滚的时候又有点糊了」。这次让录制版每出一帧就从画面里读出实际滚到的位置（`GhosttyScrollPresentProbe`，滚动测试终端每行开头是
行号的条码），按「每次换画面走的像素 ÷ 上一幅停留的拍数，比 UIKit 的真实速度」算屏上速度纹波（理想恒为 1）：

- 第二步（`moving`）在 150–400 pt/s 没有自己的 link，UIKit 的减速在这一段是 80 Hz（帧间隔 8 / 17 ms 交替）；画面固定比 UIKit 晚一帧，
  间隔一不均匀，屏上速度就忽快忽慢。Duo 真手：150–250 pt/s 那一段 51% 的帧偏离 30% 以上（合成手指 44%），每次减速尾段节奏变 19 次
  （`touching` 4 次）。慢拖「发糊」是同一件事：没人要 120 Hz。
- 减速时同步重画的两种（`touching` / `always`）在真手长时间滚动下 400–1200 pt/s 有 4–7.5% 的帧停一拍再走两倍，还有旧帧盖掉新帧
  （往回跳最多 80–157 px：主线程同步画的新帧先设上，渲染线程更早那一帧的交帧块后到）。
- `hold`：滚动动着时不同步重画（同第一步），每次 `scrollViewDidScroll` 把自己的 link 续上（`holdDisplayLinkForMotion`，最后一次之后
  空转 30 帧照常停）。屏幕全程 120 Hz，UIKit 的 80 Hz 段变成均匀的 120 Hz、40 Hz 段变成均匀的 60 Hz。合成手指五种做法同一脚本：
  150–400 pt/s 偏离 30% 以上的帧 44% / 20% → 3.4% / 0%；60 pt/s 以下帧间隔 100% 两拍，偏离等于整像素取整的理论下限。
- 同时去掉滚动途中的重复重画：wakeup 的 tick 原来每次 `refresh`，滚动的每一步引擎自己已经排了重画，高速减速时九成的帧同一个位置
  出两次。现在动着时不 `refresh`、欠着，停下后空转的 tick 里补一次。
- 第二步的门槛（`wakeupDisplayLinkMinimumSpeed`、`deferWakeupTick`）只在 `moving` 下还走，留着做 A/B。

A/B（同一个包里比）：`UTermScrollTrace.scrollWakeupSyncDraw` —— `hold`（默认，第一步 + 第三步）、`moving`（前两步）、`moving-link`（只有第一步）、
`touching`（只在手指拖着时不同步重画）、`always`（补丁 #20 之前）；`wakeupDisplayLinkMinimumSpeed` 调门槛。uTerm 的 Debug 构建
认启动参数 `-GhosttySyncDrawDuringScroll YES|touching|moving-link|moving|hold`（`GhosttyScrollDebugSwitch`；写了它就开录制，见第 21 条末尾）。

另一种发法（120 Hz 定时器、不对齐显示帧）下改前改后都是每秒二三十次「一帧 0 步、下一帧两步」：UIKit 的拖动跟手指 1:1，
一帧里来 0 个或 2 个触摸就是 0 / 2 步。真手指的触摸在 iOS 上是不是按显示帧对齐派发的，测试量不到；对齐时（上面那组）为 0。

回归用例：`GhosttySlowDragFrameTests.testDragAcrossRowsDoesNotSyncDraw`（拖着跨 5 行以上 `tick-draw` 必须 0 次、wakeup 不开 display link
（`wakeup-deferred`），停下后的 wakeup 仍同步重画；改前每跨一行同步重画一次）、`testStuckBusyStateDoesNotDeferWakeupsAtRest`
（越界停着时 wakeup 照常同步重画、没有轮询），测量用 `testSlowDragFrames`、`GhosttyFlickFrameTests.testSoakIdle`（静置 10 分钟、
退后台 70 s 前后各量一轮）与
`GhosttyFlickFrameTests.testFlickFrames`（`TEST_RUNNER_UTERM_MEASURE=1`，真机；后者 `UTERM_FLICK_GLASS=1` 是上玻璃模式，配 xctrace）。
真手指的手感要 user 在 Duo 上验。

### 21. iOS：系统滚动每一步等引擎把这一帧交到图层，和 UIKit 同一拍提交（画面不再比手指多晚一帧）

文件：`Surface/TerminalSurface+SmoothScroll.swift`（`smoothScrollTracked(byPixels:)`、`smoothScrollPresented()`）、
`Platform/UIKit/UITerminalView+SystemScrollDelegate.swift`（`systemScrollWaitForFrame`）、`UITerminalView+SystemScroll.swift`
（`frameWaitSuspendedUntil`、`frameWaitMisses`）、`Platform/UIKit/TerminalMainTurnClock.swift`（新）、`UTermScrollTrace.swift`
（`scrollSameFrameWaitMilliseconds` 等）。要引擎补丁（现在是上游的 0023）。

**和上游的关系（2026-11-23）**：整条随 [#123](https://github.com/Lakr233/libghostty-spm/pull/123) 进了上游，`TerminalSurface+SmoothScroll.swift`、
`TerminalMainTurnClock.swift` 和上游逐字节一致。本地只剩 `systemScrollWaitForFrame` 里的两处：时限和退避读 `UTermScrollTrace` 的设置
（上游是写死的 `frameWaitBudget` 等常量，数值相同），以及等到 / 超时的打点。

- `systemScrollDidScroll` 改用带编号的 `smoothScrollTracked(byPixels:)`，随后原地等 `smoothScrollPresented()`（50 µs 一查），
  最晚等到这一轮 run loop 醒来之后 6.5 ms（`TerminalMainTurnClock`：一个 `afterWaiting` 观察者记下每轮醒来的时刻）。等到了，交帧块
  已经在主队列里，这一轮接着跑它，和 UIKit 这一拍一起提交。
- 时限从「这一轮醒来」算而不是从开始等算：手指按下那一轮 UIKit / SwiftUI 分发触摸要 12–17 ms（Duo，Debug 构建），这一轮早就过了
  时限，不等。Duo 上主线程一轮跑到 6–7 ms 不掉帧，9 ms 以上开始掉。
- 没等到：这一帧照旧晚一拍上屏。连着 3 帧没等到（渲染跟不上、程序挂着同步输出、surface 不可见）歇 0.25 s 不等。
- 读数见引擎补丁「上游的 0023」一节。

排查工具（uTerm 的 Debug 构建，`uTermMobile/Screens/Terminal/Ghostty/GhosttyScrollDebugSwitch.swift` 与 `GhosttyScrollAutoPilot.swift`）：
启动参数 `-GhosttySyncDrawDuringScroll <做法>` 打开录制，滚动打点每秒写进 `Documents/scroll-trace-<做法>.txt`（`devicectl device copy from` 取）：
每次 didScroll 的位置、每次出帧时从画面读回的位置（条码，配 `-LiveActivityDebugDemo scroll`）、主线程每轮 ≥ 2 ms 的耗时与长耗时里的调用栈
（进程内采样）、等这一帧的耗时与超时。`auto:做法,做法…` 让 App 自己用合成手指按脚本滚（装不了 XCTest 的 vphone、无人值守的真机都能跑）；
做法后面加 `+wait<毫秒>` 改等待时限（`+wait0` 关）。真正上屏的账要再配 xctrace 的 Animation Hitches（提交表 + 换屏表）。

## manifest 改动（相对上游的 `Package.swift`）

1. `libghostty` 这个 binaryTarget 从 `url:` + `checksum:` 改成 `path: "BinaryTarget/GhosttyKit.xcframework"`（同上游的 `Package.local.swift`）。
2. 多一个 binaryTarget `GhosttyVt`（`BinaryTarget/ghostty-vt.xcframework`）和同名 library product。
3. 去掉 `ShellCraftKit`、`GhosttyTheme` 两个 target 和 product、`GhosttyKitTest` 测试 target（源码没带进来）。

`DisplayLink`（`Lakr233/DisplayLink`）仍由 manifest 从远程拉，在工程的 `Package.resolved` 里。

## 引用方式

pbxproj 以 `XCLocalSwiftPackageReference "vendor/libghostty-spm"` 引用本目录。`uTerm` 与 `uTermMobile` 两个 App target 各依赖
`GhosttyTerminal`、`GhosttyKit`、`GhosttyVt` 三个 product；测试 target 不依赖。

现在是本地 path 包，所以二进制可以放在目录里。以后如果拆成独立仓库按 tag 消费，
binaryTarget 要换回 `url:` + `checksum:`（按 tag 消费的远程包不能带 path），那时 `ENGINE.lock` 里的地址就是 manifest 要填的。

## 升级步骤

换 Ghostty 提交、换上游 tag、加减引擎补丁都走这一套。**不要整目录覆盖 `Sources/`。**

1. 读上游新 tag 的变更，对照本文件看哪些补丁上游已经有了（`gh pr list -R Lakr233/libghostty-spm --author @me` 看我们提的 PR）。
2. Swift 层：把上游新 tag 的 `Sources/GhosttyKit`、`Sources/GhosttyTerminal` 和基线 tag 做三方合并（我们的改动都标着「uTerm 本地补丁」，
   7 个新文件直接留着）。做法：临时仓库里提交基线 tag、我们这份、上游新 tag 三个快照，`git merge`（`merge.conflictstyle diff3`）。
   上游收了我们 PR 的地方，冲突块一律取上游的版本（审过、改过名、常常还多了修正），再把那条补丁里上游没收的部分接回去；
   这时自动合并成功的文件也要和上游逐个比一遍，PR 的代码和我们原来那份往往放在不同位置，两份会同时留下来。
   `Package.swift` 按「manifest 改动」重做。
3. 引擎：先改 `ENGINE.lock` 的来源几行（tag、提交、Ghostty 提交、Zig 版本与 sha256）和两个 zip 的文件名，再
   `make engine-build ENGINE_BUILD_ARGS='--platforms macos,ios,maccatalyst,visionos --pack <artifacts 目录> --no-install'`
   出包（原理见 `BUILD.md`）。我们的 `0024` 打不上时在新树上重切（`--keep-source` 留下源码树），文件头里写清是切在哪个提交上的。
   上游新增的补丁和我们的编号撞了，脚本会停下，先给我们的改号。vt 由脚本在打完全部补丁的**同一棵树**上编。
4. `--pack` 打印的两个 sha256 填进 `ENGINE.lock`，zip 留在 artifacts 目录（换二进制 = 换文件名）。
5. 三处一起改：`ENGINE.lock` 的 zip 文件名与 sha256、`ENGINE.lock` 的 `engine_version`、
   `uTerm/Features/Terminal/Shadow/TerminalEngineVersion.swift` 的 `TerminalEngineVersion.current`。快照的二进制格式变了就把串尾的
   `snapshot-N` 加一。漏改常量会被两端的 `TerminalEngineLockTests` 拦住。只改渲染的补丁把旧串记进 `sameSnapshotFormat`，
   换 Ghostty 提交时把那张表清空（见上面「引擎版本串」）。
6. `make engine`，两端重编。本地 path 包的二进制不在 DerivedData 的 `SourcePackages/artifacts` 里（那里只有 Sparkle 这种远程包的预编译产物），
   **别删那个目录**：`make test-fast` 带 `-skipPackageUpdates`，删了取不回来，Xcode 还会把「找不到 XCFramework」的报错缓存在构建描述里重放
   （2026-11-23 踩过：从别的工作树拷回 `artifacts/sparkle`，再删 `Build/Intermediates.noindex/XCBuildData`）。行为对不上时删整个 DerivedData 重编。
7. vt 的 C API 还没到 1.0，换 Ghostty 提交就可能变，`ShadowTerminal.swift` 要对着新头文件改（`git diff <旧> <新> -- include/`）。
   编译器只拦得住签名变化，拦不住语义变化，两类都碰到过（`042b16b6` → `cf5519b2`）：
   - 签名：formatter 的选项从「创建时整体传结构体」改成逐项 `ghostty_formatter_set`；结构体不再带 `size` 字段；
     `GhosttyStyle` 的布尔字段并进 `flags` 位域（那几个 `GHOSTTY_STYLE_FLAG_*` 宏带类型转换，Swift 导不进来，按位号写）；
     `ghostty_info().version` 变成非 Optional。
   - 语义：`GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES` 传 NULL 从「不限」变成「恢复默认 10,000 字节」，要不限得传 `SIZE_MAX`。
     回放自查的临时终端原来传 NULL，换版后长回滚的自查全部不过（`ShadowTerminalTests.testReplayCostReadout` 拦住的）。
     凡是给 vt 传 NULL / 0 表示特殊含义的地方，都要对着新头文件的注释核一遍。
8. 回归：
   - 影子与画面一致、快照往返：`GhosttySpikeTests`、`TerminalSnapshotTests`、`TerminalMirrorSnapshotTests`、`ShadowTerminalReadingTests`、
     `uTermMobileTests/ShadowTerminalTests`；
   - 对比度、字体：`TerminalContrastTests`、`GhosttyFontRenderingTests`、`uTermMobileTests/GhosttyFontTests`；
   - 滚动：`GhosttyMacScrollTests`，iOS 的 `GhosttyScrollEdgeTests` / `GhosttySystemScrollJitterTests` / `GhosttyCapturedMomentumTests`
     在 iPhone Duo 真机上再跑一遍；
   - 然后 `make test-fast`、`make test-mobile-fast`。
9. 更新本文件顶部的基线、`ENGINE.lock` 里的来源几行、`BUILD.md` 里的读数。
10. 发版说明里写明这是一次引擎升级：旧版本和新版本之间远控接不上终端，要两端一起更新。

## 合规

- libghostty-spm 与 Ghostty 都是 MIT（本目录的 `LICENSE` 是 libghostty-spm 的），发版的第三方声明要列上两者。
- `Sources/GhosttyTerminal/Resources/` 里带着 Ghostty 的主题和 terminfo，随包一起分发。
