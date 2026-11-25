# uTermMobileTests —— iOS/iPadOS 测试基建

`uTermMobile`（iOS + iPadOS）的单元测试 bundle。宿主是 `uTermMobile.app`，
跑在 **iOS 模拟器**上。桌面那套（`uTermTests`，宿主 `uTerm.app` / macOS）不受影响，
两者互不依赖、也不共享文件。

一句话跑法：

```sh
make test-mobile
```

## target 是怎么配的

对齐现有的 `uTermTests`，只在平台相关的几项上跟随宿主 `uTermMobile`：

| 设置 | 值 | 为什么 |
|---|---|---|
| `productType` | `com.apple.product-type.bundle.unit-test` | 单元测试 bundle，不是 UI 测试 |
| `TEST_HOST` | `$(BUILT_PRODUCTS_DIR)/uTermMobile.app/uTermMobile` | iOS 的可执行文件在 `.app` 根下，**没有** macOS 的 `Contents/MacOS/` 那层 |
| `BUNDLE_LOADER` | `$(TEST_HOST)` | 与 `uTermTests` 相同：符号从宿主取 |
| Frameworks 构建阶段 | **空** | 与 `uTermTests` 相同。包产品（UDesignKit / USSHKit / GhosttyTerminal…）已经链进宿主，测试 bundle 再链一遍会把 SwiftPM 产品切成动态 framework，撞 Xcode「带 resources 的产品不生成 Ld」的老 bug |
| Dependencies | `uTermMobile` | 先建宿主再建测试包 |
| `SDKROOT` | `iphoneos` | 跟随宿主 |
| `IPHONEOS_DEPLOYMENT_TARGET` | `18.0` | 跟随宿主 |
| `TARGETED_DEVICE_FAMILY` | `1,2` | 跟随宿主：iPhone + iPad 都要能跑 |
| `SWIFT_VERSION` | `6.0` | 与 `uTermTests`、宿主都一致 |
| `SWIFT_DEFAULT_ACTOR_ISOLATION` | **`nonisolated`** | 对齐 `uTermTests`（宿主 `uTermMobile` 是 `MainActor`）。所以探针类要显式写 `@MainActor` |
| `CODE_SIGN_ENTITLEMENTS` | **不设** | 见下面「entitlements」一节 |
| 源码组织 | `PBXFileSystemSynchronizedRootGroup` → `uTermMobileTests/` | 与 `uTermTests` 相同：新文件丢进目录即入编译，不用改 pbxproj |

`uTermMobile.xcscheme` 的 `TestAction` 里加了一条 `Testables`（此前是空的，
所以 `xcodebuild test -scheme uTermMobile` 什么都不跑也不报错）。

### 隔离：为什么探针类要写 `@MainActor` 且不能覆写 `tearDown()`

target 默认隔离取 `nonisolated`（跟 `uTermTests` 一致），而 `UIWindow` /
`UIHostingController` / `CADisplayLink` 全是 `@MainActor`。于是：

- 探针类整体标 `@MainActor`；
- **不要覆写 `tearDown()`** —— `XCTestCase.tearDown()` 是 `nonisolated` 的，
  覆写不能改隔离，Swift 6 语言模式下从那里碰 `@MainActor` 的成员一律判成数据竞争
  （`MainActor.assumeIsolated` 也不行，它要求把 `self` sending 出去）。
  改用每条用例开头 `defer { closeAllWindows() }`，断言抛错也能把窗拆掉。

这条与桌面 `uTermTests` 的坑②完全同源，见 `docs/scroll-perf-findings.md`。

## 夹具

`Support/` 下四个文件，`Probes/` 下放各屏幕的评估探针。

| 文件 | 是什么 | 来源 |
|---|---|---|
| `Support/ProbeMetrics.swift` | 三把尺 `percentile` / `threadCPUSeconds` / `footprintMB` + `UIView` 遍历扩展 | 三把尺**一字不改**抄自 uTable `uTableTests/ProbeMetrics.swift`（`65fb6eb`），经 uTerm `uTermTests/Support/ProbeMetrics.swift`（`2791b0b5`）转手。纯 Darwin API，与 UIKit/AppKit 无关 |
| `Support/MobileProbeWindow.swift` | 建窗三档 + `isolateHost` + `closeAll()` + `DisplayLinkCounter` | 对应桌面 `ProbeWindow.swift`，**不是逐行移植**，差异见文件头与下面「iOS 与桌面的口径差异」 |
| `Support/VisionTextProbe.swift` | OCR（`VNRecognizeTextRequest`）+ 墨迹判据 `inkFraction` | 抄自 uTerm `uTermTests/Support/VisionTextProbe.swift`（`2791b0b5`），那份抄自 uTable（`aaea666`）。只换了平台 API |
| `Support/MobileProbeRig.swift` | **一次量测的统一口径**：`mount → measureScroll → snapshot` | 新写。桌面没有对应物（桌面每个探针各写一遍） |
| `ProbeSmokeTests.swift` | 链路自证：`@testable import` 通没通、整条量测链路、像素不是空壳 | |
| `Probes/ProbeRigSelfTests.swift` | 尺本身准不准：三档 A/B、四条滚动驱动、**反向自证**、OCR、拆窗与宿主层级不漂移 | |
| `Probes/StyleGalleryTests.swift` | **样式画廊（按需）**：每个页面 × 设备形态（iPhone Duo 外屏 466×678 / 展开 669×951 / 分屏 330 宽、iPhone、iPad）× 日夜各截一张 PNG，供人眼核对样式与折叠屏适配。不是闸门：没设 `UTERM_STYLE_SHOTS_DIR` 就整条 skip；跑法 `TEST_RUNNER_UTERM_STYLE_SHOTS_DIR=/tmp/shots xcodebuild test … -only-testing:uTermMobileTests/StyleGalleryTests`（窗口最大 820×1180，选 iPad 模拟器跑） | |
| `Probes/PromoGalleryTests.swift` | **宣传截图（按需）**：干净夹具（常见名字的主机、真的 Claude Code 录制 `Support/Recordings/`）。`testPromoScreens` 用探针窗口出图；`testPromoScreensOnDevice` 在 iPhone Duo 模拟器（展开、横握）里整屏挂真的外壳，等宿主脚本截屏（带状态栏那一列与屏幕圆角）。同 `UTERM_STYLE_SHOTS_DIR` 开关 | |
| `Probes/ParallelRunProbeTests.swift` | 并行执行屏：追加期心跳 / 单帧、跨格跳转、贴底跟随、AI 泳道展开、ticker 与脉冲的运行态门控 | 判定与读数见 `docs/scroll-perf-findings.md`「并行执行屏 · Shell（iOS）」 |

### `MobileProbeRig` —— 探针只写十几行

```swift
@MainActor
final class SomeScreenProbeTests: XCTestCase {
    func testHostList() async throws {
        defer { MobileProbeWindow.closeAll() }          // 必须；别覆写 tearDown()

        let rig = MobileProbeRig(label: "hosts-200")     // 默认 390×700 / .transparentOnScreen
        rig.mount(HostListView(servers: ...))            // → 挂载耗时（ms）
        let beat   = try await rig.heartbeat(seconds: 3) // → 双心跳
        let scroll = try await rig.measureScroll()       // → 200 步往返单帧（滚不动直接抛）
        let shot   = await rig.snapshot()                // → 结构 + hitTest + 像素 + 成本
        rig.report(scroll, shot, beat)                   // → 一行读数进日志
        attachProbePNG(shot.png, name: "hosts-200")      // → 截图进 xcresult

        XCTAssertGreaterThan(scroll.scrollable, 0)       // 闸门只用结构判据
        await rig.close()
    }
}
```

入口一览：

