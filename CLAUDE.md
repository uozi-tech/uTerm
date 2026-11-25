## 原生多语言项目（必读）

uTerm 是**原生多语言**项目：源语言简体中文，同时完整支持 **English、繁體中文（台湾）、日本語、한국어**。任何新增或修改面向用户的文字
（界面、报错、通知、权限说明、命令行输出、README、官网、商店介绍），都要**同一次改动里把所有语言、所有位置一起更新**，
不能只改中文、留着「以后再翻」。具体写法与流程见下面「文案目录」一节的「多语言」。要同步的位置：

| 位置 | 文件 | 核对 |
|---|---|---|
| App 界面（两端） | `uTerm/Localizable.xcstrings` | `make sync-strings` 后 `make check-translations` |
| 共享包 | uAppKit 各 target 的 `Sources/<target>/Localizable.xcstrings`（`bundle: .module`） | 改 uAppKit 时一起翻，发新 tag 后升级引用 |
| 权限说明等 Info.plist 文字 | `uTerm/InfoPlist.xcstrings`、`uTermMobile/InfoPlist.xcstrings`、`Config/uterm-holder/<语言>.lproj/`、`uTermRemoteHost/<语言>.lproj/` | 新增 `NS…UsageDescription` 时四种语言都要写 |
| 命令行客户端 | `scripts/utermctl` 的 `TRANSLATIONS` 表 | `make check-cli` |
| README | `README.md` + `README.en.md` / `README.zh-Hant.md` / `README.ja.md` / `README.ko.md` | 改一份就改全部五份 |
| 官网（维护者私有） | `internal/website/index.html` + `locales/<语言>.json` | `internal/website/scripts/build-i18n.py --check` |
| App Store 介绍（维护者） | App Store Connect 里各语言的描述、关键词、截图 | 发版 skill 里核 |

有意只用中文的：`CHANGELOG.md`、`docs/` 设计文档、`skills/` 技能文档（给 AI 读的）、日志、代码注释、提交说明。
新加一种语言要改：上表全部位置 + pbxproj 的 `knownRegions` + `AppLanguage` + holder 的拷贝脚本 + `scripts/translations.py`
与 `build-i18n.py` 的语言表。

## Vendored 依赖

- `vendor/libghostty-spm`：终端引擎。上游 `Lakr233/libghostty-spm` 的 fork（基线 tag `2.2.2026112301` / `1f378020`，Ghostty `5ebe501a`；我们提的回放入口、滚动小修、逐像素平滑滚动、松手续速与同拍上屏四个 PR 都已在这一版里），pbxproj 以 `XCLocalSwiftPackageReference` 引用，两个 App target 依赖它的 `GhosttyTerminal` / `GhosttyKit` / `GhosttyVt` 三个 product。fork 的原因：引擎要带我们的补丁（`Patches/ghostty/` 的 0024 保色相最低对比度，改 Ghostty 的 shader；逐像素平滑滚动现在是上游的 0022，「带着这一步滚动的那一帧交到图层了」的信号是上游的 0023，iOS 系统滚动靠它和 UIKit 同一拍提交）；Swift 层要改 internal 的东西（surface 生灭回调、wakeup 重画、自写惯性、按键过滤）；libghostty-vt 要和 GhosttyKit 在同一棵打过补丁的源码树上编，影子终端和画面才逐格一致。**二进制不进版本库**：`make engine`（`scripts/fetch-ghostty-engine.sh`，自测 `scripts/fetch-ghostty-engine.test.sh`）按 `vendor/libghostty-spm/ENGINE.lock` 取 zip、校验 sha256、解到 `BinaryTarget/`，已是那一份就不动；`make build` / `archive` / `test*` / `archive-mobile` 等都先依赖它，`make clean` 不动 `vendor/`。zip 从 `UTERM_GHOSTTY_ARTIFACTS` 指向的目录取（维护者的目录在 `internal/config.mk`；不发布二进制，别人本地现编），取 zip 不联网；**取不到 zip（新克隆、换机器）时 `make engine` 自动退到从上游源码现编**（`make engine-build` = `scripts/build-ghostty-engine.sh`，自测 `scripts/build-ghostty-engine.test.sh`；按 `ENGINE.lock` 的来源几行取 tag / Ghostty 提交 / Zig，只编 macOS + iOS，约 15 分钟、要联网，stamp 记 `local-build <engine_version>`，不核 sha256；`UTERM_GHOSTTY_NO_BUILD=1` 关掉；发版用测过的 zip，不用现编的）。新克隆的仓库没跑 `make engine` 之前 Xcode 会报 binaryTarget 路径不存在。补丁清单与升级步骤见 `vendor/libghostty-spm/UTERM-PATCHES.md`（升级前必读，不要整目录覆盖 `Sources/`），从上游 tag 编出两个二进制的步骤见 `vendor/libghostty-spm/BUILD.md`。**升级算协议变更**：`ENGINE.lock` 的 `engine_version` 与 `TerminalEngineVersion.current` 必须一字不差（两端的 `TerminalEngineLockTests` 拦着），两端快照格式不同时远控镜像改发回放流（两端都声明 `terminal-replay` 才行，`RemoteTerminalReplay`；有一端是这之前的版本就照旧拒绝镜像），holder 检查点的二进制快照解不开、改用退出时另存的回放流接回画面（只改渲染的补丁记进 `TerminalEngineVersion.sameSnapshotFormat`，两样都照常）。
- `vendor/CodeEditTextView`：上游 `CodeEditApp/CodeEditTextView` 的 vendored 副本（基线 `0.12.1`）。vendor 的原因：上游 `TextLayoutManager+Layout.swift` 的 `layoutLine` 把 `inout maxFoundLineWidth` 遮蔽成局部变量，量到的行宽写进副本后丢弃 → `maxLineWidth` 恒为 0 → 不折行时文档视图宽度永远等于视口宽，**横向滚动完全不可能**。涉及 private 方法与 internal 属性，包外改不了也 override 不了（`updateFrameIfNeeded()` 是 public 非 open）。补丁清单与升级重放见 `vendor/CodeEditTextView/UTERM-PATCHES.md`。
- `vendor/tree-sitter-grammars`：python / javascript / yaml / toml / ini 五套 grammar 打成一个包（各自 pin 的上游 commit 写在它 `Package.swift` 的头注释里）。vendor 的原因：上游每套 grammar 自己的 `Package.swift` 用 `FileManager.fileExists("src/scanner.c")` 条件加 scanner，而 SwiftPM 求值 manifest 时 cwd 不是包根、这个判断恒为 false → scanner 漏链。这里改成 vendor 一份 C 源 + 手写硬编码 sources 的 manifest 一次绕开。另带一个本地补丁 `patches/scanner-serialization.patch`（python / yaml 的 external scanner 序列化越界）。升级跑 `scripts/sync-vendored-grammars.sh`——pin 的 commit 在脚本里，它会在同步后重放 `patches/` 下的补丁。

- `vendor/libjuice`：上游 `paullouisageneau/libjuice` v1.7.4，纯 C 的 ICE（打洞），MPL-2.0，带一处本地补丁（触发检查立即发，`src/agent.c` 里标着 `uTerm patch #1`）。vendor 的原因：上游只有 CMake，这里手写 `Package.swift` 接进两个 App。升级步骤与合规说明见 `vendor/libjuice/UTERM-PATCHES.md`。
- `vendor/kcp`：上游 `skywind3000/kcp` 2.1.1，纯 C 的可靠重传（公网直连上跑控制消息和终端，视频不走它），MIT，代码未改。vendor 的原因同上。两端版本不同可能不兼容，升级算协议变更，见 `vendor/kcp/UTERM-PATCHES.md`。
- `vendor/zstd`：上游 `facebook/zstd` v1.5.7，**只有解压部分**（`lib/common` + `lib/decompress` 里解压用的 9 个 `.c` 与头文件，arm64 代码段约 63 KB），BSD，代码未改（`MANIFEST.sha256` 逐个核对）。vendor 的原因：Codex CLI 把 7 天没动过的会话记录压成 `.jsonl.zst`，「历史会话」要在 App 里解开，Apple 的 Compression 框架没有 zstd，依赖闭包里也没有。手写 `Package.swift`（product `CZstd`）接进两个 App。升级见 `vendor/zstd/UTERM-PATCHES.md`。

### SSH 栈（USSHKit / USSHCore / NIOSSH）在 uAppKit 里

