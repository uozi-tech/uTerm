# uTerm 列表/表格渲染评估

> **2026-11-10 说明：终端引擎已换成 GhosttyKit（画面）+ libghostty-vt（影子终端），SwiftTerm 已从工程里删除。**
> 本文与终端渲染相关的读数和结论（终端屏的自绘成本、按 16 ms 节拍的 flush 循环、`getTopVisibleRow()` 的消费计数、
> 隐藏终端照解析照重绘等）是旧引擎的，正文保留作历史。新引擎的读数见 `docs/ghostty-eval/`
> （`measure-ios.md`、`measure-macos.md`、`migration-log.md`）。列表 / 表格部分不受影响。

每个视图一段：规模（含来源）、读数表、判定（A/B/C）、改法、前→后、探针类名。
**判定只用结构判据与同轮相对比，绝对毫秒只打印。**

先看「一页总表」定位到视图，再看「与 uTable 结论不同之处 / 已排除的路」与「探针纪律」——
这两节是**跨视图**的账，别只读自己那一段就动手。所有仍开着的账收在文末「未决账」。

## 一页总表

一行一个视图。「极端档关键读数」只挑最能说明问题的两三个，完整读数在各自那一段里。
判定 A = 保持现状（探针留下当尺），B = SwiftUI 就地修，C = 按 T1/T2 样板重写成原生自绘。

| 视图 | 文件 | 判定 | 极端档关键读数 前 → 后 | 探针类名 | commit |
|---|---|---|---|---|---|
| 欢迎页服务器列表行 | `Welcome/Views/ServerRow.swift` | B（A/B 边界） | 2000 台：帧 p50 4.472 → 2.320ms、p95 6.956 → 3.671ms、NSView 91 → 29 | `WelcomeServerListCostTests` | `393773ec` |
| 欢迎页服务器列表「选中驱动滚动」 | `Welcome/Views/ServerList.swift` | **A（判据 1 不过，但照方抓药是负收益）** | 2000 台换选中行：`scrollTo` 比手滚同样距离贵 2.0~2.3×；100 台档 0.88~0.98×（不收税）；NSView 恒 43 不随规模涨 | `ServerListSelectionScrollProbeTests` | 本轮 |
| 欢迎页左侧栏 | `Welcome/Views/WelcomeSidebar.swift` + `Core/Models/ServerFilter.swift` | B | 2000 台 / 60 组：一次击键 p50 93.47 → 21.31ms；`counts` 51.445 → 2.328ms | `WelcomeSidebarCostTests` | `41e30c18`（+ `078b173d` 补 `existingGroups`） |
| 快捷命令执行日志 | `Welcome/Views/QuickCommandRunLog.swift` + `Core/Models/QuickCommand.swift` | B | 3000 条：挂载 251.94 → 2.26ms、hitTest 18351 → 293µs、NSView 6029 → 29 | `QuickCommandRunLogCostTests` | `717ceba4` |
| ⌘K 命令面板 | `CommandPalette/CommandPaletteModel.swift` | 视图层 A / 模型层 B | 2202 项：↑↓ p50 10.673 → 2.399ms、击键 p50 9.230 → 7.094ms、NSView 恒 15 | `CommandPaletteCostTests` | `67c2e5c3` |
| SFTP 文件表 + 侧栏文件树 | `SFTP/Views/SFTPFileTable.swift`、`Files/Views/FileBrowserView.swift` | B | 20000 条目 · 侧栏：超预算 4.5%/3.5% → 0.0%/0.5%、NSView 258 → 18 | `FileBrowserScrollCostTests`（5 个类） | `4be8724a` |
| SFTP 传输进度 + Dock / 浮层 | `Files/FileBrowserModel.swift`、`SFTP/Views/SFTPTransfersDock.swift` | 浮层 A / 写入频率 A / 写路径 B | 队列 1000 条：`applyProgress` 0.07064 → 0.00034ms、芯片派生 0.55147 → 0.07638ms | `SFTPTransferProgressCostTests` | `aa71f9df` |
| Agent 消息流 | `Agent/Views/AssistantView.swift`、`Terminal/Views/TerminalAgentView.swift` | B | 流式 1000 条：拍数 184 → 481 / 1500、文档高 1588044 → 307349pt | `AgentMessageListCostTests` | `e4a54ccd` |
| **`MobileAgentChat`（iOS）** | `uTermMobile/Screens/Agent/MobileAgentChat.swift` + `Agent/Backend/AgentCommandExecutorSeam.swift` | B | 1000 条：文档高 2388073 → 447787pt（5.33×）、流式期单帧 p95 6.341 → 3.579ms、footprint 280 → 199MB；**拍数两臂都 0.94，桌面那条 2.61× 在 iOS 不成立** | `AgentChatProbeTests` | 本轮 |
| Agent 会话历史下拉 | 同上两个文件 | B | 1000 条会话：取数 9.5 → 0.7ms、物化对象 1000 → 50 | `ManagementListScrollCostTests.testSessionDropdownFetchLimit` | `9f7779ac` |
| 预览窗口 Markdown | `Preview/MarkdownRenderer.swift` → `Views/Markdown/MarkdownBlocks.swift` | B | 2.8MB / 50001 块：挂载 43740.6 → 887.0ms、超预算 100% → 0.5%、RSS 11292 → 479MB | `MarkdownPreviewCostTests` | `e4a54ccd` |
| 并行执行 · Shell 网格 | `ParallelRun/Views/ParallelShellGrid.swift` | B 已落地，**终局 C** | 24 台 × 1200 行追加期：p50 58.55 → 14.96ms、拍数 95 → 149 / 1250 | `ParallelRunScrollCostTests` | `b9f0c0f2` |
| 并行执行 · AI 泳道 / 广播条 / 状态栏 | `ParallelAgentView.swift`、`ParallelRunChrome.swift` | **A，三处都不动** | 24 台泳道：滚动 p95 1.53ms、超预算 0% | 同上 | `b9f0c0f2` |
| 全局端口转发窗口 | `PortForward/Global/GlobalForwardingWindowView.swift` | B | 1000 行：挂载 908.84 → 30.05ms、超预算 99.5% → 4.5%、NSView 6465 → 176 | `GlobalForwardingListCostTests` | `c2123c21`（+ `6d4a9953` 复量、`4d47cbfe` 统一 helper 路径） |
| 单主机端口转发列表 | `PortForward/Views/PortForwardListView.swift` + `TunnelRow.swift` | B | 200 条：挂载 49.29 → 2.41ms、hitTest 2700 → 429µs、NSView 1817 → 128 | `PortForwardListCostTests` | `6d4a9953` |
| 分组管理 | `Groups/Views/GroupsManagerView.swift` | B | 1 组 / 2000 成员：挂载 1664.1 → 36.0ms、hitTest 13453 → 323µs、NSView 3936 → 36 | `ManagementListScrollCostTests` | `50e7b533` |
| 密钥管理侧栏 | `Keys/Views/KeyManagerView.swift` | B（轻） | 50 密钥 / 2000 台：挂载 83.6 → 34.3ms（滚动本来就达标） | 同上 | `50e7b533` |
| SSH config 导入复核表 | `Import/Views/SSHConfigImportView.swift` | B | 2000 行：挂载 432.1 → 4.6ms、hitTest 5566 → 260µs | 同上 | `50e7b533` |
| **滚动期间的 hover（跨视图）** | `UAppKitBridge/ScrollHoverGate.swift` + 6 处接入 | B | 光标压在列表上滚：全局转发 1000 行 p50 10.00 → 3.74ms、超预算 73.5% → 5.5%、NSView 波动 46 → 2；欢迎页 2000 台 5.24 → 3.29ms、超预算 14.5% → 0.0% | `ScrollHoverGateProbeTests`（4 个类） | `18d48893`（+ `b959982f`） |
| **行悬停：整表一个跟踪层（跨视图）** | `UAppKitBridge/RowHoverTracker.swift` + 5 处接入 | B | 光标压在列表上滚，**in/out 单帧 p50 比值** 欢迎页 1.15 → 1.01×、SFTP 1.32 → 1.01×、全局转发 2.27 → 0.98×（p50 −22% / −23% / −57%）；滚动期间行级 hover 事件 280~320 → 0 | `RowHoverTrackerProbeTests`（5 个类） | 本轮 |
| **对话记录正文（Mac 的 Code 标签页 / 历史窗口，iOS 的历史会话标签）** | `ClaudeHistory/Views/AgentHistoryBrowser.swift`（`AgentTranscriptMarkdown`）、`uTermMobile/Screens/Workspace/ClaudeHistoryTab.swift`（`MTranscriptMarkdown`） | B | 120 条往回翻 4860pt：画面跳 16 次（单次最大 317pt）+ 整屏换 13 次 → 0 / 0；滚动中文档高变 11 次共 10437pt → 0；打开时文档高 4957 → 22751pt（改前是按空文档量的）；帧耗时两臂都在 0.4ms 以内（不是掉帧）；iOS 120 条往回翻跳 8 + 整屏换 13 → 0 / 0 | `ClaudeTranscriptScrollProbeTests`（Mac、iOS 各一个） | 本轮 |
| **uTermMobile 全端（iOS）** | `uTermMobile/**` + `Core/Models/ServerGrouping.swift` | B（10 处），**但只有一处有读数** | 2000 台 / 60 组「组名→台数」：47.882 → 0.852ms（56×）；其余 9 处是形态归因，iOS 无可用模拟器 runtime、平台组件未装，一条真窗口读数都没有 | `ServerGroupingTests` + `MobileRenderLintTests`（文本 lint） | 本轮 |
| **终端屏 · 单会话输出压力（iOS）** | `uTermMobile/Screens/Terminal/*` | **A** | 1 会话 × 2000 行/秒 × 10s：单帧 p50 0.050ms、p95 5.751ms、超 8.33ms 0.0%、display 拍 599/600 | `TerminalScreenProbeTests` | 本轮 |
| **终端屏 · 非活动会话仍全量渲染（iOS）** | 同上 | B | 4 会话各 2000 行/秒：单帧 p50 3.855 → 0.041ms、超 8.33ms 15.2% → 0.0%、主线程 CPU 6.771 → 5.910s，四片消费计数不变（不丢字节） | 同上 | 本轮 |

| **并行执行屏 · Shell（iOS）** | `uTermMobile/Screens/Parallel/ParallelRunView.swift` | B | 24 台 × 1200 行：**跨格一跳 p50 316.2 → 20.8ms**、追加期 p95 10.66 → 2.06ms、超 8.33ms 7.8% → 0.0%、心跳 770 → 1027 / 1250、footprint 1075 → 73MB | `ParallelRunProbeTests` | 本轮 |
| 并行执行屏 · AI 泳道展开（iOS） | 同上 | **A（不动）** | 24 条 × 6 步：展开后内容高 3519 → 9231pt、UIView 恒 6、往返 p95 3.24 → 2.43ms、超预算 0% | 同上 | 本轮 |

心跳的「理想拍数」按测多久算，各表表头都标了：3 秒 = 375 拍，10 秒 = 1250，12 秒 = 1500，
Shell 网格的变体归因是 4 秒 = 500。跨表比拍数之前先看分母。

## 方法来源

方法论与样板代码都在同作者的 uTable 仓库（只读引用，不改）：

- 三种渲染方式、A/B/C 判定流程、探针写法速查、已排除的路：
  `uTable 仓库的 docs/table-rendering-guide.md`
- 四把尺、探针九坑、「Button 才是主因」、分层处方、LazyVStack 判据、探针窗口三档：
  `uTable 仓库的 docs/swiftui-scroll-perf-playbook.md`
- 原生自绘样板：`uTable/UI/Data/DataGridTableView.swift` + `DataGridCellRendering.swift`（T1）、
  `uTable/UI/UTable/Workspace/UTableSchemaSidebarTable.swift` 与 `UTableMigrationScreen.swift`
  里的 `MigrationNativeGrid`（T2）、
  `uTable/UI/UTable/Workspace/UTableRowEditModal.swift` 与 `uTable/UI/Redis/RedisValueEditor.swift`（T3 活行）。

### 判定规则（照抄 guide，写在这里免得每次回翻）

- **A**：极端档 p95 ≤ 8.33ms、超预算帧 ≤ 2%、hitTest 不随规模涨 → 保持现状，探针留下当尺。
- **B**：已知形态（每行 Button / TextField / Menu / `.help`、非 lazy、无截断）→ 就地修，
  同一轮里前→后对照。
- **C**：B 之后仍超预算，或是可编辑网格 → 按 T1/T2 样板重写成原生自绘，
  保住多选 / 右键 / 悬停 / 编辑 / AX / 键盘 / 拖拽契约，配像素或墨迹判据 + 行为测试。

## 夹具位置

三件夹具从 uTable 移过来，放在 `uTermTests/Support/`，**别再抄第二份**：

| 文件 | 抄自 uTable commit | 作用 |
|---|---|---|
| `uTermTests/Support/ProbeWindow.swift` | `bba891b` | 建窗三档：`.offScreen`（结构/几何/像素判据）、`.transparentOnScreen`（计时判据，屏内但 `alphaValue = 0`）、`.visibleOnScreen`（tooltip / 真光标）。`Unconstrained` 覆写 `constrainFrameRect` 与 `mouseLocationOutsideOfEventStream`（把用户真鼠标挡在窗外，否则 `.onHover` 会把读数染红）。 |
| `uTermTests/Support/ProbeMetrics.swift` | `65fb6eb` | 三把尺：`percentile`（统一口径）、`threadCPUSeconds`、`footprintMB`；外加 `ProbeWindow.isolateHostWindows` 与 `NSView.firstScrollView()`。 |
| `uTermTests/Support/VisionTextProbe.swift` | `aaea666` | 截图判读：OCR 离主线程 + 钉 CPU 计算设备 + 90s 预算，超时退回 `inkFraction` 像素兜底。 |

自证用例：`uTermTests/Support/ProbeSmokeTests.swift` —— **它不评判任何 uTerm 视图**，
只证明「建窗 → 上屏 → 挂 SwiftUI → 滚 → 量 → 截图识别」这条链路在 uTerm 的测试宿主里跑得通。
后续视图评估直接抄它的形状。

### 夹具移植时与 uTable 的三处不同（这是夹具的坑；结论上的差异见「与 uTable 结论不同之处」）

1. **`uTermTests` target 的默认 actor 隔离是 `nonisolated`**（uTable 那边是 `MainActor`），
   而且是 Swift 6 语言模式。所以 `ProbeWindow` 整个 enum 显式标了 `@MainActor`；
   探针测试类里**不能覆写 `tearDown()` 去拆窗**（`XCTestCase.tearDown()` 是 nonisolated 的，
   覆写不能改隔离，`MainActor.assumeIsolated` 也不行——它要求把 `self` sending 出去）。
   改用每条用例开头 `defer { closeAllWindows() }`。
2. **宿主 app 会在最后一个窗口消失时 `exit(0)`**（`uTermApp` 是纯 SwiftUI `WindowGroup`）。
   `isolateHostWindows` 卸掉宿主窗口、探针再拆自己的窗口，那一瞬宿主进程直接没了；
   xcresult 里只有一句「The test runner exited with code 0 before finishing running tests」，
   既没有断言消息也没有崩溃栈。`ProbeWindow.terminationAnchor` 常驻一个 1×1 的屏外锚窗口
   顶住窗口数，`isolateHostWindows` 会自动把它排除在卸载名单外——照抄夹具就不会踩到。
3. `VisionTextProbe.perform` 上的 `@concurrent` 去掉了：`uTermTests` 没开
   `SWIFT_APPROACHABLE_CONCURRENCY`。它在这里也不必要（target 默认隔离本就是 `nonisolated`，
   调用点又在 `Task.detached` 里），「离开主线程再跑」这条约束仍然成立。

## uTermMobile 测试基建（iOS / iPadOS）

上面整套讲的是 macOS：target `uTermTests`、宿主 `uTerm.app`、`-destination 'platform=macOS'`。
iOS/iPadOS 端 2026-09-08 起有了自己的一套，**与桌面那套互不依赖、不共享文件**：

| | macOS | iOS / iPadOS |
|---|---|---|
| 测试 target | `uTermTests` | `uTermMobileTests` |
| 宿主 | `uTerm.app` | `uTermMobile.app` |
| scheme | `uTerm` | `uTermMobile` |
| destination | `platform=macOS` | `platform=iOS Simulator,name=iPhone 17 Pro` |
| 一条命令 | `make test` | `make test-mobile` |
| 夹具 | `uTermTests/Support/` | `uTermMobileTests/Support/` |
| 自证用例 | `uTermTests/Support/ProbeSmokeTests` | `uTermMobileTests/ProbeSmokeTests` |

**详细的 target 配置、八条坑与基线读数在 `uTermMobileTests/README.md`**，这里只记会
影响别的人的三条：

1. **这台机器（以及任何新机器）默认没有 iOS 模拟器运行时。** Xcode 26.6 只装了 iOS
   SDK；`xcrun simctl list runtimes` 是空的，所有模拟器都报
   `runtime profile not found`。先跑一次 `xcodebuild -downloadPlatform iOS`
   （iOS 26.5，8.52GB，约 15 分钟），之后 iPhone 17 / iPad Pro (M5) 等才可用。
2. **往 `uTerm/` 里加 AppKit-only 的文件，必须同步加进 `uTermMobile` target 的
   `membershipExceptions`**，否则移动端立刻编译不过。`uTermMobile` 用
   `PBXFileSystemSynchronizedRootGroup` 同步整个 `uTerm/` 目录，新文件**默认就是成员**，
   排除是白名单式的例外表。main HEAD `66d88a51` 上 `uTermMobile` 就是这么红的 ——
   `cb899345`（整表悬停跟踪层）加的 `Features/Files/RemoteRowDropTargeting.swift` 与
   `Shared/Views/ClickSelectActivate.swift` 漏进例外表，本轮补上。
   自查脚本在 `uTermMobileTests/README.md` 坑②。
3. **模拟器上 CloudKit 必然刷 `CKAccountStatusNoAccount` 错误，是常态不是故障**
   （模拟器没登 iCloud，`NSPersistentCloudKitContainer` 起不来）。SwiftData 本地容器
   照常工作，测试全绿。与桌面那边 `CKError "Service Unavailable"` 同性质。

iOS 侧夹具与桌面的对应关系：`ProbeMetrics` 的三把尺（`percentile` /
`threadCPUSeconds` / `footprintMB`）是**纯 Darwin API，一字未改**地照搬；
`ProbeWindow` **没有**逐行移植（iOS 不用躲真鼠标、也不用 `terminationAnchor`），
换成了 `MobileProbeWindow`（`UIWindow` + 更高的 `windowLevel` 压住宿主窗口）
加一个 `DisplayLinkCounter`（`CADisplayLink` 真拍数，比 sleep 拍更贴近体感；
两种拍数都留，量的不是一回事）。`VisionTextProbe` 暂未移植 ——
iOS 侧的「不是空壳」判据先只用墨迹（`drawHierarchy` 截图后数非白像素）。

### iOS 链路自证的基线读数

夹具与桌面同形（纯 `Text` 行的 `ScrollView + LazyVStack + ForEach`，没有 Button /
TextField），390×700pt、行高 22pt、往返幅度钳 ≈3 视口。
iPhone 17 Pro · iOS 26.5 模拟器 · `maxFPS=60`，2026-09-08 两轮实测：

| 行数 | 挂载 | sleep 拍/375 | CADisplayLink 拍/180 | 单帧 p50 | 单帧 p95 | 超 8.33ms | hitTest p50 | UIView | 内容高 |
|---|---|---|---|---|---|---|---|---|---|
| 200 | 14.3 / 17.4ms | 334 / 335 | 179 | 1.73 / 1.63ms | 2.26 / 2.09ms | 0.0% | 10.0 / 6.1µs | **6** | 4400 |
| 2000 | 7.0 / 5.2ms | 334 / 333 | 179 | 1.60 / 1.66ms | 2.15 / 2.11ms | 0.0% | 6.0 / 6.9µs | **6** | 44000 |

结构判据（硬断言）：UIView 数 200 行 vs 2000 行完全相同（6 = 6，±2 闸门），
CADisplayLink 拍数 > 30（掉下去 = 窗口没真上屏），可滚动高度 > 0 且随行数增长。
绝对毫秒只打印，不设闸门。

两条读法上的提醒：

- **挂载耗时 200 行比 2000 行贵**（14.3 vs 7.0ms），因为每次运行的第一个 fixture
  吃了 SwiftUI 首次渲染的一次性开销。**跨档比挂载没有意义**，只在同一档做前→后对照。
- 模拟器的 `maximumFramesPerSecond` 跟着宿主 Mac 的显示器走，这台报 60；
  ProMotion 显示器上是 120，理想拍数随之翻倍。**跨机器比拍数之前先看分母。**

## 跑法

worktree 基于 main，**不要碰主工作树**（用户有未提交改动）：

```sh
B=<worktree 根>
git -C <uTerm 仓库> worktree add -b <分支名> $B/<目录> main
mkdir -p $B/<目录>/build/DerivedData
cp -R <uTerm 仓库>/build/DerivedData/SourcePackages $B/<目录>/build/DerivedData/
```

编译一次，然后只跑要跑的类：

```sh
cd $B/<目录>
xcodebuild build-for-testing \
  -project uTerm.xcodeproj -scheme uTerm -destination 'platform=macOS' \
  -derivedDataPath $B/<目录>/build/DerivedData \
  -disableAutomaticPackageResolution -skipPackageUpdates

caffeinate -dimsu xcodebuild test-without-building \
  -project uTerm.xcodeproj -scheme uTerm -destination 'platform=macOS' \
  -derivedDataPath $B/<目录>/build/DerivedData \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:uTermTests/ProbeSmokeTests
```

耗时参考（2026-09-07，M-series MacBook Pro，Debug）：冷 `build-for-testing` 约 56s，
增量约 7s；`ProbeSmokeTests` 单跑约 13s 测试时间 / 18–30s 墙钟。

注意：

- **不要加 `CODE_SIGNING_ALLOWED=NO`** —— uTerm 的 Keychain 类测试要 entitlement，
  不签名会有 16 条假红。
- 全量或长跑之前先 `caffeinate -dimsu`。
- 已知环境噪声：`QuickCommandStoreTests` 等 CoreData + CloudKit 用例会卡上百秒甚至崩；
  日志里成片的 `CKError "Service Unavailable"` / `Sandbox restriction` 是沙盒里连不上
  cloudd 的常态，与探针无关。
- 杀进程只能按自己 worktree 的路径匹配，**绝不能全局 `pkill -f`**。
- **三条会在全量里假红的时间型护栏**（2026-09-08 实测）：全量一跑四十分钟，
  机器同时还在编译时，下面三条**单跑必过、全量里会红**。红了先单跑复核，
  别当回归：
  · `WelcomeSidebarCostTests.testSidebarScale`（2000 台 / 60 组一次击键 < 200ms；
    全量里量到 224ms，单跑过）
  · `ServerListSelectionScrollProbeTests.testSelectionDrivenScrollToStaysResponsive`
    （换选中行 < 500ms / 搜索切换 < 800ms；全量里量到 674ms / 1870ms，单跑过）
  · `GlobalForwardingRowHoverTests.testExtremeScale`（追踪区数不随光标位置变；
    全量里 4 vs 2，单跑 相等）——这条不是时间型，但同样只在全量里出现。

### 链路自证的基线读数

`ProbeSmokeTests` 的夹具是纯 `Text` 行的 `ScrollView + LazyVStack + ForEach`
（没有 Button / TextField / `.help`，因而不产生平台视图）。460×520 窗口、行高 22pt、
往返幅度钳 ≈3 视口，2026-09-07 实测：

| 行数 | 挂载 | 拍数/375 | 单帧 p50 | 单帧 p95 | 超 8.33ms | hitTest p50 | NSView | 文档高 |
|---|---|---|---|---|---|---|---|---|
| 200 | 3.0–5.0ms | 303–308 | 2.50–2.85ms | 3.28–3.52ms | 0.0% | 121–125µs | **29** | 4400 |
| 2000 | 3.9–4.7ms | 304–306 | 2.55–2.78ms | 3.32–3.48ms | 0.0% | 120–126µs | **29** | 44000 |

结构判据（硬断言）：NSView 数 200 行 vs 2000 行完全相同（29 = 29），
`blindsRealMouse` 为真，可滚动高度 > 0 且随行数增长。
绝对毫秒只打印，不设闸门。


## 与 uTable 结论不同之处 / 已排除的路

方法论抄自 uTable，但**结论不能照抄**。下面每条都是这一轮探针实测出来的差异或死路，
带出处（视图段名）。动手前先扫一遍这节，能省掉一整轮白做的工。

### 一、与 uTable playbook 结论**不同**的

1. **`LazyVStack` 在 uTerm 的 Agent 消息流里真的回收行**：NSView 恒 802/803，200 条与
   1000 条完全相同，钳 3 视口的滚动读数两臂一致。uTable AI 面板那组「800 条 / 200 条
   = 0.40 拍」在这里**不成立**（那边改前是非 lazy 的 `VStack`）。任务书里「长会话线性
   增长」这条推断被探针证伪了一半。→「Agent 消息流」
2. **形态可移植，量级不一定可移植**：欢迎页服务器列表与 uTable ① 是「同一个名字的屏」，
   但 uTable 那边改前是非 lazy（6007 NSView / 15ms hitTest / 373ms 挂载），uTerm 这边
   改前就是懒栈（91 NSView / 400µs / 3ms）。照抄结论会得出 **67 倍的假预期**。
   → 「欢迎页服务器列表行」
3. **`.help` 悬停门控不是万能刀**：服务器列表行三臂对照下 `helpGated` 与 `legacy` 的
   常驻 NSView 完全相同（91 = 91）、帧差在噪声内，已钉成断言；SFTP 文件表 / 侧栏那种
   「每行**一个** `.help`」在 20000 条目档同轮 A/B/B/A 全在噪声里，所以那两处**没有**
   引入门控。uTable 权限树那次是「每行数个 × 上千行」，形态不同。转发窗口两处仍改了
   门控，但收益记在「hover 按钮悬停才建」上，**不是** `.help` 那一刀。
   → 「欢迎页服务器列表行」「SFTP 文件表…」「全局 / 单主机端口转发」
4. **`onHover` 不是每行一个平台节点**：`hoverBackground` 全程只有 1~3 个
   `NSTrackingArea`（整个列表共用），与行数无关。→「SFTP 文件表…」