| 调用 | 给什么 |
|---|---|
| `init(label:size:placement:isolateHost:)` | `size` **写死**（默认 390×700）：iPhone 与 iPad 可视行数差三倍，不写死跨机器没法比 |
| `mount(_:)` | 建窗 + 挂 SwiftUI + `layoutIfNeeded()` + `CATransaction.flush()`，返回挂载 ms |
| `requireScrollView()` / `requireScrollable()` | **前置判据**，不满足就抛。见「反向自证」 |
| `sweepLazyRows(amplitude:)` | 以 <1 屏的间距扫一遍，把懒建的行都实例化（`measureScroll` 默认自己先扫） |
| `scrollTo(_:driver:)` / `scrollViaReader(_:to:)` | 四条驱动，见下 |
| `heartbeat(seconds:wave:)` | `Task.sleep` 拍 + `CADisplayLink` 拍，都带「理想值」和比值 |
| `measureScroll(steps:driver:amplitudeViewports:)` | 200 步往返，幅度钳 ≈3 视口；单帧 p50/p95/max、两种超预算比例、`travelled` |
| `snapshot(ocr:hitSamples:)` | `UIView` 数 + 类名直方图、hitTest p50/p95、footprint、CPU、PNG、`ink`、可选 OCR |
| `capturePNG()` | 只要截图时用 |
| `report(_:_:_:)` / `close()` | 一行日志 / 拆窗 + 200ms 让图层散掉 |

### 四条滚动驱动（iOS 没有可靠的触摸合成）

`UIScrollView.panGestureRecognizer` 要收 `UITouch` 序列，而 `UITouch` 没有公开构造器；
`XCUIElement.swipeUp()` 只在 UI Test target 里有，我们是 unit test bundle（宿主同进程）。
所以**四条路都是直接推 `contentOffset`**，区别在节拍和寻址方式：

| 驱动 | 怎么推 | 实测（1000 行，60 步往返） |
|---|---|---|
| `.contentOffset`（默认） | `setContentOffset(_:animated: false)` + 8ms `Task.sleep` | p50 1.07–1.62ms，`travelled=3068` |
| `.scrollRectToVisible` | `scrollRectToVisible(_:animated: false)` | p50 1.56–1.67ms，`travelled=3068` |
| `.fingerDrag` | 挂在 `CADisplayLink` 上，**每一拍推一小步**，耗时记在 `DisplayLinkCounter.workMS` | p50 1.20–1.62ms，`drag-ticks=60/60` |
| `ScrollViewReader` | `rig.scrollViaReader(anchor, to: 600)`，视图要用 `ProbeScrollReaderBox` 包一层 | `offset 0 → 13200`（= 600×22pt，一点不差） |

**四条在 `.transparentOnScreen`（`alpha = 0`）档下全部有效** —— 因为推的是属性，不走触摸路径。
`.fingerDrag` 是「按刷新率节拍逐步推进」这条要求的落点：它量到的是真实帧节奏下
主线程每拍的账，而不是「我 sleep 8ms 你给我个数」。

### 反向自证：滚不动必须判红

`requireScrollable()` 与 `measureScroll()` 在 `contentSize.height ≤ viewport` 时**抛**
`ProbeRigError.notScrollable`。

为什么这是整套夹具最重要的一条：一个滚不动的档，单帧 p50、拍数、hitTest 全都是
「静止画面」的读数 —— 又快又稳又好看，但什么都没测到。要是夹具不拦，
后面每一份「A（保持）」的判定都可能是这么来的。

`ProbeRigSelfTests.testNonScrollableFixtureIsRejected` 故意挂 3 行（内容高 66 < 视口 700），
断言两道闸门都抛，再拿同一形状的 2000 行当对照组证明「判红是因为滚不动，不是夹具坏了」：

```
[negative] content=66 viewport=700 scrollable=-634
[negative-throw] 可滚动余量 = 0（内容高 66 ≤ 视口 700）：这一档根本滚不动，所有滚动读数都是假的
[negative-control] scrollable=43300 travelled=968
```

## 造数据夹具

探针要把每个屏幕撑到真实档与极端档，又不能连真环境。这一节的四件夹具都在
`Support/MobileFixtures*.swift`，自证测试在 `Fixtures/MobileFixturesTests.swift`。

### 1. SwiftData 播种 —— `MobileFixtures`

```swift
let container = try MobileFixtures.modelContainer(seed: .realistic)
// 只读探针可以共享一份，省掉重复播种：
let extreme = try MobileFixtures.shared("hosts-extreme", seed: .extreme)
```

档位（`MobileFixtures.Seed`）：

| 档 | 主机 | 分组 | 密钥 | 命令 | 运行日志 | 会话 | 每会话消息 |
|---|---|---|---|---|---|---|---|
| `.smoke` | 12 | 3 | 4 | 5 | 8 | 4 | 2 |
| `.realistic` | 100 | 10 | 20 | 50 | 200 | 50 | 8 |
| `.extreme` | 2000 | 60 | 50 | 300 | 3000 | 1000 | 4 |

`knownHosts` 默认 = 主机数 × 0.8，`forwardingRules` 默认 = 主机数 / 5；所有比例
（`sftpOnlyRatio` / `keyBackedRatio` / `recentlyConnectedRatio` …）都是 `Seed`
的字段，直接改结构体，不要改 `populate` 的实现。

播出来的数据满足这些性质（探针可以当前提，自证测试逐条钉住）：

- **分组**：组名即成员键（写进 `ServerProfile.group`），组色全部取自产品自己的
  `ServerGroup.palette` 10 色板，前两组置顶。
- **密钥**：ed25519 / rsa 2048 / rsa 4096 / ecdsa P256 / P384 五种都出现；约
  55% 的主机 `authMethod = .privateKey` 且 `keyID` 指向某把密钥 ——
  密钥页的 `usedCount` 靠这个才非零。
- **`lastConnectedAt` 三档**：25% 落在 7 天内（「最近」段有内容）、35% 落在
  8~90 天、其余 `nil`（从没连过）。
- **运行日志**：全部落在 30 天窗口内（产品侧 `pruneExpiredRuns` 的保留窗口），
  成功 / 失败混排，`results` / `aiRecord` 走**真实 JSON 编码**（`QuickCommandRun`
  的计算属性写入路径），不是手糊字符串。
- **会话**：`updatedAt` 严格递减，正好对上
  `@Query(sort: \ChatSession.updatedAt, order: .reverse)` 的顺序。
- **主机名 / 文件名长短混排**（短名 5 字符到长中文名 60+ 字符）—— 单行截断与
  自适应宽度的成本只有在长度真的散开时才量得准。

三条**不能改**的实现约束（都是踩过的坑）：

1. `cloudKitDatabase: .none` 必须显式写。宿主 `MobileModelContainer` 走
   `.automatic` 靠模拟器回退（坑③），但夹具不能靠回退：
   `NSPersistentCloudKitContainer` 一旦真建起来，一条 100ms 的用例会被拖到 100 秒。
2. `isStoredInMemoryOnly: true`。落盘会跟宿主自己的 `default.store` 打架。
3. **播种后必须 `save()`**。只 `insert` 不 `save`，`@Query` 一条都读不到 ——
   `testSeededStoreIsVisibleToQuery` 就是钉这条的。

确定性：所有随机取值走 `SplitMix64(seed: Seed.seedValue)`，同一份 `Seed`
每次播出的数据逐字段一致（`testSeedIsDeterministic`）。前→后对照才有意义。

### 2. 假 SFTP —— `MobileFakeSFTPProvider` / `MobileFakeSFTP`

```swift
let provider = MobileFakeSFTPProvider(entries: 20_000)            // 极端档
let provider = MobileFakeSFTPProvider(entries: 500,               // 带子目录
                                      subdirectories: 6, childCount: 40, depth: 3)
let provider = MobileFakeSFTPProvider(entries: 500, latency: .milliseconds(50))

// 挂进 SFTPScreen（不发起任何真实连接）：
let session = await MobileFakeSFTP.session(host: host, provider: provider)
SFTPScreen().environment(store).environment(HostKeyChallengeRelay()).environment(session)
```

目录树里文件名长短混合、目录 / 普通文件 / 符号链接（`S_IFLNK`）都有、大小从
0B 到 40GB、权限 0644/0755/0600/0777/0640、修改时间散在 3 年内。排序与产品
`MobileSFTPController.load` 一致（目录在前，其余按名不区分大小写升序）。

**挂载的原理**：`MobileSFTPController` 把会话声明成 `any SFTPProviding`（与桌面
`FileBrowserModel` 同一个产品协议），并有一条同形的测试注入口
`MobileSFTPController(testProvider:startPath:)`。`MobileFakeSFTPProvider` 是一个
实现了该协议全部要求的**内存假会话**，所以产品自己的每条路径都跑得起来：
`load` / `open` / `goUp` / `refresh` / `delete` / `rename` / `chmod` /
`download` / `upload` 都真的改内存目录树、再由产品自己重列目录。
`MobileFakeSFTP.session(host:provider:)` 还会把 `activeTarget` 预设成
`store.sftpTarget`，这样 `SFTPScreen.consumeSFTPTarget` 判定「已在浏览」，
不会去建真连接。