三层都在 uAppKit（`github.com/uozi-tech/uAppKit`，按版本引用，当前 `upToNextMinor` 2.0.0；工程与 `Packages/USSHStack` 的版本要求要一致）里，本工程只引用 uAppKit 这一个包：`USSHKit`（产品层：主机密钥库与策略、
凭据与私钥导入、`-L` 隧道、文件传输、错误文案）→ `USSHCore`（我们自己写的客户端层：连接、认证、exec / PTY 句柄、
direct-tcpip、远程转发、SFTP、RSA / DH / AES-CTR 等算法，没有面向用户的文字）→ `NIOSSH`（Apple swift-nio-ssh 0.15.2
的源码作为 uAppKit 的 target 编进去，带 15 个补丁，上游自己的测试一起编成 `NIOSSHTests`）。`USSHKit` 用
`@_exported import USSHCore` 转出客户端层，App 里 `import USSHKit` 就够。补丁存成 `.patch` 放在 uAppKit 的
`ThirdParty/swift-nio-ssh/patches/`，由 `Tools/ssh-stack/sync.sh` 在上游基线上重放（`check` 核对、`apply` 升级）；
**补丁清单与升级步骤见 uAppKit 的 `ThirdParty/README.md`，升级上游前必读。** App 侧怎么用这些接口（窗口 = 包长 × 64、
错误怎么判断要不要重连、`SFTPPath`）见 uAppKit 的 `docs/ssh-stack-migration.md`。
- 测试要 SSH 服务端时用 uAppKit 的 `USSHTestServer`（进程内，带 SFTP、故障注入）；它编在 `USSHStack.framework` 里
  （见下），所以随 macOS 的 App 发布，iOS 不链它。
- **别再在本工程（或任何依赖 uAppKit 的 App）里引用上游的 swift-nio-ssh 包**：模块会和 uAppKit 里的同名 target 重名。

来历：2026-06 起 Citadel 与 Wellz26 的 swift-nio-ssh fork 在本仓库 `vendor/`，2026-09 拆成 fork 仓库，2026-11 并进
uAppKit；2026-11 底 uAppKit 2.0.0 换成跟 Apple 上游的 NIOSSH 加自写的 USSHCore，Citadel、它的补丁与 `Citadel` product
删除（不兼容升级，所以版本要求是 `upToNextMinor` 而不是 `from`）。

**macOS 上 SSH 栈是一个动态 framework**：本地包 `Packages/USSHStack`（只有一个空 target，`type: .dynamic` 的 product，依赖 uAppKit 的
USSHKit 与 USSHTestServer，整个闭包——USSHKit / USSHCore / NIOSSH / USSHTestServer / swift-nio / swift-crypto 含 BoringSSL /
swift-asn1 / BigInt / swift-log / swift-collections 的 DequeModule——链进 `Contents/Frameworks/USSHStack.framework`）。主程序 `uTerm` 与 `Helpers/uterm-ssh` 都只声明
这一个 product、都从那里加载（uterm-ssh 的 rpath 是 `@executable_path/../Frameworks`，`Embed Frameworks` 阶段只在 uTerm target 上）。
之前 uterm-ssh 静态链着和主程序一模一样的一整份（7.4 MB）。规矩：
- 这两个 target 与测试 target **不要再直接声明** USSHKit / USSHCore / USSHTestServer / SwiftASN1 / _CryptoExtras 这些静态 product，源码照常 `import NIOCore` 之类
  （都在 USSHStack 的依赖闭包里）。同一个静态 target 既进 framework 又进 App，Xcode 会把它悄悄改成动态 framework 塞进
  `Contents/Frameworks/`（每个带一份 swiftmodule），或者链出两份类型元数据。`make verify-distribution-signing` 核两边都链着它。
- 别的包也别再用 swift-collections：CodeEditTextView 为此打了补丁 #5（见它的 `UTERM-PATCHES.md`），否则 DequeModule 两头都要，
  Xcode 就把它拆成三个动态 framework。
- `make archive` 带 `ARCHS=arm64`：工程里的 `ARCHS[sdk=macosx*]` 管不到包的 target，包自己链接成的 framework 会是双架构。
- iOS 不用它，照旧静态链；远控进程 `uTermRemoteHost` 不能链它（不能链包内动态库），它也不用 SSH 栈。

## iOS / macOS 共享代码

两端的逻辑**只写一份**：凡是 iOS 与 macOS 都要的状态、算法、数据操作、文案，放 `uTerm/` 下两端共享，
`uTermMobile/` 只留 iOS 的视图与平台桥接（UIKit、手势、抽屉、分享面板）。动手写 iOS 功能前先找 mac 侧有没有同名逻辑。

- **机制**：`uTerm/` 是同步组，默认同时编进 `uTerm` 与 `uTermMobile`；pbxproj 里
  `10C0DE0000000000000000C0 /* Exceptions for "uTerm" folder in "uTermMobile" target */` 的 `membershipExceptions`
  列的是**不编进 iOS** 的 mac-only 文件。新文件放 `uTerm/` 下即两端共享；把 mac-only 文件改成共享 = 从该列表删一行。
  一个文件里混着 AppKit 视图时，把纯逻辑剪到单独的文件再共享（例：`Features/Welcome/QuickCommandLogic.swift`），
  别给整份文件套 `#if`。
- **写法**：共享文件不裸用 AppKit / UIKit（需要时 `#if canImport(AppKit)`，如 `TerminalPlatformColor`）；
  模块默认 `@MainActor`，纯值类型、纯函数、`static let` 表标 `nonisolated`。iOS 没链 UPaneGroups。
- **有意差异做成参数**，不要按平台复制一份：如 `ParallelRunModel` 的 `approval` / `hostLabel`、`HostAvatar` 的
  `defaultSize` / `monogramScale`（按 `#if os(macOS)` 取默认值）、`StreamingMarkdownRenderer` 的可选项、
  `AppLockPreference.defaultValue`（mac 开 / iOS 关）。iOS 侧残留的旧名（`ParallelRunController`、`PLine` 等）
  只是 typealias / 转发壳，新代码直接用共享名，别往壳里加实现。