5. **「换掉 `Button` 一定让命中变快」在这里不成立**：服务器列表行三臂 hitTest 都在
   326~401µs，看不出方向，**不作为收益记账**。→「欢迎页服务器列表行」

### 二、试过并被数据推翻的路（别再走一遍）

6. **`ChatCodeBlock` 的复制 `Button` → `onTapGesture` + 手工 AX**：hitTest **473 → 664µs**、
   NSView **803 → 817**，命中不再早早落在真控件上，且「复制」二字在 `.textSelection`
   作用域里各多长一个 `SelectionTextField`。**已撤回**。→「Agent 消息流」反例表
7. **分组一层无条件换 `LazyVStack`**：真实档 10 组 / 50 行 p95 **2.00 → 15.41ms**、
   超预算 **0% → 9.5%**。所以才有 `lazyRowThreshold = 120`（两档之间的确切拐点没量过）。
   → 「全局端口转发窗口」
8. **只换懒栈、不做「悬停才建」**：200 条档 p95 **7.108 → 10.050ms**、超预算
   **0.0% → 20.0%**。懒栈把成本从「挂载 + 命中」搬到了「滚动时现建行」。
   → 「单主机端口转发列表」
9. **换懒栈在小规模档不是白拿的**：快捷命令日志 200 条档 p50 1.88 → 2.68ms、
   p95 2.59 → 3.68ms —— 拿 1.1ms 的帧换 9ms 的挂载 + 667µs 的每次鼠标移动，划算，
   但要如实记。3000 条时才两头都赢。→「快捷命令执行日志」
10. **预览窗口不能换懒栈**：`1a0bd63d`「修复窗口缩放时的布局卡死」已经把这里的
    `LazyVStack` 换回 `VStack`，`MarkdownRendererTests` 至今钉着；「外层 `LazyVStack`
    只对顶层块」这条处方与该历史结论冲突，**按历史结论办**，改成分段渲染。
    → 「预览窗口 Markdown」
11. **Shell 网格贴底跟随的替代路全部同档或更差**：`scrollTo(edge: .bottom)`、
    `.defaultScrollAnchor` 两档、行戳 `.equatable()` 门控、`.textSelection` 提到整格、
    `lineLimit(1)`、50 行分块、尾窗 400/120/60 —— 逐条读数在变体表里。
    → 「并行执行 · Shell 网格」
12. **「`TimelineView` 降到 1Hz」「`scrollKey` 改用计数」两条原倾向被读数推翻**：
    10Hz 唤醒是 1 拍之差 / 0.05s CPU，字符串拼戳是 14µs。→「并行执行 · AI 泳道…」
13. **渲染窗口压不下「点开面板要等的那一下」**：同一份 1000 条会话，上限 25 / 50 / 200 / ∞
    的挂载是 1335 / 1313 / 1132 / 839ms，而文档高度 7182 / 18913 / 53961 / 260001 ——
    几何被钳住了，挂载没有。→「Agent 消息流」反例表
14. **两条原设想没有做的必要**：「传输浮层行去 `Button`」（1000 行 p95 2.69ms / NSView 37，
    `LazyVStack` 已经压住）与「给进度写入加第二层节流」（源头 emitter 已把每路钉在 4Hz，
    再加一层是死代码，还会弄红两条「迟到进度」同步用例）。→「SFTP 传输进度…」

### 三、夹具够不到的（是边界，不是结论）

15. **真拖拽端到端跑不通**：`NSDraggingInfo` 造不出来。拖入契约只能靠
    `RemoteRowDropDelegate` 的落点换算与分派做单元闸门，改成整表一个目标之后建议
    手工验一次「跨 SFTP 标签把文件拖进目录 / 拖到 `..`」。→「SFTP 文件表…」
16. **`accessibilityPerformPress()` 在本工程的 `UDToggle`（`Button(.plain)` 包装）上
    返回 true 却不触发 action**，实测按不动；合成 `NSEvent` 更不行。开关的契约测试退到
    「改模型 → AX 动作文案当场跟着翻」的活绑定判据。→「全局端口转发窗口」
17. **SwiftUI 手势只认真实光标**：行为闸门走 `accessibilityPerformPress` 与
    `NSAccessibilityCustomAction`，**不是**合成 `NSEvent`（改前那版 `Button` 同样点不动，
    是夹具边界不是回归）。→「欢迎页服务器列表行」
18. **tooltip 验不了**：合成事件驱动不了 `NSToolTipManager`。人肉验要进入行之后**完全
    静止**数到 2 秒（每收一次 mouseMoved 就重置计时器）。→「欢迎页服务器列表行」
19. **SSH config 复核页的 `review` 相位进不去**（要走 `NSOpenPanel`，`phase` 是私有
    `@State`），量的是同形状替身，真视图那一侧只有编译期保证。→「SSH config 导入复核表」
20. **`opacity(0)` 的视图不进 AX 树**：铅笔 / 编辑删除按钮改前改后都读不到，
    本轮没让无障碍变好也没变差。→「全局 / 单主机端口转发」

## 探针纪律：会让读数说谎的坑

按「踩到就会得出错误结论」排，不按发现顺序。各视图段里引用它们时用 P 编号。

- **P1 · `@State` + 换 `rootView` 驱动不了 body 重跑。** 同类型的根视图换上去时 `@State`
  被保留、新初值被丢弃，数组又 `==` 相等，于是一次 body 都没重跑 —— 量到的 0.09ms 是
  「什么都没发生」。要用 `@Observable` 盒子。
- **P2 · SwiftData 探针的三条（同一族，一起记）。**
  1. **多档的 `ModelContainer` 必须在挂第一个视图之前全部建好。** 拆完上一档的窗口再
     `ModelContainer(...)` 会 SIGTRAP 在 `SwiftData → _SwiftData_SwiftUI →
     NSNotificationCenter` 上（上一个 `@Query` 的观察者还挂在通知中心里）。xcresult 里
     只有一句「Restarting after unexpected exit」，崩溃栈要去
     `~/Library/Logs/DiagnosticReports/uTerm-*.ips` 里读。
  2. **内存库一律 `ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)`。**
     不关的话 `NSCloudKitMirroringDelegate` 会为新插入的上千条记录排导出任务，在沙盒里
     连不上 cloudd、反复重试，把用例挂住 **~100 秒**（日志里成片的 `CKError "Service
     Unavailable"`）。关掉之后 `testSessionDropdownFetchLimit` 从 **100.1s → 0.1s**。
  3. **换档时 `ModelContext.save()` 会把测试宿主打没。** 上一档的宿主视图刚拆、
     `_SwiftData_SwiftUI` 的 `@Query` 观察者还没散时存盘，SwiftData 在通知回调里
     `EXC_BREAKPOINT`。解法：所有档的数据在挂第一个窗口**之前**一次造完；契约测试里每条
     用例建窗前先 `closeAllWindows()` + 转 0.25s runloop。另外造数据要用
     `container.mainContext`（`.modelContainer(_:)` 把 `@Query` 接的正是它），另起
     `ModelContext` 会让探针与视图拿到两套实例。
- **P3 · AX 树里只收 `accessibilityLabel` 读不到纯 `Text`。** SwiftUI 的静态文本把内容放在
  `accessibilityValue` / `accessibilityTitle` 上，只有显式 `.accessibilityLabel(...)` 过的
  元素才有 label。「找不到元素」不等于「元素不存在」。
- **P4 · SwiftUI 的 `.accessibilityAction(named:)` 不进 `accessibilityActionNames`。**
  它在 AppKit 侧落成 `NSAccessibilityCustomAction`（`accessibilityCustomActions()`），
  标准动作名里只有 `AXPress` / `AXScrollToVisible`。另外 `accessibilityValue()` 在
  `AnyObject` 上有多个重载、直接调是 ambiguous，要走 selector 取值。
- **P5 · 预置历史 = 跟随根本没开。** Shell 网格第一版给每台预置 700 行再流 500 行，读数
  15.69ms 看着还行 —— 其实 `tail-gap` 是 14487pt：窗格 `onAppear` 那一发 `scrollTo` 赶在
  首次布局之前落空，紧接着 `onScrollPhaseChange` 的 `.idle` 用「内容一万多 pt、可见区在
  最顶上」算出 `isNearBottom == false`，`followsTail` 就此永久为假。**探针必须打印
  `tail-gap` 并断言它**，否则量的是另一条路（真实场景里命令刚开跑 `lines` 是空的，
  所以探针也从空开始）。
- **P6 · `proxy.scrollTo` 收的是非可选 `Hashable`。** 传 `UUID?` 会让 ID 类型变成
  `Optional<UUID>`，与 `ForEach` 注册的 `UUID` 永不相等 —— **静默不滚**，读数漂亮得像修好了
  （p50 11ms），`tail-gap` 一看 29146pt 才露馅。
- **P7 · 整类一起跑会把读数抬一档。** Shell 网格那条用例单跑 14.96ms vs 整类 22.87ms，
  `rss` 从 160MB 涨到 221MB。**前→后对照一律单跑。**
- **P8 · 静止窗口只量「相邻两拍的墙钟间隔」量不到东西。** 窗口 `alphaValue = 0` 时 CA 不会
  每帧替我们跑 SwiftUI 的更新，1000 行与 50 行读到的间隔一模一样（p50 9.08 / max 10.5ms）。
  每拍显式 `layoutSubtreeIfNeeded()` 交付一次才看得见；而**真正的判据是拍数**（1000 行档
  28/375），单拍耗时的 p99/max 反而看不出来（开销落在 runloop 里，不在那一次交付里）。
- **P9 · 数据源不变 ⇒ SwiftUI 什么都不做。** `@State` 的写入带相等性比较，注入一份恒定的
  流量快照时 `traffic = stats` 根本不触发重求，读到的 idle 开销假性为 0。探针必须让累计
  字节**真的涨**（`mutateSource`，在计时区间外调用）。
- **P10 · 滚到底不能一步跳到 `maxOffset`。** 懒栈先估后修、行高还不一（失败行多一条原因条），
  一次性跳过去时 documentView 高度还是估的、落点根本没到末尾，「最后一条规则」读不到 ——
  一屏一屏往下走、每步交付一次布局才行（`ForwardingListContractTests.scrollToBottom`）。
- **P11 · 队列的排列顺序决定了 `applyProgress` 是不是 O(n)。** 第一版探针用
  `blockTransfers` 直接挂起 N 条，活动条正好排在数组最前面，`firstIndex` 一步就命中 ——
  读到「历史 20 条与 1000 条一样快（ratio 1.0×）」，差点得出「没问题」的错误结论。
  改成「先跑完 N 条留在数组里、再挂起 4 条」（`makeAgedQueue`）之后，35× 才显出来。
- **P12 · 把用户的真光标挡在窗外，也把用户那笔账挡掉了。** 之前每个探针都断言
  `ProbeWindow.blindsRealMouse`（谎报鼠标在窗外），理由正确 —— 真光标一参与，读数就取决于
  这轮跑测试时鼠标停在哪块屏（见 `ProbeWindow` 顶部那张 uTable 的表）。但**用户是用手滚的
  轮，滚的时候光标必然压在列表上**，于是每一行经过指针都真的触发一次 `.onHover`。
  挡光标的探针把这一整笔开销量成了 0。用 `.transparentOnScreen(cursorAt:)` 谎报一个
  **固定在内容区里**的合成光标，同一个夹具的单帧 p50 就从 1.38ms 变成 10.00ms
  （全局转发 1000 行）—— 这不是噪声，是之前从来没量过的一档。
  合成光标同样与用户真光标无关，所以可复现性没有丢（断言换成
  `ProbeWindow.reportsSyntheticCursor`）。

## 通用读法（欢迎页 / 命令面板那一轮攒下的四条）

1. **形态可移植，量级不一定可移植** —— **探针是去确认，但确认的是这一处的量级**。
   （读数与出处见「与 uTable 结论不同之处」2。）
2. **`.help` 悬停门控不是万能刀**：它值钱的前提是「行常驻且行内 tooltip 挂在自建
   平台视图上」。（读数与出处见「与 uTable 结论不同之处」3。）
3. **先看 body / 行体里有没有循环，再数元件。** 侧栏（12 万次 SwiftData
   属性读）与命令面板（一次 body 两遍 filter+dedupe+group）都不在
   「一行挂几个控件」的模型里，而且都是这一轮最大的两笔。
4. **`@Model` 的计算属性可能藏着 `JSONDecoder`。** `QuickCommandRun.results`
   看起来只是个属性，实际每 get 一次解一次 JSON（45µs / 行）。
   SwiftData 的普通属性读本身也不便宜（约 0.4µs），循环里别重复读。

## 各视图判定

<!-- 每个视图一段，按下面这个形状写：

### <视图名>（`<文件路径>`）

- **规模**：真实档 N（来源：……），极端档 M（来源：……）
- **读数**：

  | 档 | 挂载 | 拍数/375 | 单帧 p50 | 单帧 p95 | 超 8.33ms | hitTest p50 | NSView |
  |---|---|---|---|---|---|---|---|

- **判定**：A / B / C，理由……
- **改法**：……
- **前→后**：同一轮对照……
- **探针类名**：`uTermTests/.../XxxScrollCostTests.swift`
- **没做到的**：……
-->

### 欢迎页服务器列表行（`uTerm/Features/Welcome/Views/ServerRow.swift`）

- **规模**：真实档 100 台 / 10 组，极端档 2000 台 / 60 组。
  来源 = 用户保存的主机数。`~/.ssh/config` 导入是产品功能
  （`WelcomeView.handleConfigDrop`），一个运维团队把内网机器灌进来上千台是真实的。
  Tweaks 假数据工厂把上限钳在 50（`MockServerFactory.swift:28`）是**调试旋钮**
  的上限，不是数据的上限 —— 探针不走工厂，直接构造 `ServerProfile` 数组。
- **形态**：`ScrollView + LazyVStack + ForEach`（本来就是懒栈），
  每行一个 plain `Button` + `onHover` + 双击手势 + **两个常驻 `.help`**
  + `UDHostDot` + `onDrag`/`DropDelegate` + `contextMenu`。
  **`UDHostDot` 的 `repeatForever` 脉冲不用管**：`pulse:` 只在 `isSelected`
  时为真（全列表至多一行），而且 `UDHostDot` 自己还判了
  `accessibilityReduceMotion`，本轮读过源码后不动它。
- **读数**（三臂 ABBA 两遍均值，Debug、真窗口屏内 alpha0、900×620 视口、
  往返幅度钳 ≈3 视口）：

  | 规模 | 臂 | 挂载 | 拍数/375 | 帧 p50 | 帧 p95 | 超 8.33ms | hitTest p50 | NSView |
  |---|---|---|---|---|---|---|---|---|
  | 100 台 / 10 组 | legacy | 3.48ms | 317 | 4.621ms | 7.034ms | 1.0% | 401µs | **91** |
  | 100 台 / 10 组 | helpGated | 3.24ms | 309 | 4.239ms | 7.384ms | 2.0% | 327µs | **91** |
  | 100 台 / 10 组 | tuned | 4.41ms | 321 | **2.026ms** | **2.770ms** | **0%** | 326µs | **29** |
  | 2000 台 / 60 组 | legacy | 3.01ms | 313 | 4.472ms | 6.956ms | 0.5% | 398µs | **91** |
  | 2000 台 / 60 组 | helpGated | 2.78ms | 305 | 4.726ms | 6.661ms | 1.0% | 396µs | **91** |
  | 2000 台 / 60 组 | tuned | 1.84ms | 320 | **2.320ms** | **3.671ms** | **0%** | 395µs | **29** |

- **判定 B（A/B 边界，如实记）**：改前臂 p95 6.96ms **其实已经过了 A 的闸**
  （≤ 8.33ms、超预算 0.5%、hitTest 不随行数涨、NSView 不随行数涨）。
  之所以还是动手：形态确凿（类名直方图里 `_FocusRingView×51` +
  `KeyViewProxy×11` 常驻，全部来自每行那个 plain `Button`）、改法便宜、
  契约守得住，且把 p95 从预算的 81% 压到 37%。
- **改法**（三刀）：
  1. `Button(action:)` → `onTapGesture` + `onTapGesture(count: 2)`，
     AX 默认动作与具名动作「打开」手工补回；
  2. 两个常驻 `.help` → 新增的 `View.help(whenHovering:_:)`
     （`uTerm/Shared/Views/HoverGatedHelp.swift`）；
  3. `WelcomeFormat.relative` 不再每行现建 `RelativeDateTimeFormatter`，
     改共享 `@MainActor` 实例（与 `QuickCommandFormat` 同一处方）。
- **一条先验被推翻（比任何一次加速都值钱）**：`.help` 悬停门控在这一处
  **零收益** —— `helpGated` 与 `legacy` 的常驻 NSView 完全相同（91 = 91），
  帧时间差在噪声内。tooltip 注册在外层平台视图上，不自建子视图。
  整笔收益来自 `Button`。这条已钉成断言
  （`XCTAssertEqual(hugeGated.views, hugeLegacy.views)`）。
  `.help` 那一刀仍然保留（tooltip 区域按行数收费的成本模型见 uTable
  playbook 第 3 层），但**如实记为「本探针量不到」** —— 合成事件驱动不了
  `NSToolTipManager`。
- **另一条反向读数**：hitTest 三臂都在 326~401µs，**看不出方向**，
  不作为收益记账。「换掉 Button 一定让命中变快」在这里不成立
  （uTable ① 那边是 67 倍，因为那边改前是非 lazy 的 6007 个 NSView；
  这里改前就是懒栈，常驻只有 91 个）。
- **探针类名**：`uTermTests/Features/Welcome/WelcomeServerListCostTests.swift`
  （含改前逐字拷贝臂 `LegacyServerRow`）。
- **行为闸门**：`uTermTests/Features/Welcome/WelcomeServerListContractTests.swift`
  9 条 —— AX label 念出「名称，端点」/ AXButton 角色 / AX 默认动作真的走到
  `onTap` / 具名动作「打开」走到 `onDoubleTap` / 选中态进 AX / 右键菜单与
  拖拽重排接线 / 键盘导航映射 / tooltip 门控 / 共享格式化器。
  走 `accessibilityPerformPress` 与 `NSAccessibilityCustomAction`，
  **不是**合成 `NSEvent`（SwiftUI 手势只认真实光标；改前那版 `Button`
  同样点不动，是夹具边界不是回归）。
- **没做到的**：真鼠标下的悬停 / tooltip / 双击留给人肉验收
  （验 tooltip 必须进入行之后**完全静止**数到 2 秒，`NSToolTipManager`
  每收一次 mouseMoved 就重置计时器）。

### 欢迎页左侧栏（`uTerm/Features/Welcome/Views/WelcomeSidebar.swift` + `Core/Models/ServerFilter.swift`）

- **规模**：真实档 100 台 / 10 组，极端档 2000 台 / 60 组，
  中间插一档 2000 台 / 10 组把「主机数」与「分组数」的贡献分开。
- **尺子不一样**：侧栏**不是滚动屏**（10 组时压根滚不动，硬套滚动探针会撞
  playbook §二·3 的「压根没滚动」）。账在**每次 body 重跑要付多少**，
  而 body 重跑得很勤：搜索框每一次击键要重跑一次，
  **主机列表里按一次 ↑/↓ 也要重跑一次**（`selectedProfileID` 是
  `WelcomeView` 的 `@State`，变了整棵 body 连同侧栏一起重算）。
- **主项不在「行挂几个控件」上**（与 uTable ⑨ 权限屏角色 rail 同一类：
  **先看 body 里有没有循环，再数元件**）：`body` 第一行的
  `ServerFilter.counts` 改前每个 section 各扫一遍 profiles，分组那一段是
  `for g in allGroups { profiles.filter { $0.group == g } }` ——
  2000 台 × 60 组 = **12 万次 `ServerProfile.group` 取值**，
  而 SwiftData 的属性读要走一遍持久化 / 观察机制（实测约 0.4µs 一次）。
- **`counts` 单独称**（同轮 ABBA 两遍均值，p50）：

  | 档 | 空 query 前→后 | 打字中 前→后 |
  |---|---|---|
  | 100 台 / 10 组 | 0.578 → 0.117ms | 1.271 → 0.338ms |
  | 2000 台 / 10 组 | 11.267 → 2.309ms | 25.277 → 6.863ms |
  | 2000 台 / 60 组 | **51.445 → 2.328ms** | **65.607 → 6.941ms** |

  改后不再随分组数涨（2000 台下 10 组 2.309ms vs 60 组 2.328ms），
  这条已钉成结构断言。

- **侧栏端到端一次击键**（**非同轮**：改动停用后单独跑一轮，标注在案）：

  | 档 | 挂载 前→后 | 击键 p50 前→后 | 击键 p95 前→后 | NSView |
  |---|---|---|---|---|
  | 100 台 / 10 组 | 4.26 → 4.52ms | 5.37 → 3.29ms | 10.68 → 8.34ms | 101 |
  | 2000 台 / 10 组 | 3.40 → 3.51ms | 36.71 → 13.43ms | 39.99 → 16.96ms | 101 |
  | 2000 台 / 60 组 | 8.10 → 7.86ms | **93.47 → 21.31ms** | 109.39 → 43.44ms | 301 |

- **判定 B**，两刀：
  1. `ServerFilter.counts` 一趟过（每台主机每个字段只取一次值，分组用字典累加）；
     语义逐字保持 —— 分组键取自 profiles 自身、被 query 全过滤掉的分组仍留在
     字典里且值为 0。探针对着改前的逐字拷贝**逐键比字典**，
     `ServerFilterTests` 另补两条语义闸门。
  2. `WelcomeSidebar.body` 里 `sortedGroups` 只求一次值（改前 `navEntries` 与
     `ForEach` 各求一次 = 每次击键多排一遍序）。
- **探针类名**：`uTermTests/Features/Welcome/WelcomeSidebarCostTests.swift`
  （含改前 `counts` 的逐字拷贝臂）。
- **没做到的**：2000 台 / 60 组仍要 21ms 一击键。剩下的账在
  ① 分组 `ForEach` 仍是非 lazy（60 组 = 301 个常驻 NSView，其中
  `_FocusRingView×76` + `KeyViewProxy×76` 来自 `UDSidebarRow` 的 plain
  `Button` —— 那是 **uAppKit 共享包**、以 uTable 为 canonical，本轮不动）；
  ② `WelcomeSidebarNav.shortcutHint` 每行做一次 `entries.firstIndex(of:)`
  （O(行 × 条目)）；③ 11 个零尺寸快捷键 `Button` 每次 body 重建。

  还有一笔**在侧栏外面、同一类账**的：`WelcomeView.existingGroups`
  （`WelcomeView.swift:100`）每次 `WelcomeView.body` 都扫一遍全部 profiles 取
  `group` 再 Set + sort，实测 **2000 台 / 60 组 1.172ms**（100 台 / 10 组
  0.061ms）；它随每次击键与每按一次 ↑/↓ 重跑，并被传进**每一行**的
  `contextMenu`。本轮没改（它的语义是「profiles 自身出现过的分组名」，
  与 `ServerGroup` 表不是同一份数据，改法要先确认 `GroupStore.reconcile`
  的对齐保证），读数已钉在
  `WelcomeSidebarCostTests.testWelcomeViewPerBodyDerivationsCost`。

### 快捷命令执行日志（`uTerm/Features/Welcome/Views/QuickCommandRunLog.swift` + `Core/Models/QuickCommand.swift`）

- **规模**：真实档 200 条，极端档 3000 条。
  来源 = 该命令近 30 天的执行记录数，**没有任何上限**
  （`QuickCommandStore.retentionDays = 30`，`runs(for:)` 只按时间过滤、
  不 `fetchLimit`；一条每 10 分钟跑一次的巡检命令 30 天就是 4320 条）。
- **形态**：playbook §四 的三层**全占**——非 lazy `VStack + ForEach`、
  每行一个 plain `Button`、每行每次 body 跑 5 次 `JSONDecoder`
  （`results` / `aiRecord` 是「每次 get 都解码」的计算属性，
  折叠态行体里 `allSucceeded` → `failureCount` → `results` ×2 → `aiRecord`）。
- **读数**（两臂 ABBA 两遍均值，640×620 视口）：

  | 规模 | 臂 | 挂载 | 拍数/375 | 帧 p50 | 帧 p95 | 超 8.33ms | hitTest p50 | NSView | RSS |
  |---|---|---|---|---|---|---|---|---|---|
  | 200 条 | legacy | 12.44ms | 310 | 1.884ms | 2.592ms | 0.2% | 1032µs | **429** | ~100MB |
  | 200 条 | tuned | 3.38ms | 314 | 2.684ms | 3.675ms | 0.0% | **365µs** | **29** | ~92MB |
  | 3000 条 | legacy | **251.94ms** | **182** | 14.816ms | 16.275ms | **100%** | **18351µs** | **6029** | 539–758MB |
  | 3000 条 | tuned | **2.26ms** | **319** | **2.062ms** | **2.670ms** | **0%** | **293µs** | **29** | ~250MB |

  解码单独称（同轮 ABBA，200 条，折叠态一行 5 次取值）：
  **45.2 → 2.4µs/行**（9.109 → 0.481ms / 200 行）。

- **判定 B**，三刀：模型侧 `@Transient` 解码缓存（按当前 JSON 串判失效，
  任何写入路径含直接改 `resultsJSON` 都自动作废；不入库，CloudKit schema
  一字未变）、`VStack` → `LazyVStack`、展开头 `Button` → `onTapGesture`
  + 手工 AX（`isButton` + 展开态进 `accessibilityValue` + 默认动作），
  行体里 `results` / `aiRecord` 各只取一次值。
- **最值钱的两个数字不是帧**：挂载 **252 → 2.3ms**（点开一条命令详情就是
  这段等待）与 hitTest **18.4 → 0.3ms**（鼠标在这块面板上动一下就付一次）。
  类名直方图 `_FocusRingView×3000 KeyViewProxy×3000` → 0。
- **一笔反向读数**（与 uTable ⑧ 同形）：200 条档单帧 p50 从 1.88 涨到
  2.68ms、p95 2.59 → 3.68ms —— 非 lazy 那版把行全建好了，滚动时一行不用建；
  懒栈把这笔钱从挂载挪到了每帧。**「换懒栈一定更快」在小规模档不成立**：
  200 条是拿 1.1ms 的帧尾换 9ms 的挂载 + 667µs 的每次鼠标移动，划算，
  但不是白拿的；3000 条时两头都赢。
- **探针类名**：`uTermTests/Features/Welcome/QuickCommandRunLogCostTests.swift`
  （含改前逐字拷贝臂与解码两臂）。