（2026-09-08 之前这里是另一回事：控制器直接持有具体的 `SFTPSession`，夹具靠直接写
`state` / `path` / `entries` 三个字段绕过 `start()`，`open` / `delete` / `rename` /
`chmod` / 上传下载全是 no-op。那条路已经不需要了。）

还能做的三件事：

```swift
await provider.inject(.removeFile, at: "/etc", message: "权限不足")  // 失败注入
await provider.callCount(.list)                                     // 每种操作发生几次
try await provider.seedFile("/a.bin", data: payload)                // 给下载准备语料
```

两条已知边界：

- **大小与内容是两件事**。生成器刻意造出 0B~40GB 的条目好把 UI 的单位分支走全，
  但假会话不会为 40GB 的条目真的造 40GB 字节：没写过内容的文件读出来是确定性
  合成载荷，长度钳在 `syntheticContentCap`（64 KiB）；`stat` / 列表返回的仍是条目
  **声明**的大小。写过（`upload` / `write`）之后两者一致。
- **`start(profile:container:relay:)` 那条真实建连路径不在假会话覆盖范围内**：
  注入口是从「已连上」开始的，SSH 建连 / 主机密钥审批 / 认证材料解析仍然只有真环境走得到。

与桌面 `uTermTests/Support/MockSFTP` 的分工：两边实现的是**同一个协议**
`SFTPProviding`，没有第三份实现。`MockSFTP` 是断言用的录音机（静态树 + `renames` /
`removedFiles` 等数组），这边是规模化的假服务器（500 / 20000 条、时延、失败注入、
真的改树）。两个测试 target 各自是一个 `PBXFileSystemSynchronizedRootGroup`，
一个文件进不了两个 target，所以「合成单一文件」要动 pbxproj 的同步组结构 —— 没做。

### 3. 假 Agent 流 —— `MobilePacedLLMClient` / `MobileFakeAgent`

```swift
let chunks = MobileFakeAgent.pacedChunks(seconds: 6, chunksPerSecond: 20)
let (model, client) = MobileFakeAgent.streamingModel(chunks: chunks, chunksPerSecond: 20)
MobileAgentChat(model: model, host: host, tasks: MAgentTaskBag())
```

与 `uTermTests/Support/MockLLMClient` 的区别只有一条：那个把事件**一次性**
yield 完（测状态机），这个按 wall clock 一块一块吐（测流式渲染成本）。
语料是 Markdown 混排（标题 / 段落 / 列表 / ```bash 代码块 / 表格），
与桌面 `AgentMessageListCostTests.assistantMarkdown` 同形，默认 36 块一条。

历史回放走产品自己的持久化载入路径（`AssistantModel.load(_:)`，`messages` 是
`private(set)`，没有开后门）：

```swift
MobileFakeAgent.replayHistory(into: model, context: context, messages: 1000)
```

节拍与上屏文本之间最多差一块：`StreamingTextBuffer` 以 50ms 为节拍发布，
而 20 chunk/s 正好也是 50ms 一块。**断言写成前缀关系，不要写等长。**

### 4. 假并行执行 —— `MobileFakeParallelRun`

**主用法是当执行器**（2026-09-08 产品侧开了 `ParallelCommandExecuting` 这条缝之后）。
状态机与状态类型现在与 macOS 共用：`ParallelRunController` 是 `ParallelRunModel` 的 typealias，
`PServerState` / `PLine` 等是 `ParallelServerState` / `ParallelTermLine` 的旧名（定义都在
`uTerm/Features/ParallelRun/`），iOS 侧的 `init` 不带 `approval` / `hostLabel`，按 iOS 默认装配：

```swift
let fake = MobileFakeParallelRun(config: .streaming(hosts: 24, lines: 1200, seconds: 10,
                                                    failing: 4, unreachable: 1),
                                 targets: hosts)
let controller = ParallelRunController(…, container: container, executor: fake)
controller.start()                                    // 注入的控制器由调用方自己发车
ParallelRunView(request: req, controller: controller, onClose: {})
    .modelContainer(container)                        // ← 整屏就挂起来了
```

真控制器跑真流程（`runLane` / `markUnreachable` / `finalize` 一条不少），只有每台的
SSH 会话换成按节拍吐行的假会话。`failing` 台以非 0 退出码收尾，`unreachable` 台
（**从末尾数**）`run` 直接抛错走 `markUnreachable` —— 失败两条路都走得到。
取消也真的传得下去（`controller.cancel()` → 会话的 `Task.sleep` 抛 `CancellationError`）。

另外两种用法是**自己驱动一份 `states`**（不经控制器，只量模型侧）：

```swift
let run = MobileFakeParallelRun(config: .standard(hosts: 8, failing: 3))   // 50 行/秒 × 10 秒
run.emitAll()      // 同步发完，行数精确：每台 1 + 500 + 1 行
run.start()        // 真实节拍（每 20ms 一批），run.stop() 中途停
```

产出的 `states` 与 `ParallelRunController.states` **完全同形**（同一个
`PServerState`、同样的 `PLine.Kind` 序列、同样的 tone / exitCode / durationMs
语义），所以泳道与行的**模型侧**成本量得准。

### 5. 假工具执行器 —— `MobileFakeCommandExecutor`

```swift
let fake = MobileFakeCommandExecutor(lines: 40, linesPerSecond: 200)          // 正常，exit 0
let fake = MobileFakeCommandExecutor(exitCode: 3)                              // 非零退出（不是抛错）
let fake = MobileFakeCommandExecutor(outcome: .failure(message: "connection reset by peer",
                                                       afterLines: 6))         // 吐 6 行后抛
let fake = MobileFakeCommandExecutor(outcome: .timeout(after: .seconds(2)))    // 挂住到点才抛

// 经产品自己的注入口换掉真执行器（屏幕不知道后端是假的）：
MobileAgentChat(model: model, host: host, tasks: MAgentTaskBag())
    .modelContainer(container)
    .environment(\.agentCommandExecutorFactory, .stub(fake))
```

产品侧新增 `uTerm/Features/Agent/Backend/AgentCommandExecutorSeam.swift`：
`AgentCommandExecuting`（`CommandExecutor` 的精化，多一条 `cancelInFlight()`）＋
`AgentCommandExecutorFactory`（`.live` / `.stub(_:)` / `.none`）＋
`\.agentCommandExecutorFactory` 环境值。**默认值就是 `.live`**，逐字等价于改前
`MobileAgentChat.configureExecutor()` 里那两行 —— 生产路径零变化。

配套的剧本夹具（`MobileFakeAgent.toolCallScenario(...)`）把「短开场白 → 一张
`run_command` 卡 → 批准 → 执行 → 输出回填 → 续轮收尾」整条串起来。两个**必须知道**的约束：

1. **工具调用只在第一轮吐**（`MobilePacedLLMClient` 按 `streamCount` 判轮）。
   `AssistantModel` 在工具 resolved 之后会自动续轮，续轮再吐一张卡就是
   「批准 → 执行 → 又一张卡 → 批准…」的死循环。
2. **批准前必须等到 `.awaitingApproval`**。`approveAndRun` 有状态门禁，
   流还在飞时点它是 no-op，卡片会永远停在 pending
   （踩过：超时那一档被拖成 10 秒假红，报错指着「超时没落 .failed」，罪在没等门禁）。

等待用 `MobileFakeAgent.waitForToolCall(_:id:in:timeout:)` /
`waitForState(_:timeout:where:)`（8ms 轮询，与探针心跳同频）。

### 5. 假终端传输 —— `MobileFakeTerminalTransport` / `MobileFakeTerminal`

```swift
// 一个已注入假传输、还没 start() 的会话标签
let (tab, handles) = MobileFakeTerminal.tab(host: host, .flood(seconds: 12))
tab.controller.start(profile: host, container: container, relay: relay)
_ = await MobileFakeTerminal.waitUntilConnected(tab.controller)

// N 个已建连的会话，直接喂给 TerminalScreen
let (sessions, handles) = MobileFakeTerminal.sessions(
    count: 8, hosts: hosts, script: .interactive(), container: c, relay: relay)