- **各模块的共享落点**（新增同类逻辑往这里放）：
  - 主机 / 密钥 / 分组：写操作走 `ServerProfileStore`（含 `delete` 的级联清理）/ `GroupStore` / `SSHKeyLibrary`
    （`KeyStore` 只管钥匙串）；生成与导入密钥 `KeyGeneration` / `KeyImport`；主机表单 `Features/Hosts/HostDraft`；
    展示文案在 `ServerProfile` 扩展；组色 `ServerGroupTint`；头像 `Shared/Views/HostAvatar`。
  - 终端：引擎只有 Ghostty 一套。**画面归 GhosttyKit**（surface 自己解析、自己在渲染线程上画），**读状态归影子终端**
    `Features/Terminal/Shadow/ShadowTerminal`（libghostty-vt 的一个终端，吃同一份字节）：标题、OSC 7501 程序状态、
    OSC 133、通知、光标与备用屏、读屏、命令标记、二进制快照都读它，不读 surface。**应答只有一个来源**：surface 在吃字节时
    由它答，不吃的时候（后台、标签没露出、surface 放掉）由影子答；回放不产生应答（OSC 7501 查询 surface 不答，一律由宿主照影子的事件答）。**surface 挂上 / 回前台靠回放**：
    影子的快照转成 VT 流灌进 surface，不重放原始字节。这些都由共享的输出泵 `TerminalOutputPump` 管
    （`start(outputItems)` → 每片先喂影子、再 tap、再给 surface；`setSurfaceFeeding` / `markSurfaceStale` / `applySnapshot`；
    背压 1 MiB 停取、256 KiB 再取）——**别再写第二份分流或回放**；平台只负责告诉它 surface 什么时候能吃字节。
    同目录的 `Shadow/TerminalCheckpoint.swift`：检查点的数据格式和后端拍检查点的接口
    （Mac 本机 holder 与主机上的保持进程共用，见「主机上的会话保持进程」）。同目录的 `Shadow/TerminalEngineVersion.swift`：`TerminalEngineVersion`（见「Vendored 依赖」；单独成文件是因为远控进程不链接引擎）；`Shadow/TerminalEngine.swift`：`TerminalScrollbackLimits`
    （影子和 surface 的回滚上限必须用它算成同一个值）。其余共享件：`TerminalColorScheme`（`ansiColors` 是 `[TerminalRGB]`）/
    `TerminalPaste` / `TerminalTitle` / `TerminalCloseProbe` / `TerminalConnectionState` / `TerminalResizeSettler`
    （两端的容器都等尺寸停稳才提交）/ `TerminalCursorPreference`；程序状态 `ProgramStatusTracker` 与它的记账副本
    `ProgramStatusJournal`（在影子的事件回调里同步更新，和检查点存在一起）；输入与尺寸 `TerminalInputChannel`
    （写入和 resize 同一条 FIFO，同轮合并、相同尺寸不重发）。远控的整屏快照是引擎的二进制格式（消息 47），经
    `TerminalBackend.outputItems` 的 `.snapshot` 进泵。影子的回调在喂字节的线程上、拿着锁同步调用，回调里不能再
    `feed` / `resize` / `restore`。平台各自的一层：Mac 是 `Features/Terminal/Ghostty/`（`GhosttyTerminalBridge` /
    `GhosttyHostView` / `GhosttyTerminalConfig`，mac-only），iOS 是 `uTermMobile/Screens/Terminal/Ghostty/`——两边各有一个
    叫 `GhosttyTerminalBridge` 的类，不是同一个。由主机组装 SSH 连接用
    `SSHConnection.make(profile:container:approver:)`（`Services/SSH/SSHConnection+Profile.swift`）。
  - 建连凭据：由已保存主机解析凭据**只走** `SSHAuthResolver.resolveForConnect`（目标与跳板机都必须解析成功，
    缺跳板机凭据报错、绝不直连）。同步版给本身同步的调用点（端口转发的会话屏障、CLI 控制通道、Agent 执行器），
    异步版在并发线程池读钥匙串；目标凭据另有来源（表单「测试连接」）时只用 `resolveJump`。held 终端用
    `HeldSSHBackend.Target.make`。（吞掉跳板机错误的旧 `resolveOffMain` 已删除，别再加回来。）
  - SFTP：`FileBrowserModel` 两端共享（目录加载后发者胜、浏览中失败只提示不进失败页、`dispose` 丢弃在途结果）；
    mac 专属的拖放与外部打开在 `FileBrowserModel+Desktop.swift`（mac-only）；iOS 的 `MobileSFTPController` 只是
    转发壳，新逻辑加进 `FileBrowserModel`。有意差异是 init 参数（`sortOptions`：nil = 读写 mac 偏好；`resolvesOwnerNames`）。
    由主机建 SFTP 会话用 `SFTPSession.make`（`Services/SSH/SFTPSession+Profile.swift`，走共享连接池）。
    其余共享件：`Features/Files/` 下的 `RemotePath` / `POSIXPermissionBits` / `RemoteEntrySort` / `RemoteEntry+Display` /
    `RemoteFileOperations` / `Views/RemoteFileIcon`，只依赖 `SFTPProviding`；文件操作显式接收所在目录（`in directory:`）。
  - 远程 Mac 的文件与命令（配对过的 Mac，走远控链路，不用 SSH）：线格式 `uTermFiles/RemoteFileWire.swift`
    （主程序、iOS、辅助程序三个 target 共用的同步组；同目录的 `RemoteFileService*` 是被控端的执行体，只编进
    Mac 主程序与 `uTermShellAgent`，在 pbxproj 的 `46494C455300000000000002` 里对 iOS 排除）。主控端
    `Core/Remote/RemoteMacFileProvider`（`SFTPProviding` 的又一个实现，`FileBrowserModel` 与命令行都只认
    这个协议）+ `RemoteMacClient.performFile`；消息 48 / 49、专用通道、握手能力 `files`（老版本不认新消息
    会断开，发之前必须看能力）。界面两端都复用现有的文件浏览器：Mac 是 `RemoteMacFilesWindow`
    （`SFTPBrowserView` + `FileBrowserModel(provider:startPath:)`），iOS 是 `MobileSFTPController(remoteMac:)`
    挂在普通的文件标签上。命令行 `macs` / `mac-*` 在 `ControlHandler+Mac` 与 `ControlMacSessions`（mac-only）。
    被控端的门禁是「允许打开本机终端」，不另设开关。子进程的退出状态用 `ExitWatch`，别用 `waitpid`
    （辅助程序忽略了 `SIGCHLD`）。设计与坑见 `docs/cli-and-skills.md` 的「配对过的 Mac」。
    **反方向**（被控 Mac 终端里的程序读写主控端的文件）同一对消息倒过来走：主控端握手多声明 `file-sharing`，
    `RemoteMacClient.handleSharedFileRequest` 只放行 `RemoteFileSharingStore`（mac-only，「我的 Mac」详情里
    一台一台加，默认没有、默认只读）里共享给那台 Mac 的文件夹，范围检查在辅助程序里做
    （`RemoteFileService.confine`，解析符号链接后比对；不能跑命令、不能打补丁、搜索不调 git）。被控端发请求走
    `RemoteHostConnection.performFile`，命令行不写 `--mac` 时取「此刻接管着发命令那个终端的设备」
    （`ControlMacSessions.defaultController`；终端编号靠辅助程序写进 shell 的 `UTERM_SESSION_ID`——
    **环境变量里只放终端编号，不放设备名**，设备会换）。别给这个方向加「整台开放」的开关：被控的 Mac
    可能是别人的。见同一份文档的「反方向」。
  - 远控「我的设备」（设备组：每台设备加入一次，新设备显示一次性 6 位数、组里任意一台输入，之后互相认）：核心 `Features/Remote/RemoteDeviceGroup`（+`+Join`，`@Observable`，两端共用）；名册 `Core/Remote/RemoteGroupRoster`（iCloud 钥匙串 `com.uozi.uTerm.remote.group`，记录靠组员的 Ed25519 签名，**被控端从不读它**）、本机状态与签名私钥 `RemoteGroupLocalStore`、名单算法 `RemoteGroupMembership`、加入的 CPace `RemoteGroupJoinCrypto`（`CPace.swift`）；规格与落地见 `docs/remote-device-group-design.md`（§7.1、§12、§13）。全 App 只有一个 `RemoteDeviceGroupService`（App 级单例在后台 `refresh()`；页面别再自己建 `RemoteDeviceGroup`，两个实例会互相清掉对方的待核对）；后台不生成远控身份，有身份时会补签名私钥。界面 Mac 是 `RemoteMyDevicesGroup` + 输码面板 `RemoteDeviceGroupPrompt`（mac-only），iOS 是 `RemoteMyDevicesScreen` + 根视图单子 `RemoteGroupJoinHandler`；文案与连带移除的勾选在共享的 `RemoteDeviceGroupCopy`。移除 / 输码加入 / 离开走 `RemoteDeviceGroupService` 带验证本人的入口（`remove` / `submit` / `leave`，先过 `RemoteGroupOwnerCheck`，§19），界面别直接调模型的同名方法（`RemoteGroupOwnerCheckLintTests` 拦）。旧的一对一确认（`RemoteSibling*`、名册 `com.uozi.uTerm.remote.devices`）已删，启动时 `RemoteLegacyDevices` 清掉残留，别复用那个 service。组里的 Mac（G2，§14）：`RemoteDeviceGroup+Hosts` 每轮发本机配对过的 Mac 的 `host`、替别的组员向在线的 Mac 担保（不同 Mac 并行、同一台一次一个；结果写成组员签名的 `grant`，只有中继配置封给对象设备，`Core/Remote/RemoteGroupHostRecords`）、收别人写给本机的 `grant` 交 `hosts.adopt`；问 Mac 经 `RemoteGroupHostAccess`（App 里是 `RemoteMacDirectory`，`RemoteMacClient.vouch(for:)`），服务 `start(hosts:localHost:)` 时交给模型。G3（§15）：`+Revoke` 从本机的移除记录推出撤销（`RemoteGroupLocalState.revocations`，每台 Mac 一格、撤销先于开通，同一个 ID 没撤完不开通），并回滚只凭被移除组员的 `grant` 收下的 Mac（`adoptedHosts`，`dropAdoptedHost` 不拉黑，别用「忘记」）；重装的设备（同 ID 新钥匙）由认下它的组员顺手移除旧身份；`+LocalHost` 让组里的 Mac 把组员记成自己的主控端（`RemoteGroupLocalHost` = `RemoteHostServer+DeviceGroup`，mac-only，担保者记成这台 Mac 自己），远控进程在服务时经 XPC 新加的 `groupAddController` / `groupDropController` 转过去，远控进程不读名册。被控端认担保（消息 50–53、能力 `device-vouch` / `sibling-revoke`）：纯规则在 `Core/Remote/RemoteVouch.swift`，来路存在独立账号 `peerVouches`（别加在 `RemotePeer` 上：旧远控进程重写信任表会丢字段）；同组撤销（消息 52）与设备组撤掉被移除的组员**不拉黑**（`RemoteIdentityStore.revoke(id:blocks: false)`），并连带撤掉一层层由被撤设备担保的主控端（`RemoteVouchPolicy.cascade`，留下一台、来路改挂 `reanchor`，手动配对的不动）；按资历（Mac 信任表里的 `pairedAt`，§18）：只能撤自己、自己的上游或比自己晚加到那台 Mac 的（否则 `not-senior`），撤上游时留下那一串里最早加入的（`survivor`），请求者可能连自己一起被撤（回执 `requesterRevoked`，组员一侧停下那台 Mac 等别人重新开通）；Mac 主人在 Mac 上撤销照旧拉黑。快通道（G4a，§16）：名册记录除了写钥匙串，同时经局域网直接送到别的设备，模型的名册是包着钥匙串的叠加层 `Core/Remote/RemoteGroupOverlayStorage`（`.live` 全 App 一份，只在内存；读到的 = 钥匙串 ∪ 快通道收到的），同步层 `RemoteGroupFastSync`（线路无关，线路抽象 `RemoteGroupPeerLink`）、局域网线路 `RemoteGroupLANLink`（Bonjour `_uterm-group._tcp`，两端 Info.plist 都要有；只认**钥匙串**名册里有 `device` 记录的设备）与 `Features/Remote/RemoteGroupLANService` / `RemoteGroupFastChannel`，由 `RemoteDeviceGroupService` 跟着 `start` / `stop` 起停、收到新东西立刻 `refresh()`；别再写第二份分流或同步。中继信箱（G4b，§17）是第二种 `RemoteGroupPeerLink`：每台设备拿默认中继的成员密钥以 `host` 注册信箱（ID 由设备 ID 派生、钥匙是另一把只存本机的 P-256，`RemoteGroupMailbox`），往别人的信箱投 `signal`；握手、逐帧加密、分片与线路对象在 `Core/Remote/RemoteGroupRelayLink`（`RemoteGroupRelaySession`），注册、投递、拨号去重与控制连接抽象（`RemoteGroupRelayControl` / `RemoteGroupRelayDialer`，测试换成内存假中继）在 `Features/Remote/RemoteGroupRelayService`；中继服务端没改。挑线路在同步层：`RemoteGroupLinkKind.priority`（局域网 > 中继），局域网在时中继拨不进来，局域网断了 `onLinkClosed` 叫中继马上补拨。核对码在做信任决定的一端输入（组员输入、新设备显示；配对审批是 Mac 输入、主控端显示）。
  - 快捷命令 / 并行执行 / Agent：`QuickCommandLogic` + `QuickCommandStore`；`ParallelRunModel` / `ParallelRunTypes` /
    `ParallelCommandExecuting`（两端同一个状态机）；`AgentComposerSupport`、`TailScrollCoalescer`、
    `StreamingMarkdownRenderer`；模型服务选择 `AIProvider.active(in:id:)`。
  - 外壳：启动引导 `App/AppBootstrap`（`startCore` = CloudKit 订阅 → 建容器 → 共享偏好 → 局域网；`finishCore` =
    应用锁 → 拉共享偏好；**顺序不要动**，平台专属步骤留在各自 `App.init` 两段之间）；`ModelRegistry`、
    `CloudKitSyncStatus`、`AppLockPreference` / `AppLockModel`、`LANSyncCoordinator`（含接收端激活）。
  - 偏好键名：全部 `UserDefaults` / `@AppStorage` / KVS 键在 `Core/Preferences/DefaultsKey.swift`。新增键先加表，
    **已有键的字符串值永远不改**（改了 = 丢用户设置、断 iCloud 同步），`DefaultsKeyTests` 把每个值钉死，
    `DefaultsKeyLintTests` 拦生产代码里裸写的 `@AppStorage("…")` / `forKey: "…"`。