- **行为闸门**：`uTermTests/Features/Welcome/QuickCommandRunLogContractTests.swift`
  —— AX 默认动作真的展开 / 收起、展开后逐台结果进 AX 树、概览文案与解码结果
  一致、源码形态。解码缓存的语义闸门（写入后读到新值、绕过 setter 直接改
  JSON 后缓存作废）在 cost 测试里。

### ⌘K 命令面板（`uTerm/Features/CommandPalette/CommandPaletteModel.swift`）

- **规模**：真实档 300 项，极端档 2000 主机 + 200 远程命中 = 2200 项。
  来源 = 静态项（每台主机一条 + 命令 / 设置项，`WelcomeView.welcomeCommandItems`）
  ＋ 远程搜索命中（上限 200）。
- **判定分两半**：
  - **视图层判 A，一行不改。** `UDCommandPalette` 的结果区本来就是处方形态
    （`LazyVStack` + `onTapGesture` + 手工 AX），常驻 NSView 在 300 项与
    2200 项下**都是 15**，不随候选数涨。
  - **模型层判 B。** `sections` / `results` / `selectedItemID` 三个计算属性
    互相嵌套：`results` 读一遍 `sections`、`selectedItemID` 又读一遍
    `results`；而 `CommandPaletteHost.paletteOverlay` 一次 body 就要读
    `sections` + `selectedItemID` = **两遍**完整的 filter + dedupe + group，
    按一次 ↑/↓ 再两遍。
- **模型侧派生单独称**（同轮 ABBA 两遍均值，p50）：

  | 档 | 一次 body 前→后 | 一次 ↑/↓ 前→后 |
  |---|---|---|
  | 300 项 | 0.527 → 0.000ms | 0.529 → 0.000ms |
  | 2200 项 | **4.041 → 0.000ms** | **4.070 → 0.000ms** |

- **真面板端到端**（**非同轮**：改动停用后单独跑一轮，标注在案）：

  | 档 | 挂载 | 击键 p50 | 击键 p95 | ↑↓ p50 | NSView |
  |---|---|---|---|---|---|
  | 302 项 前 | 1.69ms | 3.245ms | 8.488ms | 3.885ms | 15 |
  | 302 项 后 | 1.63ms | 3.199ms | 7.306ms | **2.706ms** | 15 |
  | 2202 项 前 | 1.53ms | 9.230ms | 12.162ms | **10.673ms** | 15 |
  | 2202 项 后 | 1.44ms | **7.094ms** | **9.510ms** | **2.399ms** | 15 |

- **改法**：`sections` / `results` 从计算属性改成「一次求值存下来」，
  唯一求值点是私有的 `rebuild()`；`selectedItemID` 保持计算属性（只做一次下标）。
  `query` 改成 `private(set)`，外部只能经 `setQuery` —— 直接赋值会绕过
  `rebuild()`。`open` / `close` / `setQuery` / 异步搜索回填四条路径各调一次。
- **探针类名**：`uTermTests/Features/CommandPalette/CommandPaletteCostTests.swift`
  （含改前三个计算属性的逐字拷贝臂）。
- **行为闸门**：`uTermTests/Features/CommandPalette/CommandPaletteDerivationContractTests.swift`
  5 条一致性闸门。既有 `CommandPaletteTests` 的 31 条一条没动、全绿。
- **没做到的**：2202 项每次击键仍要 7.1ms。剩下的是那一次必须做的
  `rebuild()`（filter 要走 2200 次三段 `lowercased().contains`）加 SwiftUI
  的重排。真要再往下得给 filter 预算小写化的 title/detail，
  或把搜索挪出主线程。

### 单击延迟：三处列表的手势消歧（2026-09-08）

用户报「单击要等一下才选中 / 才激活」，三处：欢迎页服务器列表、工作区侧栏文件树、
SFTP 独立窗口文件表。

- **根因**：三处行都写成
  ```swift
  .onTapGesture(count: 2) { open() }
  .onTapGesture        { select() }
  ```
  两个 tap 手势互斥，SwiftUI 必须先等满系统双击间隔（「按键与鼠标」里的双击速度，
  默认 ≈0.5s）确认「不会有第二下」才把单击发出去。上一节里那条「改前改后一样、
  不是性能问题」的注记只说对了一半 —— 它确实不是渲染成本，但它是**用户感知到的
  延迟**，而且能消掉。欢迎页改成 `onTapGesture` 之前是 `Button +
  simultaneousGesture(双击)`，单击即时；那一轮把 `Button` 摘掉时把这条一起弄丢了。
  `FileBrowserView` 注释里「不能用 `simultaneousGesture(count: 2)`：那让单 / 双都
  触发」的顾虑是对的 —— 但正确的出路是绕到 AppKit，而不是接受延迟。
- **改法**：`NSEvent` 自带 `clickCount`（第一下就是 1、第二下就是 2），系统已经替
  我们做完消歧且第一下不用等 —— 原生 `NSTableView` 就是这么做的。新增
  `uTerm/Shared/Views/ClickSelectActivate.swift`：一个 `hitTest` 返回 `nil`、
  用 `NSEvent` 本地监视器旁观 `leftMouseDown` 的透明层，`.clickToSelect(select:activate:)`
  挂在承载行的 `LazyVStack` 上（与整表 `.onDrop(delegate:)` 同一处、同一套坐标）。
  落点 → 行号：固定行高的两个文件列表直接复用 `RemoteRowDropTargeting.target(atY:)`；
  欢迎页行高是内容撑出来的，用 `UniformRowHit` 从容器高度反推（等高、行间距 0）。
- **为什么是容器级而不是逐行**：`UAppKitBridge` 的 `.onPointerDown` 是同款思路，但
  逐行挂 = 每行一个平台视图 + 一个全局事件监视器，会把 20000 条目档的常驻 NSView
  从 18 拉回几百（就是 `.onDrop` 逐行挂那一版的老账）。容器级整份列表只有一个。
- **保住**：`.onDrag` 拖拽会话、`.contextMenu` 右键、`.onHover` 悬停高亮、
  `.accessibilityAction` 默认动作 / 具名「打开」、`.focusable` 键盘导航 —— 事件原样
  放行、命中测试完全透明，这些都没碰。
- **一条配套守卫**：两个文件列表里「第二下只认第一下刚选中的那一行」
  （对齐 `NSTableView` 的 doubleAction）。因为第一下有可能就把列表换掉 ——
  在 `/a/b` 双击 `..` 回根目录时 `showParent` 变 false，同一个 y 于是落到新列表的
  entry 0 上，没有守卫就会顺手把它打开。

#### 读数（2026-09-08，同机同轮，`FileBrowserProbeRig.click`）

| 一次单击选中（20000 条目） | 改前（main 612f6102） | 改后 |
|---|---|---|
| 工作区侧栏文件树 | 394.85ms | **38.00ms** |
| SFTP 文件表 | 629.54ms | **109.20ms** |

这把尺子是 20ms 一步轮询像素，所以「改后」那两个数是**采样粒度**，不是真延迟；
真延迟在 `ClickSelectActivateTests` 里量：`NSApp.sendEvent` 一返回，选中状态
**同步**已经变了（欢迎页 0.98~3.54ms、文件表 1.40~2.76ms、侧栏 0.23~1.35ms，
全是事件派发本身的开销）。

结构闸门（同轮，两档都取）：

| 视图 / 档 | NSView 改前 | NSView 改后 |
|---|---|---|
| 侧栏 500 / 20000 | 18 / 18 | 20 / 20 |
| 文件表 500 / 20000 | 51 / 51 | 53 / 53 |

**+2 且不随行数涨**（一个 `AppKitPlatformViewHost` + 那一个 `RowClickLayerView`）。

#### 探针 / 闸门类名

- `uTermTests/Shared/ClickSelectActivateTests.swift` —— 三处各一条「按下即选中」+
  「第二下才打开且只打开一次」，落点换算纯算术单测，极端档滚到中段的命中复核，
  以及「点击层只有一个」的结构闸门。
- 源码闸门改成钉行为：`WelcomeServerListContractTests` /
  `WelcomeEqualPaddingLayoutTests` 原先钉的是 `.onTapGesture { onTap() }` 这个字符串，
  现在钉「行里没有点击手势 + 容器层接线在 + AX 默认动作在」。
- `FileBrowserProbeRig.click` 改走 `NSApp.sendEvent`：本地事件监视器是
  `NSApplication` 派发的，原先的 `window.sendEvent` 绕过 `NSApp` 就收不到。

### SFTP 独立窗口文件表（`uTerm/Features/SFTP/Views/SFTPFileTable.swift`）与工作区左侧栏文件树（`uTerm/Features/Files/Views/FileBrowserView.swift`）

两个视图共用一份 `FileBrowserModel` 数据、同一套行形态（`ScrollView + LazyVStack +
ForEach`，每行：双击 / 单击两个 `onTapGesture` + `onDrag` + `contextMenu(SFTPRowMenu)` +
`hoverBackground` 的 `onHover` + 目录行 `onDrop` + AX 四件套；文件表另有权限 chip 的
`.help`），所以一起评估。

- **规模**：`FileBrowserModel.swift` 的 `entries = try await provider.list(path:)`
  **全量发布、无截断**，所以列表长度 = 远端目录真实条目数。
  真实档 500（普通项目目录），极端档 20000（`node_modules` / `/usr/bin` 量级），
  另有「5 个 SFTP 标签同时挂载」一档（`SFTPWindowView.swift` 的
  `ZStack + ForEach(tabs)` + opacity 显隐）。
  探针用 `MockSFTP` 假 provider 注入目录，`FileBrowserModel(testProvider:startPath:)` +
  `refresh()`，挂载的是**真** `SFTPBrowserView` / `FileBrowserContent`。

#### 读数（2026-09-07/08，M-series MacBook Pro，Debug，`.transparentOnScreen`）

跨视图结论一律取 **A/B/B/A 交替**那一轮（`FileBrowserInterleavedComparisonTests`）——
同一个测试进程里先跑的那一档系统性偏慢（归因矩阵首轮 p50 5.37ms → 末轮 3.41ms，
而结构读数证明末轮只多不少）。

改前 / 改后，20000 条目，交替四轮：

| 轮次 | NSView | 单帧 p50 | 单帧 p95 | 超 8.33ms | hitTest p50 |
|---|---|---|---|---|---|
| 侧栏（改前） | 258 | 6.146 / 6.194ms | 8.275 / 8.221ms | **4.5% / 3.5%** | 582 / 454µs |
| 侧栏（改后） | **18** | 4.211 / 3.993ms | 5.330 / 5.607ms | **0.0% / 0.5%** | 376 / 397µs |
| 文件表（改前） | 177 | 4.989 / 5.126ms | 6.854 / 7.197ms | 0.0% / 0.5% | 457 / 452µs |
| 文件表（改后） | **51** | 2.735 / 2.965ms | 3.957 / 4.182ms | 0.0% / 0.0% | 405 / 412µs |

单档（各自拆窗）：

| 视图 / 档 | 挂载 | 拍数/375 | 单帧 p50 | 单帧 p95 | 超 8.33ms | hitTest p50 | NSView |
|---|---|---|---|---|---|---|---|
| 侧栏 500（前 → 后） | 6.03 → 3.25ms | 302 → 311 | 5.645 → 4.448 | 8.030 → **5.927** | 2.5% → **0.0%** | 555 → 531µs | 162 → **18** |
| 侧栏 20000（前 → 后） | 3.34 → 2.61ms | 308 → 309 | 6.540 → 4.343 | 8.813 → **5.550** | 8.0% → **0.0%** | 536 → 375µs | 258 → **18** |
| 文件表 500（前 → 后） | 5.09 → 5.97ms | 310 → 318 | 4.979 → 3.095 | 7.040 → **3.797** | 0.0% → 0.0% | 451 → 409µs | 177 → **51** |
| 文件表 20000（前 → 后） | 5.06 → 4.15ms | 306 → 316 | 5.093 → 3.090 | 6.810 → **3.860** | 0.0% → 0.0% | 450 → 404µs | 177 → **51** |

交互端到端（20000 条目）：

| 项 | 改前 | 改后 |
|---|---|---|
| 一次筛选击键（文件表） | 112.5 / 129.7ms | **67.4ms**（其中扫全表 15.0ms、SwiftUI 重建 ≈52ms） |
| 一次单击选中（两个列表） | 延迟 390 / 504ms，像素 delta 0.045 / 0.047 | 延迟 386 / 509ms，像素 delta 不变 |

5 标签同时挂载（500 条目 / 标签，对照 1 标签，同一轮）：

| 档 | NSView | 挂载 | RSS | hitTest p50 | 单帧 p95 | 超 8.33ms |
|---|---|---|---|---|---|---|
| 1 标签（前 → 后） | 177 → **51** | 5.86 → 4.69ms | 125 → 129MB | 451 → 414µs | 7.90 → 3.72ms | 1.0% → 0.0% |
| 5 标签（前 → 后） | 637 → **311** | 22.95 → 21.11ms | 157 → 156MB | 512 → 543µs | 7.17 → 4.62ms | 1.0% → 0.0% |

#### 判定：B（SwiftUI 就地修）

- **文件表本来就在 A 的线内**（20000 条目 p95 6.85ms、超预算 0.0%、hitTest 不随规模涨：
  500 与 20000 完全相同的 177 个 NSView / 450µs）。
- **侧栏越线**：超 8.33ms 的帧 3.5~8.0%（A 的线是 ≤2%），p95 8.2~8.8ms。
  交替对照排除了「先跑的偏慢」这个混淆。
- 没有升到 C：**病灶是一个具体的行内修饰器**，摘掉它两个视图都回到线内，
  不需要重写渲染方式。

#### 病灶归因（探针量出来的，不是猜的）

先用一份与真行同形状的**合成行**逐个把修饰器加回去（`FileBrowserRowAttributionTests`，
20000 条目）：

| 档（累加） | NSView | tracking area |
|---|---|---|
| base（纯 Text + 图标） | 29 | 1 |
| +两个 `onTapGesture` | 29 | 1 |
| +`hoverBackground`（`onHover`） | 29 | 2 |
| +AX 四件套 | 29 | 2 |
| +`contextMenu(SFTPRowMenu)` | 29 | 2 |
| +`.help` | 29 | 3 |
| +`onDrag` | 29 | 3 |
| **+目录行 `onDrop`** | **51** | 3 |

结论：**行内唯一会长出平台视图的是 `onDrop`** —— 每个挂它的行常驻一对
`_PlatformDraggingDestinationView` + `AppKitPlatformViewHost<…DraggingDestinationView>`，
而 `LazyVStack` 的行一经实例化就不释放，滚一遍就攒满。侧栏 20000 条目滚完
攒下 **122 对 = 244 个 NSView**（整棵树 258 个）。

两条**被推翻**的先验：

- `hoverBackground` 的 `onHover` **不是**每行一个平台节点：tracking area 全程
  恒 1~3 个（整个列表一个），与行数无关。
- 行内 `.help` 在这个规模下**量不出来**：结构上 0 个平台视图、0 个 `toolTip != nil`
  的视图；同轮 A/B/B/A（`testRowHelpAtTableGeometry`）p50 4.22 / 4.30 / 4.49 / 2.40ms、
  超预算 1.0 / 0.0 / 0.5 / 0.0% 全在噪声里；第二次重跑四轮全是 0.0~0.5%，同样分不出来。
  （uTable 权限树那次是**每行数个** `.help` × 上千行，这里是每行一个。所以
  **没有**引入悬停门控 —— 量不出来就别改。）

再用同一几何、同一份合成行做 `onDrop` 的同轮 A/B/B/A（`FileBrowserDropTargetAttributionTests`，
侧栏几何 320×760、行高 30、20000 条目）：

| 轮次 | NSView | 单帧 p50 | 单帧 p95 | 超 8.33ms |
|---|---|---|---|---|
| 无行内 `onDrop` | 29 | 5.473ms | 6.691ms | **0.0%** |
| 有行内 `onDrop` | 67 | 5.980ms | 8.221ms | **3.5%** |
| 有行内 `onDrop` | 67 | 5.771ms | 8.252ms | **3.5%** |
| 无行内 `onDrop` | 29 | 5.198ms | 6.655ms | **0.0%** |

同样的行、同样的几何，只差一个修饰器，超预算 0.0% ↔ 3.5% 两两复现；
改完之后第三次重跑同一条探针又复现一次（0.0% / 0.5% 对 2.0% / 3.5%）。定案。

#### 改法

1. **每行 `.onDrop` → 整表一个 `DropDelegate`**（`uTerm/Features/Files/RemoteRowDropTargeting.swift`）。
   落点纵坐标按**固定行高**换算成行号（文件表 52 / `..` 46，侧栏两者都是 30），
   `dropUpdated` 逐点复核「这一行收不收货」，所以拖入契约（只有目录行与 `..` 行收货、
   文件行光标显示禁止）与逐行挂 `.onDrop` 时一致。
   行高改成 `SFTPFileTable.rowHeight/parentRowHeight`、`FileBrowserContent.rowHeight`
   常量，与行的 `.frame(height:)` 同源，并有闸门钉住。
   **侧栏那处必须挂在 `.padding(.vertical, 2)` 之前** —— 落点坐标是修饰器所在视图的
   局部坐标，挂在 padding 之后会整体偏 2pt。
2. **`SFTPBrowserView` 的 `visible` / `selected` 记忆化**
   （`uTerm/Features/Files/RemoteEntryFilter.swift`）。原来 `visible` 是 computed
   property，一次 body 求值跑**三遍**全表 `localizedCaseInsensitiveContains`
   （文件表 `entries:` 一遍、检视器经 `selected` 一遍、状态栏 `selectedCount` 再一遍）。
   key 用「整份 `sortedEntries` 值 + 筛选词」——`Array ==` 先比缓冲区身份，
   没变是 O(1)，变了必然是新缓冲区必然重算，不会出现「指纹相同但内容变了」的漏判。

#### 量出来但**没有**改的

- **5 个标签同时挂载**（`SFTPWindowView.swift` 的 `ZStack + ForEach(tabs)` + opacity）。
  改后 5 标签 NSView 311（1 标签 51）、挂载 21.1ms、RSS +27MB、hitTest +31%，
  但**单帧 p95 4.62ms、超预算 0.0%**，滚动完全在线内。要让非活动标签不挂载，
  就得把 `SFTPBrowserView` 的 5 个跨标签 `@State`（`history` / `hIdx` / `selectedID` /
  `query` / `inspectorWidth`）搬进每标签一个的引用类型，还要重新安排
  `SFTPBrowserContainer` 里 `.task(id:)` 的连接生命周期（现在非活动标签也在后台连）。
  代价与风险都在「量不出问题」这一边，按「先量后改」不动。数字留在
  `SFTPFileTableScrollCostTests.testMultipleTabsMountedAtOnce` 里当尺。
- **筛选击键剩下的 ≈52ms**。67.4ms 里扫全表只占 15.0ms，其余是 SwiftUI 重建
  `ForEach`（第二次击键把结果集从 6878 缩到 ~700，仍要 58.4ms，说明它不跟结果集规模走）。
  再往下压要换成 T2 原生自绘 —— 但滚动本身已在 A 的线内，不构成升 C 的理由。
- ~~**单击选中要等 ~390~510ms 才高亮**：……这是系统双击间隔常数，不是渲染成本，
  改前改后一样；记在这里免得下次被当成性能问题。~~
  **2026-09-08 推翻**：那段等待确实不是渲染成本，但它是**可以消掉的**，而且用户
  就是把它当卡顿报上来的。见下面「单击延迟：三处列表的手势消歧」一节。
  探针里的 `repaintMS` 是「等待期间最贵的那一步布局」，取的是采样最大值，
  SwiftUI 的异步更新可能整个落在两次采样之间，**方差很大、不作判据**。

#### 探针类名

- `uTermTests/Features/SFTP/FileBrowserScrollCostTests.swift`
  - `SFTPFileTableScrollCostTests`（文件表两档 + 交互端到端 + 5 标签）
  - `FileBrowserSidebarScrollCostTests`（侧栏两档 + 单击）
  - `FileBrowserInterleavedComparisonTests`（两视图 A/B/B/A 交替）
  - `FileBrowserRowAttributionTests`（行内修饰器归因矩阵）
  - `FileBrowserDropTargetAttributionTests`（`onDrop` 与 `.help` 各自的同轮 A/B/B/A）
- 行为闸门：`uTermTests/Features/Files/RemoteRowDropTargetingTests.swift`（拖入契约 +
  行高常量同源）、`uTermTests/Features/Files/RemoteEntryFilterTests.swift`（筛选语义 +
  「同一份数据同一个词不重扫」）

#### 没做到的

- 没量 VoiceOver / 全键盘控制下的实际表现（AX 树本来就在，改动没碰它）。
- 拖入 / 拖出的**真拖拽**没有端到端跑通（`NSDraggingInfo` 造不出来）；契约靠
  `RemoteRowDropDelegate` 的落点换算与分派做单元闸门，加上 `onDrag` 一侧未改动。
  换成整表一个目标之后，建议手工验一次「跨 SFTP 标签把文件拖进目录 / 拖到 `..`」。
- 5 标签档只量了 500 条目 / 标签；20000 × 5 没跑（挂载会到秒级，且没有对应的真实场景）。

### SFTP 传输进度写路径 + 传输 Dock / 浮层（`uTerm/Features/Files/FileBrowserModel.swift`、`uTerm/Features/SFTP/Views/SFTPTransfersDock.swift`）

- **规模**：
  - 并发数 = `FileBrowserModel.maxConcurrentTransfers`（`sftpMaxConcurrentTransfers`，
    默认 **4**，钳 1…**64**）。真实档 4 路，极端档 16 路。
  - 队列长度：传输行**不会自动清**（`.done` / `.failed` 留着等用户点「清除已完成」），
    所以「历史 1000 条 + 4 条在飞」是能攒出来的真实形态。浮层行数取 1000。
- **先纠一条前提**：「100MB/s ÷ 32KiB ≈ 每秒 3200 次进度回调」是**旧账**。
  `SFTPSession` 的四条传输路径全都走
  `TransferProgressEmitter(totalBytes:minimumInterval: 0.25)`（首块与完成必达，
  中间按时间节流），也就是**每路每秒最多 4 次**（emitter 落在 commit `90f89177`）。
  探针两个频率都量了：`throttled` = 每路 4Hz（真实），`raw` = 每路 800Hz（假设没有 emitter）。
- **读数**（2026-09-08，Debug，`.transparentOnScreen`）：

  | 量 | 前 | 后 |
  |---|---|---|
  | 一次 `applyProgress`（历史 20 条） | 0.00202ms | 0.00041ms |
  | 一次 `applyProgress`（历史 1000 条） | **0.07064ms** | **0.00034ms** |
  | 「1000 条 / 20 条」比值 | **35.0×** | **0.8×** |
  | 状态栏芯片一次派生（20 条） | 0.01338ms | 0.00168ms |
  | 状态栏芯片一次派生（1000 条） | **0.55147ms** | **0.07638ms** |

  进度流打在主线程上的代价（3 秒 8ms 心跳，理想 375 拍；芯片 + 浮层同屏）：

  | 档 | 实际回调频率 | 拍数/375 |
  |---|---|---|
  | 4 路 · 真实（emitter 节流） | 13/s | **329** |
  | 16 路 · 真实（emitter 节流） | 53/s | **325** |
  | 4 路 · 假设无 emitter | 1950/s | 209 |
  | 16 路 · 假设无 emitter | 7168/s | 192 |

  传输浮层 1000 行：挂载 2.21ms、单帧 p50 **1.674ms** / p95 **2.688ms**、
  超 8.33ms **0.0%**、hitTest **28µs**、NSView **37**。

- **判定：分成三块**
  1. **浮层列表 → A**。1000 行的 p95 2.69ms、超预算 0%、hitTest 28µs、NSView 恒 37 ——
     `LazyVStack` 已经把它压住了，行里那一两个 `Button` 在这个量级不构成问题。
     **不动**，探针留下当尺。原任务设想的「浮层行去 Button」没有做的必要（也就没做）。
  2. **进度写入频率 → A**。源头 emitter 已经把每路钉在 4Hz；真实档 16 路合计
     53 次/秒，主线程拍数 325/375，和空载没差别。**不再加第二层节流** ——
     那会是死代码，而且 `applyProgress` 目前是同步生效的（`FileBrowserModelTests`
     的两条「迟到进度」用例调完立刻读 `transfers`），改成按显示节拍延迟发布会把它们弄红。
     「无 emitter」那两行读数留在案，是这条结论的依据。
  3. **`applyProgress` 查行 + 状态栏芯片派生 → B**，已改。
- **改法**：
  1. `FileBrowserModel` 加 `transferIndexByID`（`id → transfers 下标`）。
     改前是 `transfers.firstIndex(where:)`，O(队列长度)，而**新起的传输永远排在
     一堆已完成行的后面**，所以那是真实最坏序。增删时重建（低频），
     查行时校验缓存下标处真的是这一条、不是就退回线性扫描并**自愈**。
     `applyProgress` / `updateTransfer` / `retryTransfer` / `startTransfer` 全部改走它。
  2. 新增 `SFTPTransfersDockSummary`：状态栏芯片一次 body 要的六个数一遍扫完。
     改前 `active`（filter）在芯片分支 / 聚合芯片 / 浮层参数里各求一次，
     加上 `doneCount` / `failedCount` / `aggPct`（两次 reduce）/ `aggSpeed`（filter + reduce），
     至少 5~6 遍全表 —— 而每次进度回调都会让这个 body 重求一次。
- **探针类名**：`uTermTests/Features/Files/SFTPTransferProgressCostTests.swift`；
  行为闸门在 `SFTPTransferProgressCostTests.testDockSummaryMatchesTheLegacyScans`
  与 `FileBrowserModelTests` 新增的两条
  （`testProgressStillLandsOnTheRightRowAfterRemovals` /
  `testProgressStillLandsOnTheRightRowAfterClearingFinished`）。
- **没做到的**：
  - 没碰 `entries` / 文件列表相关代码（另一位同事在做 SFTP 文件表）。
  - 每次进度写入仍然会让**整个** `transfers` 的观察者失效（`@Observable` 数组的元素写
    没法只通知一行）。真实频率下这不构成问题（325/375 拍），但如果以后把 emitter 的
    `minimumInterval` 调小、或并发调到 64，就要把「按显示节拍合并发布」重新摆上桌
    —— 那时要一并处理「同步可见」这条契约。
  - 浮层的 `rows` 排序仍是每次 body 重排一遍（1000 行 O(n log n)）；在 A 的读数里
    看不出来，没动。