TerminalScreen().environment(store).environment(relay).environment(sessions)
```

**这一条走的是正门，不是绕后门**（与假 SFTP 相反）：`MobileTerminalController`
的后端已经抽成了桌面那个 `TerminalBackend` 协议 + 一个工厂
（`uTermMobile/Screens/Terminal/MobileTerminalTransport.swift`），默认 `.live`
就是原来内联在 `start()` 里的 `SSHAuthResolver` + `HostKeyVerifier` + `SSHConnection`
组装。所以整条产品路径（`connect()` → `.connected` → 共享的 `TerminalOutputPump`
→ 影子终端 `ShadowTerminal` 与 GhosttyKit 的 surface）都真的跑起来，只是底下没有 socket。

脚本（`MobileFakeTerminalScript`）能配：`linesPerSecond` / `seconds` /
`corpus`（`.plain` / `.ansiColor` / `.cursorHeavy`——SGR 颜色、光标定位、行内擦除）/
`columns` / `connectLatency` / `writeLatency` / `echoesInput` /
`exitsWhenScriptEnds` / `connectFailure`。现成档位：`.interactive()` = 60 行/秒、
`.flood()` = 2000 行/秒、`.idle` = 连上但不吐。节拍是 **20ms 一批 + 累加器**，
所以 60 行/秒（1.2 行/批）与 2000 行/秒（40 行/批）都不会因取整而系统性偏低。

- **断线**：`await transport.simulateDrop()` → `exitStream` 送一个元素 → 控制器翻 `.disconnected`。
- **重连**：给工厂**两条**脚本（第一条 `connectFailure` 非空）。第一条失败 → `.failed`
  → `controller.restart()` → 工厂发第二条。走的是产品自己的重试路径（连接中页「重试」），
  不是夹具造的。
- **账本**：`await transport.ledger` 一次拿全（吐出行/字节、上行字节、resize 次数与
  最后尺寸、connect/close 次数）；`await transport.writtenText` 拿上行文本。

配套两把尺（同文件）：`MobileTerminalLoad.measure(rig:seconds:)` 在一个窗口里同时收
心跳（`Task.sleep` 拍 + `CADisplayLink` 拍）、单帧（每拍一次
`layoutIfNeeded()` + `CATransaction.flush()` 的墙钟）与 CPU / footprint **增量**——
终端屏没有可滚的列表，`measureScroll()` 在这里会（正确地）判 `notScrollable`。
`MobileTerminalConsumption.read(_:)` 读影子终端的行数、光标行和累计解析的字节数，
当「这一片吃进了多少输出」的代理。影子终端不管标签在不在屏上都照吃字节，所以活动 / 非活动标签的
消费计数没有差别；要分辨「这一片有没有在画」得看交帧数（`TerminalHiddenRenderingTests`）。

自证测试 11 条：`uTermMobileTests/Fixtures/MobileFixturesTerminalTests.swift`。

### 数据注入口不存在的屏幕（探针进不去，要改产品才行）

| 屏幕 | 现状 | 缺口 |
|---|---|---|
| ~~`SFTPScreen` 的文件操作~~ | **已解决（2026-09-08）**：控制器依赖 `any SFTPProviding` + `init(testProvider:startPath:)`，`open` / `goUp` / `delete` / `rename` / `chmod` / 上传下载都走得通，探针见 `Probes/SFTPScreenProbeTests.swift` | 只剩 `start(...)` 那条真实建连路径没有假后端 |
| `ParallelRunView` | **整屏挂不上** | `@State private var controller` + `onAppear { setup() }` 现造控制器，无外部注入；`states` 是 `private(set)`；行视图 `ParShellPane` / `ParAILane` 是 `private struct`，探针也拿不到 |

| `SFTPScreen` 的文件操作 | 列表可挂（见上），但 `open` / `delete` / `rename` / `chmod` / 上传下载全 no-op | `MobileSFTPController` 直接持有具体的 `SFTPSession`，无协议、无注入点 |
| `ParallelRunView` 的**「点一下展开处理过程」** | 整屏已经挂得上（见上「假并行执行」），只剩这一下点不着 | `ParAILane.open` 是 `@State`，SwiftUI 的 Button 在 iOS 视图树里不是 `UIControl`、hitTest 也点不着。探针走 `ParAILane(initiallyOpen:)`（默认 false = 现状）量**展开态的稳态成本**，那一下动画的成本量不到 |
| ~~`TerminalScreen`~~ | **已解决**：后端走 `MobileTerminalTransport` 工厂，假后端见下面「5. 假终端传输」 | — |
| ~~`MobileAgentChat` 的工具执行~~ | **已补**：`\.agentCommandExecutorFactory` 环境注入口 + `MobileFakeCommandExecutor` | 见下面「5. 假工具执行器」 |

| `MobileAgentChat` 的工具执行 | 卡片能渲染（给 `.toolCall` 事件即可），但**批准执行**走真连接 | `configureExecutor()` 用 `WorkspaceCommandExecutorFactory.make(server:container:)` 现造真执行器；夹具可以先设 `model.executor`（它只在 `nil` 时才被覆盖），但那是个 `CommandExecutor` 假实现，本轮没做 |

`@Query` 驱动的那些屏（`HostsScreen` / `CommandsScreen` / `KeysScreen` /
`GroupsScreen` / `FingerprintsView` / `SettingsScreen` / `QuickCommandDetailView` /
`CommandPaletteView` / `MobileAgentChat` 的会话列表）**全都能靠
`.modelContainer(MobileFixtures.modelContainer(seed:))` 撑起来**，不需要别的口子。

### 播种耗时（2026-09-08，M-series MacBook Pro，Debug，iOS 26.5 模拟器）

| 档 | 空闲机器 | 三条 xcodebuild 并发时 |
|---|---|---|
| `.smoke` | 3.4ms | 6.7~9.0ms |
| `.realistic` | 57~65ms | 106~144ms |
| `.extreme` | 2.97~3.22s | 5.08~6.52s |

极端档三秒起步，所以只读探针请走 `MobileFixtures.shared(_:seed:)`（同 key 只播一次）。
其余读数：假 SFTP 20000 条列目录 1.0~1.9ms；`SFTPScreen` 挂 20000 条 17.6~44.5ms、
`UIView` 恒 **7**（500 条也是 7 —— 与 `ProbeSmokeTests` 同源的结构判据）；
`SFTPScreen` 的交互端到端读数（2026-09-08，iPhone 17 Pro Max 模拟器，`SFTPScreenProbeTests`，
全量跑三轮取区间）：

| 档 | 挂载 | 单帧 p50 / p95 | 超 8.33ms | hitTest p50 | UIView | 进目录 | 返回上级 | 改名 | 删除 | chmod |
|---|---|---|---|---|---|---|---|---|---|---|
| 500 | 13.2~29.7ms | 1.42~1.59 / 2.25~2.53ms | 0.0% | 3.0~6.1µs | **7** | 11.0~18.5ms | 7.5~11.6ms | 6.8~7.8ms | 3.1~3.7ms | 2.8~3.8ms |
| 20000 | 12.3~21.1ms | 1.35~1.73 / 2.71~2.78ms | 0.0% | 3.0~9.1µs | **7** | 10.5~19.1ms | 14.3~22.8ms | 38.6~43.3ms | 19.0~21.9ms | 30.8~36.5ms |

读法：
- 「进目录」两档都是进同一个 200 条的子目录，所以两档同价 —— 这条正说明成本跟的是
  **落地目录的条数**，不是离开的那个目录。
- 「返回上级」「改名」「删除」「chmod」都要重列当前目录（产品的 `load` 全量重排 +
  SwiftUI diff），20000 档贵的正是那一次重列，40ms 量级；`list-calls` 恒 4
  （建控制器 1 + 三次操作各 1），说明没有多余的重列。
- 上传 128KB + 下载回来：4.9~7.0ms + 0.5~0.7ms。
- `UIView` 两档恒 **7**、`travelled` 恒 8412、`content` 恒 28000 / 1120000 ——
  结构判据三轮一位不差，列表确实是懒建的。

假 Agent 回放 1000 条历史 187~515ms；假并行 8 台 × 500 行生成 4.6~6.5ms。

### 跑自证测试

```sh
xcodebuild test-without-building \
  -project uTerm.xcodeproj -scheme uTermMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build/DerivedData \
  -only-testing:uTermMobileTests/MobileFixturesTests