- **命名**：共享类型别用 SwiftUI / 系统已有的名字（如 `PreferenceKey`）——会在模块里遮住系统类型，iOS 侧编译失败，
  mac 侧可能还看不出来。
- **还没合的**（两端规则本来就不同，合了会改行为）：终端的退出流监听与断开 / 重连状态机（mac 只把 `.connected`
  翻成断开并持续监听；iOS 首个事件就停、配合连接中页）；CLI 的 `injectInput` 仍直接 `await backend.write`
  （要等写入落地，不能进输入队列）；`StartupMaintenance.run` 两端时机不同，各留在入口。端口转发与 CLI 控制通道的
  钥匙串仍在主线程同步读（会话屏障要求同步创建）。
  终端换引擎之后：输出泵、影子终端、镜像快照、程序状态是两端同一份。还分开的是
  **surface 什么时候吃字节**——Mac 的 surface 建好后不销毁，切走标签也照吃；iOS 只在 App 在前台且 surface 报出了和视图一致的
  网格时吃，隐藏 60 秒放掉 surface、露出来重建再回放（`SurfaceGridGate`）；Mac 对应的是 `surfaceGrid` + `holdsGridReports`。
  另外：holder 检查点只有 Mac 有；字体配置两端各写（Mac 带 `font-style = Medium` 和 `font-thicken`，iOS 不带）；
  OSC 7501 查询的应答 Mac 发 `ProgramStatusTracker.queryReply`、iOS 发 vt 拟好的那串；引擎 wakeup 要不要同步重画按平台定死
  （iOS 同步、Mac 不同步）。

## 远控中继 `relay/`

`relay/` 是独立的 Go 模块（用户自建，没有官方服务器）：TCP 中继加 UDP STUN，只转发不解密。协议见 `relay/PROTOCOL.md`，部署见 `relay/README.md`，方案与读数见 `docs/remote-control-research.md` §15。

- 中继自身的测试：`cd relay && GOWORK=off go test -race ./...`（上层有 `go.work`，不加 `GOWORK=off` 会报错）。
- 经真实中继的端到端：`make test-relay-e2e`。`make test-fast` 里这组用例会跳过。
- 配置里有成员私钥，别写进日志。

## 被控端的远控进程 `uTermRemoteHost/`

被控端（手机 / 别的 Mac 接管这台 Mac）的网络与采集跑在包内的 `uTermRemoteHost.app`（`Contents/Helpers/`）里：
带沙盒的 LaunchAgent，`SMAppService.agent` 注册，launchd 在 App 连它的 mach 服务 `com.uozi.uTerm.RemoteHost` 时按需拉起。
App 更新、崩溃、被强制结束时已建立的远控连接不断。方案、探针、取舍见 `docs/remote-control-daemon-plan.md`（§14 是探针结果）。

- **同一套代码两处跑**：`RemoteHostServer` / `RemoteHostConnection` / 桌面 / 中继在远控进程里服务；App 里也有一个
  `RemoteHostServer`，`agent` 不为 nil 时只镜像状态（`applyAgentState`）、把操作转给远控进程，设置页与命令行照旧读它。
  服务端只经 `RemoteHostSessions` 看终端：进程内是 `RemoteRegistrySessions`，远控进程里是 `RemoteForwardedSessions`
  （字节经 XPC 从 App 来，512 KiB 信用窗口流控）。**别让被控端代码直接碰 `TerminalSession` / `TerminalSessionRegistry`**。
- **XPC 协议只加不改**（`Features/Remote/Agent/RemoteHostAgentProtocol.swift`）：App 更新后旧的远控进程可能还在服务
  （有设备连着时等它们断开才换，`RemoteHostAgentBridge.scheduleUpgradeCheck`）。新操作加 case、新字段加可选。
- **交给 XPC 的闭包都标 `@Sendable`**（错误回调、`invalidationHandler`、回复）：XPC 在自己的队列上调，默认继承主线程隔离
  的闭包会在运行时直接中断（`_dispatch_assert_queue_fail`）。监听器的 delegate 也是在 XPC 队列上调的。
- **钥匙串与设置归 App**：远控进程没有钥匙串访问组，App 在 `hello` 里交身份、信任表、中继配置、设置，远控进程只放内存；
  写入（配对、改名、中继证书）回传 App 落盘，App 不在时排队。被控端用到的身份账号见 `RemoteHostAgentBridge.secretAccounts`。
- **权限**：屏幕录制（含声音）、本地网络归到 uTerm（tccd 按 `SMAppService` 的父 App 认），用户不用另授权。**「辅助功能」
  （PostEvent，控制鼠标键盘、远程解锁、帘幕）不归过去**：tccd 按远控进程自己的身份判，系统设置里要另外打开「uTerm 远程控制」
  （2026-11-14 实测，2.1.1–2.1.4 因此被控 Mac 只能看）。被控端的授权只经 `RemoteHostPermissionSource` 查和申请（远控进程在
  服务时问它，命令 `desktopPermissions` / `requestPostEvents`），别在 App 进程里直接 `CGPreflightPostEventAccess` 当被控端
  的状态。远控进程的沙盒里读不到用户文件，远程文件与命令交给它包内嵌的那份 `uTermShellAgent.xpc`。
- **系统设置里的名字与图标**：名字在 `uTermRemoteHost/{zh-Hans,en}.lproj/InfoPlist.strings`；`Info.plist` 里未本地化的
  `CFBundleDisplayName` 必须等于包的文件名 `uTermRemoteHost`，否则系统不用本地化名字、只显示文件名（`CFBundleName` 构建时
  也会被换成 `PRODUCT_NAME`）。图标是 uTerm 图标加角标，由 `scripts/render-helper-icon.swift` 生成。本机终端的 holder 同理：
  它是 `Helpers/uterm-holder.app`（不是裸可执行文件——裸文件 tccd 只按路径记，系统设置里只有文件名和通用图标），disclaim 后
  终端里程序的授权记在「uTerm 终端」名下；资源在 `Config/uterm-holder/`（`uTermHolder/` 同步组也编进主程序等 target，资源
  不能放那里），由 holder target 的 Run Script 拷进包。开发机上系统设置
  显示旧名字 / 空白图标时，先看 `lsregister -dump` 里是不是登记了一堆 DerivedData 里的同 bundle id 副本，`lsregister -u` 掉。