### Agent 消息流（`uTerm/Features/Agent/Views/AssistantView.swift` · `uTerm/Features/Terminal/Views/TerminalAgentView.swift`）

- **规模**：真实档 200 条消息，极端档 1000 条。来源：`ChatSession` 对消息条数没有任何
  上限（`AgentKit` 里一条消息一行 `ChatMessageRecord`，`AssistantModel.load` 全量映射进
  `messages`），`ContextCompressor` 只裁**进模型的上下文**、不裁视图数组。每条 assistant
  消息 ≈36 个 Markdown 块（标题 / 段落 / 列表 / 代码块 / 表格混排），每 8 条带一张工具卡。
  窗口 420×760（Agent 侧栏的实际宽度量级）。
- **读数**（同一进程、同一轮，两臂靠 `AssistantView.messageWindowLimit` 切换；
  轮内顺序反转；全量前 `caffeinate -dimsu`）：

  | 档 | 挂载 | 拍数/375 | 单帧 p50 | 单帧 p95 | 超 8.33ms | hitTest p50 | NSView | 文档高 |
  |---|---|---|---|---|---|---|---|---|
  | 200 条 · 无窗口 | 882.1ms | 245 | 2.349ms | 7.321ms | 4.5% | 472µs | 802 | 328737 |
  | 200 条 · 窗口 200 | 963.0ms | 244 | 2.414ms | 7.489ms | 4.5% | 614µs | 802 | 321371 |
  | 1000 条 · 无窗口 | 911.7ms | 241 | 2.138ms | 7.785ms | 4.5% | 467µs | 802 | **1588044** |
  | 1000 条 · 窗口 200 | 1092.0ms | 250 | 1.753ms | 7.131ms | 3.5% | 469µs | 803 | **307349** |

  真实档 200 条正好等于默认上限，两臂在那里**是同一件事**（读数一致即为自证）。

  **流式期间**（1000 条打底，20 chunk/s 的假 SSE 追加 12 秒，主线程只跑 8ms 心跳，
  理想 1500 拍）：

  | 臂 | 拍数/1500 | 12 秒里尾消息收到的字符 |
  |---|---|---|
  | 无窗口 | **184** | 4727 |
  | 窗口 200 | **481** | 5547 |

  三轮比值 1.85 / 2.87 / **2.61**（同轮相对比，绝对值跨轮不可比）。

  **每 100ms 一次重解析的增长曲线**（`Document(parsing:)`，不建窗口）：

  | 块数 | 4 | 8 | 16 | 32 | 64 | 128 |
  |---|---|---|---|---|---|---|
  | 字符 | 276 | 557 | 1144 | 2374 | 4784 | 9591 |
  | parse p50 | 0.053ms | 0.169ms | 0.366ms | 0.742ms | 1.491ms | 3.005ms |

  近似线性，≈0.31µs/字符。一条 1 万字符的长回复每 100ms 要付 3ms ≈ 主线程 3%。

- **判定：B**。三条理由：
  1. **滚动本身不随会话总量退化** —— `LazyVStack` 在这里确实回收行：NSView 恒 802/803
     （200 条 vs 1000 条完全相同），钳 3 视口的帧读数两臂一致。所以 uTable AI 面板那组
     「800 条 / 200 条 = 0.40 拍」在 uTerm **不成立**（uTable 那边是非 lazy 的 `VStack`）。
     任务书里「长会话线性增长」这条推断被探针证伪了一半。
  2. **但流式期间被挂载条数拖垮**：每 50ms 一次文本发布（`StreamingTextBuffer`）+ 每 100ms
     一次贴底 `proxy.scrollTo`，每次都要走一遍挂载中的全部消息。1000 条时主线程只剩理想
     心跳的 12%（184/1500），渲染窗口抬回 32%（481/1500）。
  3. 改前**真实档就已经越过 A 线**（超 8.33ms 的帧 4.5% > 2%），本来也判不了 A。
- **改法**（`AgentMessageWindow`）：
  - 渲染窗口 200 条 + 顶部「显示更早的 N 条」（一次放开 200）。
    **只裁渲染不裁数据**：`AssistantModel.messages`、SwiftData 记录、模型上下文一条不动
    （闸门 `testRenderWindowNeverTruncatesTheModel`）。换会话时窗口收回默认值。
  - 五个只做贴底跟随的 `onChange` 合成一个 `ChatTailSignature`（尾消息 id / 正文
    `utf8.count` / 尾消息工具卡 / 追问 / 追问加载中）。正文用长度而不是整串：原生 Swift
    字符串的 `utf8.count` 是 O(1)，也不必每次 body 求值都把一份长文本存进 onChange 的旧值。
  - `.help` 悬停门控（新增 `View.help(whenHovering:_:)`，抄 uTable playbook §四 第 3 层）：
    用户气泡（本就有 `isHovering`）、工具卡命令行、代码块复制钮。
  - 同一形态的终端 Agent（`TerminalAgentView`）套用同一处方。
- **前→后**：流式 1000 条 拍数 **184 → 481 / 1500**（2.61×）；文档高度
  **1588044 → 307349 pt**（5.2×）；1000 条档超预算帧 4.5% → 3.5%、单帧 p50 2.138 → 1.753ms。
  钳 3 视口的滚动读数与 hitTest 在噪声内（**渲染窗口不改善普通滚动，只改善流式与几何**）。
- **反例（留在案，别再走一遍）**：

  | 试过的 | 反向读数 |
  |---|---|
  | `ChatCodeBlock` 的复制 `Button` 换成 `onTapGesture` + 手工 AX | hitTest **473 → 664µs**、NSView **803 → 817**。命中不再早早落在真控件上（与 uTable §五·八③ 同因）；而且整棵消息树套着 `.textSelection(.enabled)`，「复制」二字从按钮标签变成可选文本后，每个在屏代码块反而多长出一个 `SelectionTextField`。**已撤回**，只留 tooltip 门控那一半 |
  | 指望渲染窗口把「点开面板要等的那一下」也压下去 | 同一份 1000 条会话，上限 25 / 50 / 200 / ∞ 的挂载是 1335 / 1313 / 1132 / 839ms，而文档高度 7182 / 18913 / 53961 / 260001 —— 几何被钳住了，挂载没有。那 0.9~1.3s 在 `NSHostingView` 建树与首屏上，不在列表上 |
  | 照抄「整篇一个余弦」量满程甩动 | 改前臂 1.6M pt 的 `LazyVStack` 上跑 200 步满程余弦，**3.5 分钟没跑完、测试 runner 判超时重启**（uTable playbook §七「LazyVStack + 大跨度跳转」那条坑的复现）。改成 8 次顶↔底跳转后两轮读数**反向**（legacy p50 798.9 / windowed 91.9，复跑 77.7 / 2177.3），样本太少判为噪声，只保留「行程」这条结构判据 |

- **`ChatCodeBlock` 的贡献**（1000 条档，同轮：有围栏代码块 vs 换成等长的缩进段落）：
  挂载 **2.33×**（1100ms vs 472ms）、NSView **803 vs 635**、hitTest 1.27×、单帧 p50 1.31×、
  拍数 0.92。代码块那套「横向 `ScrollView` + `fixedSize` + 复制 `Button` + `.help` +
  `textSelection`」是消息流里最大的单块内容成本，但去掉按钮那条路已证伪（见上表）。
- **探针类名**：`uTermTests/Features/Agent/AgentMessageListCostTests.swift`
  （`testMessageListMountAndScrollCost` / `testStreamingMainThreadCost` /
  `testChatCodeBlockChromeContribution` / `testMountCostTracksWindowLimit` /
  `testFullRangeJumpCost` / `testReparseCostGrowsWithMessageLength`）；
  契约闸门 `uTermTests/Features/Agent/AgentMessageWindowTests.swift`。
- **没做到的**：见文末「未决账」1 / 2 / 5。

### Agent 会话历史下拉（`AssistantView.swift` / `TerminalAgentView.swift`）

- **规模**：1000 条 `ChatSession`（每次「新建对话」一条，长期累计）。
- **读数**（`testSessionDropdownFetchLimit`，同一个 1000 条的内存库）：

  | 取法 | 条数 | 耗时 |
  |---|---|---|
  | 无 `fetchLimit`（原写法） | 1000 | **9.5ms** |
  | `fetchLimit = 50`（新写法） | 50 | **0.7ms** |

- **判定**：**B**。`@Query(sort:order:)` 不带 `fetchLimit`，开窗就把整库会话物化成模型对象，
  而下拉浮层只有 280pt 高（约 6 行可见）。
- **改法**：新增 `uTerm/Features/Agent/ChatSessionQueries.swift`，两处下拉共用
  `FetchDescriptor` + `fetchLimit = 50`（排序仍是 `updatedAt` 倒序，取到的就是最近那批）；
  `AssistantView` 的下拉列表 `VStack` → `LazyVStack`。
  **只动了会话下拉那几行**（`AssistantView.swift:83` 与 `:239` 一带、
  `TerminalAgentView.swift:21`），消息流那一带没碰。
- **前→后**：取数 **9.5 → 0.7ms（−93%）**，物化对象 1000 → 50。
- **契约测试**：限量之后第一条仍是最近更新的那条、最后一条是倒序第 50 条。
- **探针类名**：同上（`testSessionDropdownFetchLimit`）。
- **没做到的**：**契约有损** —— 下拉不再列出第 50 条之前的历史会话。
  它是「最近用过的对话」的快速切换器，不是历史归档浏览器；真要翻旧会话得另开入口。

### 预览窗口 Markdown（`uTerm/Features/Preview/MarkdownRenderer.swift` → `Views/Markdown/MarkdownBlocks.swift`）

- **规模**：真实档一份 2000 行 README（实测 1919 行 / 31330 字符 / **600 块**），
  极端档 **2.8MB / 50001 块**（末尾一张 200×6 的表）。来源：预览对 Markdown 只有 50MB 的
  **字节**上限（`FilePreviewModel`），块数没有任何上限。窗口 900×700。
- **读数**（同一进程、同一轮，两臂靠 `MarkdownRenderer.initialBlockLimit` 切换）：

  | 档 | parse | 挂载 | 拍数/375 | 单帧 p50 | 单帧 p95 | 超 8.33ms | hitTest p50 | NSView | 文档高 | RSS |
  |---|---|---|---|---|---|---|---|---|---|---|
  | 极端 · 不分段 | 627.9ms | **43740.6ms** | **22** | **238.6ms** | 251.9ms | **100%** | **142289µs** | 29 | 2359832 | **11292MB** |
  | 极端 · 分段 800 | 566.2ms | **887.0ms** | **298** | **6.275ms** | 7.005ms | **0.5%** | **1761µs** | 30 | 37736 | 479MB |
  | 真实 · 不分段 | 8.6ms | 679.7ms | 316 | 4.311ms | 5.308ms | 0% | 1278µs | 29 | 28258 | — |
  | 真实 · 分段 800 | 6.8ms | 649.3ms | 316 | 4.235ms | 4.761ms | 0% | 1300µs | 29 | 28258 | — |

  注：Markdown 块渲染成 `Text`，**不产生平台视图** —— NSView 在这一处不是有效的成本尺
  （两臂都是 29/30，差的那一个是「继续渲染」按钮壳）。真正的账在文档高度与布局树规模上。
- **判定：B**。极端档不分段时每一帧都超预算（100%）、一次挂载要 43.7 秒、物理足迹
  11.3GB —— 远在任何 A 线之外。
- **改法**（`MarkdownBlockWindow`）：**不能换懒栈**。`1a0bd63d`「修复窗口缩放时的布局卡死」
  已经把这里的 `LazyVStack` 换回 `VStack`，`MarkdownRendererTests`
  `.testMarkdownPreviewCoalescesParsingAndUsesStableBlocks` 至今钉着这条；
  「外层 `LazyVStack` 只对顶层块」这条处方与该历史结论冲突，按历史结论办。
  改成**分段渲染**：`MarkdownBlocks` 加一个 `maxBlocks`（默认 `.max`，不裁）与一个
  「还剩几块」的尾巴回调；`MarkdownRenderer` 首屏挂 800 块，底部「继续渲染（还有 N 块）」，
  换文件时收回第一段。600 块的真实档一次就挂完 —— 常规文件完全无感（比值 0.96~1.00）。
- **前→后**（极端档，同轮）：挂载 **43740.6 → 887.0ms（49×）**、拍数 **22 → 298（13.6×）**、
  单帧 p50 **238.6 → 6.275ms**、超预算 **100% → 0.5%**、hitTest **142289 → 1761µs（81×）**、
  文档高度 2359832 → 37736pt、RSS **11292 → 479MB**。真实档两臂在噪声内。
- **`isStreaming` 写死 `true` —— 量不出问题，不改**：`.preview` 的
  `usesChatCodeBlock == false`，`MarkdownBlocks` 只把这个标志传给 `ChatCodeBlock`，
  预览根本不走那条分支；对预览的渲染结果零影响。改它反而要动一条现存的锁定断言。
  闸门 `MarkdownPreviewCostTests.testStreamingFlagIsInertForPreviewSkin`。
- **表格逐格 `MDInlineView`**：极端档里那张 200×6 的表在分段臂里落在第一段之外，
  单独的表格成本没有分离出来（见未决账 6）。
- **探针类名**：`uTermTests/Features/Preview/MarkdownPreviewCostTests.swift`；
  语义闸门 `uTermTests/Features/Agent/AgentMessageWindowTests.swift` 的
  `MarkdownBlockWindowPixelTests`（默认上限与「完全不限」逐像素相同，裁一半必须不同，
  外加 `inkFraction` 自证不是空图）。
- **没做到的**：见文末「未决账」3 / 4 / 6。

### 并行执行 · Shell 网格（`uTerm/Features/ParallelRun/Views/ParallelShellGrid.swift`）

- **规模**：真实档 6 台 × 600 行，极端档 24 台 × 1200 行，10 秒内流式追加完
  （**从空开始**，不预置历史，见「探针纪律」P5）。
  来源：一条快捷命令绑定的服务器数（`QuickCommand.serverIDs`）；行数来自
  `SSHCommandExecutor(maxLines: 200, maxBytes: 16000)` × `ParallelRunModel.maxAgentSteps = 6`
  = 1200 行封顶。
- **读数**（`ParallelRunScrollCostTests.testShellGridStreamingAndPaneScroll`，单跑；
  `tail-gap` = 追加期结束时各格离底的中位数，≈8pt 表示跟随真的在生效）：

  | 档 | 版本 | 挂载 | 拍数/1250 | 单帧 p50 | 单帧 p95 | 超 8.33ms | 单格滚动 p95 | hitTest p50 | NSView | tail-gap |
  |---|---|---|---|---|---|---|---|---|---|---|
  | 6 台 × 600 行 | 前 | 9.7ms | 453 | 5.76ms | 40.05ms | 38.4% | 4.78ms | 331µs | 395 | 8pt |
  | 6 台 × 600 行 | 后 | 11.5ms | 393 | 6.65ms | 49.11ms | 37.4% | 5.93ms | 329µs | 415 | 8pt |
  | 24 台 × 1200 行 | 前 | 22.2ms | **95** | **58.55ms** | 75.93ms | 100% | 4.26ms | 446µs | 801 | 8pt |
  | 24 台 × 1200 行 | 后 | 31.6ms | **149** | **14.96ms** | 50.33ms | 100% | 4.56ms | 447µs | 663 | 8pt |

- **判定**：**B 已落地，但极端档仍不达标 → 终局是 C**。
  - 单格**滚动**本身一直很好（p95 4~6ms、超预算 0%）——问题不在滚动，在**输出追加期**。
  - 24 台档追加期 100% 的帧超预算，B 级别把 p50 砍掉 74%（58.55 → 14.96ms）、
    心跳从 95 拍拉到 149 拍，仍在预算之外。要真正达标得按 T1/T2 样板把窗格换成
    自绘终端面（CoreText 画行 + 按 bounds 贴底），**本轮没做**。
- **根因（变体归因，`testShellGridVariantAttribution`，24 台 × 1000 行、两轮交替）**：

  | 变体 | 拍数/500 | p50 | p95 | 真的在跟随？ |
  |---|---|---|---|---|
  | A 生产写法：贴 `"shell-bottom"`（**在 LazyVStack 外面**），100ms 合并 | 39 / 44 | 59.13 / 62.84ms | 100.96 / 74.42ms | 是（8pt） |
  | B 改贴**最后一行自己的 id**（在 LazyVStack 里面） | 73 / 77 | 15.39 / 14.31ms | 21.92 / 21.85ms | 是（10pt） |
  | E 把 `"shell-bottom"` 挪进 LazyVStack（仍是它最后一个孩子） | 46 / 54 | 15.09 / 14.20ms | **65.76 / 66.61ms** | 是（32pt） |
  | D 完全不跟随（地板值） | 266 / 271 | 7.70 / 7.46ms | 8.77 / 8.12ms | 否 |

  贵的是**「贴底」这件事本身**：跟随一开，单帧从 7ms 跳到 55~125ms。
  再往下拆，贵的是**锚点解析**——`Color.clear.id("shell-bottom")` 是 `LazyVStack`
  的**兄弟**，要定位它必须先知道整条懒栈的真实高度，于是 1200 行（长行还会换行、
  行高不定）全被量一遍。锚点换成 `ForEach` 里的真行之后，懒栈能按序号带估高直接跳。
- **试过但没用 / 更差的路**（同一套变体，都留在探针里当反证）：

  | 路 | 结果 |
  |---|---|
  | `ScrollPosition.scrollTo(edge: .bottom)` 代替 id 锚点 | 60.65ms，与生产写法同档 —— 边缘式一样要算整高 |
  | `.defaultScrollAnchor(.bottom)` | 76.94ms，**更差** |
  | `.defaultScrollAnchor(.bottom, for: .sizeChanges)` | 7.34ms 但 **根本不跟随**（tail-gap 29000pt） |
  | 每格 `.equatable()` 行戳门控 | 与生产写法同档 —— 追加期每格都真的变了，门控无处可挡 |
  | `.textSelection` 从每行提到整格 | 84.93ms，**更差**（平台视图 1009 → 2641） |
  | 完全去掉 `.textSelection` | 22.71ms（比 B 好，但**牺牲选中复制**，不采纳） |
  | 行 `lineLimit(1)` 不换行 | 84.64ms，更差 |
  | 分块（50 行一块的 `VStack` 塞进懒栈） | 177.22ms，p95 1637ms，**灾难** |
  | 只渲染末尾 400 / 120 / 60 行 | 28~119ms 且非单调 —— 滑动窗口每追加一行就换掉首元素，`ForEach` 身份整体重排 |
- **改法**：`ParallelShellPane` 的贴底跟随拆成两条路——
  1. **热路径**（每批追加、100ms 合并）：`proxy.scrollTo(最后一行的 id, anchor: .bottom)`；
     最后一行的 id 用 `@State tailLineID` 存，工作项里读**当前值**（不是排队时的快照），
     合并窗口里又进了几行也贴得到真正的最后一行。
  2. **凉路径**（输出停 350ms 后一次）：`proxy.scrollTo("shell-bottom")`，把最后一行
     底下的运行光标 / 主机指纹卡带进视野。它贵，但一阵输出只发一次。
- **前→后**：24 台 × 1200 行追加期 单帧 p50 **58.55 → 14.96ms（−74%）**、
  8ms 心跳 **95 → 149 拍（+57%）**、p95 75.93 → 50.33ms（−34%）。
  6 台档在噪声内（p50 5.76 → 6.65ms，拍数 453 → 393）——那一档本来就没被跟随压住。
- **探针类名**：`uTermTests/Features/ParallelRun/ParallelRunScrollCostTests.swift`
- **没做到的**：极端档仍 100% 超预算；`ParallelShellPane` 的自绘终端面（C）没做。

### 并行执行 · AI 泳道 / 广播条 / 状态栏（`ParallelAgentView.swift`、`ParallelRunChrome.swift`）

- **规模**：6 / 24 台泳道（同上）。
- **读数**：

  | 视图 | 档 | 挂载 | 滚动 p50 | 滚动 p95 | 超 8.33ms | NSView |
  |---|---|---|---|---|---|---|
  | AI 泳道 | 6 台 | 13.0ms | 0.75ms | 3.73ms | 0.0% | 67 |
  | AI 泳道 | 24 台 | 21.5ms | 0.83ms | 1.53ms | 0.0% | 173 |

  广播条 10Hz `TimelineView(.periodic(by: 0.1))`：3 秒 8ms 心跳
  **运行中 327 拍 / CPU 0.392s vs 已完成 328 拍 / CPU 0.342s** —— 在噪声内。
  `ParallelAgentView.scrollKey` 的 `states.map{}.joined()`：24 台 **p50 14.07µs**
  （换成 `Hasher` 拼戳是 12.04µs，同样在噪声内）。

- **判定**：**A，三处都不动**。
  - AI 泳道 24 台档 p95 1.53ms、超预算 0%、hitTest 不随台数涨 —— 达标。
    它的 `Color.clear.id(bottomAnchor)` 本来就在 `LazyVStack` **里面**，
    而且孩子只有 24 个，不吃 Shell 网格那个亏。
  - **原倾向「TimelineView 降到 1Hz 或只在运行中」被数据推翻**：10Hz 的
    唤醒在这台机器上量不出来（1 拍之差 / 0.05s CPU，两轮都在噪声里）。
    改它只有「跑完不再空转」的道理，没有性能上的道理，本轮不改。
  - **原倾向「`scrollKey` 改用计数/版本号」也被数据推翻**：14µs 对上追加期
    十几毫秒的一帧，是噪声。不改。
- **探针类名**：同上（`testAgentLaneScroll` / `testBroadcastBarTimelineIdleCost` /
  `testScrollKeyStringJoinCost`）。

### 全局端口转发窗口（`uTerm/Features/PortForward/Global/GlobalForwardingWindowView.swift`）

- **规模**：真实档 **10 主机 × 5 规则 = 50 行**；极端档 **50 主机 × 20 规则 = 1000 行**。
  来源：`@Query(sort: \ForwardingRule.sortOrder)` 与 `@Query(sort: \ServerProfile.sortOrder)`
  都**没有上限**，行数 = 主机数 × 每台的规则数；50 台的上界对齐欢迎页 Tweaks 的
  `MockServerFactory.make` 里 `clamp(serverCount, 0, 50)`。
- **改前的形态**（四条同时成立）：
  1. `ScrollView + VStack + ForEach(groups) → VStack + ForEach(group.rules)` **两层非 lazy**，
     1000 行全部实例化；
  2. `GlobalForwardRow` 每行 1 个铅笔 `Button` + `UDToggle`（也是 `Button`）+
     失败时状态徽标再多一个 `Button` + **5 处 `.help`** + `onHover` + 双击手势；
  3. `pollTraffic()` **每秒**整体替换 `@State traffic`，那一拍整窗 body 重求；
  4. body 里 `groups` / `summary` / `launchItems` 三个计算属性各自重算，
     `groups` 一次 body 被算 2~3 遍，`isHostOnline` 还**逐组**线性扫全部规则 —— O(主机 × 规则)。
- **读数**（2026-09-08，Debug，`.transparentOnScreen`，900×700 窗口，往返幅度钳 ≈3 视口。
  「前」「后」是两轮进程；同一轮里另有一条 `legacyNestedList` 改前臂做同轮相对比，读数附在下表末行）：

  | 档 | 挂载 | 静止 3s 拍数/375 | 单帧 p50 | 单帧 p95 | 超 8.33ms | hitTest p50 | NSView |
  |---|---|---|---|---|---|---|---|
  | 50 行 · 前 | 76.20ms | 318 | 1.569ms | 1.999ms | 0.0% | 736µs | 315 |
  | 50 行 · 后 | 54.23ms | 309 | 1.592ms | 2.982ms | **0.0%** | 749µs | 315 |
  | 1000 行 · 前 | 908.84ms | **28** | 16.677ms | 17.899ms | **99.5%** | **17030µs** | **6465** |
  | 1000 行 · 后 | **30.05ms** | **317** | **1.702ms** | **7.324ms** | **4.5%** | **570µs** | **176** |
  | 1000 行 · 同轮改前臂 | 400.71ms | 177 | 14.206ms | 15.177ms | 99.5% | 15348µs | 3461 |

  （「后」这一行是**做完单主机列表那一轮的「悬停才建按钮」之后**的复量 ——
  `GlobalForwardRow` 的铅笔改成悬停时才构造，1000 行档 NSView 又从 316 掉到 176、
  p95 从 8.812 掉到 7.324ms。同轮改前臂也跟着受益（NSView 6461 → 3461），
  所以那一列的绝对值与上面「前」那一行不可直接相减 —— 只看同轮的相对差。）

  派生数据一次求值（纯逻辑，同轮两臂交替）：50 条 0.371 → **0.210ms**；
  1000 条 **13.75 → 3.44ms**；「1000 条 / 50 条」的比值 **37.1× → 16.4×**
  （规则数正好 20×，线性实现应贴着 20）。

- **判定：B**。极端档 p95 17.9ms、超预算 99.5%、hitTest 随行数涨到 17ms、NSView 6465，
  离 A 差得远；但形态是 playbook 点名的四条已知病（非 lazy、每行多个 `Button`、
  每行多处 `.help`、每秒整窗重求），先就地修。修完极端档超预算 4.5%、hitTest 570µs
  且不随规模涨、NSView 176（`6d4a9953`「悬停才建」后的复量；`c2123c21` 那一轮是 5.0% / 643µs / 316）—— 没有升级到 C 的必要。
