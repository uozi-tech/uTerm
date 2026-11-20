# 终端引擎迁移计划：SwiftTerm → GhosttyKit + libghostty-vt

状态：第五版（2026-11-10）。测量门 M1–M17 已跑完、预算已定（§3.1）；M16 的 iOS 滚动手感和 Mac 手感 user 都已验收，
M10 修后过线，影子终端 `ShadowTerminal` 已落在共享目录；iOS 滚动以外的手感（选区、键盘、输入法）还没人试。
**实施（§4）已开工**：user 定了彻底移除 SwiftTerm、删掉调试开关，进度见 `docs/ghostty-eval/migration-log.md`。依据是四份评估报告、
三份测量报告与两轮真机探针，报告都已收进本分支的 `docs/ghostty-eval/`（见文末「依据」）。

**user 定的前提：**

- **破坏性替换，不做灰度**：没有引擎开关、没有双引擎并存、不留 SwiftTerm 退路。
- **并进 2.0.0**：2.0.0 等引擎换完再发。远控镜像、重启不断终端（holder 检查点）在已发布的 v1.18.1 / mobile-v1.3.0 里都没有，
  所以**没有任何旧版本要兼容**：快照只用二进制格式、两端同版本，不写 VT 流兼容，不做旧检查点迁移。
- **开工前把需要的指标测完**（§3 测量门）。
- **图形协议换成 Kitty**：放弃 Sixel / iTerm2 内联图，双向文字同样放弃。
- 最低对比度保留现状（改 shader）；Mac 内存先查清再定预算；VoiceOver 不阻塞发版；优先在 uTerm 本地做、少提 PR。

## 1. 目标与结论

- **画面交给 GhosttyKit**（`Lakr233/libghostty-spm`：完整 libghostty，Metal 渲染、CoreText、IME、UIKit/AppKit 视图、host-managed IO）。
- **读状态交给 libghostty-vt**：uTerm 要读终端内部状态的功能（远控快照、holder 检查点、CLI 读屏、OSC 7501 / 6973 / 133、
  是否在备用屏）GhosttyKit 的 Swift 层不给，每个会话另跑一个 vt 实例（**影子终端**），吃同一份字节。
- 迁移完成时 `vendor/SwiftTerm` 与 21 个本地补丁全部删除。

已有真机读数（iPhone 真机，同一次运行交替测）：

| 场景 | SwiftTerm | GhosttyKit |
|---|---|---|
| 远端来字到上屏 p50 | 18.4 ms | 2.7 ms |
| `cat` 2 MB 带色日志 | 1737 ms | 24 ms |
| Claude 思考时 CPU | 15.6% | 4.5% |
| 手指滚动 | ~60 fps，CPU 53% | ~115 fps，CPU 23% |
| 每帧 GPU（vertex+fragment 上限） | ≈0 | 0.8–1.1 ms |

## 2. 目标架构

```
SSH / holder / 本机 shell 字节
        │
  TerminalOutputPump（两端一份，重写）
        │  有界缓冲 + 反压（surface 的 backlog handler）
        ├──► tap：远控镜像、holder 检查点（原样字节）
        ├──► 影子终端 ShadowTerminal（libghostty-vt，同步解析，nonisolated 共享代码）
        │        ├ OSC 回调：7501 程序状态、133 提示符、6973 起止行（UNKNOWN_SEQUENCE）
        │        ├ 状态查询：备用屏、光标、总行数
        │        ├ 读屏：formatter PLAIN（CLI terminal-read / Agent read_terminal）
        │        └ 快照：二进制 snapshot（远控、holder 检查点、surface 补齐）
        └──► GhosttyKit surface（receive 异步解析，渲染线程出帧）
                 └ 输入 / 应答 / 网格尺寸 → TerminalInputChannel（现有 FIFO）
```

1. **两个库钉同一个 Ghostty commit**，都由我们自己编：影子终端与画面同源，镜像端看到的才和 Mac 屏一致
   （GhosttyKit 钉的 `042b16b6` 与官方 `vt-1.0.0` 差 165 个提交，Mac spike 已撞到一次 DECSTBM 分叉）。