- **什么时候不用它**（服务留在 App 里，行为同以前）：测试宿主、没装在 `/Applications` 或 `~/Applications` 的构建（开发构建
  与正式版同 bundle id，注册同一个任务会顶掉正式版的）、用户在「登录项与扩展」里关了它、`DefaultsKey.remoteHostAgentDisabled`。
- **App 走了**：远控进程宽限期内照常服务（崩溃 120 秒、Sparkle 更新 300 秒），终端暂停、桌面与文件不受影响；App 回来按原会话
  重新接入（第一段是新快照）。用户 ⌘Q 时随之结束。到期就停止服务并正常退出（`KeepAlive` 只在崩溃时重启）。
  **回来的 App 换了 build（更新）时远控进程立即退出**：换过包的旧进程过不了 App 的签名核对（`-67065`），tccd 也不认它的
  屏幕录制授权（手机开屏幕报「用户拒绝」）。App 连续几次等不到握手回话就注销再注册它（救 2.1.5 及以前不会自己退的旧进程）；握手 10 秒没回也算一次（`RemoteHostAgent.helloTimeout`：launchd 拉不起进程时连接不断、只是一直排队，没有超时 App 会永远停在「正在连接」）。开发机上的典型起因：开机时系统按 bundle id 重新登记任务，挑中了 build 号更大的工作树 Debug 构建，之后那份被重编或删掉；或后台项目记录里缓存着当年开发签名的启动约束（launchd 报 `Launch Constraint Violation`）。先 `lsregister -u` 掉非 `/Applications` 的副本，再让 App 注销再注册（重启 App 即可触发）。
  所以更新会让远控连接断一次，见方案文档 §4.5。
- **进程身份不写死**：bundle id 前缀是构建设置 `UTERM_BUNDLE_ID`（`Config/Version.xcconfig`，正式版 `com.uozi.uTerm`，
  外部贡献者在 `Config/Local.xcconfig` 换成自己的），9 个 target 的 bundle id、entitlements、iOS 后台任务 id、远控进程的
  launchd plist（构建时按前缀替换，正式前缀下逐字节不变）都由它派生。代码里的 mach 服务名、XPC 服务名、互认身份、登录项 id
  一律走 `AppIdentity`（`uTermHolder/CodeSigningTeam.swift`，读本进程 Info.plist 的 `UTermBundleIDBase`）；iOS 用
  `Bundle.main.bundleIdentifier`。钥匙串服务名、日志 subsystem、队列名、UTType **不**跟着变（改了丢已有用户的数据）。
- **加文件**：远控进程只编列出来的共享源码（pbxproj 里 `Exceptions for "uTerm" folder in "uTermRemoteHost" target`）。
  被控端代码引用了新的类型就要把它的文件加进去；那个文件又拖进主控端或终端引擎的代码时，把用得到的部分拆成单独文件。
- **launchd plist**（`Config/com.uozi.uTerm.RemoteHost.plist`）在注册时被缓存，改了它 App 会先注销再注册（按内容摘要判断）；
  尽量别改。远控进程不能链接包内的动态库，`verify-distribution-signing` 核这一条和沙盒、调试权限。
- 测试：`RemoteHostAgentTests`（同一进程里的匿名 XPC 监听器 + 真 `RemoteMacClient`）；`scripts/remote-host-live-test.sh`
  把刚编好的远控进程登记成 launchd 任务（不经 SMAppService、不广播 Bonjour）跑 `RemoteHostAgentLiveTests`：真沙盒、
  真 mach 服务、两头核签名、内嵌文件服务、App 重启续上。SMAppService 注册、TCC 归属、Sparkle 换包、真机远控要在装好的
  公证包上手动验（清单见方案文档 §15）。

## 主机上的会话保持进程 `holder/`

`holder/` 是独立的 Go 模块，编出 `uterm-holder`（Linux amd64 / arm64，静态链接，无依赖）。App 第一次连某台主机时把它传到
`~/.local/share/uterm/bin/uterm-holder-<版本>`（不需要 root），之后每个终端会话在主机上由它持有 PTY：SSH 连接断了
（手机退后台被挂起、换网络）shell 接着跑，重新连上经 exec 通道按「已收到的位置」接回，断开期间的输出补上。
和 Mac 本机那个 `uTermHolder/`（重启不断终端）是两个程序，帧协议相同（`uTermHolder/HolderWire.swift`，**只加帧、不改已有帧**）。

- App 这头在 `uTerm/Services/SSH/HostHolder/`（两端共享）：`HostHolder`（常量、主机上跑的命令、打包的二进制）、
  `HostHolderInstaller`（上传 + `probe`）、`HostHolderLink`（一条 exec 通道上的帧收发）、`PersistentSSHConnection`
  （后端：自己重连、接回；用不了保持进程的主机退回 `SSHConnection`）。**现在只有 iOS 的终端用它**
  （`MobileTerminalTransportFactory.makeLive`）；Mac 仍走原来的路径。没有开关（维护者定）。
- 二进制随 App 打包，不进版本库：`make holder`（`scripts/build-host-holder.sh`）交叉编译、LZMA 压缩到
  `uTerm/Services/SSH/HostHolder/Binaries/`（已 gitignore），源码没变就不重编；`make build` / `archive` / `test*` /
  `archive-mobile` 等都先依赖它。需要本机有 Go。
- **发版之后改了 Go 源码就必须升版本**：`holder/cmd/uterm-holder/main.go` 的 `version` 与 `HostHolder.version` 一字不差
  （`HostHolderTests` 拦着）。主机上的文件名带版本，不升的话已经装过的主机永远用旧二进制。
- 会话什么时候结束：shell 退出；关标签（`close()` 发 `terminate`）；没有客户端接着超过 24 小时
  （`HostHolder.detachedTimeoutSeconds`，App 被系统杀掉后没人回来接）。
- **两种接回**，都在 `PersistentSSHConnection` 里：
  - 连接断了、后端对象还在（App 被挂起、换网络）：按已收到的位置接（`HostHolderAttach.fromOffset`），补断开期间的字节。
  - App 被系统结束后重新打开（新的后端对象、空的终端，同一个会话 id）：第一次接入从主机存着的**检查点**开始
    （`fromStoredCheckpoint`）——检查点是影子终端的快照加程序状态（`TerminalCheckpointBlob`，和 Mac 本机 holder 同一个格式，
    只带最近 `HostHolder.checkpointScrollbackLines` 行回滚；另带一份回放流，App 更新换了引擎、快照解不开时由
    `TerminalCheckpointBlob.restorableSnapshot` 重画成快照），App 进后台时、每收到 8 MiB 输出各存一张
    （`CheckpointingTerminalBackend.saveCheckpoint`）。没存过就把主机上留着的那 16 MiB 整段补上。
  - 补的那段字节按**历史**交给输出泵（`TerminalOutputItem.history`）：照常解析，里面的查询不答、通知不发，程序状态照收。
    只有刚新建的会话例外（shell 启动时发的查询等着回答）。检查点对应字节流上的哪个位置，靠同步点
    （`TerminalOutputItem.afterFed` + `HostHolderStreamPosition.mark`）在泵的锁里对齐，别改成数 tap 的字节数：
    泵里还会进别的字节（光标复位、本端加的提示）。
- iOS 的标签归档（`uTermMobile/Screens/Workspace/MobileTerminalTabArchive.swift`，偏好键 `mobile.restorableTerminalTabs`，只存本机）：
  直连主机、没断开的终端标签连同会话 id 记下来，启动时由根视图里的 `MobileTerminalTabRestorer` 开回来。测试宿主里它不读不写
  （和正式版共用一份偏好）。会话结束后控制器换一个会话 id（`MobileTerminalController.hostSessionID`），之后「重新连接」开的是新会话。
- iOS 进后台向系统要约 30 秒运行时间（`MobileBackgroundGrace`，只给直连主机的会话）：短暂切出去连接不断，检查点也靠这段时间发出去。
- 回前台、网络刚变（Wi-Fi ↔ 蜂窝）时不等看门狗：`ConnectionWatchdog` 一收到路径更新就调 `networkPathChanged`，控制器转给
  `ReconnectingTerminalBackend.recheckAfterDisruption`。原来走的网卡没了直接断开重连，否则 2 秒时限探一次；正在重连就取消退避马上再试。
  只有判错了无所谓的后端实现它（多重连一次、画面不动），普通 `SSHConnection` 仍然等看门狗的 3 秒稳定期。