- **改法**（四处，都在 `GlobalForwardingWindowView.swift` / `GlobalForwardRow.swift` / `GlobalForwardingSupport.swift`）：
  1. **派生数据一遍算完**：新增 `gfDerivedCounts`（单遍扫描，每条规则只查一次状态，
     同时产出 `GFSummary` + 在线主机集合 + 每主机活跃数）与 `GlobalForwardingDerived`
     （分组 + 计数 + launchItems 一次算完），body 里 `let derived = self.derived` 算一次往下传。
     `isHostOnline` 的 O(主机 × 规则) 全表扫整条删掉。
  2. **流量轮询下沉**：把 `@State traffic` / `lastBytes` / `.task { pollTraffic() }` 和列表
     一起搬进新的 `GlobalForwardingList`。每秒那一拍只让列表重求，标题栏 / 启动横幅 /
     汇总条 / 派生数据都不再跟着算。
  3. **分组一层按规模走懒栈**：总规则数 > `GlobalForwardingList.lazyRowThreshold`（120）
     时用 `LazyVStack`，否则维持 `VStack`。组内仍是普通 `VStack` —— 圆角卡片、组内分隔线、
     `isLast` 判定这些视觉契约一点没动。
  4. **行内 tooltip 悬停门控**：`View.help(whenHovering:_:)`（`uTerm/Shared/Views/HoverGatedHelp.swift`，
     抄 uTable `UTableSharedUI` 的同名 API），`GlobalForwardRow` 的 5 处 `.help` 全部改成
     只在本行悬停时才装 tooltip 追踪区；AX 标签**不**门控。
  4b. **hover 按钮悬停才建**（随单主机列表那一轮一起做）：铅笔改前是常驻一个 `Button`
     再 `opacity(0)` 藏起来，1000 行就是 1000 个真控件；改成 `if hover { … } else { 等宽占位块 }`。
     几何一模一样（26pt），无障碍也没变差 —— 完全透明的视图本来就被 SwiftUI 排除在 AX 树外。
  5. `pollTraffic` 里 `if stats != traffic` 才写回 —— 全部隧道闲着时（速率归零后每拍快照
     一模一样）连这一拍的重求也省掉。
- **一个反向读数（务必留着）**：分组一层无条件换 `LazyVStack` 时，**真实档变差**——
  10 组 / 50 行 单帧 p95 **2.00 → 15.41ms**、超预算 **0% → 9.5%**（1000 行档同时
  从 p95 17.90 改善到 7.23ms）。这正是 playbook「换懒栈不一定更快」的反例。
  所以才有 `lazyRowThreshold`；两档之间的确切拐点没量过。
- **探针类名**：`uTermTests/Features/PortForward/GlobalForwardingListCostTests.swift`
  （夹具 `ForwardingProbeSupport.swift`），行为闸门
  `uTermTests/Features/PortForward/ForwardingListContractTests.swift`，
  纯逻辑等价闸门 `uTermTests/Features/PortForward/GlobalForwardingSupportTests.swift`
  的 `testDerivedCountsMatchTheLegacyPerHostScans`。
- **没做到的**：
  - 行内「编辑配置」铅笔是 `opacity(hover ? 1 : 0)`，SwiftUI 把完全透明的视图排除在
    无障碍树之外 —— **改前改后都读不到**。这是老问题（双击行编辑同样没有 AX 入口），
    本轮没动它。
  - `accessibilityPerformPress()` 在本工程的 `UDToggle`（`Button(.plain)` 包装）上返回 true
    却不触发 action，实测按不动；合成 `NSEvent` 更不行（playbook §五·八④）。所以开关的
    契约测试退到「改模型 → AX 动作文案当场跟着翻」的活绑定判据，`setKeepConnected`
    本身靠「本轮一字未改」兜底。
  - `lazyRowThreshold = 120` 的确切拐点没量（只量了 50 行与 1000 行两端）。
  - 1000 行档改后仍有 4.5% 的帧越 8.33ms（p95 7.32ms）。剩下的账在「一屏十几行、
    每行一个 `UDToggle` + 状态徽标」本身，要再往下就是 C。

### 单主机端口转发窗口列表（`uTerm/Features/PortForward/Views/PortForwardListView.swift` + `TunnelRow.swift`）

- **规模**：真实档 **8 条**（一台机器上手工建的转发通常个位数）；极端档 **200 条**。
  来源：`PortForwardWindowView` 里按 `serverID` 过滤的 `@Query` **无上限**，
  单主机规则数没有任何钳制。
- **改前的形态**：`ScrollView + VStack + ForEach(visible)` 非 lazy；`TunnelRow` 每行
  2 个图标 `Button`（编辑 / 删除，`opacity(hover ? 1 : 0)` 但**一直构造**）+ `UDToggle`
  （也是 `Button`）+ **4 处 `.help`** + `onHover` + 双击；工具栏一次 body 里做 **5 次**
  `rules.filter`（三个类型各一次 + 活跃 + 异常，后两次还各查一遍每条规则的状态）。
- **读数**（2026-09-08，Debug，`.transparentOnScreen`，820×640 窗口；同一轮里另有
  `legacyNonLazyList` 改前臂）：

  | 档 | 挂载 | 单帧 p50 | 单帧 p95 | 超 8.33ms | hitTest p50 | NSView |
  |---|---|---|---|---|---|---|
  | 8 条 · 前 | 2.66ms | 0.125ms | 0.189ms | 0.0% | 263µs | 89 |
  | 8 条 · 后 | 2.13ms | 0.131ms | 0.194ms | 0.0% | 261µs | **41** |
  | 200 条 · 前 | 49.29ms | 6.026ms | 7.108ms | 0.0% | **2700µs** | **1817** |
  | 200 条 · 后 | **2.41ms** | 5.630ms | **7.307ms** | **1.0%** | **429µs** | **128** |
  | 200 条 · 同轮改前臂（也吃到了「悬停才建」） | 25.24ms | 4.967ms | 5.471ms | 0.0% | 2626µs | 607 |

  注：8 条档内容装得下一屏（`scrollable = 0`），按 playbook 只看挂载与 NSView，
  滚动读数不作数。

- **判定：B**。极端档的单帧其实**没有**越预算（p95 7.11ms、超预算 0%），
  但 A 的第三条判据不成立 —— **hitTest 随规模涨**（8 条 263µs → 200 条 2700µs，10 倍），
  NSView 也是线性涨到 1817。形态又正好是 playbook 点名的那几条，所以就地修。
- **改法**：
  1. **hover 按钮悬停才建**（`TunnelRow` + `GlobalForwardRow` 同改）：编辑 / 删除两个
     `Button` 改成 `if hover { … } else { Color.clear.frame(width: 54, height: 26) }`。
     这是本处收益最大的一条 —— 200 条档 NSView 1807 → 607、单帧 p95 7.92 → 5.47ms
     （见下面那条反向读数里的中间态）。
  2. **超过 `PortForwardListLayout.lazyRowThreshold`（120）才换 `LazyVStack`**，
     阈值与全局面板共用。
  3. **4 处 `.help` 悬停门控**（`help(whenHovering:)`）。
  4. **工具栏 5 次 `filter` 合并成一遍扫描**（`ToolbarCounts`：每条规则只查一次状态、
     只走一遍数组）。
- **一个反向读数（务必留着）**：只换懒栈、不做「悬停才建」时，200 条档
  单帧 p95 **7.108 → 10.050ms**、超预算 **0.0% → 20.0%**（同轮 hitTest 2700 → 557µs、
  NSView 1817 → 350、挂载 49.29 → 3.54ms）。也就是说**懒栈把成本从「挂载 + 命中」
  搬到了「滚动时现建行」**；只有把行本身变便宜（悬停才建）之后，懒栈才两头都赢。
- **探针类名**：`uTermTests/Features/PortForward/PortForwardListCostTests.swift`；
  行为闸门在 `ForwardingListContractTests` 的
  `testSingleHostToolbarCountsMatchTheRules` / `testSingleHostLazyListStillRendersTheLastRule` /
  `testSingleHostRowToggleLabelTracksStatus`。
- **没做到的**：
  - 200 条档仍有 1.0% 的帧越 8.33ms（p95 7.31ms）；剩下的账在 `TunnelRow` 本身
    （`TypeBadge` + 富文本流向 + `UDToggle`），要再往下就是 C。
  - 编辑 / 删除两个按钮在不悬停时既不在视图树也不在 AX 树 —— 但这与改前一致
    （`opacity(0)` 的视图 SwiftUI 本来就不给 AX），本轮没有让无障碍变好也没变差。
  - 类型筛选切换（`filter`）没有单独量：切一次会整列表重建，200 条档的切换成本未测。

### 分组管理（`uTerm/Features/Groups/Views/GroupsManagerView.swift`）

- **规模**：真实档 6 组 / 60 台；极端档 60 组 / 2000 台，外加 **1 组 / 2000 成员**
  （右栏成员列表的极端形态）。来源：`ServerGroup` / `ServerProfile` 都没有条数上限，
  欢迎页 Tweaks 的 mock 只钳到 50 台（`MockServerFactory.swift:28`），极端档自己造。
- **读数**（`ManagementListScrollCostTests.testGroupsManagerLists`）：

  | 档 | 版本 | 挂载 | 拍数/375 | 单帧 p50 | 单帧 p95 | 超 8.33ms | hitTest p50 | NSView |
  |---|---|---|---|---|---|---|---|---|
  | 6 组 / 60 台 | 前 | 40.7ms | 333 | 0.12ms | 0.17ms | 0.0% | 255µs | 66 |
  | 6 组 / 60 台 | 后 | 25.9ms | 334 | 0.08ms | 0.12ms | 0.0% | 258µs | 46 |
  | 60 组 / 2000 台 | 前 | 197.9ms | 322 | 2.81ms | 3.77ms | 0.0% | 476µs | 222 |
  | 60 组 / 2000 台 | 后 | 39.7ms | 321 | 3.03ms | 4.33ms | 0.0% | 410µs | 110 |
  | **1 组 / 2000 成员** | 前 | **1664.1ms** | 229 | **10.21ms** | 11.24ms | **100%** | **13453µs** | **3936** |
  | **1 组 / 2000 成员** | 后 | **36.0ms** | 294 | **3.86ms** | 4.77ms | **0.0%** | **323µs** | **36** |

- **判定**：**B**。三条已知形态全中——每行全表扫、非 lazy、每行一个 `Button`。
- **改法**：
  1. `memberCounts: [String: Int]` 一趟聚合，`groupRow` 从
     `GroupStore.members(of:in:profiles).count`（60 组 × 2000 台 = 每次 body 12 万次比较）
     改成 O(1) 查表。
  2. 左栏组列表、右栏成员 / 候选列表、未分组成员列表全部 `VStack` → `LazyVStack`。
  3. `MemberRowView` 的「移出 / + 加入」从 `Button` 换成
     `contentShape + onTapGesture + AX traits/action`（playbook §三「Button 才是主因」）。
- **前→后**：2000 成员那一档 挂载 **1664 → 36ms（−98%）**、
  hitTest p50 **13453 → 323µs（−98%）**、NSView **3936 → 36（−99%）**、
  单帧 p50 10.21 → 3.86ms（−62%）、超预算 **100% → 0%**。
  60 组 / 2000 台 挂载 197.9 → 39.7ms（−80%）、NSView 222 → 110（−50%）。
- **契约测试**：`testGroupMemberRowRemainsAccessibleButton` —— 走 **AX 树**找
  role=button、label 以「移出 」开头的元素，`accessibilityPerformPress()` 按下去，
  断言真有一台主机被移出分组。换掉 SwiftUI `Button` 之后，这条才是真正的回归闸门
  （改回 `Button` 会让 label 退成「移出」而不带主机名，用例立刻红）。
- **探针类名**：`uTermTests/Features/Groups/ManagementListScrollCostTests.swift`
- **没做到的**：`candidates: profiles.filter { $0.group != g.name }` 仍在每次 body
  重算一个 2000 元素数组（O(n) 分配，没有 O(n²)）；没量到它拖住哪一帧，留着没动。

### 密钥管理侧栏（`uTerm/Features/Keys/Views/KeyManagerView.swift`）

- **规模**：真实档 5 密钥 / 60 台；极端档 50 密钥 / 2000 台。
- **读数**（`testKeyManagerSidebar`）：

  | 档 | 版本 | 挂载 | 拍数/375 | 单帧 p50 | 单帧 p95 | 超 8.33ms | hitTest p50 | NSView |
  |---|---|---|---|---|---|---|---|---|
  | 5 / 60 | 前 | 30.6ms | 328 | 0.10ms | 0.21ms | 0.0% | 145µs | 27 |
  | 5 / 60 | 后 | 30.0ms | 329 | 0.14ms | 0.19ms | 0.0% | 192µs | 27 |
  | 50 / 2000 | 前 | 83.6ms | 320 | 0.94ms | 1.20ms | 0.0% | 332µs | 27 |
  | 50 / 2000 | 后 | 34.3ms | 318 | 0.93ms | 1.20ms | 0.0% | 353µs | 27 |

- **判定**：**B（轻）**。侧栏本来已经是 `LazyVStack` + `onTapGesture`（没有 `Button`），
  所以滚动一直达标；唯一的账是**每行两次全表扫**（行文案一次、AX 标签一次），
  50 × 2000 × 2 = 每次 body 最多 20 万次比较，落在**挂载**上。
- **改法**：`hostCounts: [UUID: Int]` 一趟聚合，行里查表，两处共用同一个数。
- **前→后**：50 密钥 / 2000 台 挂载 **83.6 → 34.3ms（−59%）**；滚动读数在噪声内
  （本来就达标）。
- **探针类名**：同上（`testKeyManagerSidebar`）。

### SSH config 导入复核表（`uTerm/Features/Import/Views/SSHConfigImportView.swift`）

- **规模**：2000 条 Host（`~/.ssh/config` 里的 Host 段，复核页一次全列）。
- **读数**：解析 + 计划本身很便宜：`parseSSHConfig + SSHConfigImporter.plan`
  50 条 0.7ms / 2000 条 **16.4ms**。视图侧的账见下表。

  复核页要走 `NSOpenPanel` 才进得去 `review` 相位（`phase` 是私有 `@State`），
  探针进不去，所以用一份**与 `importRowView` 同形状**的行列表把改法的两个开关
  （懒栈 / 每行 `.help`）在**同一轮**里对照：

  | 形态 | 挂载 | 拍数/375 | 单帧 p50 | 单帧 p95 | 超 8.33ms | hitTest p50 | NSView | 文档高 |
  |---|---|---|---|---|---|---|---|---|
  | 2000 行 · 旧（`VStack` + 每行 `.help`） | **432.1ms** | 312 | 6.45ms | 8.02ms | 1.0% | **5566µs** | 29 | 94023 |
  | 2000 行 · 新（`LazyVStack`，无 `.help`） | **4.6ms** | 304 | 2.58ms | 3.15ms | 0.0% | **260µs** | 29 | 94023 |
  | 50 行 · 新 | 8.0ms | 306 | 2.24ms | 2.88ms | 0.0% | 190µs | 29 | 2373 |

- **判定**：**B**。两条已知形态：非 lazy、每行 `.help`。
- **改法**：`VStack` → `LazyVStack`；去掉每行的 `.help`，完整 endpoint / 私钥路径
  改挂 `.accessibilityValue`（读屏仍拿得到）。
- **前→后**：2000 行 挂载 **432.1 → 4.6ms（−99%）**、hitTest p50 **5566 → 260µs（−95%）**、
  单帧 p50 6.45 → 2.58ms（−60%）。
- **闸门要盯命中路径，不是 NSView 数**：`.help` 挂的是 `NSTrackingArea`，**不长 NSView**
  （前后都是 29 个）。2000 个 tracking area 只在 `hitTest` 和挂载上现形。
- **探针类名**：同上（`testSSHConfigImportReviewList`）。
- **没做到的**：真视图的 `review` 相位进不去（要 `NSOpenPanel`），量的是同形状替身；
  真视图这一侧只有编译期保证（同样的懒栈、同样没有 `.help`）。

### 欢迎页服务器列表「选中驱动滚动」（`uTerm/Features/Welcome/Views/ServerList.swift`）

前一轮（`393773ec`）量的是**滚轮扫列表**，压根没碰 `onChange(of: selectedID)`。
这一轮补的是另一条路径：**键盘 ↑↓ 换选中行**与**搜索过滤切换**，
两者都会触发 `ScrollViewReader` 的程序性 `scrollTo`。

之所以单开一轮，是因为这块面上 `LazyVStack` + `scrollTo` + `withAnimation`
三要素齐全，与 uTable `753575d` 那次「单次布局事务 3s+、99% CPU」的 AI 面板同形
（playbook §七 判据 1）。

- **规模**：与 `WelcomeServerListCostTests` 同源 —— 真实档 100 台 / 10 组，
  极端档 2000 台 / 60 组（`~/.ssh/config` 批量导入是产品功能；
  Tweaks 那个 50 台的钳是调试旋钮上限，不是数据上限）。
- **动作**：3 秒 × 8ms 心跳，每拍换一次选中行（= 按住 ↓ 不放）；
  再连续 200 次「换选中行 + 同步布局」端到端计时（步长 7 行，逼选中行不断跨出视口）；
  再来回 20 次搜索过滤切换（`"web"` 命中 1/5 ⇄ 全量）。

#### 读数（2026-09-08，Debug，`.transparentOnScreen`，三臂各两轮交替）

2000 台 / 60 组：

| 臂 | 一步 p50 | p95 | max | 超 8.33ms | 3s 心跳 /375 | filter max | NSView | 文档高 |
|---|---|---|---|---|---|---|---|---|
| 带 `withAnimation`（现状） | 34.97 / 36.69ms | 91.21 / 56.19ms | 98.1 / 61.2ms | 99 / 100% | 242 / 246 | 39.4 / 38.5ms | 39 | 122000 |
| 去掉 `withAnimation` | 39.11 / 39.79ms | 63.91 / 64.25ms | 66.7 / 67.3ms | 100 / 100% | 245 / 251 | 45.3 / 42.5ms | 39 | 122000 |
| 连 `scrollTo` 一起去掉（**完全不滚**） | **6.59ms** | **9.16ms** | **10.7ms** | **15.0%** | **333** | **15.6ms** | 39 | 122000 |

100 台 / 10 组：带动画 p50 **6.18 / 6.37ms**（p95 8.67 / 9.04），
去掉动画 **8.32 / 8.87ms**（p95 11.77 / 11.91），完全不滚 **5.28ms**。

「完全不滚」那一行里混着「整屏重绘」的账，所以它当分母会被机器负载带偏
（见下面「闸门」一节）。把分母换成**手滚同样距离**之后，纯 `scrollTo` 的税是
2000 台 66ms vs 33ms（2.0~2.3×）、100 台 15.5ms vs 16.8ms（0.88~0.98×，不收税）。

#### 判定：**A（不动），但理由和去之前的先验相反**

§七 三判据逐条：

1. 无 `withAnimation` 包着的 `scrollTo` —— **不满足**；
2. 容器提案：`ScrollView` 挂 `.frame(maxWidth:.infinity, maxHeight:.infinity)`，
   坐在填满整个 pane 的 `HStack` 里，是填充提案 —— 满足；
3. 行高稳定廉价：`ServerRow` 恒 61pt（`docHeight / rows` 实测）—— 满足。

判据 1 不过，但**照方抓药被数据否了**，两条：

1. **753575d 的失效模式在这里不发生。** 那次是单次布局事务 3s+、主线程 99% CPU；
   这里最坏一步 98ms，3 秒心跳 242~251 拍（被按死的话是个位数），
   NSView 恒 39 不随行数涨（§七 第四条：判「回不回收」只看扫完之后数 NSView）。
2. **去掉 `withAnimation` 不是收益，是负收益。** 2000 台 p50 35 → 39ms，
   100 台真实档 6.2 → 8.6ms；只有尾部收紧一点（p95 91/56 → 64/64、max 98/61 → 67/67）。
   两轮同向，不是噪声。合理的解释是：0.12s 的补间让滚动偏移**逐帧挪一点**，
   每帧只需要新建少数几行；瞬时定位则一步跳过去，一帧里要建的行更多。

**账在 `scrollTo` 本身**：归因臂（连 `scrollTo` 一起去掉）p50 6.59ms、心跳 333 拍，
与带 `scrollTo` 的 35ms / 242 拍差了 5 倍多。也就是说这 35ms 是
「让 `LazyVStack` 解析 2000 行里某一行的目标偏移」的价钱，跟动画无关。

所以 `withAnimation` **留着**（它是键盘导航的设计语义），改动只有注释与闸门。

#### 闸门：结构判据 + 同轮比值，绝对毫秒只打印

第一版闸门钉的是绝对拍数（真实档 `beats > 200`，当时实测 324~334）。它**在全量套件里
读到 177 判红、单跑同一条 214~238 判绿**；拿闸门开 / 关做三组交替 A/B
（238 / 222 / 214 vs 228 / 212 / 224）排除了 `ScrollHoverGate` 的嫌疑 ——
纯粹是绝对阈值在负载下翻面，playbook §二·4 点名过的错误。

第二版换成「同轮两臂比值」，分母是**关掉 `scrollsSelectionIntoView` 的同一份
`ServerList`**（产品代码本身的开关，不是复刻件）。**它也翻了**：在旁边跑着另一套
全量测试的机器上（load ~5），100 台档的比值从 1.17× 涨到 2.62× 判红。

| 100 台 · 一步 p50 | 空闲时 | 有负载时 | 膨胀 |
|---|---|---|---|
| 带 `scrollTo`（分子） | 6.2ms | 16.1ms | **2.6×** |
| 完全不滚的分母（第二版） | 5.3ms | 6.1ms | 1.15× |
| 比值 | 1.17× | **2.62×（判红）** | —— |

**这一轮的教训**：「同轮比值能约掉机器负载」有个前提 —— **两臂得干同样多的活**。
滚动那臂每一步整屏重绘，不滚那臂只重画两行高亮；WindowServer 一忙，只有分子涨。
playbook §二·4 只说了「不要写死毫秒」，没说分母怎么选，这条补上。

第三版（现状）的分母是**手滚镜像**：归因臂照样关掉 `scrollsSelectionIntoView`，
探针每一步改用 `NSClipView.scroll(to:)` 把目标行滚进视口（最小可见滚动，与
`scrollTo(id)` 默认锚点同语义）。两臂重绘同样多、滚同样远，差的只剩 `scrollTo`
自己：把 id 解析成偏移（`LazyVStack` 要为此摸行）+ 那 0.12s 补间。

| 比值 | 七轮读数（机器负载各不相同，其中三轮旁边跑着另一套全量测试） | 闸门（max × 1.5） |
|---|---|---|
| 2000 台 一步 p50 | 2.24 / 2.25 / 2.13 / 1.97 / 2.19 / 2.01 / 2.23× | < 3.4 |
| 2000 台 心跳（分母分子倒过来） | 1.27 / 1.16 / 1.23 / 1.15 / 1.18 / 1.13 / 1.23× | < 1.9 |
| 100 台 一步 p50 | 0.98 / 0.91 / 0.90 / 0.88 / 0.90 / 0.92 / 0.96× | < 1.5 |
| 100 台 心跳（倒过来） | 1.18 / 1.06 / 1.15 / 0.96 / 1.12 / 1.17 / 1.28× | < 1.9 |

同期的绝对读数漂了 20~30%（100 台 13~17ms、2000 台 64~72ms），比值只漂 5~7%。
顺带一条新结论：**真实档上 `scrollTo` 不收税**（0.88~0.98×，比手滚还略便宜）；
那笔税全是 2000 行档才有的。

现在 `ServerListSelectionScrollProbeTests` 的判据分三层：

- **结构判据**（负载翻不动的那些）：
  - 文档高 == 行数 × 行高，且行高跨规模一致（2000 台与 100 台都是 61pt）——
    证明量到的是那张长表，不是别的滚动视图；
  - 可滚动余量 > 一屏（否则「换选中行要滚」这件事压根没发生）；
  - NSView 数不随规模涨（100 台 43 → 2000 台 43，允许 ±12）——
    懒栈真的在回收行（§七 第四条）；
  - 12 个散点，动画落定后目标行**必须**落在视口内；选第一行 ⇄ 选最后一行，
    视口原点走过 > 90% 满量程 —— `scrollTo` 那笔钱到底买到了什么；
  - **分母的自证**：归因臂在落点那一段一步都不滚（`scrollSpan == 0`），
    否则「比值」比的是两个一样的东西。
- **同轮相对判据**：上表四条，两臂正反各跑一遍取均值（交错采样，
  免得机器状态一漂比值就塌）。
- **数量级护栏**（只是护栏，不是基线）：心跳 > 60 拍、单步 < 500ms、
  过滤切换 < 800ms —— 钉的是 `753575d` 那种「一次布局事务吞掉整个交互」的形态，
  离实测值一到两个数量级。绝对读数一律只打印在 `[server-list raw]` 行里。

**没有加源码闸门**（「不许再包 `withAnimation`」那种）：数据说那个形态在这里不是病因，
钉它等于把一条被证伪的先验固化进 CI。

**反向验证**：往 `onChange(of: selectedID)` 的 `scrollTo` 之前临时塞一段 O(n) 回归
（整表扫一遍 + `usleep(行数 × 150µs)`），四条同轮判据全红、数量级护栏跟着响：

| | 正常 | 注入回归后 | 闸门 |
|---|---|---|---|
| 2000 台 一步 p50 比值 | 1.97~2.25× | **11.56×** | < 3.4 |
| 2000 台 心跳比值 | 1.13~1.27× | **16.59×** | < 1.9 |
| 100 台 一步 p50 比值 | 0.88~0.98× | **1.93×** | < 1.5 |
| 100 台 心跳比值 | 0.96~1.28× | **2.42×** | < 1.9 |
| 2000 台 3 秒心跳（护栏） | 155~229 拍 | **11 拍** | > 60 |

撤掉即恢复。

#### 「落定」也得是轮询出来的（第四轮，2026-09-08）

时间闸门换成比值之后，全量套件里翻面的换成了一条**结构判据**：
「2000 台：动画落定后目标行必须在视口内」—— 12 个散点只中 10 个判红，
同一条单跑三次全绿。当时同机压着 uTable 的全量（本条一步 p50 50~73ms、超预算 100%）。

判据本身没问题（`scrollTo` 必须把目标行滚进视口），坏的是**「落定」的定义**：
落点那段原本固定 `Task.sleep(260ms)`，赌 0.12s 补间加 SwiftUI 的调度一定跑得完。
**固定等待量的是机器有多闲，不是 `scrollTo` 有没有生效** —— 跟第二、三轮同一个病，
只是这次穿的是结构判据的外衣。

改法：轮询到「目标行进入视口 **且** 视口原点连续两拍不动」为止，8ms 心跳步进、
每拍 `layoutSubtreeIfNeeded()` + `displayIfNeeded()`，上限 2s。超时才判红。
落定耗时逐点记录、只打印。计时段（心跳 / 单步 / 过滤）一行没改，比值读数与第三轮可比。

实测的落定耗时说明了旧写法为什么必输 —— 260ms 那条线连空闲时都只是勉强够：

| 落定耗时（12 散点 + 首尾 2 点） | 空闲（三轮） | 人为加负载（14 个忙循环 + 同机另一套全量，load ≈ 26） |
|---|---|---|
| 100 台 · 带 `scrollTo` | p50 249~256ms，max 251~270ms | p50 244~253ms，max 249~259ms |
| 2000 台 · 带 `scrollTo` | p50 341~352ms，**max 447~497ms** | p50 467~540ms，**max 682~715ms** |
| 超时次数 | 0 | 0 |