```

16 条用例，约 10~12 秒（其中 3 秒是假 Agent 那条的节拍、1 秒是并行节拍，设计如此）。**并发跑测试的机器上要换一台自己的模拟器**：多个
xcodebuild 同时往同一台模拟器装同一个宿主 app，后来的会把先来的 kill 掉，
报 `Early unexpected exit, ... Test crashed with signal kill before establishing
connection` —— 与代码无关。`xcrun simctl boot <另一台的 UDID>`，用
`-destination 'platform=iOS Simulator,id=<UDID>'`，用完 `xcrun simctl shutdown` 它。

## 夹具跨用例契约

`uTermMobileTests` 的所有用例跑在**同一个宿主进程、同一台模拟器**里，夹具的
`static` 状态、宿主 `UIWindow`、共享 `ModelContainer` 都是跨用例活着的。
两位作者并行写的两批用例各自单跑全绿、合到一个 target 里全量跑一次就红，
根因正是这里没有立规矩。下面四条是从那次事故里定下来的，新写夹具照着来。

### 1. 拆窗只走 `MobileProbeWindow.closeAll()`

每条建过窗的用例开头写 `defer { MobileProbeWindow.closeAll() }`（**不要**覆写
`tearDown()`，理由见「隔离」一节）。别自己攒一个 `[UIWindow]` 数组逐扇
`MobileProbeWindow.close(_:)` —— `MobileProbeRig.close()` 也走 `close(_:)`，
所以 `close(_:)` 现在会在拆掉**最后一扇**探针窗时顺手复原宿主层级，但
「一条用例结束时宿主必须回到原始值」这条契约的唯一保证入口仍然是 `closeAll()`。

**曾经的事故**：`MobileFixturesTests` 自己维护 `windows` 数组、逐扇 `close(_:)`，
宿主窗口被 `isolateHost` 压到 `-100` 之后没人抬回去。按字母序它跑在
`ProbeRigSelfTests` 之前，于是
`ProbeRigSelfTests.testCloseAllTearsDownAndRestoresHost` 在「mount 前」量到的
宿主层级已经是残值 `-100`，而 `closeAll()` 把窗口恢复成了真正的原值 `0`，
断言 `XCTAssertEqual` 拿到 `0.0` 期望 `-100.0` —— 报错指着 rig，罪在 fixtures。

### 2. 宿主窗口层级：原值**只记一次**

`MobileProbeWindow.isolateHostWindows` 在某扇宿主窗第一次被压时把当时的
`windowLevel` 记进进程级的 `hostLevelMemos`（弱引用），**之后不再更新**；
复原永远回到那个首见值。所以「压 → 复原」是幂等的：谁先谁后、中间漏没漏，
都不会让原值漂移。老实现每轮重记一次「压之前的层级」，只要有一轮漏了复原，
下一轮就会把残值当原值记进来，从此再也回不去。

想在用例里断言原值，用 `MobileProbeWindow.originalHostLevel(of:)`，
别写死 `.normal`、也别拿 `hostLevel` 反推。守卫这两条性质的用例是
`ProbeRigSelfTests.testCloseAllTearsDownAndRestoresHost`（mount 前的值 == 拆完的值）
与 `testRepeatedIsolateCloseDoesNotDriftHostLevel`（两轮、两条退出路径都不漂移）。

### 3. 进程级 `static` 由用它的那条用例自己复位

夹具里的 `static var` 跨用例活着，读之前先写。典型是
`QueryCountProbe.lastSeenServers`：不在挂载前置回 `-1`，
「视图压根没 `onAppear`」这种真失败会被上一轮的残值盖成假绿。
`MobileProbeWindow.didLogPlacement`（每进程一行摆法日志）是有意为之的例外。

### 4. 共享 `ModelContainer` 只给只读用例

`MobileFixtures.shared(key:seed:)` 按 key 记忆化，省掉 extreme 档每次 3~5.5 秒的
播种。代价是容器跨用例存活：**任何往里写的用例都不能用它**，要写就
`MobileFixtures.modelContainer(seed:)` 现建一个（`emptyContainer()` 是
`isStoredInMemoryOnly`，建一个不贵）。

## 坑（都是实测踩出来的，按踩到的顺序）

### ① 这台机器上没有 iOS 模拟器运行时

`xcrun simctl list runtimes` 空、`xcrun simctl list devices available` 全是
`runtime profile not found`。Xcode 26.6 只装了 iOS **SDK**，没装模拟器运行时。
补：

```sh
xcodebuild -downloadPlatform iOS     # iOS 26.5 (23F77) arm64，8.52 GB，约 15 分钟
```

装完 `xcrun simctl list devices available` 才有 iPhone 17 / iPad Pro (M5) 这些机器。

### ② `uTermMobile` 在 main HEAD（`66d88a51`）上根本编译不过

```
uTerm/Features/Files/RemoteRowDropTargeting.swift:2:8: error: Unable to resolve module dependency: 'UAppKitBridge'
uTerm/Shared/Views/ClickSelectActivate.swift:1:8:   error: Unable to resolve module dependency: 'AppKit'
```

这两个文件是 `cb899345`（整表悬停跟踪层）加进 `uTerm/` 的 macOS 专有文件，
但没有加进 `uTermMobile` target 的 `membershipExceptions`。`uTermMobile` 用
`PBXFileSystemSynchronizedRootGroup` 同步整个 `uTerm/` 目录，**新加的文件默认就是成员**，
排除是白名单式的例外表 —— 所以只要往 `uTerm/` 里加一个 AppKit-only 的文件而不同步
更新例外表，移动端立刻红。已在本轮补进例外表。

**给以后改 `uTerm/` 的人**：加了只在 macOS 编译得过的文件（`import AppKit` /
`UAppKitBridge` / `UPaneTree` / `UPaneGroups` / `Sparkle` / `CodeEditTextView` /
`SwiftTreeSitter`，且没有用 `#if canImport(...)` 包住）就要同步加进
`PBXFileSystemSynchronizedBuildFileExceptionSet`。自查一行：

```sh
# 列出「需要排除但不在例外表里」的文件
sed -n '/Exceptions for "uTerm" folder/,/target = 10C0DE/p' uTerm.xcodeproj/project.pbxproj \
  | grep -oE '[A-Za-z0-9_/+.-]+\.swift' | sort > /tmp/exc.txt
(cd uTerm && grep -rlE '^import (AppKit|UAppKitBridge|UPaneTree|UPaneGroups|Sparkle|CodeEditTextView|SwiftTreeSitter)' . \
  | sed 's|^\./||' | sort) > /tmp/needs.txt
comm -23 /tmp/needs.txt /tmp/exc.txt
```

（`#if canImport(AppKit)` 包住的文件会被这个 grep 误报 —— 例如
`Core/Models/AppearancePreference.swift`、`Services/ConnectionWatchdog.swift`
就是两处已知误报，它们不需要排除。逐个看一眼 import 是不是条件编译的。）

### ③ 模拟器上 CloudKit 必然报错，但**不影响测试**

宿主一启动就会在日志里刷：

```
[CloudKit] CoreData+CloudKit: -[NSCloudKitMirroringDelegate recoverFromError:]
  Error Domain=NSCocoaErrorDomain Code=134400
  "Unable to initialize without an iCloud account (CKAccountStatusNoAccount)."
```

模拟器没登 iCloud 账号，`NSPersistentCloudKitContainer` 的镜像起不来。
**这是常态，不是故障**：SwiftData 本地容器照常工作（走模拟器容器里的
`Application Support/default.store`），测试全绿。别为了消掉这条日志去改
`MobileModelContainer`。

### ④ entitlements / `aps-environment` 在模拟器上不挡路

宿主 `uTermMobile` 带 `CODE_SIGN_ENTITLEMENTS = uTermMobile/uTermMobile.entitlements`
（iCloud container、CloudKit、`aps-environment=development`、
`keychain-access-groups`）。模拟器构建走 ad-hoc 签名、不要求 provisioning profile，
所以这些 entitlement 都不会导致签名失败 —— **不需要**为跑模拟器测试去掉它们，
也**不需要**加 `CODE_SIGNING_ALLOWED=NO`（跟桌面那条同理：别关签名）。