- 用不了的主机：不是 Linux、不是这两种架构、`KillUserProcesses=yes` 且没开 linger（退出登录会清进程，矩阵见
  `holder/cmd/uterm-holder/systemd.go`）。判定一次后在主机上留 `.unsupported` 标记，之后直接走普通 PTY。
- 测试：`make test-holder`（`cd holder && GOWORK=off go test -race ./...`）；`make test-holder-e2e` 起一个 Docker 里的
  sshd 走真实 SSH。App 侧的真连用例 `PersistentSSHConnectionLiveTests` 默认跳过，开关是
  `TEST_RUNNER_UTERM_LIVE_SSH_PORT`（配 `…_USER` / `…_PASSWORD`，可以直接指向 e2e 那个镜像起的容器）。
- 真机验证：`holder/scripts/device-verify.sh --device <udid>`（或 `--simulator <名字>`）。它在 Mac 上起一次性的 sshd 容器，
  按阶段跑 `MobileTerminalDeviceVerifyTests`，从外面切后台、挂起进程、掐连接、杀进程再重开。测试会话下系统不会自己挂起宿主
  进程，所以挂起是 `devicectl device process suspend` 做的；系统自己挂起、Wi-Fi ↔ 蜂窝切换、根视图里的标签恢复入口要人手试。

## iOS 灵动岛 / 锁屏（实时活动）与「离开后继续运行」

- 组件扩展 target `uTermLiveActivity`（`com.uozi.uTerm.LiveActivity`，嵌在 `uTermMobile` 的 `PlugIns/`），源码在 `uTermLiveActivity/`，
  Info.plist 是根目录的 `uTermLiveActivity-Info.plist`。App 与扩展共用的类型只有 `uTermActivityShared/TerminalActivityAttributes.swift`
  （同步组，两边都编）。**扩展不编 `uTerm/` 的共享源码**：文字全部由 App 算好放进 `ContentState`，扩展里只用 `Text(verbatim:)`，
  不进文案目录（`SWIFT_EMIT_LOC_STRINGS = NO`）。扩展的 build 号由它自己的 `Set Build Number` 阶段写，必须等于 App 的
  （`verify-mobile-signing` 核）；改那段脚本要三处一起改。
- App 侧在 `uTermMobile/Screens/LiveActivity/`：`TerminalActivityCenter`（根视图持有并注入；观察工作区、建 / 更新 / 收实时活动、
  后台时发本地通知、`uterm://terminal/<标签页 ID>` 深链接）、纯函数 `TerminalActivityContent`（排序、截断、已暂停）、
  `TerminalKeepAlive`（标签页长按菜单「离开后继续运行」，iOS 26 的 `BGContinuedProcessingTask`，标识 `com.uozi.uTerm.terminal.*`）。
  `BGContinuedProcessingTask` 的提交 / 汇报 / 交还只有一份：`uTermMobile/Shell/ContinuedProcessingLease.swift`，并行执行也用它。
- **没有推送**（要团队的 APNs 钥匙放服务器上，中继是用户自建的，不可能）。App 挂起后内容停在最后一次：挂起前推一次「已暂停」，
  每次更新带 `staleDate` 兜底，扩展把过期内容按已暂停画。ActivityKit 只允许在前台发起，所以条件一满足就在前台建。
- iOS 上 `UNUserNotificationCenter` 的 delegate 只有 `TerminalNotificationRouter` 一个（前台不弹横幅，同没有 delegate 时）。
- 测试：纯逻辑 `TerminalActivityTests`；接真控制器的 `TerminalActivityCenterTests`（真机上真的建实时活动；系统给的后台
  时间由用例经 `TerminalActivityCenter(backgroundTimeRemaining:)` 给，先「无限」再有限，不然走不到「已暂停」）；
  真机看灵动岛用 `TerminalActivityDeviceTests`，默认跳过，`TEST_RUNNER_UTERM_LIVE_ACTIVITY_DEVICE=plain|keep` 打开，
  外面切后台（`devicectl device process launch … com.apple.Preferences`）再截屏。**测试会话里系统不挂起宿主、后台时间读到「无限」**，
  量不了「多久暂停」：那要用 Debug 构建的启动参数 `devicectl device process launch --console … com.uozi.uTerm -- -LiveActivityDebugDemo YES`
  （值写 `keep` 顺带开后台保持）开演示终端，看 stderr 里的 `[live-activity]` 行。Duo 截屏要 `--display-unique-id 123-456-789`。
- 2026-11-19 Duo 实测：普通后台系统给 25 秒，到点前 5 秒推「已暂停」；后台保持期间 App 一直在跑（实测 150 秒仍实时），
  但**灵动岛被系统自己的「后台继续处理」占着**（展开态，标题 / 副标题 / 进度 / 停止键），我们的实时活动这时看不到，
  状态靠 `TerminalKeepAlive` 写进系统那份的副标题。横屏时灵动岛竖着窄，紧凑态右侧放不下字就换图标（`ViewThatFits`）。

## CloudKit schema

iOS 与 macOS 通过共享容器 `iCloud.com.uozi.uTerm` 同步（SwiftData，`cloudKitDatabase: .automatic`）。
两端的 entitlements 都把 `com.apple.developer.icloud-container-environment` 钉死在 **Production**，
因此**没有任何构建连 Development**——而 `NSPersistentCloudKitContainer` 的自动 schema 初始化只对
Development 生效。结论：**新增 / 改名 `@Model` 属性不会被任何一次运行自动推上 CloudKit**，同步会对
该字段静默失败。别指望「跑一下就好了」。

发版前（以及任何动过 `@Model` 之后）跑：

```
make check-cloudkit-schema
```

它 = `scripts/check-cloudkit-schema.py`：从源码解析全部 `@Model` 的存储属性 → 按 SwiftData→CloudKit
映射算出期望字段 → 跟 `xcrun cktool export-schema --environment production` 的线上 schema 逐字段比对；
同时核对模型注册表。注册表只有一份：`uTerm/Core/Persistence/ModelRegistry.swift` 的 `ModelRegistry.types`，
`AppModelContainer` / `MobileModelContainer` / iOS 测试夹具都引用它；**新增 `@Model` 只加在这里**。脚本解析它，
并核对两个建容器的文件确实引用了 `ModelRegistry.types`；注册表或容器文件找不到、解析出 0 个类型都会报错退出
（不再静默跳过）。有漂移就非零退出。
自测：`bash scripts/check-cloudkit-schema.test.sh`（全离线，不碰真实容器）。

扫描根不止本仓库：`ChatSession` / `ChatMessageRecord` 这两个 `@Model` 在 uAppKit 的 AgentKit 里，
Makefile 因此把 SwiftPM 的 checkout（`build/DerivedData/…/checkouts/uAppKit/Sources/AgentKit`，找不到时
退回 `~/Library/Developer/Xcode/DerivedData/uTerm-*/…`）一并喂给脚本。两个根都找不到时 target **报错退
出（2）**，不降级成「少扫两个类型也算过」——容器注册 10 个类型，少扫谁就等于谁不设防。换机器可显式传
`make check-cloudkit-schema CLOUDKIT_AGENTKIT_ROOT=/path/to/uAppKit/Sources/AgentKit`。

首次使用需要 CloudKit Management Token：`xcrun cktool save-token --type management`（存 keychain）。

报了漂移就按提示修（`cktool` 对 production 只读，只能先补 Development 再去 Console 部署）：

```
python3 scripts/check-cloudkit-schema.py --emit-schema /tmp/uTerm.ckdb
xcrun cktool import-schema --team-id <TEAM> --container-id iCloud.com.uozi.uTerm \
    --environment development --file /tmp/uTerm.ckdb
# CloudKit Console → 容器 → Development → Schema → Deploy Schema Changes… → Deploy to Production
make check-cloudkit-schema   # 部署后重跑，必须干净
```

漏做的后果不是「新字段不同步」这么轻：`NSCloudKitMirroringDelegate` 遇到 production 里不存在的**类型**
会整体初始化失败（`Cannot create new type CD_X in production schema`），连旧的主机 / 密钥也一起停止同步。

映射表（`TYPE_MAP`，已对照真实已部署字段核过）：`Bool`/`Int`→`INT64 QUERYABLE SORTABLE`，
`String`/`UUID`→`STRING QUERYABLE SEARCHABLE SORTABLE`，`Date`→`TIMESTAMP QUERYABLE SORTABLE`，
`Data` 与非模型数组（如 `[UUID]`）→`BYTES QUERYABLE SORTABLE`；可选性不影响类型与索引。
to-one 关系镜像成一个 `STRING` 引用字段，to-many 靠子表反向键、自己没有字段。碰到映射表里没有的类型脚本
会**报错退出**（而不是猜），补进 `TYPE_MAP` 前先用 `export-schema` 看真实类型。