2. **不加引擎抽象层**：只有一个引擎，`TerminalSession` / `MobileTerminalController` 直接用 GhosttyKit 子类。
   两端共享的逻辑（输出泵、影子终端、程序状态、快照）照 CLAUDE.md 放 `uTerm/` 下共享。
3. **surface 挂进窗口前的输出不丢**：GhosttyKit 挂载前只缓存 1 MiB、超出丢最旧。影子终端收全量；surface 创建时先 replay
   一份影子终端的状态，再接实时字节。
4. **快照只有一种**：影子终端的二进制 snapshot。远控握手里带引擎版本号，不一致就拒绝镜像并提示升级（与局域网同步一样要配对版本）。
   holder 检查点也存二进制快照，引擎版本变了就丢弃检查点（holder 里的 shell 不受影响，只是回滚历史从当前屏开始）。

## 3. 测量门（开工前做完）

都在现有评估分支上做，不碰 main。前面是指标，后面是怎么测、过线标准。标「定」的过线标准需要 user 看数后拍板。

| # | 指标 | 怎么测 | 过线 |
|---|---|---|---|
| M1 | **Mac 内存构成** | Release，1 / 6 / 20 个窗格 × 回滚 10k / 100k 行；`footprint` + Instruments Allocations / VM Tracker 拆出字形图集、IOSurface、回滚、共享 app 对象各多少 | 定（先拿构成） |
| M2 | **iOS 内存** | 真机 1 / 4 / 8 个终端标签（含分屏）footprint 与 jetsam 余量；同样拆构成 | 8 个标签远离 jetsam 上限；定 |
| M3 | **影子终端开销** | 真机上 vt 解析 MB/s、每会话常驻内存（回滚 10k 行）、Claude 输出时额外 CPU | CPU 增量 < 画面引擎省下的一成 |
| M4 | **影子与画面一致** | 同 commit 编的 vt 与 GhosttyKit 喂同一批语料，影子 formatter 文本 vs surface `readViewportText` 逐行比 | 0 差异 |
| M5 | **快照往返（同 commit）** | 复用 vt spike 的 33,243 切点，用同 commit 的 vt 重跑；再把快照灌进 surface（replay），比 surface 文本 | 0 差异 |
| M6 | **打字回显延迟** | 真机，`insertText` / 硬件键 → 本地回环 echo → 出帧，两引擎对照；Mac 同测 | 不劣于 SwiftTerm |
| M7 | **开标签与恢复** | 新开标签到首帧；冷启动恢复 20 个标签（含分屏）总耗时与内存峰值；两端 | 定 |
| M8 | **多窗格并发输出** | 4 窗格同时 Claude 式输出、整屏刷新，Mac / iOS 的 CPU 与出帧 | 不劣于 SwiftTerm |
| M9 | **功耗** | 真机 10 分钟 Claude 式输出：总 CPU 时间、热状态（xctrace Power Profiler） | 不劣于 SwiftTerm |
| M10 | **iOS 后台** | 退到后台继续收输出 5 分钟：写线程是否阻塞、内存是否涨、回前台是否补出最新画面 | 不阻塞、不涨 |
| M11 | **包体积** | Release archive + App Thinning 报告，iOS / Mac 各一份，对照现在 | 记录（已知 iOS 约 +11–12 MB） |
| M12 | **系统等宽字体** | `font-family` 能否取到 SF Mono（两端）；取不到时退回什么、和现在截图比 | 能取到，或定个替代字体 |
| M13 | **对比度 shader 补丁可行性** | 在 fork 里写出保色相 + 不豁免装饰字形的 shader，编 6 个 slice；p10k 浅色截图与现在比；GPU 每帧增量 | 观感与现在一致，GPU 增量可忽略 |
| M14 | **Mac 真事件输入** | XCTest 发真 NSEvent：拼音输入法、⌘ 组合键、⌃↩、鼠标拖选、双击选词、复制粘贴、贴图 | 全部可用 |
| M15 | **Kitty 图形** | 经 SSH（host-managed IO）显示 Kitty 图片（`kitty +kitten icat` / `chafa -f kitty`），两端 | 能显示、能滚出屏 |
| M16 | **手感（人工）** | 真机上连主机比滚动、甩、到顶到底、长按选区、点按弹键盘、硬件键盘方向键与按住重复 | user 认可（约 15 分钟） |
| M17 | **出包与升级演练** | 干净目录从朋友最新 tag 起，打补丁、同 commit 编两份、跑 M4/M5 | 一次通过，记录耗时 |