2000 台那档**空闲时就已经有一半散点越过 260ms**（旧写法之所以还能绿，是因为
「行进了视口」比「补间彻底停下」来得早）；负载一来整档 330~715ms，旧的固定等待
必然读到补间中途的几何。换成轮询后同一档 `landed = 12/12`、`timeouts = 0`，
负载轮的同轮比值也照常（2000 台一步 1.95×、100 台 0.97×，都在闸门内）。

#### 没做到的

`scrollTo` 在 2000 行上那 2.2 倍的税没动。要往下走得让 `LazyVStack` 不必为一次定位
解析全表 —— 候选是给行声明固定高度让估算变廉价，或者「目标已可见就不滚」
（需要自己算可见区间）。两条都超出这一轮的范围，见文末「未决账」。

### 滚动期间的 hover（跨视图 · `UAppKitBridge/ScrollHoverGate.swift`，2026-09-08）

一条产品级判断落成代码：**滚动的时候不要去计算 hover**。

#### 病灶

光标停着不动、内容在指针底下滚过去时，每一行经过指针都是一次真的 enter / exit ——
AppKit 在视图几何变化时会拿窗口的 `mouseLocationOutsideOfEventStream` 重算
`NSTrackingArea`。代价不是那个回调本身，是它写进 `@State` 之后连锁的一串：

- 「悬停才建真控件」的行（`GlobalForwardRow` / `TunnelRow` 的编辑 · 删除按钮）
  每帧拆一棵子树再建一棵；
- hover 底色变化让那一行重绘；
- 行 body 重求，`help(whenHovering:)` 的文案跟着重新拼。

**用户滚轮时光标本来就落在列表上**，所以这笔账每次滚动都在付 —— 而在这之前，
uTerm 的每一个滚动探针都把真光标挡在窗外（P12），把它整笔量成了 0。

#### 量法：合成光标

`ProbeWindow.Placement` 从三档变成 `.transparentOnScreen(cursorAt: NSPoint?)`：
`nil` 是老行为（谎报鼠标在窗外）；给一个点则谎报「鼠标就停在这个点上」。
两种都与用户真光标无关（断言换成 `ProbeWindow.reportsSyntheticCursor`），
所以可复现性没丢，但后者能把「用户姿势」这一档量出来。

`hoverGated` 转发 / 抑制的次数记在 `HoverGateStats` 上 —— 让「滚动期间到底还有没有把
hover 交出去」成为一个**可断言的整数**，不必靠帧时间去猜。
`ScrollHoverGate.isEnabledByDefault` 是同轮改前 / 改后对照的开关（产线恒 true）。

#### 读数（2026-09-08，M-series MacBook Pro，Debug）

`.transparentOnScreen`，200 步往返 × 每档两遍取均值，四臂在同一进程里轮流量
（正序一遍、逆序一遍）。

| 视图（极端档） | 档 | 单帧 p50 | 单帧 p95 | 超 8.33ms | 滚动中 hover 转发 | 滚动中 NSView 波动 |
|---|---|---|---|---|---|---|
| 欢迎页服务器列表 2000 台 | 光标在外 · 改前 | 2.354ms | 3.115ms | 0.2% | 0 | 38..38 |
| | **光标在列表中央 · 改前** | **5.235ms** | 9.734ms | **14.5%** | **280** | 38..38 |
| | **光标在列表中央 · 改后** | **3.286ms** | 4.145ms | **0.0%** | **1** | 38..38 |
| | 光标在外 · 改后 | 2.385ms | 3.020ms | 0.0% | 0 | 38..38 |
| SFTP 文件表 20000 条 | 光标在外 · 改前 | 2.775ms | 3.974ms | 0.0% | 0 | 55..55 |
| | **光标在列表中央 · 改前** | **4.474ms** | 5.592ms | 0.0% | **320** | 55..55 |
| | **光标在列表中央 · 改后** | **4.265ms** | 5.788ms | 0.0% | **1** | 55..55 |
| | 光标在外 · 改后 | 2.868ms | 4.129ms | 0.0% | 0 | 55..55 |
| 全局端口转发 1000 行 | 光标在外 · 改前 | 1.380ms | 7.415ms | 2.5% | 0 | 178..178 |
| | **光标在列表中央 · 改前** | **10.004ms** | 13.583ms | **73.5%** | **290** | **134..180** |
| | **光标在列表中央 · 改后** | **3.742ms** | 9.718ms | **5.5%** | **1** | **178..180** |
| | 光标在外 · 改后 | 1.437ms | 7.813ms | 3.5% | 0 | 178..178 |

「改后」那一次转发是**必须**的：进滚动的第一拍要把当时亮着的那一行灭掉，
否则它会僵在亮态滚完全程。滚动中不再有任何 `enter` —— 这一条由
`ScrollHoverGateBehaviourTests` 的**逐步**断言（200 步里每一步都断言「没有行亮着」）钉死。

三处的量级差得很开，原因也清楚：

- **全局端口转发最贵（p50 7.25× → 2.60×，超预算 73.5% → 5.5%）**，因为它的行是
  唯一「悬停才建真控件」的那一类（`if hover { iconButton } else { Color.clear }`）。
  滚动中 NSView 在 **134..180** 之间反复张合 —— 那 46 个就是被建了又拆的铅笔按钮子树；
  闸门装上之后收敛到 178..180。
- **欢迎页居中（-37%）**：行里没有悬停才建的控件，但有 hover 底色 + 两处
  `help(whenHovering:)`，逐帧重求。
- **SFTP 最轻（-5%）**：行里只有 `hoverBackground` 一个纯颜色切换，本来就便宜。

#### 改法

共享包 `UAppKitBridge` 加 `ScrollHoverGate`（uTable 可直接用同一份）：

1. `ScrollActivityObserverView` 挂在滚动内容里，靠 `enclosingScrollView` 找到
   `NSScrollView`，订阅 `willStartLiveScroll` / `didEndLiveScroll`
   （拖滚动条与惯性滚动）与 `NSClipView` 的 `boundsDidChange`
   （**滚轮、程序性 `scrollTo`、键盘翻页都不发 live-scroll 通知**，只有这条兜得住）。
2. 任一活动都只做一件事：置 `isScrolling` 并把 150ms 静默计时器往后推。
   计时器**必须加进 `.common` 模式** —— live scroll 期间主 runloop 在 `eventTracking`
   模式里，默认模式的计时器整个拖拽过程一次都不会烧。
3. `.hoverGated { }` 取代行里的 `.onHover { }`：滚动期间不转发，把值记进一个普通
   class 盒子（**不是 `@State`** —— 写 `@State` 就等于每帧让那一行重求 body，
   正是要省的那笔），静默期一到把最后那个真值交出去。

**恢复不做命中测试。** 直觉做法是拿 `NSEvent.mouseLocation` 去命中测试，但 SwiftUI 的行
不是独立 `NSView`，命中测试给不出「是哪一行」。其实不必测：滚动期间 `.onHover` 照样在发，
我们只是没转发；光标底下那一行的最后一个事件必然是 enter，其余行必然是 exit ——
这是 AppKit 已经算好的结论，比自己算更准，且一次几何计算都不用做。

#### 一个必须记住的顺序坑

**AppKit 先重算 tracking area、把 enter / exit 送出去，再发 `boundsDidChange`。**
所以一次滚动的第一个 enter 会抢在闸门开之前落地（实测 200 步程序性滚动正好漏
1 个 enter + 它随后的 exit，转发计数 3 而不是 1）。真人滚轮时 `willStartLiveScroll`
在任何 bounds 变化之前发，漏不掉；但程序性滚动 / 键盘翻页没有那条通知。

兜底判据因此取**几何**而不是通知：`ScrollHoverGate.suspendsHover` 在
`isScrolling` 之外再比一次「滚动原点是否还等于上次判定停下时的原点」。
读一个 `NSPoint` 比什么都便宜，而且不会漏。加上它之后转发计数从 3 落到 1。

#### 接入点（6 处容器 + 5 处行）

| 挂闸门的容器 | 门控的 hover |
|---|---|
| `Welcome/Views/ServerList.swift`（`LazyVStack`） | `ServerRow.hover`（底色 + 两处 `.help`） |
| `SFTP/Views/SFTPFileTable.swift` | `hoverBackground`（行底色） |
| `Files/Views/FileBrowserView.swift` | 同上 |
| `PortForward/Global/GlobalForwardingWindowView.swift`（懒 / 非懒两支） | `GlobalForwardRow.hover`（悬停才建的铅笔 + 4 处 `.help`） |
| `PortForward/Views/PortForwardListView.swift`（懒 / 非懒两支） | `TunnelRow.hover`（悬停才建的编辑 / 删除） |
| `Agent/Views/AssistantView.swift`（消息流 `LazyVStack`） | 用户气泡的悬停铅笔 + tooltip |

`Core/Theme/HoverBackground.swift` 里三个 hover 修饰器（`hoverBackground` /
`iconButtonHover` / `wsIconButtonHover`）统一改走 `hoverGated`。**没有祖先装闸门时
`hoverGated` 与裸 `.onHover` 完全等价**，所以路径栏 / toolbar 这类非滚动场景零副作用。

#### 量出来但**没有**改的

**「光标在内 / 在外」的 p50 比值没能压到 1.2×**（三处分别落在 1.38 / 1.49 / 2.60）。

> **2026-09-08 补记：这笔账已经结清，但当时写下的归因是错的。**
> 下一段（「行悬停：整表一个跟踪层」）把「每行一个 `.onHover`」换成了整表一个跟踪层，
> 比值落到 0.90~1.03×。同时那一轮实测推翻了这里的归因：**SwiftUI 的 `.onHover` 并不是
> 一行一块 `NSTrackingArea`** —— 2000 行的列表整棵树上只有 1~3 块，跟行数无关。逐行的
> 账在 SwiftUI 内部那张 hover 区域表上，不在 AppKit 的追踪区上。下面这段读数仍然作数，
> 只有「剩余开销是什么」这句话作废。

闸门里的判据 ⑥ 因此退成绊线（`ratio < 3.0`）：够松不会因机器负载假红，够紧到
「某处 `hoverGated` 被改回 `.onHover`」就会红。

**SFTP 那一档的时间判据在全量里会翻面，所以做成了有前提的。** 单跑时它的
in/out 是 1.61×（改前 4.474ms），整套 1352 条一起跑时变成 1.01×（改前 2.815ms）——
hover 的开销根本没冒头，「改后必须更便宜」于是在噪声里翻面（2.995 vs 2.815）。
三处里只有它会这样：行里只有一个纯颜色切换的 `hoverBackground`，单跑也只有 -5%，
机器一忙就淹没（P7）。闸门因此先看「改前 in 比 out 贵了多少」，贵出 20% 以上才比时间；
否则这一轮没有可比的东西，只留结构判据（转发计数 / NSView 波动，对机器负载免疫）。

UDesignKit 的通用控件（`UDListRow` / `UDButton` / `UDSidebarRow` 等 19 处 `.onHover`）
这一轮**没动** —— 它们不在被测的三条列表的行里，改动面大、收益未量。

#### 探针类名

`uTermTests/Shared/ScrollHoverGateProbeTests.swift`：
`WelcomeServerListHoverGateTests` / `SFTPFileTableHoverGateTests` /
`GlobalForwardingHoverGateTests`（各一条四臂用例）+ `ScrollHoverGateBehaviourTests`
（合成列表上的行为判据：滚动中逐步断言「没有行亮着」、停下 200ms 后光标所在行恢复、
以及闸门关掉的对照臂必须**大量**转发 —— 没有最后这一条，前两条随时可能是
「合成光标压根没生效」的假绿）。

### 行悬停：整表一个跟踪层（跨视图 · `UAppKitBridge/RowHoverTracker.swift`，2026-09-08）

上一段（`ScrollHoverGate`）留下的那笔账：闸门装上之后，「光标停在列表内」滚动仍比
「停在列表外」贵 1.35~2.31×。这一段把它收掉，顺带**推翻了上一段写下的病因**。

#### 病因假设被自己的探针推翻

上一段的结论写的是「剩余开销是 AppKit 每帧重算整窗 `NSTrackingArea`，因为 SwiftUI
的每个 `.onHover` 各占一块」。这一轮第一件事就是量它 —— `trackingAreaCount(in:)`
递归数整棵树上的追踪区：

| 视图 | 行数 | 追踪区（逐行 `.onHover`） | 追踪区（整表跟踪层） |
|---|---|---|---|
| 欢迎页服务器列表 | 2000 | **3** | 4 |
| SFTP 文件表 | 20000 | **3** | 4 |
| 全局端口转发 | 1000 | **2** | 2 |
| 合成列表（`TrackerProbeList`） | 2000 | **1** | 2 |

**跟行数毫无关系。** SwiftUI 自己就是「一块追踪区 + 内部按区域派发」，跟这一轮要做的
事同构；逐行的账在它内部那张 hover 区域表上：`.onHover` 越多表越长，鼠标位置或几何
一变就要过一遍，命中之后还要写回 `@State`、让那一行重求 body。滚动时内容在指针底下
走，每帧都有行进出指针，这张表因此每帧都在被翻 —— 闸门挡掉的是「写回 + 重求」，
翻表本身照付。

所以做法没变（整表一个跟踪层 + 按行几何算行号），**省掉的东西换了一个**：不是 AppKit
的追踪区，是 SwiftUI 的那张区域表。上一段「量出来但没有改的」那一节里的归因因此作废，
读数仍然作数。

#### 读数（2026-09-08，M-series MacBook Pro，Debug，`.transparentOnScreen`）

四臂：光标在外 / 在内 × 跟踪器关 / 开，**滚动闸门四臂全开**（它已经是产线形态，这一轮
的分母就是「上一轮之后的现状」）。200 步往返 × 每档两遍（正序一遍、逆序一遍）取均值。
下表是六档**一个进程里连着跑完**的那一轮，可横向比。

| 视图 · 档 | 单帧 p50（光标在内）前 → 后 | **in/out 比值** 前 → 后 | 超预算 前 → 后 | 滚动中行级 hover 事件 前 → 后 |
|---|---|---|---|---|
| 欢迎页 2000 台（极端） | 3.428 → **2.671ms**（−22%） | 1.15 → **1.01×** | 0.0% → 0.0% | **280 → 0** |
| 欢迎页 100 台（真实） | 3.332 → **2.886ms**（−13%） | 1.19 → **0.98×** | 0.0% → 0.0% | **204 → 0** |
| SFTP 20000 条（极端） | 5.332 → **4.100ms**（−23%） | 1.32 → **1.01×** | 1.2% → 1.2% | **320 → 0** |
| SFTP 500 条（真实） | 4.450 → **3.288ms**（−26%） | 1.22 → **0.90×** | 1.2% → 0.2% | **320 → 0** |
| 全局转发 1000 行（极端） | 4.405 → **1.912ms**（−57%） | 2.27 → **0.98×** | 5.5% → 5.2% | **290 → 0** |
| 全局转发 50 行（真实） | 5.163 → **1.781ms**（−66%） | 2.64 → **0.94×** | 0.5% → 0.5% | **260 → 0** |

单跑（一个类一个进程）时改前那一栏更贵一些：欢迎页 2000 台 1.32×、SFTP 20000 条
1.31×、全局转发 1000 行 2.18×，改后同样落在 0.88~1.03×。两种跑法的**改后**读数一致，
差的是改前 —— 机器越闲，hover 那笔账越显。这与 P7（「机器一忙就淹没」）是同一件事。

**「光标在内 / 在外」的 1.2 目标线达成，六档全落在 0.90~1.01×**（单跑口径 0.88~1.03×）
—— 也就是「光标压在列表上滚」这件事本身不再收费；低于 1.0 的那些是同轮机器漂移，
不必当成负成本。上一轮三处 1.38 / 1.49 / 2.60 的账到此结清。

真实档（100 台 / 500 条 / 50 行）的收益**不比极端档小**（全局转发 50 行 −66%）：这笔账
按「在屏行数 × 每帧翻表」收费，不按总行数收费，所以小规模列表一样在付。

#### 改法

共享包 `UAppKitBridge` 加 `RowHoverTracker`（uTable 可直接用同一份，v1.4.3）：

1. `RowHoverTrackerView`：挂在行容器上的透明 `NSView`（`hitTest` 返 nil、不画东西），
   **一个** `NSTrackingArea`（`.mouseMoved` / `.mouseEnteredAndExited` /
   `.activeInActiveApp` / `.inVisibleRect`）。**只建一次** —— `.inVisibleRect` 让 AppKit
   自己把矩形跟着可视区走，不必在 `updateTrackingAreas` 里拆了重建。
2. 落点 → 行号：`RowGeometry` / `UniformRowHit`，与点击层（`ClickSelectActivate`）、
   拖放层（`RemoteRowDropTargeting`）**共用同一份算术**。三档：反推行高（欢迎页那种
   「行高由内容撑出来」的）、定高 + 异高首行（文件表的 `..`）、分组定高组头（全局转发）。
   原先散在 uTerm 两处的两份拷贝这一轮合并进 `UAppKitBridge.UniformRowHit`。
3. **失效面只有前后两行**：`RowHoverState` 自己**不是** `@Observable`，每行各有一个
   `RowHoverBox`（`@Observable`，只装一个 `Bool`），行读的是自己那个盒子。把
   `hoveredID` 直接做成可观察属性的话，读它的每一行都会随每次悬停移动失效 ——
   比改前还糟。
4. 与闸门协作：滚动期间不更新（读 `ScrollHoverGate.suspendsHover`），进滚动那一刻把
   当前行灭掉，静默期一到补算一次。

#### 补算不能省（这一轮的关键坑）

单个覆盖整块可视区的追踪区有一个代价：**「光标底下换了一行」不再产生任何事件**。
光标没动、内容滚过去了，AppKit 眼里「在不在这块区域里」自始至终没变，于是
`mouseMoved` / `mouseEntered` 一个都不发。逐行 `.onHover` 时代那是 SwiftUI 每帧替我们
算的（也正是那笔账）。

所以跟踪器要在三个时刻按 `window.mouseLocationOutsideOfEventStream` **自己补算一次**：

- 滚动停下（闸门的 `isScrolling` 翻回 false）；
- 列表刚挂出来（追踪区装上那一刻若光标已经压在里面，AppKit 不会补发 `mouseEntered`）；
- 行集换了一批（进目录 / 过滤 / 排序 —— `updateNSView` 里 `refreshSoon()`）。

漏掉第一条时探针的表现是「滚完之后一行都不亮」；漏掉第二条时是「列表刚出来不亮，
动一下鼠标才亮」。两条都由 `RowHoverTrackerBehaviourTests` 钉住（滚前 / 滚后必须是
**不同的两行**）。

另一个顺手省掉的：`.rowHover` **不用** `onChange(of:initial: true)`。用了的话
`LazyVStack` 每建一行都会白发一次 `action(false)`（行自己的 `@State hover` 本来就是
false），把「新建一行」的账又抬回来 —— 实测 200 步滚动里多出 43 次无用回调。
行刚建出来就已经被悬着的那种情况由 `onAppear` 单独补。

#### 接入点（5 处容器 + 5 处行）

| 挂跟踪器的容器 | 行几何 | 接管的 hover |
|---|---|---|
| `Welcome/Views/ServerList.swift` | 反推行高（`.uniform`） | `ServerRow.hover`（底色 + 两处 `.help`） |
| `SFTP/Views/SFTPFileTable.swift` | 定高 52 + `..` 46 | `hoverBackground`（行底色） |
| `Files/Views/FileBrowserView.swift` | 定高 30 + `..` 30 | 同上 |
| `PortForward/Global/GlobalForwardingWindowView.swift`（懒 / 非懒两支） | 分组：组头 22 + 行 52 + 组间 12 | `GlobalForwardRow.hover`（悬停才建的铅笔 + 4 处 `.help`） |
| `PortForward/Views/PortForwardListView.swift`（懒 / 非懒两支） | 定高 52 | `TunnelRow.hover`（悬停才建的编辑 / 删除） |

`Core/Theme/HoverBackground.swift` 的 `hoverBackground` 多了 `rowHover` / `rowID` 两个
可选参数：传了就走跟踪器，不传照旧走 `hoverGated`（路径栏 / toolbar 这类非列表场景
零改动）。`GlobalForwardingList` 的组头这一轮**钉成定高 15pt**（实测 `fittingSize`
恰为 15，观感不变）—— 分组几何算术要求组头不随内容漂移。

#### 量出来但**没有**改的

- **单主机端口转发列表在「有异常规则」时退回逐行 `.onHover`**。`TunnelRow` 的 error 行
  下面会长出一条 `lineLimit(2)`、高度由文案撑出来的原因条，行不再等高 —— 落点换算会
  从第一条异常规则起整体错位。正确性优先：`hasErrorRow` 为真时几何返回 nil、行也拿
  不到跟踪器状态，两边一起退回改前形态。要根治得把那条原因条钉成定高（是一次对
  异常态的观感改动），或者让它把自己的实测高度报上来。
- **`AssistantView` 的消息流没动**：它的「行」是气泡，高度由内容撑出来、差异极大，
  没有可用的行几何。它仍走 `hoverGated`（闸门那一层的收益照拿）。
- **UDesignKit 的通用控件**（`UDListRow` / `UDButton` / `UDSidebarRow` 等 19 处
  `.onHover`）这一轮仍然没动 —— 它们不在被测的这几条列表的行里。
- **`mouseMoved` 的真机投递没有自动化验证**。探针用的是合成光标
  （`ProbeWindow` 谎报 `mouseLocationOutsideOfEventStream`），进不来真的鼠标事件，
  所以「光标在列表里移动 → 高亮跟着走」这条只在 uAppKit 的单测里用手工构造的
  `NSEvent` 调 `mouseMoved(with:)` 验过，端到端要人肉过一遍。
- **光标被挡在窗外的臂上仍抓到少量 `.onHover` 回调**（SFTP 真实档 5~64 次，转发 0~1
  次 —— 一行都没真的亮）。没有归因，疑似 `LazyVStack` 新建行时 SwiftUI 为登记 hover
  区域补发的初值。极端档恒 0。判据因此写成「窗外流量 < 窗内的 1/4」而不是恒 0。

#### 探针类名

`uTermTests/Shared/RowHoverTrackerProbeTests.swift`：
`WelcomeServerListRowHoverTests` / `SFTPFileTableRowHoverTests` /
`GlobalForwardingRowHoverTests`（各两条：极端档 + 真实档，四臂 ABBA 两遍）+
`RowHoverTrackerBehaviourTests`（合成列表上的行为判据：静止时正好一行亮、滚动中逐步
断言一行都不亮、停下后补算出**新的**那一行、以及跟踪器关掉的对照臂必须退回逐行
`.onHover` 并产生大量事件）。

算术与状态机的单测在 uAppKit：`Tests/UAppKitBridgeTests/RowHoverTrackerTests.swift`
（`UniformRowHitTests` / `RowHoverStateTests` / `RowHoverTrackerViewTests`）。

`ScrollHoverGateProbeTests` 的三条视图级用例这一轮**改成显式关掉跟踪器**
（`RowHoverState.isEnabledByDefault = false`）：它们量的是闸门，而产线这三处的悬停
已经不走逐行 `.onHover` 了；关掉之后 `.rowHover` 逐字退回 `.hoverGated`，那几条断言
的含义原样成立。

### 对话记录正文（Code 标签页 / 历史窗口 · `uTerm/Features/ClaudeHistory/Views/AgentHistoryBrowser.swift`，2026-11-25）

- **症状**（用户录屏，5.6 秒 288 帧）：往回翻一份长对话，画面在几处之间来回跳、滚动条滑块大幅跳。逐帧找相邻两帧的纵向位移：
  1.16s、3.62s、4.39s 三处整屏换到别处（最佳对齐误差 > 15，前后两帧内容对不上），其中 3.62s 那次一下到了对话末尾。
- **原因**：行里的 Markdown 用 `StreamingMarkdownView`，它在 `onAppear` 里才解析。`LazyVStack` 给没出现过的行量高时
  文档是空的（几乎 0 高），整份对话的高度只量出实际的五分之一（120 条：4957 vs 22751pt）；往回翻时行一出现才长到真实高度，
  文档高度在滚动中一次变几百点，视口里的内容跟着跳。**不是掉帧**：两臂每个事件之后交付布局 + 绘制都在 0.4ms 以内。
- **读数**（`testScrollFollowsFingersWithoutJumps`，30 轮 / 120 条，760×620，打开停在底部，12 拨往回 + 12 拨往下，
  每拨 began + 8 个 changed（15/30/60…pt）+ ended，16ms 一个事件；每个事件后截左边一条比对画面位移）：

  | 臂 | 往回翻：画面 / 手指 | 跳（>24pt） | 整屏换 | 文档高变 | 往下翻：跳 / 整屏换 |
  |---|---|---|---|---|---|
  | 改前 | 8589 / 4860pt | 16 次，共 4173pt，最大 317pt | 13 | 11 次，共 10437pt | 0 / 0 |
  | 改后 | 4860 / 4860pt | 0 | 0 | 0 | 0 / 0 |

  只读了最后一页、翻到顶再按「加载更早的消息」（`testLoadingEarlierPageKeepsPositionAndStaysSmooth`，60 轮）：
  改前翻到顶的路上跳 4、整屏换 7，加页后接着往回翻跳 14、整屏换 7；改后都是 0。按钮那一下画面上移 80pt 两臂一样
  （`scrollTo(原来最上面那条, anchor: .top)` 把按钮那一截让出去，设计如此）。
  打开（`testMountCost`，每次新文字，单跑，前后交替两轮）：120 条首屏 154.2 / 100.5 → 66.2 / 70.0ms、到停稳主线程 CPU
  318.9 / 374.7 → 249.6 / 289.6ms；400 条首屏 119.3 / 55.4 → 31.5 / 30.3ms、CPU 226.0 / 124.2 → 128.4 / 140.9ms。
  同步解析多出的钱被省掉的「出现后再解析、再重排」抵掉了，不变差。
- **改法**：`AgentTranscriptMarkdown` 在 body 里同步取解析结果（`MarkdownDocumentCache.transcript`，512 段，按全文为键），
  第一次量高就是对的。跟随最新（`AgentTranscriptTailFollow`）、锚点、懒栈都没动。