测试 bundle 自己**刻意不设** `CODE_SIGN_ENTITLEMENTS`：它不需要 iCloud / APNs /
keychain 组，带上只会在将来往真机跑时多一层 profile 要求。

### ⑤ 宿主 app 会真的启动到首屏，探针窗口要压在它上面

`TEST_HOST` 模式下 `uTermMobile.app` 是真跑起来的：`MobileApp` 建 SwiftData 容器、
起 `CloudKitSyncMonitor`、渲染 `SplashView` → `MobileRootView`。
应用锁（`requireAuthAtLaunch`）默认关，模拟器上不会卡在 Face ID 门口，
**不需要跳过引导/登录**。

但宿主窗口盖在探针窗口上会污染读数。做法是给探针窗口更高的 `windowLevel`
（`.normal + 100`），**不要**把宿主窗口拆掉 —— 拆掉会连带带走 SwiftData 的
`ModelContainer` 环境。（桌面那边的 `terminationAnchor` 在 iOS 不需要：
`MobileApp` 走 `UIApplicationMain`，窗口数归零不会让进程 `exit(0)`。）

### ⑥ `layer.render(in:)` 截 SwiftUI 会得到空白

墨迹判据要用 `view.drawHierarchy(in:afterScreenUpdates: true)`。
`CALayer.render(in:)` 不走 SwiftUI 的绘制路径，纯 `Text` 会被画成一片白，
墨迹判据直接假红。

### ⑦ `CADisplayLink` 要加进 `.common` mode

默认 mode 的 link 在主 runloop 进 tracking/modal 模式期间静默停摆，
3 秒拍数腰斩，看起来像卡顿。

### ⑧ iOS 没有 `displayIfNeeded()`

桌面 `host.layoutSubtreeIfNeeded(); host.displayIfNeeded()` 的等价物是
`view.layoutIfNeeded(); CATransaction.flush()`。不 `flush` 的话「挂载」只量到布局、
漏掉 CA 提交那笔账（与 uTable「自绘行 CA 提交成本」那条同源）。

### ⑨ `snapshot()` 里 hitTest 会把列表扫走，截图前必须滚回来

`snapshot()` 为了量 hitTest 要扫首中尾三处，扫完停在 98% 那一处。第一版没还原位置，
于是「滚到第 300 行再 `snapshot()`」截出来的是**第 1929 行**（`0.98 × 43300 ÷ 22`）——
OCR 一读就露馅，墨迹判据却看不出来（两屏的墨迹比例一样）。

现在 `snapshot()` 进来时记下 `contentOffset`，截图前滚回去。
`rig.scrollTo(y); await rig.snapshot()` 截到的确实是 `y` 那一屏，
`ProbeRigSelfTests.testVisionTextProbeReadsRowLabels` 用 OCR 断言这件事。

**这类坑靠墨迹判据是发现不了的** —— 这也是把 `VisionTextProbe` 移过来的实际收益。

### ⑩ `CAFrameRateRange.preferred` 在 iOS 26 SDK 上是 `Float?`

`minimum` / `maximum` 是 `Float`，只有 `preferred` 是可选（`nil` = 没有偏好）。
`String(format:)` 里直接用会编译不过，要 `?? 0`。

顺带：`CAFrameRateRange.default` 报出来是 `[0,0]p0`，看着像坏了，其实是「跟随系统」。
真实拍率要看 `DisplayLinkCounter.nominalIntervalMS`（第一拍的 `link.duration`），
本机 16.67ms = 60Hz。

### ⑪ Swift 6 隔离的三处具体落点

target 默认隔离是 `nonisolated`（对齐 `uTermTests`），踩到的三处：

1. **`DisplayLinkCounter.onTick` 必须写成 `(@MainActor () -> Void)?`**。
   不标的话闭包被当成非隔离的，里面碰 `UIScrollView` 每一句都判成数据竞争。
2. **`ProbeScrollAnchor` 反而不能标 `@MainActor`**。它的绑定点在 SwiftUI 的
   `onAppear` 里，那是个非隔离闭包，从里面写 `@MainActor` 属性一样判红。
   改成 `@unchecked Sendable` 的普通类（实际读写全在主线程）。
3. **`@MainActor` 类的静态成员不能给另一个类的静态属性当初始化式**
   （`private static let rowHeight = ProbeSmokeTests.rowHeight` 编译不过：
   静态属性的初始化式跑在 actor 之外）。写字面量。

## 基线读数（2026-09-08，M-series MacBook Pro，Debug）

夹具：纯 `Text` 行的 `ScrollView + LazyVStack + ForEach`，390×700pt，行高 22pt，
往返幅度钳 ≈3 视口。**绝对毫秒只打印，闸门只用结构判据。**

iPhone 17 Pro（iOS 26.5 模拟器，`maxFPS=60`）：

| 行数 | 挂载 | sleep 拍/375 | CADisplayLink 拍/180 | 单帧 p50 | 单帧 p95 | 超 8.33ms | hitTest p50 | UIView | 内容高 | footprint |
|---|---|---|---|---|---|---|---|---|---|---|
| 200 | 14.3 / 17.4ms | 334 / 335 | 179 | 1.73 / 1.63ms | 2.26 / 2.09ms | 0.0% | 10.0 / 6.1µs | **6** | 4400 | 59.0 / 57.9MB |
| 2000 | 7.0 / 5.2ms | 334 / 333 | 179 | 1.60 / 1.66ms | 2.15 / 2.11ms | 0.0% | 6.0 / 6.9µs | **6** | 44000 | 58.3 / 57.4MB |

iPad Pro 11-inch (M5)（同运行时）：200 行 挂载 11.8ms / p50 1.38ms / hitTest 5.0µs /
UIView 6；2000 行 挂载 5.5ms / p50 1.52ms / hitTest 5.0µs / UIView 6。

夹具尺寸写死 390×700 之后**几何读数跨设备完全一致**（两台都是 `content=4400 / 44000`、
`scrollable=3700 / 43300`、`views=6`），这正是写死而不用屏幕尺寸的目的。
全部 9 条在 iPad 上同样全绿（`make test-mobile MOBILE_DESTINATION='...iPad Pro 11-inch (M5)'`）。

改用 `MobileProbeRig` 之后同一份夹具的读数（2026-09-08 两轮，iPhone 17 Pro）：

| 行数 | 挂载 | sleep 拍/375 | 拍/180 | p50 | p95 | 超 16.67ms | 超 8.33ms | hitTest p50 | UIView | 内容高 | ink |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 200 | 6.7 / 6.5ms | 335 / 334 | 179 (0.99) | 1.48 / 1.41ms | 1.87 / 2.04ms | 0.0% | 0.0% | 6.0 / 11.0µs | **6** | 4400 | 0.025 |
| 2000 | 7.9 / 7.6ms | 335 / 339 | 179 (0.99) | 1.39 / 1.55ms | 2.04 / 2.30ms | 0.0% | 0.0% | 4.1 / 6.9µs | **6** | 44000 | 0.023 |

### 每把尺怎么读

| 尺 | 读法 | 能不能当闸门 |
|---|---|---|
| **挂载 ms** | 只在**同一档**做前→后对照。跨档比没有意义：每次运行的第一个 fixture 会吃掉 SwiftUI 首次渲染的一次性开销（表里 200 行反而比 2000 行贵就是这个） | 否，只打印 |
| **sleep 拍 / 理想** | 8ms `Task.sleep` 循环收到几拍 = 主线程还愿不愿意回到 runloop。本机稳定在 0.89–0.90（不是 1.0，`Task.sleep` 本身有调度余量） | 只挡「一拍都收不到」这种硬故障 |
| **CADisplayLink 拍 / 理想** | 渲染循环实际交付了几帧。本机恒 0.98–1.00。**这个数掉下去才说明窗口没真上屏** | 只挡硬故障（比值 < 0.1） |
| **单帧 p50 / p95** | 每步「设 offset + `layoutIfNeeded()` + `CATransaction.flush()`」的主线程墙钟 | 否，只打印。判定看**同轮相对比** |
| **超预算比例** | 打两份：`over-16.67`（按本机 `maxFPS` 算）和 `over-8.33`（固定，跨机器可比）。**跨机器比之前先看分母** | 否 |
| **`travelled`** | 200 步实际走过的 offset 里程。它 ≈ 0 说明驱动没生效 —— 比「p50 很快」更值得先看 | **是**（必须 > 单程幅度） |
| **`scrollable`** | `contentSize.height - viewport`。**0 就一切读数作废**，`measureScroll` 会抛 | **是** |
| **UIView 数 + 类名直方图** | 纯 `Text` 的 `LazyVStack` 恒 6，200 行与 2000 行完全相同。视图树是 `_UIHostingView` / `HostingScrollView` / `PlatformGroupContainer` / `PlatformContainer` / `_UIScrollViewScrollIndicator` / `UIView`。**每行一个 Button/TextField 会让这个数随行数涨** —— 这是判 B/C 的第一判据 | **是**（硬断言，±2） |
| **hitTest p50/p95** | 命中路径有没有被行数拖累。守**比值**不守绝对微秒 | **是**（比值） |
| **`ink`** | 非**众数**颜色像素占比。挡「截图是空壳」。同一台机器上三档一位不差（0.0259）；**跨设备不完全可比**（同一份夹具 iPhone 17 Pro 0.0259 / iPad Pro 11-inch 0.0294，抗锯齿不同），所以它只当空壳闸门，别拿来比「谁画得多」 | **是**（> 0.005） |
| **footprint / CPU** | `phys_footprint`（不是 RSS）与本线程累计 CPU 秒。都是**单调累加的进程级读数**，同一次运行里越靠后越大 —— 只在同一档拆窗前后对照 | 否 |