M16 需要在评估分支上临时挂一个能连主机的入口（不进 main），是唯一需要 user 动手的一项。

### 3.1 结果与定下的预算（2026-11-09）

读数顺序都是 Ghostty / SwiftTerm。Mac 为 Release、iOS 为 iPhone 真机。

| # | 结果 | 读数与结论 |
|---|---|---|
| M1 | 定 | 大头是每个**可见**窗格 3 张交换链 IOSurface（800×500 约 18 MB、16 寸满窗约 93 MB），`setSurfaceVisible(false)` 即还；共享 app 对象 0.7 MB；回滚每行 0.15–0.5 KB（SwiftTerm 3–4 KB）。20 窗格 × 10 万行 0.87 / 5.8 GB。**预算：日常（≤4 可见窗格、≤20 标签、回滚 ≤1 万行）增量 ≤300 MB；重度（20 个 800×500 可见窗格）≤700 MB。** |
| M2 | 过、定 | 8 个标签 263 / 203 MB，jetsam 上限约 3.4 GB。隐藏标签的帧缓冲不释放（每个约 14.5 MB）。**预算：8 个标签 ≤350 MB。** |
| M3 | 过 | 影子解析 0.39 ms/s（预算 10.3 ms/s），520–630 MB/s，1 万行回滚每会话常驻 5.1 MB。 |
| M4 | 过 | 576 个检查点 + 中途 resize 24 项，0 差异。前提见第 2 步。 |
| M5 | 过 | 同 commit 33,243 切点 0 差异；快照 → replay 进 surface 真实语料 320/320 一致。 |
| M6 | 过（iOS）/ 定（Mac） | iOS 真实 `insertText` p50 16–24 / 28–36 ms。Mac 到交给 Core Animation：默认 vsync 11.5 / 1.3 ms，关 vsync 1.9 ms。**定：Mac 保持默认 vsync，接受约一帧**（上游说明关 vsync 曾致内核 panic；真上屏时 SwiftTerm 也要等同步，实际差距更小）。 |
| M7 | 定 | 开窗格到首帧：Mac p50 5.6 / 7.0 ms，iOS 热 p50 24.6 / 9.4 ms。恢复 20 个：Mac 0.20 / 3.14 s（峰值 +939 / +831 MB），iOS 0.50 / 2.26 s（+626 / +125 MB）。**定：接受；恢复时先还原影子终端，标签第一次露出再建 surface。** |
| M8 | 过 | 4 格 Claude 式输出：Mac 主线程 11.9% / 27.0%，iOS 全进程 5.3% / 21–25%。Mac 只要有输出每格按约 90 fps 交帧（内容不变也画）。 |
| M9 | 过 | 10 分钟 CPU 时间 20.3 / 85.0 s，热状态正常；焦耳数没录成。 |
| M10 | **修后过**（2026-11-10） | 修之前：后台时 GhosttyKit 不 tick，每帧带的 OSC 0 标题约 6 s 填满 64 格 app mailbox 后停止解析、字节无上限排队；回前台 1119 / 59 ms（iPhone 真机）。修法（user 定，已在评估分支实现）：后台只喂影子终端、回前台把影子的快照回放进 surface、入站在 surface 积压 1 MiB 时停取。Duo 上同一探针 5 分钟：surface 排队全程 0（修前 6.7 MB），影子常驻 5.5 MB 封顶，回前台 19 ms（修前 82 ms；两轮屏幕状态不同，同屏只有第一版代码的 75 ms）。进出后台是模拟的。详见 `docs/ghostty-eval/measure-ios.md` M10。 |
| M11 | 记录 | iOS 装机 +8.4 MB；Mac App +17.2 MB（压缩 +7.7 MB），均为 SwiftTerm 未删时。 |
| M12 | 过 | 两端都只认 family 名 `.AppleSystemUIFontMonospaced`（`SF Mono` / `SFMono-Regular` 会落到内置 JetBrains Mono）。 |
| M13 | 过 | 补丁 0022：188 个样本最大差 2/255、ΔE 0.17，与测量误差相同；GPU 最坏每帧 +0.09–0.25 ms。**定：接受，不改 CPU 缓存。** |
| M14 | 过（真输入法除外） | Mac 14 项：⌃↩ 与右键菜单原来不过，已在 `GhosttySurfaceView` 里修（⌃↩ 没开 kitty 键盘协议时发 `\r`，右键菜单用回拷贝 / 粘贴 / 全选），真事件用例 13 项全过；真拼音输入法测试宿主测不了，user 试用时没报问题。 |
| M15 | 过 | 直传、分块、Unicode 占位符、滚出滚回、RIS 释放都正常。 |
| M16 | iOS 滚动过、Mac 过；iOS 其余待试 | iOS：十轮返工，单指滚动交给隐藏的 UIScrollView（手势、减速、回弹都是系统的），user 在 Duo 上验收「和 SwiftTerm 无异」。依赖引擎补丁 0023（逐像素平滑滚动）与本地包 `vendor/libghostty-spm` 里的一批 Swift 改动（清单见其 `UTERM-PATCHES.md`）。**定：**「渲染不同步」保持默认关；程序抓着鼠标（Claude 全屏界面）时松手后的惯性滑普通滚动的四分之一；停在底部时不够一行的余量留在提示符下面，不向 SwiftTerm 对齐。Mac：`ghostty-migration` 分支的 Release 版装进 /Applications 由 user 试用（11-10），评价「挺丝滑的没什么问题」；试之前补了触控板停手吸附整行、⌃↩、右键菜单（M14 两项随之过）。Mac 上 Ghostty 路径还缺滚动条和远控钉尺寸。iOS 的选区 / 键盘 / 输入法没试。详见 `docs/ghostty-eval/measure-ios.md` M16。 |
| M17 | 过 | 干净目录从 tag `2.2.2026110702` 一次通过：GhosttyKit 973 s，vt 43 s + 预链接 2 s；`build/cache` 4 GB。 |