- **夹具上的坑**：
  - 合成的惯性事件（momentumPhase）SwiftUI 的滚动视图不认，实测一点不动，探针只发 began / changed / ended。
  - 只看 clip view 的偏移量不到抖：文档改高时 SwiftUI 有时把坐标补一大截（画面照旧跟手），有时不补（画面跳），
    所以判据是截图位移，坐标只打印。按 `.textSelection` 的交互层视图位置对位移也不行：短行一样高，投票会投错。
  - 生成的假对话每轮结构一样，截图签名（每行墨量）分不清只差数字的两屏，比对只用在相邻两次采样之间。
- **iOS 同病**（`uTermMobile/Screens/Workspace/ClaudeHistoryTab.swift`，`MStreamingMarkdown` 也在 `onAppear` 才解析）：
  `uTermMobileTests/Probes/ClaudeTranscriptScrollProbeTests`，390×760、120 条、每 16ms 把 `contentOffset` 往回挪 60pt
  共 100 步再往下 100 步，每步截图比对（不走手势）。真机 iPhone 18 Pro Max（改后 / 改前 / 改后）与 iPhone 18 Pro 模拟器
  （改后 / 改前交替两轮）：

  | 臂 | 打开时内容高 | 往回翻：跳 / 整屏换 | 滚动中内容高变 | 打开到停稳主线程 CPU |
  |---|---|---|---|---|
  | 改前 · 真机 | 5471pt | 5 次（最大 372pt）/ 13 | 7 次共 18943pt | 193.4ms |
  | 改后 · 真机 | 26906pt | 0 / 0 | 0 | 143.0 / 188.6ms |
  | 改前 · 模拟器 | 5471pt | 8 次（最大 375pt）/ 13；5 次（最大 101pt）/ 6 | 7 次共 15659pt；8 次共 4423pt | 358.1 / 410.8ms |
  | 改后 · 模拟器 | 27083pt | 0 / 0；0 / 0 | 0 | 319.0 / 281.9ms |

  往下翻改后两处都是 0 / 0（改前往回翻时内容长高、偏移被拽到靠底，往下翻只走得动几百点，不可比）。
  改前偏移会被一下拽走一万多点（3496 → 14992），画面整屏换掉。改法同 Mac：`MTranscriptMarkdown` 在 body 里同步取
  `MarkdownDocumentCache.transcript`（缓存挪到了两端共享的 `StreamingMarkdownRenderer.swift`，两端用同一份）。

## uTermMobile（iOS 端，2026-09-08）

桌面这一整轮做完之后顺手扫的 iOS 端。**这一段和上面所有段的性质不一样**：
上面每段都有真窗口探针的读数，这一段**只有一处有读数**（收进共享层的那个派生量），
其余全是形态归因 + 代码改动，原因写在下面「探针现状」。

### 桌面结论哪些移植了 / 哪些不适用

| 桌面那轮的结论 | iOS 端 | 说明 |
|---|---|---|
| 密集网格里每行挂 `Button` 是主因 | **不适用（没这个债）** | iOS 行体本来就是 `Button` + `MPressStyle`，但规模是「一台机器上的主机 / 密钥 / 分组数」，不是 87 列 × N 行的网格 |
| `.help` tooltip 风暴 | **不适用** | iOS 没有 tooltip |
| 悬停门控 / 整表一个跟踪层 | **不适用** | 触屏没有 hover |
| 单击被双击判定窗口拖慢 | **不适用** | iOS 端一处双击都没有；但**长按 + 单击同链**是 iOS 独有的同族形态，见下 |
| `binding ForEach` / 选中态盖掉语义色 | **不适用** | 扫过，没有 |
| **body 里的全集合循环 / 无界查询** | **就是 iOS 的债** | 本轮全部落地 |
| 非 lazy 容器换懒栈 | **不照搬** | 桌面同轮的反例：小规模档换懒栈反而更慢。iOS 的容器多是 `MInsetGroup` / `MCardList`，规模就是用户自己的库 —— **没读数不动** |

### 改了什么（10 处，按收益排）

1. **Agent 会话历史无界查询**（`Screens/Agent/MobileAgentChat.swift`）——
   `@Query(sort: \ChatSession.updatedAt)` 没有 `fetchLimit`，一开会话就把库里
   **所有** `ChatSession` 取出来物化，而下拉只 `prefix(20)`；更糟的是
   `TerminalScreen` 给**每个终端 tab** 各挂一份 `MobileAgentChat`，开 n 个标签
   就是 n 份全表。改成复用 macOS 已有的 `ChatSessionQueries.recent`
   （`fetchLimit = 50`，该文件本来就编进 iOS target）。
   桌面同一处的读数在案：1000 条会话 **取数 9.5 → 0.7ms、物化对象 1000 → 50**。
2. **密钥列表逐行整表 fetch**（`Screens/Settings/KeysScreen.swift`）——
   `usedCount(_:)` 在 `MInsetRow` 的行体里调
   `context.fetch(FetchDescriptor<ServerProfile>())`：**每渲染一行就把整张主机表
   取出来物化一遍**再 filter。十把钥匙就是十趟全表 fetch。改成一个 `@Query hosts`
   （同文件的 `KeyDetailSheet` 本来就是这么写的）+ body 里建一次 `[UUID: Int]`。
   **这条已升级为判红闸门**（`MobileRenderLintTests.testNoWholeTableFetchOutsideSortOrderSeeding`）。
3. **命令面板每击键 ≥8 趟四表 filter**（`Screens/Palette/CommandPaletteView.swift`）——
   `fHosts` / `fCommands` / `fKeys` / `fGroups` 四个无缓存计算属性，
   `empty` 里各求一遍、body 里 `if !fHosts.isEmpty` + `ForEach(fHosts)` 又各求一遍；
   分组那一行的 `memberCount(_:)` 还是 O(分组 × 主机)。收成一个 `PaletteResults`
   一次求值 + `PaletteMemo` 记忆盒（key = query + 四张表的条数）。
   **只有这块屏敢跨 body 缓存**：它是只读的全屏覆盖层，打开期间没有任何编辑入口。
4. **命令表单关联主机区的嵌套派生**（`Screens/Settings/CommandsScreen.swift`）——
   五个互相套着的计算属性 + 每组重建整张 `groupColorHexes` + 每组扫两遍成员算
   `picked`（`groupState` 一遍、显示用的又一遍），而 `serverIDs` 是 `@State`，
   **每点一台主机整个 body 重跑一次**。收成一趟聚合的 `HostSelection`。
   容器**仍是非 lazy `VStack`**（见上表最后一行）。
5. **主机列表三个派生量 + 逐行重建组色表**（`Screens/Hosts/HostsScreen.swift`）——
   `groupColorHexes` 是计算属性却由 `card(_:)` **逐行**调用：每行重建一次整张
   「组名 → hex」字典再解析一次十六进制，O(主机 × 分组)。改成 body 里
   `MGroupTint.colors(for:)` 求一次往下传；`grouped` / `recent` 同样一次求值，
   `recent` 补上 `prefix(20)`（对齐 macOS `ServerFilter.apply`）。
   **没有做跨 body 记忆化**，理由见下「为什么这里不缓存」。
6. **分组页 O(分组 × 主机) 扫两遍**（`Screens/Settings/GroupsScreen.swift`）——
   `count(_:)` 逐组扫全表，列表里每行一次、页脚 `groups.reduce` 里**再来一次**。
   改成共享的 `ServerGrouping.memberCounts` 一趟过。**这一处有读数**，见下。
7. **设置页五个只为计数的无界 `@Query`**（`Screens/Settings/SettingsScreen.swift`）——
   `ServerProfile` / `SSHKey` / `ServerGroup` / `KnownHost` / `ForwardingRule`
   五张表整表取出来物化，只为显示五个数字（`KnownHost` 在老库里本身就上千行）。
   改成 `context.fetchCount`（SQL 层 `COUNT(*)`，不物化）+ `onAppear` /
   `ModelContext.didSave` 两处刷新补回订阅。
   顺带：「端口转发规则」那一行带着 `chevron: true` 却没有 `onTap`（看着可点、
   点了没反应）——移动端没有转发管理页，**去掉 chevron 变成信息行**，与同屏
   「字体 / 字号 / 光标」一致。
8. **每行现建 formatter**（7 个文件 9 处）—— 新增 `DesignKit/MFormat.swift`
   收静态实例（相对时间 / `yyyy-MM-dd` / `MM-dd HH:mm` / `HH:mm:ss` / 字节数）。
   **没法复用 macOS 的 `WelcomeFormat`**：它在 `Features/Welcome/Views/WelcomeComponents.swift`，
   那个文件在 `uTermMobile` target 的 membership exception 清单里（整个 Welcome/Views
   都是 AppKit 专属），iOS 根本编不到；语义也不同（移动端钉死 `zh_CN`、
   用完整单位、「从未」的兜底文案还分两种）。
9. **SFTP 行体三处**（`Screens/SFTP/SFTPScreen.swift`、`MFileIcon.swift`）——
   ① `ByteCountFormatter.string(fromByteCount:countStyle:)` 那个**类方法**每调一次
   就在内部现建一个 formatter，改走 `MFormat.bytes`（`FileActionSheet` 另两处一并改）；
   ② `permString()` 每行现建 9 元组数组、`map` 成 9 个 `String`、再 `joined()`
   —— 一行 10 次小字符串分配，改成往预留容量的 `String` 里追加 `Character`，
   位表提到 `static let`；③ `MFileIcon` 的 `folderBack` / `docBody` / … 全是**计算属性**，
   一个文档图标一次求值要现建 4~6 条 `Path`，改成按 `size` 缓存的 `MFileIconGeometry`
   （实际只有 26 这一档）。
10. **`MDot(pulse:)` 的行为 bug**（`DesignKit/MComponents.swift`）——
    `anim` 只在 `onAppear` 置位，而三个调用点传的都是**动态**布尔
    （并行执行先 `.pending` 后 `.running`、终端标签先 `.idle` 后 `.connecting`），
    行建出来时还不该呼吸，等它真跑起来置位时机早过了，圈永远不动。
    补 `onChange(of: pulse)`，并在转回 false 时把 `anim` 归零。
    `ParallelRunView` 的 n 台并行：`if pulse` 本来就会把带 `repeatForever` 的那层
    整个撤掉，所以**任何时刻只有真正在跑的行挂着无限动画**——量不到，
    但结构上确认了。

另外：把 iOS 四份手写的分组 / 计数副本收成共享的
`uTerm/Core/Models/ServerGrouping.swift`（`grouped` / `memberCounts` / `recent`），
和 `ServerFilter` 放一起。**收共享层的第二个动机是可测**：iOS 没有测试 target，
视图里的副本钉不了任何闸门；搬到共享层之后它同时编进 macOS target，
就能在现有的 `uTermTests` 里量。

### 唯一一处有读数：`ServerGrouping.memberCounts`

纯逻辑读数（`ServerGroupingTests`，macOS `uTermTests`，ABBA 交替取 p50，
规模与 `WelcomeSidebarCostTests` 同两档以便可比）：

| 规模 | 改前（逐组扫全表） | 改后（一趟过） | 倍数 |
|---|---|---|---|
| 100 台 / 10 组 | 0.400ms | 0.040ms | 10.0× |
| 2000 台 / 10 组 | 7.900ms | 0.807ms | 9.8× |
| 2000 台 / 60 组 | **47.882ms** | **0.852ms** | **56.2×** |

结构判据（闸门）：改后 2000×60（0.852ms）与 2000×10（0.807ms）在同一量级 ——
成本**不随分组数涨**；改前 7.900 → 47.882ms 是标准的 O(分组 × 主机)。
`grouped` 同样钉了不随分组数涨的闸门（2000×10 = 1.182ms、2000×60 = 1.166ms）。
与 `ServerFilter.counts` 改前那一处是同一个形态、同一个量级（那边单独就是 50ms）。

绝对毫秒只打印；闸门用的是「2000×60 < 2000×10 × 2 + 1ms」这个结构判据，
以及同轮 legacy / tuned 的相对差。

### 为什么主机列表不做跨 body 记忆化

`HostsScreen` 的 cache key 只能拿 `hosts.count` / `groups.count` 这类 O(1) 签名
（SwiftData 数组逐元素比身份是 O(n)，比派生本身还贵），而**「改了某台主机的分组名」
恰恰不改条数** —— 编辑表单一关，分组段就会停在旧值。这三个派生量本来每次 body
也只需要各一趟，跨 body 缓存换不来什么，却要拿正确性去赌。
命令面板敢缓存是因为它是只读覆盖层（见上 3）。

### 探针现状：iOS 一条真窗口读数都没有

- **桌面 AppKit 探针夹具 0% 可用**：`ProbeWindow` / `ProbeMetrics` / `VisionTextProbe`
  全套建在 `NSWindow` / `NSView` / `NSEvent` 上，iOS 没有对应物。
- **iOS 没有测试 target**，本轮也没能新建：这台机器上
  `xcrun simctl list runtimes` **一个 runtime 都没有**，
  `xcrun simctl list devices available` 全部 Unavailable（iOS 17.5 ~ 26.5 逐条）。
- **连编译都过不去**：Xcode 26.6 里 `-showsdks` 列出了 iOS 26.5 / iOS Simulator 26.5
  的 SDK，但 `xcodebuild -destination 'generic/platform=iOS Simulator'` 报
  「Found no destinations」、device 档报「iOS 26.5 is not installed. Please download
  and install the platform from Xcode > Settings > Components」——
  **平台组件没装**，只有 SDK 桩。要补得下载数 GB 的 iOS 平台组件，本轮没做。
  用 `swiftc -frontend -parse`（iphonesimulator26.5 SDK）把全部 41 个
  `uTermMobile/*.swift` 过了一遍语法，零报错；但那只是**语法**，不是类型检查。
- 因此本轮 iOS 侧的自动化只有 macOS `uTermTests` 里的两样：纯逻辑闸门
  （`ServerGroupingTests`）+ 文本 lint（`MobileRenderLintTests`、
  `GestureChainLintTests` 扩到扫 `uTermMobile/`）。
  共享层的改动（`ServerGrouping`）由 macOS build 真正类型检查过。

### 长按 + 单击同链：没能证实也没能证伪

`SFTPScreen` 的文件行把 `.onTapGesture` 和 `.onLongPressGesture(minimumDuration: 0.45)`
挂在同一条修饰链上。SwiftUI 在这种组合下「长按满时长触发一次、抬手时**再**派发一次
tap」是有可能的 —— 真发生了就是「长按一个目录：动作面板弹出来的同时目录也被打开了」。
没有可用的模拟器 runtime，**没法在真设备行为上确认**。

所以没有改手势组合（换 `.exclusively(before:)` 在拿不到读数时是拿「点不动了」去赌），
而是加了一个**两种情况下都正确**的守卫：`guard actionEntry == nil`。
长按一定会把 `actionEntry` 置上（动作面板开着），面板开着时这一行本来就不该响应点击；
不双触发时这里读到的恒是 nil，守卫是惰性的。
**没用时间窗**——时间窗要猜「按住多久才抬手」，按久一点就漏。
lint 里另有一条只打印的扫描（`MobileRenderLintTests.testReportTapAndLongPressOnTheSameChain`）
把这个形态列出来。

### lint 首次运行的命中清单（2026-09-08）

判红两条：手势链双击 + 单击（0 处）、`uTermMobile/` 渲染路径整表 fetch（0 处，
本轮修完；剩下 3 处 `context.fetch` 都在 `save()` 里求下一个 `sortOrder`，按指纹放行）。

只打印的四条：

- **单击 + 长按同链：1 处** —— `SFTPScreen.swift:275`（已加守卫，见上）。
- **行体现建 formatter：0 处**（改前 9 处 / 7 个文件，本轮清零）。
- **`@Query` 无 `fetchLimit`：24 处** —— 绝大多数是正当的（主机 / 分组 / 密钥列表
  本来就要全表，规模是用户自己的库且不会无限长）。**真正该盯的是会一直长的两张表**：
  `ChatSession`（本轮已钉 `fetchLimit`）与 `KnownHost`
  （`FingerprintsView.swift:6`，仍是无界，见「未决账」）。
- **非 lazy `VStack` + `ForEach` 行体带 `Button`：27 处** —— **不要照着这份清单
  无脑换懒栈**，桌面同轮的反例摆着（小规模档换懒栈更慢）。这份清单的用途是
  「哪天某块屏卡了，先来这里找形态」。规模最可能失控的三处：
  `CommandsScreen.swift:209`（关联主机区，规模 = 主机数）、
  `GroupsScreen.swift:231`（分组成员，规模 = 组内主机数）、
  `QuickCommandDetailView.swift:192`（执行日志，规模 = 历史条数）。
- 颜色 lint 扩到认 `M.<色>` / `accent` 之后，iOS 侧严格形态命中 1 处：
  `MComponents.swift:354  let c = danger ? M.danger : (iconColor ?? accent)`
  —— 看着是**设计要的**（危险态统一压红），只是提示，不判红。

### iOS 侧仍开着的账

- **一条真窗口读数都没有**（上面「探针现状」）。要补：装 iOS 平台组件 + 一个模拟器
  runtime，然后建 `uTermMobileTests`（pbxproj 用 synchronized group，照 `uTermTests`
  的写法，`TEST_HOST` 指向 `uTermMobile.app`），放 `UIHostingController` 挂载耗时探针
  （SFTP 1000 条目 / 主机 2000 台）。本轮**没做成**，不是没做。
- **长按 / 单击是否真的双触发**，未证实（见上）。
- **`FingerprintsView` 的 `KnownHost` 仍是无界 `@Query`** —— 这张表随连过的主机数
  单调增长，是本轮清单里唯一「规模 = 库且会一直长」还没钉的。
- **27 处非 lazy 容器**都没量过，一个都没改。
- **并行执行屏（iOS）没做的三条**：① `shellBody` 没有贴底跟随（tail-gap 极端档
  4939 → 661782pt），补它要先定「用户往上翻之后还跟不跟」的产品口径；
  ② AI 模式（`aiBody`）的整屏成本没量 —— 探针只跑了 Shell 模式与单独挂的泳道列表，
  AI 模式还要一个假 `ParallelDoctor`（`ParallelDoctor` 是具体类型，没有协议）；
  ③ 「信任并重试」这条交互的端到端成本没量（要造真的 `HostKeyChallenge`）。


### `MobileAgentChat`：工具执行注入口 + 渲染窗口（iOS，2026-09-08）

**这一段是 iOS 端第一份带真窗口读数的 Agent 屏评估**（上面「探针现状」那条账，
Agent 屏这一块结清了）。宿主 iOS 26.5 模拟器（iPhone 17 Pro，**maxFPS = 60**，
单帧预算 16.67ms），窗口 390×700，全量前 `caffeinate -dimsu`。

#### 先补注入口（这是本轮的主要交付）

改前 `MobileAgentChat.configureModel()` 直接
`WorkspaceCommandExecutorFactory.make(server:container:)` 现造真 SSH 执行器，
于是「批准 → 执行 → 输出回填 → 完成态」这条链在测试里根本走不通
（`uTermMobileTests/README.md` 的「注入口缺口」表里挂着）。

新增 `uTerm/Features/Agent/Backend/AgentCommandExecutorSeam.swift`：

- `AgentCommandExecuting`：`CommandExecutor` 的精化（多一条 `cancelInFlight()`），
  把契约写死 —— 执行命令 / 按节拍攒输出 / 返回退出码 / 可取消 / 可失败 / 可超时。
  生产类型 `SSHCommandExecutor` **零改动**满足。
- `AgentCommandExecutorFactory`：`.live`（默认，逐字等价于改前那两行）、
  `.stub(_:)`、`.none`。
- 环境值 `\.agentCommandExecutorFactory`，默认 `.live`。**生产路径零行为变化**：
  桌面两处调用点（`TerminalWindowView` / `WorkspaceWindowView`）与
  `ParallelRunModel` / `QuickCommandRunner` 都仍直呼
  `WorkspaceCommandExecutorFactory`，本轮一个字没动。

测试侧 `MobileFakeCommandExecutor`（行数 / 节拍 / 退出码 / 失败 / 超时可配）
＋ `MobileFakeAgent.toolCallScenario(...)` 把整条剧本串起来。

#### 读数一：历史回放（200 / 1000 条 × 渲染窗口 关 / 开，同轮，轮内顺序反转）

| 档 | 挂载 | 单帧 p50 | p95 | 超 8.33ms | UIView | hitTest p50 | 文档高 |
|---|---|---|---|---|---|---|---|
| 200 · 无窗口 | 180.7ms | 1.116ms | 1.653ms | 0.0% | 25 | 8.9µs | 472982 |
| 200 · 窗口 200 | 69.6ms | 1.086ms | 1.660ms | 0.0% | 25 | 4.1µs | 478892 |
| 1000 · 窗口 200 | 181.2ms | 1.050ms | 1.949ms | 0.0% | 31 | 6.1µs | 447787 |
| 1000 · 无窗口 | 65.8ms | 1.235ms | 1.925ms | 0.0% | 31 | 5.0µs | **2388073** |

- **挂载列不能读**：两对里各是「先跑的那一档更贵」（180.7 / 69.6、181.2 / 65.8），
  这是 SwiftUI 首次渲染的一次性开销砸在每对的第一个 fixture 上 —— 正是
  `MobileProbeRig.mount` 的注释警告过的那件事。顺序反转把它暴露出来了，没有掩盖它。
- **滚动本身与规模无关**：`UIView` 25 / 31（200 条与 1000 条几乎相同），
  超预算帧 **0.0%**，钳 3 视口的 p50/p95 四档一致。`LazyVStack` 在 iOS 上确实回收行，
  与桌面同结论。
- **窗口买到的是几何**：1000 条文档高 **2388073 → 447787（5.33×）**，
  与桌面的 5.2× 一致。

#### 读数二：流式 30 秒（20 chunk/s，1000 条打底，两臂同轮，先 legacy 后 windowed）

| 臂 | `Task.sleep` 拍/理想 | `CADisplayLink` 拍/理想 | 30s 收到字符 | 投递块 | UIView min~max | 流式期单帧 p95 | 超 8.33ms | footprint |
|---|---|---|---|---|---|---|---|---|
| 无窗口 | 2780/3750 (0.74) | 1698/1800 (**0.94**) | 14326 | 600/600 | 19~22 | 6.341ms | 3.3% | 280.1MB |
| 窗口 200 | 3044/3750 (0.81) | 1690/1800 (**0.94**) | 14326 | 600/600 | 22~25 | **3.579ms** | 1.7% | 198.5MB |

**桌面那条最响的结论在 iOS 上不成立**：桌面 1000 条流式时主线程只剩理想心跳的
12%（184/1500），渲染窗口抬到 32%（481/1500，2.61×）。iOS 这边**两臂的渲染循环
都跑满 0.94**，拍数比值 **1.00×**；两臂 30 秒都收满 600 块 / 14326 字符，
一块不落。也就是说 **iOS 的 Agent 流式没有被挂载条数拖垮** —— 原因大概率是
`MStreamingMarkdown` 的 100ms 重解析节流 + `LazyVStack` 真回收 + 移动端窗口只有
390×700（在屏行数少），但这只是推断，没有单独量证。

窗口在 iOS 上买到的是另外三样，都在同轮里稳定复现：
**流式期间单帧 p95 6.341 → 3.579ms（1.77×）**、超 8.33ms 的帧 **3.3% → 1.7%**、
footprint **280.1 → 198.5MB**，外加上面那条 5.33× 的文档高度。
`UIView` 波动两臂都只有 3~6（19~22 / 22~25），不随会话总量涨。

**复跑一轮（同机同日）**，方向全部一致、绝对值有噪声：
拍数 1667/1800 (0.93) vs 1675/1800 (0.93)、`sleep` 0.72 → 0.81、
流式期单帧 p95 **3.162 → 2.230ms（1.42×）**、字符 14302 / 14326。
两轮共同结论：**拍数比值 1.00×（窗口不改善主线程占用），单帧 p95 改善 1.4~1.8×**。
文档高度两轮**逐位相同**（2388073 / 447787）—— 它是确定性的，所以闸门放在它上面。

#### 读数三：一次工具执行端到端（本轮注入口的直接产物）

- 批准 → 完成 **279.3ms**（假执行器 40 行 @ 200 行/s，理想 200ms；差的 79ms 是
  状态机落库 + 卡片回填 + 续轮启动）。
- **卡片重绘 2 次**（pending → running → done）。计数走
  `ToolCardProbeHost`：吃同一份 `@Observable` 依赖、渲染同一个产品视图 `MToolCall`。
- 负路径：失败 **70.4ms** 落 `.failed`、错误文本折回卡片；
  超时 **647.0ms**（配 600ms）落 `.failed`。
- 「按节拍」有证人：执行途中 `emittedLines` 取到中间值，不是瞬间返回。

#### 读数四：会话历史菜单

1000 条会话的库上，取数**钉住 1.60ms / 50 条 vs 无界 26.31ms / 1000 条（16.5×）** ——
`ChatSessionQueries.recent` 的 `fetchLimit` 在移动端仍然生效（回归闸门）。
菜单内容（20 条 `Button`）挂载 88.45ms。

#### 判定与改法

**B**。滚动那一半是 A（超预算 0.0%、`UIView` 不随规模涨），但几何与流式单帧越线，
且桌面已有现成处方，照抄成本极低：

1. `AgentMessageWindow` 渲染窗口 200 条 + 顶部「显示更早的 N 条」（一次放开 200）。
   **只裁渲染不裁数据**：`model.messages` / SwiftData 记录 / 模型上下文一条不动。
   换会话（首条消息换身份）时窗口收回默认值。
2. 三条只做贴底跟随的 `onChange`（`messages.count` / `messages.last?.text` /
   `state`）合成一个 `MChatTailSignature`（镜像桌面 `ChatTailSignature`）。
   正文用 `utf8.count` 而不是整串。
3. `.help` 悬停门控那一条**不适用**：iOS 没有 tooltip。

**前→后**（1000 条）：文档高 **2388073 → 447787 pt（5.33×）**；
流式期单帧 p95 **6.341 → 3.579ms**、超 8.33ms **3.3% → 1.7%**；
footprint **280.1 → 198.5MB**。滚动读数与 hitTest 在噪声内
（**渲染窗口不改善普通滚动，只改善几何、流式单帧与内存**，与桌面同）。

- **探针类名**：`uTermMobileTests/Probes/AgentChatProbeTests.swift`
  （`testHistoryReplayMountAndScroll` / `testStreamingMainThreadCost` /
  `testToolExecutionEndToEnd` / `testToolExecutionFailureAndCancellation` /
  `testSessionHistoryMenuOpenCost`）。