### 三档 A/B（2026-09-08，iPhone 17 Pro 模拟器，1000 行，60 步往返，六轮）

**结论与桌面很不一样，别照抄桌面 `ProbeWindow.swift` 顶部那张表的推论。**

单帧 p50（ms）：

| 轮 | `.offScreen` | `.transparentOnScreen` | `.visibleOnScreen` |
|---|---|---|---|
| 1 | 1.514 | 1.198 | 1.203 |
| 2 | **0.778** | 1.641 | 1.670 |
| 3 | 1.674 | 2.157 | 1.903 |
| 4 | 1.945 | 1.767 | **1.020** |
| 5 | 1.484 | 2.083 | 1.845 |
| 6 | 2.087 | 1.486 | 1.557 |
| 均值 | 1.58 | 1.72 | 1.53 |

- **三档的时间读数分不出来**：排序每轮都在换，区间大幅重叠（0.78–2.09 / 1.20–2.16 /
  1.02–1.90）。`CADisplayLink` 拍数比六轮恒 **0.98–1.00**。
  桌面那条「屏外会让计时读数崩塌」（拍数腰斩、超预算帧 0% → 22%）**在 iOS 上没有复现**。
- **结构与几何三档完全一致**：`views=6`、`content=22000`、`scrollable=21300`、
  `travelled=3068`，六轮一模一样。所以三档可以互相当对照组。
- **三档都截得到像素**，`ink` 三档一位不差（0.0259）。
  `drawHierarchy(afterScreenUpdates:)` 会自己驱动一次离屏更新，窗口在不在可见区不影响。
  这一条与桌面的直觉相反，也与这套夹具最初写下的假设相反 —— 是量出来才改的。

所以 iOS 上默认档取 `.transparentOnScreen` **不是因为它更快**，而是：① 与桌面同名同义，
两边探针读起来是一件事；② 屏上看不见东西。`.offScreen` 三档里唯一真正的区别是
窗口不参与合成，想彻底排除合成器干扰时用它。

复量：`-only-testing:uTermMobileTests/ProbeRigSelfTests/testPlacementABIsRecorded`，
或用逃生阀 `TEST_RUNNER_UTERM_MOBILE_PROBE_PLACEMENT=offscreen|transparent|visible`
把整轮强制成同一档。

### iOS 27 复量（2026-10-12，iPhone 18 Pro 模拟器，iOS 27.0）

上面的读数都是 iOS 26.5 / iPhone 17 Pro 上量的。换到 iOS 27 之后整套 60 条里有 3 条变红，
逐条查下来**没有一条是产品回归** —— 在 `mobile-v1.2.5` 的提交上用同一台模拟器照样红。
三条各是一个 iOS 27 的行为变化，校准方式也各不相同：

**① 可见窗口的滚动视图多了 4 个系统视图（`ProbeRigSelfTests.testPlacementABIsRecorded`）。**
iOS 27 给滚动视图加了滚动边缘效果（内容滚到顶 / 底栏下面时那道渐隐模糊）：`UIScrollView`
下多出两个 `_UITouchPassthroughView`，里面各装一个 `BackdropView` / `ScrollEdgeEffectView`。
**只有可见窗口才挂** —— `.offScreen` / `.visibleOnScreen`（`alpha = 1`）是 10 个视图，
`.transparentOnScreen`（`alpha = 0`）还是 6 个，「三档给出同一棵树」这条自证因此红了。
处方：`UIView.recursiveViewCount()` 不再数这四个（它们不是被测视图建的），三档回到 6；
`classHistogram()` 照旧全数，自检另打一行 `[ab-<档>-chrome]` 记账。所以上面所有表里的
`UIView` 读数在 iOS 27 上仍然可比。

**像素读数三档不再一致**：边缘效果是真的画出来的，`ink` 是 offscreen 0.0847 /
transparent 0.0259 / visible 0.0847。默认档（transparent）截到的是**没有**边缘效果的画面 ——
要取证「用户实际看到什么」得用 `.visibleOnScreen`。`ink` 本来就只当「截图是不是空壳」
的闸门，这条不受影响。

**② 懒栈的估高粗了很多（`AgentChatProbeTests.testHistoryReplayMountAndScroll`）。**
`LazyVStack` 的文档高 = 建过的行的实测高 + 没建过的行的估高。同一份 200 条消息、只往返
扫过前三屏，iOS 26.5 上两次读数差 1% 量级；iOS 27 上差 14%（148k 对 173k，真实高度 28 万
上下），连挂载那一刻的估高都能差近一倍。原来拿它当「两臂挂的是同一批消息」的判据
（闸门 5%）就成了假红。处方：`MobileProbeRig.settleContentHeight()` 先把整篇扫一遍，
估高换成实测高之后再比 —— 五轮实测两臂差 0.17%–1.45%，闸门仍是 5%。代价是这条用例从
33 秒涨到 77 秒上下（两臂各把 200 条消息建一遍）。**以后凡是拿 `contentSize` 当判据的
探针，先想清楚读到的是估高还是实测高。**

**③ 跨格一跳的单轮中位数自己就飘一倍（`ParallelRunProbeTests`）。**
原判据拿「6 台 × 600 行」对「24 台 × 1200 行」的单轮中位数比（闸门 1.6），在基线提交上的
比值就在 0.91–3.22 之间摆。查下来有两层原因，都与内层懒不懒无关：两档同时差着台数
（台数固定成 8 之后，每格 300 / 1200 / 2400 行的一跳都在 20–45ms）；同一档连跑两轮的
中位数是 44.8 对 20.5ms（各 7 个样本）。处方：拆成单独一条
`testCrossPaneJumpDoesNotScaleWithLinesPerPane` —— 台数固定 8、每格行数差 8 倍
（300 对 2400）、按 轻-重-重-轻 各跑两轮、每档合并 28 个样本取中位数，闸门 3。
四轮实测比值 0.70 / 1.23 / 1.67 / 1.34。**反向自证**：临时把 `ParallelRunView` 的内层
`LazyVStack` 换成 `VStack`，比值 20.18（35.8 → 723.0ms），判红。

三档 A/B 的时间读数在 iOS 27 上仍然分不出来（单轮 p50：offscreen 1.31 / transparent 2.65 /
visible 1.09ms，`CADisplayLink` 拍数比 0.98–1.00），默认档不用换。

### iOS 与桌面的口径差异（照抄桌面结论之前先看这里）