没验证的（实施中补）：真上屏延迟、真拼音输入法、真退后台与 `BGContinuedProcessingTask`（M10 的修法也只在模拟的后台里验过）、
压到 SSH 窗口的背压（要改 Citadel）、焦耳数、快照跨版本、
一致性只比了文字没比样式光标、对比度没在真实渲染循环里量 GPU 与 iOS。

## 4. 实施（测量门过了之后）

一个迁移分支（独立 worktree）上顺序做，做完整体合进 main；中途 main 不受影响。

### 第 1 步 地基（约 1 周）

- 在 内部 git 服务器 建 libghostty-spm 的 fork：binaryTarget 指 OSS；加 `GhosttyVT` binaryTarget（同 commit、**在打过补丁的
  树上**编——补丁 0014 / 0015 改了 `Terminal.zig` / `Screen.zig`；`ld -r` 预链接，导出表收窄到 `vt.h` 的公开函数——只导出
  `ghostty_*` 仍剩 6 个同名符号 `ghostty_simd_*` / `ghostty_hwy_detect_targets`，`-all_load` 下报重复）；对比度 shader 补丁（M13 的成果）；出包脚本。pbxproj 按 exact 版本引用。
- 提 PR 1（replay 的 Swift 包装），朋友那边未合之前 fork 里先带着（§6）。
- 引擎补丁 0023（逐像素平滑滚动，M16 的前提）与 0022 一起进 fork 的补丁目录；0024（交换链）实测负收益，不带。
  M16 期间改在本地包里的 Swift 层（系统滚动、视口镜像、整行吸附、抓鼠标程序的惯性、wakeup 要不要同步重画、打点）
  整体搬进 fork，逐条清单在 `vendor/libghostty-spm/UTERM-PATCHES.md`；值得提给朋友的单列在 §6。