- **没做到的**：
  - 「iOS 流式为什么不被挂载条数拖垮」只有推断，没有拆账（没有单独量
    `MStreamingMarkdown` 节流 / `LazyVStack` 回收各占多少）。
  - 屏幕里那张真卡片的 body 求值次数量不到（在 `LazyVStack` 深处、
    `messageRow(_:)` 内联构造），只能用同源的 `ToolCardProbeHost` 代测。
  - `Menu` 的点开手势在 unit test bundle 里合成不了，菜单读数是「内容视图直接挂载」
    的耗时，不含 UIKit 弹出动画。
  - 桌面两处调用点没有改走注入口（任务范围外，且改了就是动桌面视图）。

### 终端屏 · 会话常驻挂载与输出压力（`uTermMobile/Screens/Terminal/*`，2026-09-08）

- **规模**：
  - 输出速率 —— 真实档 **60 行/秒**（交互式 shell / `tail -f` 跟一条中等流量日志），
    极端档 **2000 行/秒**（`yes` / `cat 大文件`，80 列 ≈ 250KB/s）。两档都跑满 10 秒。
  - 会话数 —— **1 / 4 / 8**。`TerminalScreen.openTab` 对同一台主机去重，但「新建终端」
    显式 `allowDuplicate: true`，会话数只受用户手指限制；8 个是手机上的合理上界。
- **前置**：先补注入口。`MobileTerminalController` 原本在 `start()` 里直接 `new SSHConnection`，
  探针进不去。本轮把后端换成桌面早就有的 `TerminalBackend` 协议 + 一个工厂
  （`MobileTerminalTransportFactory`），默认 `.live` 就是原来那段组装，生产路径零行为变化。

#### 读数（2026-09-08，iPhone 17 Pro / iOS 26.5 模拟器，Debug，390×700，`.transparentOnScreen`，budget 16.67ms）

**尺一 · 单会话在输出压力下（10 秒窗口，理想 sleep 拍 1250 / display 拍 600）**

| 档 | 挂载 | sleep 拍 | display 拍 | 单帧 p50 | p95 | 超 8.33ms | UIView | 吐出 |
|---|---|---|---|---|---|---|---|---|
| 1 会话 × 60 行/秒 | 13.3ms | 905 (0.72) | 599 (1.00) | 0.065ms | 6.020ms | 0.4% | 12 | 615 行 / 76KB |
| 1 会话 × 2000 行/秒 | 14.0ms | 926 (0.74) | 599 (1.00) | 0.050ms | 5.751ms | 0.0% | 12 | 20520 行 / 2.5MB |

**单会话判 A**：极端档比真实档还稳（`TerminalOutputBuffer` 的有界合并 + 16ms 一次 `feed`
本来就是为这个写的），display 拍恒 1.00，超预算 ≤ 0.4%。SwiftTerm 自绘一屏的成本与
喂进去多少字节几乎无关。

**尺二 · N 个会话「全部常驻挂载」（`.idle` 脚本，不吐字节，量结构本身）**

| 会话数 | 挂载 | UIView | hitTest p50 | 切 tab p50 | 切 tab p95 | footprint |
|---|---|---|---|---|---|---|
| 1 | 16.18ms | **15** | 3.9µs | — | — | 72.1MB |
| 4 | 52.28ms | **54** | 4.1µs | 6.743ms | 19.382ms | 81.3MB |
| 8 | 96.51ms | **106** | 4.1µs | 8.755ms | 10.746ms | 96.9MB |

线性：**每多一个会话 +13 个 `UIView`、+11.5ms 挂载、+3.5MB footprint**。
这就是 `ZStack { ForEach(tabs) { TerminalSessionBody } }` 全常驻的直接账
（每片 = 一个 SwiftTerm `TerminalView` + 一整个 `MobileAgentChat` + 一条键盘条）。
hitTest 不随会话数涨（非活动片 `allowsHitTesting(false)`），切 tab p50 在 8 个会话时
已经吃掉半个 16.67ms 预算。

**尺三 · 非活动 tab 到底在不在消费输出**（4 会话 × 2000 行/秒，只有一个是激活标签）

```
[term-inactive-4x2000-tab0] active=yes emitted=16760 consumed-advance=542
[term-inactive-4x2000-tab1] active=NO  emitted=16840 consumed-advance=542
[term-inactive-4x2000-tab2] active=NO  emitted=16880 consumed-advance=542
[term-inactive-4x2000-tab3] active=NO  emitted=16920 consumed-advance=542
[term-inactive-4x2000-verdict] active=542 inactive-avg=542 ratio=1.00
```

**量证了**：切走的会话与激活会话消费得一模一样 —— 因为它只是 `opacity(0)` + 移出屏外，
控制器那条 16ms 的 flush 循环照跑，SwiftTerm 照解析照重绘。

同轮对照（会话数固定 4，只改「几个在吐」）：

| 档 | sleep 拍/1000 | 单帧 p50 | p95 | max | 超 8.33ms | 主线程 CPU |
|---|---|---|---|---|---|---|
| 只有 1 个在吐 | 673 (0.67) | 0.057ms | 6.253ms | 7.849ms | 0.0% | 3.281s |
| 4 个都在吐 | 464 (0.46) | **3.939ms** | 11.625ms | 15.406ms | **16.6%** | 6.960s |

- **判定**：单会话 **A**；「非活动 tab 全量渲染」**B（就地修）**。
- **改法（B）**：`MobileTerminalController.isForeground` —— 后台会话（非激活标签，或
  处于 Agent 模式）把 feed 节拍从 **16ms 降到 250ms**，单次 drain 上限从 32KB 放大到
  512KB（节拍慢 16 倍，上限不放大就会把 4MB 环形缓冲挤爆 → 那是丢数据不是降频）。
  **字节照常进有界缓冲一个不少**，回滚缓冲与 `cat` 的完整输出都不受影响；只是不再每
  16ms 逼 SwiftTerm 解析 + 重绘一次。切回前台时 `didSet` 立刻重启 flush 泵，把那 250ms
  的等待截断。视图侧由 `TerminalSessionBody` 的 `onAppear` / `onChange(of: isActive)` /
  `onChange(of: tab.mode)` 同步；**刻意不接 `onDisappear`** —— 外壳在 Tab/Split 间切换时
  `TerminalScreen` 会重建，旧片的 `onDisappear` 可能晚于新片的 `onAppear` 到，
  置 false 会把会话卡在后台档。
- **前→后**（同一轮，4 会话全部 2000 行/秒，唯一差别是那个开关）：

  | | 前台片 | 单帧 p50 | p95 | max | 超 8.33ms | sleep 拍/1000 | 主线程 CPU |
  |---|---|---|---|---|---|---|---|
  | 前（全前台） | 4/4 | 3.855ms | 11.193ms | 23.617ms | **15.2%** | 468 (0.47) | 6.771s |
  | 后（按活动态） | 1/4 | **0.041ms** | **4.198ms** | 8.318ms | **0.0%** | 515 (0.52) | 5.910s |

  两档四片的消费计数都是 `[542, 542, 542, 542]`、吐出行数 15600 vs 15480 —— **降频没丢字节**。
  改后再跑「1 个在吐 vs 4 个都在吐」，p50 **0.045 → 0.045ms（×1.00）**：多开的后台会话
  不再向主线程收税。

**尺四 · 键盘面板展开**（`TerminalKeyBar`，390×320）

| 档 | 挂载 | UIView | hitTest p50 | ink |
|---|---|---|---|---|
| 收起（紧凑行，11 键） | 6.36ms | 4 | 1.0µs | 0.091 |
| 展开（4 组 57 键） | 24.31ms | 9 | 1.1µs | 0.366 |

**判 A**：展开一次 24ms 是「一次性、用户点了才付」的账，`LazyVGrid` 里 57 个 `Button`
没有把 `UIView` 数拉起来（4 → 9，是两层 `ScrollView` 的框架视图）。

**尺五 · `MDot` 只在连接中的会话片动**（8 片标签条，4 秒窗口，理想 display 拍 240）

| 档 | 呼吸圈数 | UIView | display 拍 | 单帧 p50 | 主线程 CPU |
|---|---|---|---|---|---|
| 8 片全 `.connected` | **0** | 4 | 240 (1.00) | 0.072ms | 0.182s |
| 8 片全 `.connecting` | **8** | 4 | 240 (1.00) | 0.110ms | 0.262s |

**判 A**：`MDot` 带 `repeatForever` 的那一层包在 `if pulse` 内，`.connected` 档一个都不建；
8 个同时呼吸也只多 0.04ms/帧、0.08s CPU，display 拍两档恒 1.00。盘点里「每片带
`MDot(pulse:)`」这条账**不成立** —— 呼吸圈数等于在连的会话数，不是标签片数。

#### 探针 / 夹具类名

- `uTermMobileTests/Probes/TerminalScreenProbeTests.swift`（7 条）
- `uTermMobileTests/Fixtures/MobileFixturesTerminalTests.swift`（11 条自证）
- `uTermMobileTests/Support/MobileFixturesTerminal.swift`（假传输 + 载荷尺 + 消费计数）

#### 没做到的

1. **「切 tab 耗时」只量到 `activeID` 变更后一次 `layoutIfNeeded + CATransaction.flush`**，
   不含 SwiftUI 的转场动画与键盘 `becomeFirstResponder` 那一段（后者走
   `DispatchQueue.main.asyncAfter(0.05)`，探针的同步尺够不着）。
2. **消费计数会饱和**：`getTopVisibleRow()` 顶在 SwiftTerm 的 500 行 scrollback 上，
   所以 `advance` 只是「至少消费了这么多」的下界，不能拿来比两档的**消费速率**。
   「降频没丢字节」这条靠的是「两档 advance 都到顶 + 吐出行数同阶」，不是逐字节对账。
3. **`TerminalScreen` 全常驻这件事本身没改**（8 会话 +91 个 `UIView`、+25MB）。
   真要拆得把非活动片的 `MobileAgentChat` 卸掉，那会丢掉「跨标签保活对话 / 草稿 /
   滚动位置」的产品契约 —— 是产品决策，不是性能改法，本轮只把账记下来。
4. **`SSHConnection` 的握手 / 认证 / 跳板机那一段不在假传输的路径上**，
   建连时延只能靠 `connectLatency` 近似。
5. **只在 iPhone 17 Pro 上跑过**，没在 iPad 档复量。

### 并行执行屏 · Shell（iOS，`uTermMobile/Screens/Parallel/ParallelRunView.swift`，2026-09-08）

桌面同名视图那段在上面（`ParallelShellGrid`）。**移动端是另一套形态**：桌面是
「每台一个带自己 ScrollView 的迷你终端窗格 + 网格」，移动端是「一条外层
`ScrollView` + `LazyVStack`，一台一格竖着排，格内的行原本是**非懒的** `VStack`」。
所以桌面那段的读数与改法不能照搬。

- **规模**：真实档 6 台 × 600 行（一条快捷命令绑定的服务器数 = 一个分组量级；
  行数 = `SSHCommandExecutor(maxLines: 200)` × 自愈几步），极端档 24 台 × 1200 行
  （`ParallelRunController.maxAgentSteps = 6` × 每步 200 行封顶 = 1200；24 台 =
  中型分组整批广播）。两档都**不预置历史**，10 秒内把该档行数全流进来
  （真实档 60 行/秒/台、极端档 120 行/秒/台），与桌面同口径。
- **怎么挂上的**：产品侧先开了执行器缝 —— `ParallelCommandExecuting` /
  `ParallelExecutionSession`（按主机起会话、按节拍回吐行、可取消、可失败），
  生产实现 `SSHParallelExecutor` 原样包住 `WorkspaceCommandExecutorFactory`，
  探针注入 `MobileFakeParallelRun`；`ParallelRunView` 加了
  `makeController:` 工厂与 `controller:` 直注入两个口。于是**整屏**（真控制器、
  真 `runLane` / `markUnreachable` / `finalize`）挂得上 `MobileProbeRig`。
- **读数**（iPhone 17 Pro 模拟器 iOS 26.5，Debug，60Hz → 预算 16.67ms，
  两轮同机对照；「追加期」= 10 秒里每 8ms 逼一次布局 + CA 提交）：

  | 档 | 追加期 8ms 心跳 /1250 | 追加期 p95 | 追加期超 8.33ms | 落定后往返 p50 / p95 | **跨格一跳 p50 / max** | hitTest p50 | UIView | footprint |
  |---|---|---|---|---|---|---|---|---|
  | 6×600 前 | 983 | 2.39ms | 0.3% | 2.04 / 2.71ms | **161.4 / 176.8ms** | 6.1µs | 6 | 414MB |
  | 6×600 后 | 1114 / 1077 | 0.72 / 1.67ms | 0.0% | 1.73 / 3.09ms | **17.3 / 23.6ms** | 9.9µs | 6 | 68MB |
  | 24×1200 前 | 770 | 10.66ms | 7.8% | 3.21 / 4.24ms | **316.2 / 366.9ms** | 3.0µs | 6 | 1075MB |
  | 24×1200 后 | 1027 / 1010 | 2.06 / 2.40ms | 0.0% | 1.76 / 2.81ms | **20.8 / 17.6ms**（max 80.8 / 67.1） | 6.0µs | 6 | 73MB |

- **判定：B（SwiftUI 就地修）**。往返扫掠那把尺**判不出问题**（两档 p95 都 ≤ 5.3ms、
  超预算 0%）—— 因为它钳在 3 个视口内，而极端档**一格就有两万多 pt**：
  200 步往返从头到尾都在同一格里，跨格的账它一次都没量到。补一把「一格一格往下翻」
  的尺才看见真账：一跳 161~367ms，是 16.67ms 预算的 **10~22 倍**。
- **病灶**：外层懒栈只保证「没进视野的**格**不建」；一旦某格进视野，格内**非懒**的
  `VStack { ForEach(state.lines) }` 会把这一台的 1200 行**整批**建出来。
- **改法**：格内 `VStack` → `LazyVStack`（一行，`ParShellPane.body`）。
  代价与桌面 `ParTermLinesView` 那次一样：内容高从「实测」变「估高」，滚动时会随着
  真行落位微调（同一档两轮 `content` 664824 / 779918pt 就是这个）。行高本来就不定
  （长行换行），本来也没有可靠的实测高度可言。
- **前→后**（同机两轮）：跨格一跳 p50 161.4 → 17.3ms（6 台）、316.2 → 20.8ms（24 台）；
  追加期 p95 10.66 → 2.06ms、超 8.33ms 7.8% → 0.0%、心跳 770 → 1027 / 1250；
  进程 footprint 峰值 1075 → 73MB。
- **闸门（结构判据 / 同轮相对比，绝对毫秒只打印）**：
  ① 跨格一跳 p50 **不随每格行数涨** —— 每格 600 → 1200 行时比值改前 1.96、改后 1.15~1.20，
  闸门钉在 < 1.6；② `UIView` 数不随台数涨（两档恒 6）；③ `scrollable > 0` +
  `travelled > 700`；④ 追加期心跳没掉到 1/8（真实档）/ 1/16（极端档）以下。
- **`ticker` / `MDot` 脉冲只在运行中的行跑**：像素判据 —— 同一屏隔 1.2 秒截两张。
  运行态（配成 60 秒才吐 4 行，窗口里没有新行）两张**不同**（对照组，证明这套判法
  看得见变化）；完成态两张**逐字节相同**（418200 字节）——
  `ticker` 被 `allDone` 门住、`MDot` 的 `if pulse` 把带 `repeatForever` 的那层整个撤掉。
- **贴底跟随：移动端根本没有**。`shellBody` 里没有 `ScrollViewReader`、没有
  `defaultScrollAnchor(.bottom)`，输出一直在底下长而视口不动：tail-gap 真实档
  751 → 82981pt、极端档 4939 → 661782pt。桌面 `ParallelShellPane` 有整套
  （热路径贴最后一行 id、凉路径 350ms 后贴真底部）。这是**行为差异不是性能问题**，
  本轮没有补 —— 补它要定「用户往上翻之后还跟不跟」的产品口径。探针里那条断言
  按「gap 会涨」钉着，真加了跟随会红，那时翻成桌面口径的 `< 200`。
- **探针类名**：`uTermMobileTests/Probes/ParallelRunProbeTests.swift`
  （`testShellStreamingAndScroll` / `testAILaneExpansionCost` /
  `testTickerAndPulseOnlyRunWhileRunning`）。
- **没做到的**：见文末「iOS 侧仍开着的账」新增的三条。

### 并行执行屏 · AI 泳道展开（iOS，同文件）

- **规模**：24 条已收尾的泳道，每条 6 步处理过程（= `maxAgentSteps`）。
- **读数**（同机同轮，收起 vs 展开）：内容高 3519 → 9231pt、`UIView` 6 → 6、
  往返 p50 1.17 → 0.95ms / 1.13 → 0.72ms、p95 3.24 → 2.43ms、超预算 0%、
  挂载 55.4 → 30.2ms（挂载跨档不可比，第一档吃首次渲染的一次性开销）。
- **判定：A（不动）**。展开只是多几行纯 `Text` + `Circle`：内容高涨 2.6 倍，
  视图数一个不涨、滚动成本反而略降（噪声内）。
- **闸门**：展开后内容高 > 收起 × 1.2（证明这一轮真的展开了，否则对照作废）+
  视图数不随步数涨。
- **量不到的**：「点一下那个按钮」的端到端成本 —— `open` 是 `@State`，SwiftUI 的
  Button 在 iOS 视图树里不是 `UIControl`，hitTest 也点不着。探针走的是
  `ParAILane(initiallyOpen:)`（默认 false = 现状）做前→后，量的是**展开态的稳态成本**，
  不是那一下动画的成本。

## 未决账

下面 1~6 条是 Agent 消息流 / 预览窗口 Markdown 那一轮明确挂起的账，**编号沿用**
（那两段里「见文末「未决账」1 / 2 / 5」「3 / 4 / 6」指的就是它们）。
再往下是其余视图「没做到的」里**仍开着**的部分，每条一行，细节回各自那一段读。

1. **Agent 面板挂载的 0.9~1.3s 没有拆开**。它不跟挂载条数走（上限 25 与 ∞ 的挂载几乎一样），
   所以既不是列表也不是 Markdown；嫌疑在 `NSHostingView` 建树 + 首屏布局 + SwiftData 容器。
   要动它先得把这一步拆成分项计时。
2. **满程跳转两臂都有 3.6~4.1s 的最坏一跳**。8 次采样的 p50 两轮反向，是噪声；但
   `jump-max` 两轮都稳定在 3.6~4.1s，说明「一跳跨几十屏」这件事本身很贵。
   量它需要一把不会把宿主挂死的尺（当前的 8 跳版本已经是妥协）。
3. **2.8MB 文档的 `Document(parsing:)` 是主线程上的 0.57~0.63s**，分段没有动它 ——
   分段只省了「建视图」，没省「解析」。挪到后台要改 `StreamingMarkdownRenderer` 的
   `@MainActor` 假设。
4. **预览真实档的 hitTest 1.3ms 偏高**（对照：`ProbeSmokeTests` 的纯 `Text` 行是 121µs），
   两臂相同、不随分段变化，没有归因。
5. **`ChatCodeBlock` 仍占消息流 2.33× 的挂载**，而「去掉 `Button`」那条路已经证伪。
   下一个候选只剩「让代码块本身构造变便宜」（例如落定后才挂横向 `ScrollView`），未量。
6. **表格（逐格 `MDInlineView`）的单独成本没有分离**。造数据时表落在极端档第一段之外，
   要单独一档「只有大表」的文档才量得到。

### 其余视图仍开着的账（索引）

- ~~**滚动期间「光标在内 / 在外」仍有 1.38~2.60× 的差**~~ —— **2026-09-08 结清**
  （「行悬停：整表一个跟踪层」那一段）：换成整表一个跟踪层之后六档全落在 0.90~1.03×。
  归因也一并更正：不是 AppKit 的追踪区，是 SwiftUI 内部那张 hover 区域表。
  仍开着的尾巴见那一段的「量出来但没有改的」——① 单主机转发列表在「有异常规则」时
  退回逐行 `.onHover`（error 行的原因条高度由文案撑出来，行不等高）；② Agent 消息流
  没有可用的行几何；③ UDesignKit 的 19 处通用 `.onHover` 仍未动；
  ④ `mouseMoved` 的真机投递只有手工构造 `NSEvent` 的单测，端到端要人肉验。

- **欢迎页服务器列表行**：真鼠标下的悬停 / tooltip / 双击留给人肉验收（夹具边界见
  「已排除的路」18）。
- **欢迎页左侧栏**：2000 台 / 60 组仍要 21ms 一击键。剩下三笔 —— ① 分组 `ForEach` 仍是
  非 lazy（`UDSidebarRow` 的 plain `Button` 在 **uAppKit 共享包**里、以 uTable 为 canonical，
  本轮不动）；② `WelcomeSidebarNav.shortcutHint` 每行一次 `entries.firstIndex(of:)`；
  ③ 11 个零尺寸快捷键 `Button` 每次 body 重建。
- **欢迎页（侧栏外面，同一类账）**：`WelcomeView.existingGroups` 每次 body 扫全表取
  `group` 再 Set + sort（2000 台 / 60 组 1.172ms），随每次击键与每按一次 ↑/↓ 重跑。
  改法要先确认 `GroupStore.reconcile` 的对齐保证；读数已钉在
  `WelcomeSidebarCostTests.testWelcomeViewPerBodyDerivationsCost`。
- **⌘K 命令面板**：2202 项每次击键仍要 7.1ms。再往下得给 filter 预算小写化的
  title / detail，或把搜索挪出主线程。
- **SFTP 文件表 / 侧栏文件树**：5 标签同时挂载没改（滚动在线内，改它要搬 5 个跨标签
  `@State` 并重排连接生命周期）；筛选击键剩下的 ≈52ms 要升 C 才压得动；20000 × 5 没跑；
  VoiceOver / 全键盘控制下的实际表现没量。
- **SFTP 传输进度**：每次进度写入仍让**整个** `transfers` 的观察者失效 —— 真实频率下不
  构成问题，但 emitter 的 `minimumInterval` 调小或并发调到 64 时要重新摆上桌（届时一并
  处理「同步可见」这条契约）；浮层 `rows` 仍每次 body 重排一遍（1000 行 O(n log n)）；
  没碰 `entries` / 文件列表相关代码。
- **并行执行 · Shell 网格**：极端档仍 100% 超预算；`ParallelShellPane` 的自绘终端面（C）
  没做 —— **这是全篇唯一一处判定终局是 C 的**。
- **欢迎页服务器列表「选中驱动滚动」**：`scrollTo` 在 2000 行 `LazyVStack` 上比手滚
  同样距离贵 2.0~2.3 倍（66ms vs 33ms），没动；候选是给行声明固定高度、
  或「已可见就不滚」。真实档（100 台）不收税，所以优先级低。
- **全局端口转发窗口**：1000 行档改后仍有 4.5% 的帧越 8.33ms，剩下的账在「一屏十几行、
  每行一个 `UDToggle` + 状态徽标」本身，再往下就是 C；`lazyRowThreshold = 120` 的确切
  拐点没量（只量了 50 行与 1000 行两端）；行内铅笔没有 AX 入口（老问题，`opacity(0)`）。
- **单主机端口转发列表**：200 条档仍有 1.0% 的帧越 8.33ms，剩下的账在 `TunnelRow` 本身；
  类型筛选切换（`filter`）没有单独量。
- **分组管理**：`candidates: profiles.filter { $0.group != g.name }` 仍在每次 body 重算一个
  2000 元素数组（O(n) 分配，没有 O(n²)），没量到它拖住哪一帧。
- **SSH config 导入复核表**：真视图的 `review` 相位进不去，量的是同形状替身。
- **Agent 会话历史下拉**：**契约有损** —— 下拉不再列出第 50 条之前的历史会话；真要翻旧
  会话得另开入口。

### 文档内已知不一致（合并五组评审时发现，均未重新跑数核实）

数字一个没改，只标出处与轮次。要定案得重跑对应探针。

1. **全局端口转发 · 1000 行改后的三个数**：判定段写「超预算 **5.0%**、hitTest **643µs**、
   NSView 恒 **316**」，同段读数表的「1000 行 · 后」却是 **4.5% / 570µs / 176**，
   「没做到的」也写 4.5%。判定段那三个数出自 `c2123c21` 那一轮；`6d4a9953` 做完
   「悬停才建」后复量成 NSView 316 → 176、p95 8.812 → 7.324ms、超预算 5.0% → 4.5%、
   hitTest 643 → 570µs，落表时**没同步判定段**。两轮读数都在案。
2. **单主机端口转发 · 200 条改前 NSView**：读数表写 **1817**，改法第 1 条写
   **1807 → 607**。`6d4a9953` 正文里两个数都出现过（「线性涨到 1817」「1807 → 607」
   「1817 → 128」）；1807 那次是「悬停才建」中间态那一轮的改前臂。是两轮读数还是
   笔误，**未核实**。
3. **全局端口转发 · 1000 行改后挂载**：文档表 **30.05ms**，`c2123c21` 正文 **31.64ms**。
   表里的「后」是 `6d4a9953` 复量那一轮，与 commit 那一轮不是同一轮，两个数都对。
4. **欢迎页服务器列表行 · hitTest 三臂区间**：文档写「326~401µs」（两档合看），
   `393773ec` 正文写「395~400µs」（只 2000 台档）。口径不同，不是矛盾，记一笔免得
   下次对不上。
5. **SFTP 传输浮层判 A 的依据里写「NSView 恒 37」**，但只量了 1000 行一档，
   没有第二档做「恒」的对照 —— 「恒」字缺依据（其余视图的「恒」都有两档）。
6. **SSH config 导入复核表判 B，但改前臂其实在 A 线内**（2000 行 · 旧 p95 8.02ms、
   超预算 1.0%），与「欢迎页服务器列表行」同属「A/B 边界」，那一段却没标注这层。
7. **⌘K 命令面板视图层判 A，但 302 项改前的击键 p95 是 8.488ms**（越 8.33）。
   击键 p95 与滚动帧 p95 不是同一把尺，A 线说的是后者 —— 该段没写明这层区分。
8. **并行 Shell 网格 6 台档「在噪声内」**的依据是 p50 5.76 → 6.65ms、拍数 453 → 393
   （−13%）；`b9f0c0f2` 正文同样这么记。−13% 的拍数称噪声偏勉强，没有重复轮次可核。

（视图还没评完。新增一段照「各视图判定」开头的注释模板写，并回填「一页总表」一行。）