| | 桌面 `uTermTests` | iOS `uTermMobileTests` |
|---|---|---|
| 单帧预算 | 写死 **8.33ms**（内建屏 120Hz） | 按 `screen.maximumFramesPerSecond` 算：模拟器跟着宿主 Mac 的显示器走，本机报 **60 → 16.67ms**。同时另打一份固定 8.33ms 的比例供跨机器对照 |
| 心跳 | 只有 `Task.sleep(8ms)` 拍数 | 两种：`Task.sleep` 拍（主线程）+ `CADisplayLink` 拍（渲染循环）。后者才是「窗口有没有真上屏」的判据 |
| 视图计数 | `NSView` | `UIView`。**两个数不可比**：同一份纯 `Text` 懒栈桌面是 `NSScrollView`+`NSClipView`+文档视图那一套，iOS 只有 6 个。判据是「**随不随规模涨**」，不是绝对数 |
| 强制上屏 | `layoutSubtreeIfNeeded()` + `displayIfNeeded()` | iOS 没有 `displayIfNeeded()`：`layoutIfNeeded()` + `CATransaction.flush()`（坑⑧） |
| 截图 | `cacheDisplay(in:to:)` | `drawHierarchy(in:afterScreenUpdates: true)`。`layer.render(in:)` 截 SwiftUI 是一片白（坑⑥） |
| 摆法的影响 | 屏外让计时读数崩塌，必须 `.transparentOnScreen` | 三档分不出来（上面那张表） |
| 真鼠标 | 屏内窗口会被用户光标悬停到，`.onHover` 亮起来把读数染红，靠 `mouseLocationOutsideOfEventStream` 谎报挡住 | **不存在**。模拟器没有会飘进来的光标，SwiftUI iOS 也没有 `.onHover` 路径。`blindsRealMouse` 一套整个没搬 |
| 宿主窗口 | `isolateHostWindows` 直接 `orderOut`，另留 `terminationAnchor` 防 `exit(0)` | 只把宿主窗口 `windowLevel` 压低（**不能拆**，会带走 SwiftData 环境，坑⑤）；`UIApplicationMain` 不会因窗口归零退出，所以不需要锚窗口 |
| 滚动驱动 | 真 `NSEvent` 打进去 | 没有可靠的触摸合成，四条路都是推 `contentOffset`（见「四条滚动驱动」） |

## 跑法

```sh
# 一条命令（默认 iPhone 18 Pro —— Xcode 27 自带的模拟器；`xcrun simctl list devices available`
# 里没有这台就传 MOBILE_DESTINATION）
make test-mobile

# 换机器
make test-mobile MOBILE_DESTINATION='platform=iOS Simulator,name=iPad Pro 11-inch (M5)'

# 只跑一个类（迭代探针时用这个，别每次都全量）
cd <worktree>
xcodebuild build-for-testing \
  -project uTerm.xcodeproj -scheme uTermMobile \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath build/DerivedData -onlyUsePackageVersionsFromResolvedFile

caffeinate -dimsu xcodebuild test-without-building \
  -project uTerm.xcodeproj -scheme uTermMobile \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath build/DerivedData \
  -only-testing:uTermMobileTests/ProbeSmokeTests
```

### 终端（Ghostty）探针

终端画面是 GhosttyKit 的 surface（`MGhosttyTerminalView`），读状态的是影子终端 `ShadowTerminal`，滚动是系统
`UIScrollView`（换引擎时自写的惯性 / 回弹整套删了）。相关夹具与跑法：

- **先 `make engine`**：GhosttyKit / vt 两个 xcframework 由 `scripts/fetch-ghostty-engine.sh` 按
  `vendor/libghostty-spm/ENGINE.lock` 放进 `vendor/libghostty-spm/BinaryTarget/`，没有它包解析就失败。
  `make test-mobile` / `test-mobile-fast` 已经依赖它；手写 xcodebuild 前自己跑一次。旧的 `build/ghostty-kit`、
  `build/ghostty-vt` 软链不再用。
- 夹具：`Support/GhosttyProbeSupport.swift`（`GhosttyProbeHost`：独立窗口里一个真 surface，进程共用一个 ghostty app；
  `RealTouchWatch`：测试期间真手指碰了屏幕就判失败——真机上碰一下，借来的 UIScrollView 会跟着滚、松手还有惯性，
  量位移的读数就作废）、`Support/MainThreadStallSampler.swift`（主线程一轮忙过 6 ms 时抄它的调用栈，
  帧率探针用它回答「这一拍是谁占了主线程」；只在 arm64 上抄得到栈）。
- **按 120 Hz 判定的探针在模拟器上跳过**：`GhosttyFrameBudgetTests`、`GhosttyOnScreenScrollTests`、
  `GhosttyScrollFeelTests` 的两条场景、`GhosttySmoothScrollPixelTests.testFlingMomentumRunsAtDisplayRate`
  开头调 `skipUnlessHighRefreshDisplay()`（屏幕最高不到 120 Hz 就 `XCTSkip`；模拟器恒为 60 Hz）。
  它们只在真机上判定，读数也只看真机的。
- 每拍位移类的门槛（`GhosttyOnScreenScrollTests.assertSmooth`）按「这一次减速经 contentOffset 取整到
  1/`UIScreen.scale` pt、再取整到整数物理像素之后的理论值」判，不写死像素数：`UIScreen.scale` 与 `nativeScale`
  不同的屏（iPhone Duo 内屏 3 vs 2.807）量化起伏天生更大。原理写在 `Quantization` 的注释里。
- 测量门（`GhosttyMeasureProbeTests` 等）挂在 `UTERM_MEASURE=1` 后面，真机单独跑；全量不捎它们。
- 真机：只用 iPhone Duo；`xcodebuild build-for-testing … -destination 'platform=iOS,id=<UDID>' -allowProvisioningUpdates`
  然后 `test-without-building -only-testing:…`。手机锁着时 xcodebuild 直接退出（destination 不可用），解锁后重跑。
  跑滚动类探针时别碰屏幕。

写新探针时的清单：

1. 文件放 `uTermMobileTests/Probes/`（同步目录，丢进去即入编译）。
2. 类标 `@MainActor`，**不覆写 `tearDown()`**，每条用例开头
   `defer { MobileProbeWindow.closeAll() }`。
3. 用 `MobileProbeRig`，别再手写建窗/心跳/往返循环 —— 手写出来的口径对不上。
4. **档要有两个**：真实规模 + 极端规模，规模从数据源推并在注释里写明来源。
5. 闸门只用结构判据（`UIView` 数随不随规模涨、`scrollable > 0`、`travelled` 够不够、
   hitTest 比值、`ink > 0.005`），**绝对毫秒只打印**。
6. 判定与读数写进 `docs/scroll-perf-findings.md`「各视图判定」一节。

### ⑩ 测试语言钉在简体中文（`uTermMobile.xcscheme` 的 TestAction `language = "zh-Hans"` / `region = "CN"`）

不少用例拿简体中文字面量比文案（`"45 秒"`、`"等待确认"`、`"在哪个目录打开？"`、`hasPrefix("删除失败")`……），
设备界面是英文时 `String(localized:)` 取到的是译文，这些用例必红（2026-11-25 在英文界面的 iPhone 18 Pro Max 上
一次红了 12 个类里的 22 条）。宿主按测试动作的语言起，与设备语言无关。新用例能比结构化字段（错误类型、枚举、
`displayName` 这类不翻译的名字）就别比文案；要核文案时照旧写简体中文原文。命令行传 `-testLanguage` 会盖掉这里的设置。

耗时参考（同上机器，Debug）：

| | 墙钟 | 测试时间 |
|---|---|---|
| 冷（空 `DerivedData`，`SourcePackages` 已在位）`xcodebuild test` | **1m18s** | 12.3s |
| 热 `test-without-building` 全部 9 条（只有探针那批时） | 45–60s | **28.0s** |
| 热 `test-without-building` **全量 26 条**（探针 + 造数据夹具，2026-09-08 连跑两次） | 44s / 40s | **39.1s / 36.1s** |
| 热 `test-without-building` 只跑 `ProbeSmokeTests`（3 条） | 17–32s | 13.3s |
| 热 `test-without-building` 只跑 `testPlacementABIsRecorded` | ~20s | 8.0s |

固定开销都是设计如此：`ProbeSmokeTests` 两档各 3 秒心跳 + 200×8ms 往返；
`ProbeRigSelfTests` 的三档 A/B 是 3×(1s 心跳 + 60 步)，四条驱动是 4×60 步。
迭代单条探针时用 `-only-testing:`，别每次全量。

其它：

- 用完自己起的模拟器记得 `xcrun simctl shutdown <UDID>`。
- 长跑前 `caffeinate -dimsu`。
- 冷解析包时才需要 `GIT_CONFIG_GLOBAL=<指向本地 uAppKit 的临时 gitconfig>`；
  `DerivedData/SourcePackages` 已在位时不需要。