- 已编好的二进制（GhosttyKit 0022 / 0023 / 0024、ghostty-vt，含 zip 与 sha256）存在仓库外的
  `<artifacts>/2026-11-09/`，传 OSS 之前先用这份；iOS 评估分支的本地包软链指向其中的 0023。
- 四份评估报告与三份测量报告收进 `docs/ghostty-eval/`；测量用例（`TEST_RUNNER_GHOSTTY_MEASURE=1` / `UTERM_MEASURE=1` 门控）
  与 `Spikes/GhosttyVT/`、`Spikes/GhosttyPatches/` 一并带上。
- **落地情况（2026-11-10 收尾）**：fork 现在是仓库里的本地包 `vendor/libghostty-spm`（由评估期的 `vendor/libghostty-spm-local` 改名），
  还没有搬到 内部 git 服务器、也没有传 OSS。二进制不进版本库，`make engine` 按 `vendor/libghostty-spm/ENGINE.lock`
  从本地 artifacts 目录取 zip、校验 sha256、解到 `BinaryTarget/`（不再靠 `build/` 下的软链）。引擎补丁 0022 / 0023 在
  `vendor/libghostty-spm/Patches/ghostty/`，预链接脚本在 `Scripts/`，出包步骤在 `BUILD.md`；`Spikes/` 下的评估工具
  （`vtsnap`、`SurfaceCheck`）没带进来，仍在评估分支上。报告都已在 `docs/ghostty-eval/`。`vendor/SwiftTerm` 已删。

### 第 2 步 共享层（约 2 周）

- `ShadowTerminal`：feed、resize、OSC / 未知序列回调、状态查询、formatter 读屏、二进制快照编解码。M4 定下的前提：
  默认打开 mode 2027（surface 默认开、vt 默认关）；resize 挂在 `InMemoryTerminalSession` 的 resize 回调上（不按视图尺寸算）；
  回滚的字节与行数上限都显式设（只设行数时 vt 默认字节上限让 1 万行只剩 1,075 行）；解码快照开
  `GHOSTTY_SNAPSHOT_DECODER_OPT_RETAIN_CONTINUATION`。注意 `042b16b6` 上是 1.0 之前的 vt C API（formatter 用选项结构体）。
- `TerminalOutputPump` 重写：入站 → 有界缓冲 → tap → 影子终端（同步）→ surface（异步）；反压走 backlog handler。
- 改读影子终端：`ProgramStatusOSC` / `ProgramStatusTracker`（7501、133）、`TerminalSession+TrackedRun`（6973）、
  `TerminalCloseGuard`（备用屏）、CLI `terminal-read` / Agent `read_terminal`、`TerminalMirrorTap`（快照）、
  `TerminalSession+HeldSession`（检查点）。
- 删掉 SwiftTerm 之前，先把语料在 SwiftTerm 下的格子指纹录成金标准文件，作为迁移期的回归基准（已知差异写明原因）。

### 第 3 步 iOS（约 2 周）

- `MGhosttyEngineView`（UITerminalView 子类）：强制英文 ASCII 键盘、关自带附件栏、IME 候选框锚点修正、字号 ×0.75（96 dpi）。
- 键盘条走终端按键 API（DECCKM、粘滞修饰键原生正确；Ctrl 上膛后点方向键发 Ctrl+←）。
- 隐藏标签 `setSurfaceVisible(false)`，隐藏一段时间后释放 surface（M2 预算）；恢复时只还原影子终端、标签第一次露出再建
  surface（M7）；转屏、分屏沿用 `TerminalResizeSettler`；surface 补齐（依赖 PR 1）。
- **后台（M10 必过）**：后台只喂影子终端、回前台用快照 replay 进 surface；SSH 通道接背压；验收：后台 5 分钟不阻塞、
  内存不涨、回前台补出最新画面与 SwiftTerm 同量级（59 ms）。评估分支上已经在「Ghostty 试用」那条路做出最小实现并过了
  验收（2026-11-10，读数见 §3.1 M10 与 `docs/ghostty-eval/measure-ios.md`）：`ShadowTerminal` 在共享目录
  `uTerm/Features/Terminal/Shadow/`，分流 `GhosttyOutputRouter` 先放在 `uTermMobile/Screens/Terminal/Ghostty/`、第 2 步并进
  共享的输出泵。还差两件：真退后台（含 `BGContinuedProcessingTask`）没验；
  背压现在只到终端这一层，压不到 SSH 窗口（Citadel 的 PTY 输出流不限长，要改 Citadel）。