不要为了让 Debug 自动维护 Development schema 而给 Debug 单独一份 entitlements：Debug 与 Release 共用
同一个 bundle id、同一份本地 store，同一个 store 在两个 CloudKit 环境间来回切会反复重置镜像元数据并整库
重传。理由与替代方案见 `uTerm/uTerm.entitlements` 里的长注释。

## Build Versioning

- `MARKETING_VERSION`（用户可见版本，main.feat.patch）**两个平台各有一份真值源**；**两份的 main.feat（前两段）必须一致**，只有 patch 可以不同（2026-11-20 起，规则见发版 skill 的「版本号对齐」）：
  - macOS（`uTerm`）：`Config/Version.xcconfig`，由 **project 级** `baseConfigurationReference` 注入所有 target；
  - iOS（`uTermMobile`）：`Config/VersionMobile.xcconfig`，由 `uTermMobile` 与 `uTermMobileTests` 的 **target 级** `baseConfigurationReference` 引用。target 级 xcconfig 叠在 project 级之上，于是覆盖掉 macOS 那份 `MARKETING_VERSION`。
  不要在 pbxproj 里再写 `MARKETING_VERSION`（会覆盖 xcconfig）。改动后核对两边：`xcodebuild -showBuildSettings -scheme uTermMobile -destination 'generic/platform=iOS' | grep MARKETING_VERSION` 应为 iOS 那份，`-scheme uTerm -destination 'platform=macOS'` 仍应为 macOS 那份。
- 改版本只用命令，不要手改文件：
  - macOS：`make print-version` / `make set-version VERSION=x.y.z` / `make bump-patch|bump-minor|bump-major`
  - iOS：同名目标加 `-mobile` 后缀 —— `make print-version-mobile` / `make set-version-mobile VERSION=x.y.z` / `make bump-{patch,minor,major}-mobile`
- 底层是同一个 `scripts/bump-version.sh`（含自测 `scripts/bump-version.test.sh`），靠 `--mobile`（或 `--file PATH`）选目标文件，不是复制两份脚本。
- `CFBundleVersion`（build 号）由 `Set Build Number` Run Script 在编译期设为 **`git rev-list --count HEAD` + `Config/BuildNumberOffset`**（Makefile 的 `BUILD_NUMBER` / `make print-build` 同一算法），只写产物 Info.plist，源码无 churn。**不要手改**。偏移量文件的来历：2026-09-11 一次 `git pull --rebase` 把已发布 1.13.0 (build 379) 之前的 7 个 merge commit 压平，提交数从 382 掉到 373，Sparkle / TestFlight 都要求 build 号单调递增，于是用 `+9` 把计数接回去。它**只能调大、不能调小**，且只在「历史重写让计数低于已发布 build 号」时才动；平时发版不用管它。
- `uTerm`（macOS）与 `uTermMobile`（iOS）**各有一份**该 phase（脚本内容一字不差，UUID 不同：`CFCFCFCF000000000000F0F1` / `...F0F3`；`...F0F2` 是 `Config` 组、`...F0F4` 是 `VersionMobile.xcconfig`，加新对象前先 grep 查重）。一个 `PBXShellScriptBuildPhase` 对象不能挂在两个 target 上，所以只能复制，不能共用；改脚本要两处一起改。
- 该脚本需要所在 app target 的 `ENABLE_USER_SCRIPT_SANDBOXING = NO`（两个 app target 都已设，测试 target 不需要）。不要改回 YES，否则脚本无法写产物 plist。
- build 号（不是版本号）两个平台仍**共用**同一个来源，所以同一次提交产出的 macOS DMG 与 iOS TestFlight 构建 build 号相同。TestFlight 要求同一 `CFBundleShortVersionString` 下 build 号**严格递增**——补传一次同一提交的构建会撞号，此时应先产生新提交（发版 skill 的 release commit 天然会 +1）。

## 发版

发版（Developer ID 导出、DMG、公证、Sparkle appcast、iOS 分发与 TestFlight、发布日志）是维护者专用的，流程、目标与脚本在
`internal/`（维护者私有，公开仓库没有；`Makefile` 末尾 `-include internal/release.mk` 接进来）。公开仓库只有面向用户的
`CHANGELOG.md`。

## 性能探针

- 列表/表格渲染的判定、读数、已排除的路与未决账全在 `docs/scroll-perf-findings.md`（开头有一页总表）；动手改列表前先读它的「与 uTable 结论不同之处」与「探针纪律」两节。
- 全量用 `make test-fast` / `make test-mobile-fast`（并行全跑，失败用例再串行复核，以串行结果为准）：实测 macOS 2368 个用例约 5 分钟（串行 40 分钟以上），iOS 217 个约 5 分钟。悬停探针和性能探针并行时会假红，性能探针在机器忙时串行也会红（脚本复核前会等负载回落，等不到会提示）；钥匙串用例在锁屏时必失败（-25308）。
- 夹具在 `uTermTests/Support/`（`ProbeWindow` / `ProbeMetrics` / `VisionTextProbe`），自证用例 `ProbeSmokeTests`——**别再抄第二份**。
- 跑法（含 worktree、`build-for-testing` + `test-without-building` 的完整命令、以及「不要加 `CODE_SIGNING_ALLOWED=NO`」等注意事项）见该文档的「跑法」一节。
- **iOS/iPadOS** 的测试 target 是 `uTermMobileTests`（宿主 `uTermMobile.app`，跑模拟器），一条命令 `make test-mobile`（换机器传 `MOBILE_DESTINATION`）。
- iOS 侧的 target 配置、夹具（`uTermMobileTests/Support/`）、基线读数与八条坑（模拟器运行时要单独下、`uTerm/` 加 AppKit-only 文件要同步改 `membershipExceptions`、CloudKit 报错是常态……）见 `uTermMobileTests/README.md`。
- **终端（Ghostty）的滚动与渲染**：读数、十轮返工的经过是维护者的内部测量记录（不在公开仓库，见 `docs/ghostty-eval/README.md`），定下的预算与结论写在用例与 `vendor/libghostty-spm/UTERM-PATCHES.md` 里；`docs/scroll-perf-findings.md` 里终端渲染的部分是旧引擎的。
  - Mac：`GhosttyMacScrollTests`（造带 phase 的滚动事件，读 IOSurface 核行界）、`GhosttyMacHostTests`、`GhosttyFontRenderingTests`（读像素核字重与标点位置）。夹具 `uTermTests/Support/GhosttySurfaceRig`（真的 surface + 在屏窗口）。**测试窗口被遮挡时显示节拍会停、第一帧常常是空的**：读画面的用例要等到有内容且连续两次读数相同才取帧；这几类并行时偶发假红，串行复核为准。
  - iOS：`uTermMobileTests/Probes/` 下的 `GhosttyScrollEdgeTests` / `GhosttySystemScrollJitterTests` / `GhosttyCapturedMomentumTests` / `GhosttyScrollFeelTests` / `GhosttySmoothScrollPixelTests`，回前台与隐藏标签是 `GhosttyBackgroundTests` / `TerminalHiddenRenderingTests`。模拟器只有 60 Hz，按 120 Hz 判定的几条（`GhosttyFrameBudgetTests`、`GhosttyOnScreenScrollTests` 的 fling、`GhosttyScrollFeelTests`、`testFlingMomentumRunsAtDisplayRate`）在模拟器上必红，要看真机。
  - 真机测量用维护者指定的那台（见 `internal/CLAUDE.md`），别的真机不要装包、不要跑测试。设备锁屏时 xcodebuild 会直接退出。
  - 测量用例默认跳过，开关是 `TEST_RUNNER_GHOSTTY_MEASURE=1`（Mac 的 `GhosttyMeasureTests`）/ `UTERM_MEASURE=1`（iOS）。量时间、帧率时别和别的编译同时跑。

## 界面画廊（`make gallery`）

`uTermTests/Support/UICatalog/` 是 macOS 每个窗口 / 状态的目录（移植自 uTable 的同名设施）：每条记录一个层级 ID + 构造闭包，
`UICatalogSnapshotTests` 浅深各渲一张，`make gallery` 拼成 `build/ui-gallery/latest/index.html`（`GALLERY_FILTER=子串` 只渲一部分，
`GALLERY_ARTIFACT=<目录>` 另出 Artifact 发布包，`make gallery-diff` 比改动前后）。

- 夹具全是假的：内存 SwiftData、一次性设置存储、`MockSFTP`、终端接 `MockBackend` 喂写好的 ANSI 输出、并行执行用假执行器 + 脚本化的
  `MockLLMClient`。**不连任何真主机**（转发规则别开 `autostart`，会真去连）。
- 终端是真的 Ghostty surface：`cacheDisplay` 拍不到 Metal 画面，渲染器把 IOSurface 那一帧贴回去；有终端的记录标 `live: true`
  （窗口透明地摆在屏上才有显示节拍）。