- 字体传 `.AppleSystemUIFontMonospaced`，取不到用 Menlo。
- 远控镜像接收端：解二进制快照。

### 第 4 步 macOS（约 2 周）

- 按 M1 定下的预算做内存调优：隐藏标签留在窗口里只调 `setSurfaceVisible(false)`（视图移出窗口会重建交换链）；回滚压缩保持开、
  字节上限按「设置行数 × 1 KB」放宽；`scrollback-limit-lines` 运行中改不生效，只对新 surface 有用。配置键用
  `scrollback-limit-lines`（`scrollback-limit` 这个版本不认、静默忽略）、`copy-on-select = none`。
- 恢复同 iOS：先还原影子、露出再建 surface；保持默认 `window-vsync`（M6）。
- `GhosttyEngineView`（AppTerminalView 子类）：字体、配色、光标、对比度、回滚上限、选中即复制、⌃↩、焦点、贴图、链接、
  右键菜单、浮层滚动条（Ghostty 不画滚动条，按 `SCROLLBAR` action 自绘）。
- holder 回放：解检查点 → 临时 vt 按检查点尺寸还原 → resize 到当前 → 灌进 surface（`receiveReplay`，依赖 PR 1）。
- 远控钉尺寸按 cell 像素（整像素取整）直接算；`LocalShellWindow` 走 host-managed IO，可注入 GhosttyKit 的 MIT shell integration。

### 第 5 步 远控协议（约 3 天）

- 握手带引擎版本号；快照走二进制格式，包在 `?2026h … ?2026l` 里；版本不一致拒绝镜像并提示升级。消息号从 47 起。

### 第 6 步 删除与收尾（约 3 天）

- 删 `vendor/SwiftTerm`、`UTERM-PATCHES.md`、只为 SwiftTerm 存在的代码（`TerminalFlushPacing` 的 SwiftTerm 扩展、行缓存、
  #17 / #21 相关、`ProgramStatusOSC.install(on: Terminal)` 等）；改写依赖 SwiftTerm 类型的测试（不删测试文件，改成针对新引擎）。
- 更新 CLAUDE.md：vendored 依赖一节、终端共享落点、性能探针一节；`docs/scroll-perf-findings.md` 补新引擎读数。
- 全量 `make test-fast` / `make test-mobile-fast`、真机探针复跑、`make check-strings`、`make check-cloudkit-schema`。
- 合进 main，接着走 2.0.0 发版流程。

VoiceOver（Mac 移植 Ghostty 自家 App 的 `SurfaceView_AppKit` 无障碍实现、iOS 按行暴露元素）不阻塞 2.0.0，放到之后的版本。

## 5. 出包与升级

- GhosttyKit 与 GhosttyVT 同一个 Ghostty commit、exact 钉死；不跟每周 tag，只为具体修复或按季度升级。
- 升级步骤：fork rebase 朋友的新 tag → 同 commit 重编两份（GhosttyKit 6 个 slice 约 14 分钟，vt 约 80 秒；依赖 37 个 Zig 包约
  270 MB，构建机缓存）→ 跑 M4 / M5 / 语料回归 / 探针 / 真机探针 → 传 OSS → 改 pbxproj。
- 风险：`ghostty.h` 上游定位是内部接口；完整版 iOS 构建上游不支持，靠 GhosttyKit 的补丁 0004/0005/0012/0016/0017 与一个
  Zig 标准库补丁。朋友维护降低了这块风险，升级仍按上面的流程验。

## 6. 上游 PR（只列必要的）

| # | 内容 | 为什么本地做不了 | 阻塞 |
|---|---|---|---|
| 1 | `InMemoryTerminalSession.receiveReplay(_:)`：包 `ghostty_surface_write_buffer_replay`，与 receive 同队列 | `TerminalSurface.rawValue` 是 internal；回放时的应答在 termio 线程异步产生 | 第 3、4 步（fork 先带着就不阻塞）。**还没提**；本地包 `vendor/libghostty-spm` 里已经自己加了（M10 用，连同 `discardPendingOutput()`，见其 `UTERM-PATCHES.md`），提的时候照那份 |
| 2 | pending 输出上限可配（或超限回调，不静默丢） | 写死 1 MiB | 不阻塞（影子终端 + replay 能绕） |

M16 攒下的、值得跟朋友说的（都已在本地包里改了，不阻塞）：引擎 wakeup 不必在主线程同步整帧重画（第六轮）；
惯性 display link 没设帧率、ProMotion 上只有 60 Hz；手势 `.ended` 把「内联选区开 + 程序抓鼠标」的惯性拦掉了（a667344）；
到顶 / 到底按滚动条行号判定会停在半行。

可选（让影子终端变薄，不急）：读屏 Swift 接口、`PROGRAM_STATUS` action（可直接提 Ghostty 上游）、系统等宽字体、
iOS 收键盘仍画实心光标、`readViewportText` 行末宽字符占位会带进下一行（uTerm 读屏走影子不受影响，跟朋友提一句即可）。
详见 patch-mapping 报告 §5。

## 7. 会丢的与新增的

- 丢：双向文字、Sixel / iTerm2 内联图。（原列在这里的「收起键盘后的实心光标」user 定为回归，已修回：本地包 `UTERM-PATCHES.md` 第 14 条。）iOS 的系统滚动手感保住了（M16：单指滚动交给 UIScrollView）。
- 暂缺：VoiceOver（之后补）。
- 新增：Kitty 键盘协议与 mode 2031 原生支持、120 Hz 滚动、解析不占主线程；Kitty 图形在 Mac 上是新增，iOS 现有 SwiftTerm
  已能画 Kitty 直传图（M15 发现），迁移后补齐分块与 Unicode 占位符。

## 8. 依据

报告都已在本分支（`ghostty-migration`）的 `docs/ghostty-eval/` 下。「原分支」是它最初写在哪条评估分支上。

| 报告 | 现在 | 原分支 | 原提交 |
|---|---|---|---|
| `docs/ghostty-eval/macos-spike.md` | 已在本分支 | `worktree-agent-a5a92280c35ff6233` | `8258af6b` |
| `docs/ghostty-eval/ios-spike.md` | 已在本分支 | `worktree-agent-a8027c0645e597763` | `dbcf9af2` |
| `docs/ghostty-eval/patch-mapping.md` | 已在本分支 | `worktree-agent-aa7cbc2aefaaa2abc` | `b1759b04` |
| `docs/ghostty-eval/vt-snapshot-and-build.md` | 已在本分支 | `worktree-agent-a6bb31349ee21df46` | `5f2c86ce` |
| `docs/ghostty-eval/measure-build-consistency.md`（M4 / M5 / M13 / M17，补丁 0023 / 0024） | 已在本分支（取的是原分支头 `64ce2ef7` 的版本，含 0023、0024 两节） | `worktree-agent-a6bb31349ee21df46` | `cd21d4c3` 起 |
| `docs/ghostty-eval/measure-macos.md`（M1 / M6–M8 / M11 / M12 / M14 / M15） | 已在本分支 | `worktree-agent-a5a92280c35ff6233` | `a3d032d7` |
| `docs/ghostty-eval/measure-ios.md`（M2 / M3 / M6–M12 / M15 / M16） | 已在本分支 | `worktree-agent-a8027c0645e597763` | 分支头（M16 十轮都在这份里） |
| `docs/ghostty-eval/migration-log.md`（实施进度） | 已在本分支 | — | — |
| 本文 | 已在本分支 | `worktree-agent-a8027c0645e597763` | 分支头 |

这些报告是评估当时写的，里面的路径（`vendor/libghostty-spm-local`、`build/ghostty-kit/current`、`Spikes/…`、`vendor/SwiftTerm`）
是当时的，现状以 `vendor/libghostty-spm/UTERM-PATCHES.md` 和迁移日志为准。

真机读数：2026-11-09 上午，iOS 分支 worktree 的 `build/ghostty-spike.trace`（Metal System Trace，3 GB）。