- 测试宿主带沙盒、写不进仓库：图挂成 XCTest 附件，`scripts/ui-gallery.py collect` 从 xcresult 导出。
- 要和用户看到的一样：整窗记录带系统红绿灯（单独拍了贴回去）；测试宿主不是前台 App，`UICatalogWindow` 覆盖了 AppKit
  判断「活跃外观」的私有方法，否则红绿灯是灰的。工作区的状态栏遥测走真解析器（`TelemetryModel.tick()` 吃写好的输出），
  预览区空着时的「最近打开」走真的打开 / 关闭流程填。离屏 `cacheDisplay` 画 CALayer 投影和屏幕合成器不一样（模糊大、
  偏移方向反），拍的那一下按比例改回去再还原（`UI_GALLERY_SHADOW_RADIUS` / `_OFFSET` 可调，默认 0.6 / -1.6，对着主按钮量的）。
  和装好的 App 对不上时，先拿 App 的真窗口截图比一遍。
- 产品侧只加了画廊用的注入口：`WelcomeView(initialPane:initialSelection:)`、`WorkspaceWindowView(catalogModel:)`、
  `TerminalWindowView(catalogModel:)`、`SFTPWindowView(catalogTabs:)`、`ParallelRunWindowView(catalogModel:)`、
  `ServerFormView(catalogStartsAtBottom:)`（表单停在最底下，拍跳板机那一节），App 里都走默认值；
  iOS 侧 `RemoteDesktopSession.showGalleryWindow`（不连 Mac，把一张图当窗口模式的画面送进画布，官网截图用）；`TelemetryModel.tick()` 由 private 放宽成 internal。
- iOS 对应的是 `uTermMobileTests/Probes/StyleGalleryTests`（压力夹具，核排版，见 `uTermMobileTests/README.md`）；宣传用的干净几屏是
  同目录的 `PromoGalleryTests`（文件名 `promo-*`，同一个开关 `UTERM_STYLE_SHOTS_DIR`）。其中 `testPromoScreensOnDevice` 在
  iPhone Duo 模拟器里整屏挂真的外壳、由宿主脚本 `simctl io screenshot` 截（带状态栏那一列与屏幕圆角）；远程桌面的窗口模式用
  Mac 画廊「终端窗口/手机窗口模式」那张图当画面。终端里的 Claude Code 是真的录制（`Recordings/README.md`）。
- 官网在维护者私有仓库（`internal/website/`，公开仓库没有），产品画面只取这些截图，不手画界面。

## 文案目录（`uTerm/Localizable.xcstrings`）

两端共用一份 String Catalog。里面的键是编译器抽出来的：`SWIFT_EMIT_LOC_STRINGS = YES` 让每个源文件编译时吐
一份 `.stringsdata`（文件里进了 `LocalizedStringKey` 的字面量：`Text("…")` / `navigationTitle` / `.alert("…")` /
`Window("…")` 等；走 `String` 参数的文案——`SettingsRow` 的 label / hint、`MInsetRow` 的 label、`UDButton` 的
title——编译器不抽，所以调用处要包 `String(localized:)`，见下面「多语言」）。把 `.stringsdata` 合进目录这一步只有 Xcode 的 IDE 在构建后会做，
`xcodebuild` 不做，Apple 的 `xcstringstool sync` 只保留带翻译的条目（一跑会删光几百个未翻译的空壳键，别用）。

- **抽文案用 `make sync-strings`**：先把 `uTerm`（mac）与 `uTermMobile`（iOS 模拟器）各编一遍拿到两端的
  `.stringsdata`，再用 `scripts/sync-strings.swift` 合进目录——输出格式逐字节对齐 Xcode（排序、空壳写法、
  文件末尾无换行），所以之后 Xcode 再写也不会产生无意义的 diff。规则同 Xcode：新键加空壳；代码里没了且
  有翻译的标 `stale`；没了又没翻译的删掉（`--no-prune` 改成只标 stale）；`manual` 的永不动。
- `make check-strings` 只核不写，目录落后于代码时非零退出（发版前自检）。
- 两端的 `.stringsdata` 必须都给：mac-only 文件只有 mac 构建才产出，只喂一端会把另一端独有的键当成
  「代码里没了」。工具在某个目录下找不到 `.stringsdata` 会直接报错。
- 自测：`bash scripts/sync-strings.test.sh`（含用仓库真实目录做的 round-trip 校验）。

### 多语言（2026-11 起）

源语言简体中文（`developmentRegion = zh-Hans`），另带 **en、zh-Hant（台湾用语）、ja、ko**。目录里每个键都要带齐这四种，
`make check-translations`（`scripts/translations.py`，自测 `scripts/translations.test.sh`）缺一个或占位对不上就非零退出。

- **写文案的规矩**（新代码照做，否则那句话永远是中文）：
  - 走 `String` 参数的地方（`SettingsRow` / `MInsetRow` / uAppKit 的 `UDButton` 等的标题、模型里返回 `String` 的
    `title` / `label` / `message`、`errorDescription`、交给 `NSAlert` 的文字）一律 `String(localized: "…")`。
    SwiftUI 直接收字面量的（`Text("…")`、`Button("…")`、`.help`、`.alert` 标题、收 `LocalizedStringKey` 的自家 helper）不用包。
  - 拼接写成一个带插值的整句（`String(localized: "已连接\(name)")`），别 `"…" + x`；列表分隔符用
    `String(localized: "、", comment: "并列项之间的分隔符")`。
  - 插值：`String` 直接插；表示**数量**的 `Int` 直接插（英文会走复数）；**标识**类整数（端口、PID、年份、版本、错误码、
    核对码）插 `String(x)`，否则按区域加千分位（`47,310`）；`Double` 等先格式化成 `String`。
  - 短而有歧义的词加 `comment:`。同一句中文在两处意思不同（如侧栏的「置顶」和菜单动作「置顶」）就给其中一处显式的键：
    `String(localized: "sidebar.pinned", defaultValue: "置顶", comment: …)`，并在目录里手写它的 zh-Hans 值。
  - 不翻译：日志、断言消息、`#Preview`、测试；示例终端输出用 `Text(verbatim:)`。**不要拿显示文字做比较 / 前缀匹配**
    （换了语言就失效）——用错误类型或 code（例：`RemoteMacLocalFileError`、`SSHConnectionError.authenticationFailed`）。
  - 发给大模型的提示词照旧用中文写，但要求模型回答用界面语言：`AgentReplyLanguage.displayName`（uAppKit 审批理由同理）。
- **翻译流程**：`make sync-strings`（新键进目录）→ `python3 scripts/translations.py missing --out todo.json`（带源码位置）
  → 翻成 `{"键": {"en": …, "zh-Hant": …, "ja": …, "ko": …}}` → `python3 scripts/translations.py merge todo-out.json`
  → 再 `make sync-strings`（回到 Xcode 格式）→ `make check-translations`。术语统一：主机 host / 主機 / ホスト / 호스트，
  中继 relay / 中繼 / リレー / 릴레이，远程控制 Remote Control / 遠端控制 / リモート操作 / 원격 제어，标签页 tab / 分頁 / タブ / 탭，
  会话（终端）session / 工作階段 / セッション / 세션，对话（AI）conversation / 對話 / 会話 / 대화；句中「」引用的设置名必须和那个设置自己的译名一致。
- **界面语言**：mac 的「设置 › 外观 › 语言」（`AppLanguage`）写本进程的 `AppleLanguages`，重启生效；iOS 用系统设置里的 App 语言。
- **别的进程**：远控进程（`uTermRemoteHost`）与 `uTermShellAgent.xpc` 也带这份目录（pbxproj 里各有一条只含
  `Localizable.xcstrings` 的例外；shell agent 为此加了 Resources 阶段）。裸可执行文件 `uterm-ssh` 没有 bundle，
  `uTermSSH/SSHHelperBundle` 往上找外层的 `uTerm.app` 取文案。uAppKit 的每个 target 自带 `Localizable.xcstrings`，
  包里的文字必须 `bundle: .module`。
- **Info.plist 文案**：主程序 `uTerm/InfoPlist.xcstrings`（对 iOS 排除）、iOS `uTermMobile/InfoPlist.xcstrings`、
  holder 的 `Config/uterm-holder/<语言>.lproj/InfoPlist.strings`（由 Run Script 拷，加语言要改脚本）、远控进程的
  `uTermRemoteHost/<语言>.lproj/InfoPlist.strings`。
- **命令行**：`scripts/utermctl` 自带翻译表（`TRANSLATIONS`，按 `UTERM_LANG` → 系统 `AppleLanguages` → `LANG` 选语言），
  App 那一侧的 `ControlHandler*` 消息跟 App 的语言走。`--json` 的字段名、错误码不翻译。
