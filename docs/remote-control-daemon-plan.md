# 远程控制常驻进程方案（规划稿，2026-11-12）

目标：把 macOS 上「被控端」的远程控制从 uTerm 主进程移到一个独立的常驻进程，使 uTerm 更新、崩溃、被强制结束时，已经建立的远控连接（手机或另一台 Mac 接管本机终端、远程桌面、远程文件与命令、局域网 / 打洞 / 中继链路）不中断。

本文为规划稿；§14 记录 2026-11-12 的探针结果与据此做的修订，与前文冲突时以 §14 为准。所有「已验证」的结论都标明出处；没有实测过的写成「推测」或列入 §11 的探针。

引用约定：「调研 §n」指 `docs/remote-control-research.md` 的章节，单写「§n」指本文。

## 0. 结论摘要

1. **新增一个常驻进程**：内嵌在 `uTerm.app/Contents/Helpers/` 里的辅助 App（下称「远控进程」，暂定 target `uTermRemoteHost`、bundle id `com.uozi.uTerm.RemoteHost`、显示名「uTerm 远程控制」，`LSUIElement`）。它承担被控端的全部网络与采集职责：监听与 Bonjour 广播、中继注册与信令、ICE / KCP 直连、`RemoteLink` 握手与加解密、连接与通道仲裁、远程桌面（采集、编码、注入、帘幕、解锁、虚拟屏、声音）、远程文件与命令、防睡眠、被控指示条。
2. **终端字节仍以 App 为唯一来源**（§5.4 的方案 T1）。App 继续持有 `TerminalSession`、影子终端、`TerminalOutputPump` 与 `TerminalMirrorTap`，只是把原来 `RemoteOutputPump` 直接写 `RemoteLink` 的那一步换成写本机 IPC。App 不在时，远控进程保持连接、冻结会话列表、暂停各终端通道；App 回来并接回 holder 后，远控进程按同一个会话 id 重新接入，第一段数据就是一张新快照，期间的输出由 holder 的缓冲经 App 补齐，不丢内容。远控进程不链接终端引擎，不需要第二份影子终端。
3. **进程形态（2026-11-12 探针后修订，见 §14）**：用 `SMAppService.agent` 注册一个**带沙盒**的 LaunchAgent（包内辅助 App），由 launchd 管理生命周期（登录时启动、KeepAlive、崩溃重启）。沙盒 App 注册沙盒 agent 是 macOS 14.2 起允许的组合；当年踩到的 `Operation not permitted` 是注册了**不带沙盒**的代理。原方案「XPC 服务 posix_spawn + disclaim」降为备选。
4. **权限归属（探针已证实，见 §14）**：agent 申请屏幕录制时，tccd 把它归到主 App（`IDENTITY_ATTRIBUTION … = <主 App bundle id>`），所以沿用 uTerm 现有的屏幕录制、辅助功能授权，**用户不用重新授权**；本地网络同理（TN3179：经 `SMAppService` 安装的 agent 以主 App 为责任代码）。App 被 `kill -9` 后，agent 的局域网长连接不断流；换成新 UUID 的 agent 二进制后不再弹本地网络框。不再需要私有接口 `responsibility_spawnattrs_setdisclaim`。
5. **钥匙串与设置仍归 App 所有**。App 经 IPC 把本机长期身份、信任表、中继配置、远控设置交给远控进程，远控进程只放在内存；需要落盘的变化（认出设备后更新名字、签发 / 续期 / 吊销中继证书、新配对）回传给 App 写入。这样远控进程不需要钥匙串访问组这类受限 entitlement 与描述文件，存储仍只有一个写入者，测试宿主的隔离（`RemoteLocalState`）原样保留。
6. **IPC（修订）**：agent 在 launchd plist 里声明 `MachServices`，App 以 `NSXPCConnection(machServiceName:)` 连接（App 的 entitlement 加一条 mach-lookup 临时例外，Sparkle 已有同类例外），探针已验证双向可通。XPC 在同一条连接上按序送达；协议只加方法、不改已有方法的含义；终端输出按通道做信用（credit）流控，保持「积压超限改发快照」的既有语义。原方案的「Unix socket + ShellAgent 代连交 fd」不再需要。
7. **远控进程自身的升级**分两步：先做「空闲时替换」（新 App 连上旧远控进程照常工作，没有已认证连接时再换新版本，见 §7.2）；之后视需要做「引导重连交接」（旧进程通知对端按计划重连到新进程、会话与标签原样保留，需要先发布支持新能力位的客户端，见 §7.3）。连接本身无法跨进程迁移：`NWConnection` / `NWListener` 不暴露 fd，libjuice、KCP、密钥序号都在进程内。
8. **分期**：P0 探针 → P1 进程内拆分（无行为变化）→ P2 远控进程上线（App 在时等价，可回退进程内）→ P3 App 缺席期间保活 → P4 远控进程升级与交接 →（可选）P5 远控进程直接挂 holder。需要用户拍板的事项集中在 §12。

## 1. 背景与范围

### 1.1 现在更新 uTerm 时会断什么

被控端的全部远控逻辑运行在沙盒 App 主进程里（`RemoteHostServer` / `RemoteHostConnection`，`uTerm/Features/Remote/`）。App 退出时 `RemoteHostServer.stop()` 关闭全部连接；被杀或崩溃时连接直接被内核关闭。具体影响：

| 功能 | App 退出时 | 恢复方式与代价 |
|---|---|---|
| 终端镜像 / 接管 | 链路断开，主控端标签显示断开 | 主控端按 `RemoteReconnectPolicy` 重连（0.5 s 起、≤ 5 s），新 App 起来、接回 holder 后才能重新接入；公网路径还要重新信令、打洞（约 3 s 后才回落中继） |
| 远程桌面与声音 | 采集停止，流结束 | 主控端要重新开流；帘幕由 gamma 表实现，进程一退系统即恢复，所以 `stop()` 先锁屏再撤帘幕 |
| 无显示器 Mac 的 HiDPI 虚拟屏 | `CGVirtualDisplay` 随进程消失 | 显示器重新配置、窗口位置变化，下一次开流重新建 |
| 远程文件与命令（消息 48 / 49） | 在途请求全部失败（`fileWaiters.failAll`） | `utermctl mac` 的单片重试 3 次，跨越整个重启窗口的传输与长命令会失败；命令的子进程由 `uTermShellAgent` 以独立会话拉起，进程本身不死，但结果送不回去 |
| 中继注册 | 注册连接关闭，中继摘掉这台 Mac | 新 App 重新注册；主控端要等目录刷新 |
| 防睡眠断言 | 随进程释放 | 重新开始远控时再申请 |

终端本身不受影响：本机 shell 与 SSH 会话都在 `uterm-holder` 里（调研 §12、§13），重启只断远控这一层。

### 1.2 目标

- **G1**：App 更新（Sparkle 下载、替换、重启）、崩溃、`kill -9` 期间，已认证的远控连接保持同一条 `RemoteLink`，不重新握手、不重新打洞、不重新注册中继。
- **G2**：远程桌面、声音、帘幕、解锁状态、虚拟屏、远程文件与命令在 App 缺席期间照常工作。
- **G3**：终端镜像在 App 缺席期间暂停，App 回来后不丢内容地续上；主控端的标签不关闭、不显示断开。
- **G4**：远控进程本身升级时，常见情况（升级时没有远控连接）对用户不可见；有连接时给出可控的替换时机。
- **G5**：任何一步失败都能退回现在的进程内实现（与 SSH 会话「辅助程序连不上就退回 App 内 `SSHConnection`」同一原则）。

### 1.3 不在范围内

- **主控端**：这台 Mac 去控制别的 Mac（`RemoteMacClient`、远程 Mac 窗口、远程桌面画布）属于 App 的界面，随 App 生灭，继续依靠现有的自动重连。
- **反方向文件共享的服务端**：被控 Mac 读写主控端共享文件夹时，应答方是主控端 App 里的 `RemoteMacClient.handleSharedFileRequest`，同上。被控端一侧（`RemoteHostConnection.performFile`，命令行在被控 Mac 上发起）的链路在远控进程里，入口仍是 App 的命令行接口，见 §5.6。
- **iOS**：iOS 只当主控端。客户端侧的改动仅限 §7.3 的可选能力位与 §8 的提示。

## 2. 现状结构

```
主控端（iPhone / 另一台 Mac）
   │  局域网 TCP（Bonjour _uterm-remote._tcp） / ICE 直连（libjuice + KCP） / 中继 TCP（accept 回拨）
   ▼
uTerm.app（沙盒，责任进程 = App）
   RemoteHostServer ── 监听、中继注册（RemoteRelayHostLink）、配对、会话仲裁、防睡眠
   RemoteHostConnection ×N ── RemoteLink 握手与加解密、消息分派
      ├ 终端：TerminalSessionRegistry → TerminalSession.mirrorTap.subscribe → RemoteOutputPump（链路队列）
      ├ 桌面：RemoteDesktopEnvironment.live（ScreenCaptureKit、VideoToolbox、CGEvent、CGVirtualDisplay、gamma 帘幕、CoreAudio）
      ├ 文件：RemoteFileAccess.live ──XPC──▶ uTermShellAgent.xpc（无沙盒，随 App 生灭）→ RemoteFileService
      └ App 代办：RemoteLocalShellOpener（开窗口）、关会话、贴图（TerminalImageReceiving）、工作目录列表
   RemotePairingPrompt / RemoteDesktopIndicator ── 浮动 NSPanel
   ▲
   │ holder 帧协议（HolderWire，只加帧）
uterm-holder ×N（setsid，父进程 launchd；SSH 会话 disclaim）── PTY ── shell / uterm-ssh
```

远控代码与 App 的耦合点（拆分时要逐个变成接口）：

| 耦合点 | 现在的位置 | 远控进程如何获得 |
|---|---|---|
| 会话目录、标签顺序、标题、程序状态 | `TerminalSessionRegistry`（`@Observable`，主线程观察） | App 推送快照与增量 |
| 终端字节与快照 | `TerminalSession.mirrorTap`（`TerminalOutputPump.onFed`，泵锁内拍快照） | App 侧订阅，经 IPC 转发（§5.4） |
| 钉尺寸、输入、Mac 上断开 | `pinRemoteGrid` / `writeRemoteInput` / `remoteDisconnect` | IPC 请求，App 执行 |
| 接回完成 | `sessionRestoration`（`LocalShellRestorer` + `SSHSessionRestorer`） | App 上报「接回中 / 已接回」 |
| 本机长期身份、信任表 | `RemoteIdentityStore`（数据保护钥匙串，访问组 `$(AppIdentifierPrefix)com.uozi.uTerm`） | App 交给内存，写回 App |
| 中继配置 | `RemoteRelayConfigStore`（iCloud 钥匙串） | 同上 |
| 吊销表、设备 ID、远控设置 | `RemoteLocalState.defaults`、`RemoteControlSettings`（App 沙盒容器内的 UserDefaults） | App 推送配置快照 |
| 开本机终端、关会话、贴图、工作目录 | `RemoteLocalShellOpener` 等（依赖 SwiftUI `openWindow` 与会话后端） | IPC 代办请求 |
| 文件服务 | `uTermShellAgent.xpc` | 远控进程自己执行（§4.2） |
| 命令行（`macs` / `mac-*` 反方向） | `ControlMacSessions` 读 `connectedControllers()`、`fileConnection(toDevice:)` | App 经 IPC 查询与转发 |

## 3. 职责划分

| 职责 | 远控进程 | App | holder |
|---|---|---|---|
| Bonjour 广播与局域网监听 | ✓ | | |
| 中继注册、信令、成员证书签发 / 续期 / 吊销的线上部分 | ✓ | 持久化 | |
| ICE（libjuice）、KCP、`RemoteP2PTransport`、`RemotePathDialer` | ✓ | | |
| `RemoteLink` 握手、密钥确认、加解密、心跳与静默判死 | ✓ | | |
| 配对判定（认出已信任设备、核销邀请凭据） | ✓ | 持久化 | |
| 配对审批弹框（6 位码） | P2–P3 留在 App；可选后移（§12 D9） | ✓ | |
| 会话仲裁（一个终端同一时刻一个接管者）、桌面接管 | ✓ | | |
| 会话目录、程序状态、标签标题节流 | 转发 | ✓ 来源 | |
| 终端字节、快照、尺寸、输入 | 转发 | ✓ 来源 | PTY |
| 远程桌面：采集、编码、码控、注入、剪贴板、光标形状 | ✓ | | |
| 帘幕（gamma）、帘幕静音、远程解锁、锁屏状态 | ✓ | | |
| HiDPI 虚拟屏（`RemoteHeadlessDisplay`） | ✓ | | |
| 被控指示条（`RemoteDesktopIndicator`） | ✓ | | |
| 远程文件与命令（`RemoteFileService`） | ✓ | 门禁配置 | |
| 防睡眠、防 App Nap | ✓ | | |
| 远控设置界面、配对面板、诊断 | | ✓（读远控进程的状态） | |
| 主控端（控制别的 Mac）、主控端键盘钩子 | | ✓ | |

原则：凡是 App 缺席时仍要工作的，以及与连接寿命绑定的系统资源（gamma 表、虚拟屏、断言、采集会话），放远控进程；凡是依赖终端引擎、SwiftUI 场景、钥匙串的，留 App。

## 4. 进程形态、沙盒与权限

### 4.1 进程形态比较

| 方案 | 能否活过 App 退出 / Sparkle 替换 | 权限归属 | 主要问题 |
|---|---|---|---|
| A. 内嵌辅助 App，由 `uTermShellAgent` posix_spawn（`SETSID` + disclaim） | 能（holder 同一路径，公证与 Sparkle 已验证） | 远控进程自己 | 依赖私有接口 `responsibility_spawnattrs_setdisclaim`（已在用，user 已同意）；macOS 27 退出 App 后 Dock 显示「后台运行」（holder 已经如此） |
| B. 内嵌辅助 App，由 App 经 `NSWorkspace.openApplication` 打开 | 能（LaunchServices 拉起的 App 本就是独立责任进程） | 远控进程自己 | 沙盒 App 打开无沙盒辅助 App 的运行期行为未验证；LaunchServices 会登记辅助 App 的路径，App Translocation 下路径会变 |
| C. `SMAppService.agent` | 能，且可由 launchd 守护重启 | 代理自己 | 沙盒 App 注册无沙盒代理被拒（`Operation not permitted`，调研 §10）；若代理带沙盒，又要另起无沙盒执行者 |
| D. `SMAppService.loginItem` | 能 | 登录项自己 | 登录项必须带沙盒；出现在「登录项与扩展」里，用户可能关掉；与已有的 `uTermBackgroundLauncher` 职责重叠 |
| E. 合进 `uTermShellAgent.xpc` | 不能（XPC 服务随 App 结束） | App | 不满足目标 |
| F. 合进 holder | 能 | holder | holder 的设计前提是「不懂终端、协议冻结、一般不动」，与频繁变化的远控代码相冲突 |

**建议 A**，以 B 为备选，由探针 D1 定夺。A 与现有 holder 的启动、命名空间、身份校验完全同构，风险最低。

为什么是带 bundle 的辅助 App 而不是裸可执行文件：

- 系统设置的「屏幕录制」「辅助功能」「本地网络」列表要显示可辨认的名字与图标，用户才知道该打开哪一项。
- Info.plist 要带 `LSUIElement`、`NSBonjourServices`（`_uterm-remote._tcp`）、`NSLocalNetworkUsageDescription`、各文件夹的用途说明、`LSAppNapIsDisabled`。
- 被控指示条与（可选的）配对弹框是 AppKit 面板，需要一个 `NSApplication`。
- 裸可执行文件的本地网络授权按 Mach-O UUID 记（holder 的实测：改了 holder 源码才会再弹一次）。远控进程每个版本都会变，若同样按 UUID 记，每次更新都会弹框。按 bundle 身份记是推测，**必须由探针 D3 证实**。

### 4.2 沙盒

两种做法，由用户拍板（§12 D3）：

- **S-A 无沙盒**（实现最简单）：文件服务在进程内执行；IPC socket 可以放在容器外的任意位置。代价是**防御纵深下降**：现在解析不可信网络数据（认证前的握手帧、STUN、ICE、KCP、中继帧）的是沙盒 App，改成无沙盒进程后，一旦解析代码有内存安全问题，攻击者直接拿到用户权限。缓解：认证前的解析面压到最小并做模糊测试；`uterm-ssh` 已经是无沙盒的网络解析者，但它只连用户自己选的服务器，暴露面小得多。
- **S-B 远控进程带沙盒，文件服务另设内嵌 XPC 服务**（建议）：远控进程自己是沙盒 App（自己的容器、`network.client` / `network.server`），保持现在的安全姿态；`RemoteFileService` 放进远控进程包内的无沙盒 XPC 服务（如 `uTermRemoteHost.app/Contents/XPCServices/uTermRemoteFiles.xpc`），它随远控进程而不是随 App 生灭，所以 App 重启不影响文件请求。现有的沙盒实测（调研 §3.7 S1：ScreenCaptureKit、`CGEvent.post` 在沙盒里可用；调研 §16 P4：`CGVirtualDisplay` 在沙盒测试宿主里可用）都支持这条路，但 gamma 帘幕、CoreAudio 帘幕静音、锁屏状态读取、在沙盒辅助 App 里是否全部可用要在探针 D6 里逐项确认。沙盒远控进程不能在容器外监听 socket，汇合点由它内嵌的无沙盒 XPC 服务代为监听、把接入的 fd 经 XPC 交给远控进程（与 App 侧「ShellAgent 代连交 fd」对称）。

### 4.3 TCC 与系统权限

| 权限 | 现在记在 | 改后记在 | 说明 |
|---|---|---|---|
| 屏幕录制与系统录音（ScreenCaptureKit） | uTerm | uTerm 远程控制 | 用户需重新授权；授权后只需重启远控进程（不必重启 App），但重启会断开现有远控连接，所以设置页在没有连接时引导授权 |
| 辅助功能（`kTCCServicePostEvent` 沿用 Accessibility） | uTerm | uTerm 远程控制 | 同上；「授权后必须重启进程」的规律不变（调研 §3.7） |
| 本地网络 | uTerm（局域网监听、Bonjour） | uTerm 远程控制 | 首次广播时弹一次；必须 disclaim 的原因（调研 §13） |
| 文稿 / 桌面 / 下载等文件夹 | uTerm（`uTermShellAgent` 的责任进程是 App） | uTerm 远程控制 | 远程文件与 `mac run` 访问这些目录时弹框记到远控进程 |
| 完全磁盘访问 | 未使用 | 未使用 | 不变 |
| 钥匙串 | App 的访问组 | 不访问 | 见 §4.6 |

App 本身仍需要「辅助功能」：主控端的系统快捷键截取（`RemoteDesktopKeyboardCapture` 的 `CGEventTap`）在 App 里。设置页要分开显示「被控（远控进程）」与「主控（uTerm）」两组权限状态，被控那一组的授权查询（`CGPreflightScreenCaptureAccess` / `CGPreflightPostEventAccess`）必须在远控进程里做，因为这类查询结果按进程身份、且在进程内缓存。

迁移体验（§12 D4）：升级到首个带远控进程的版本后，已开启远程桌面的用户会在第一次被开流时收到「uTerm 远程控制 想录制屏幕」。设置页在升级后第一次打开时主动提示，并提供「打开系统设置」与「重新启动远程控制」按钮。

### 4.4 生命周期

```
          App 启动且远控总开关打开
未运行 ──────────────────────────────▶ 服务中（App 在）
  ▲                                        │  IPC 断开
  │                                        ▼
  │      宽限期内 App 回来             托管中（App 不在）
  │  ◀──────────── 服务中 ◀───────────────┤
  │                                        │  宽限期到 / 收到「用户退出」
  └──────────── 退出（先锁屏再撤帘幕、注销中继、撤广播）◀─┘
```

- **启动**：App 在远控总开关打开时，经 `uTermShellAgent` 新增的 `ensureRemoteHost(namespace:)` 连接已在运行的远控进程，或拉起一个新的。命名空间与 holder 相同（正式版 `release`，Debug 按 App 路径哈希，集成测试单独一份），同一命名空间只允许一个实例（锁文件 `flock` + socket）。开发构建与测试宿主继续受 `RemoteRelayRegistrationBlock` 约束，由 App 在配置里告诉远控进程。
- **App 正常退出**：
  - Sparkle 更新：`AppUpdaterDelegate.updaterWillRelaunchApplication` 里发 `departing(.update)`，远控进程进入托管态，宽限期取较长值。
  - ⌘Q：发 `departing(.quit)`。是否继续远控由 §12 D1 决定；建议停止服务（通知对端「Mac 上的 uTerm 已退出」后断开），与「远控随 uTerm 运行」的现有心智一致。
  - 关掉远控总开关：发 `stop`，远控进程收尾后退出。
- **App 异常结束**：IPC 收到 EOF 而没有 `departing`，按崩溃处理，进入托管态，宽限期取默认值。
- **宽限期到期**：结束全部远控、退出。建议默认 120 秒，更新时 300 秒（§12 D2）。
- **远控进程异常结束**：所有远控连接断开（与现在 App 崩溃时相同），对端按现有重连策略恢复；App 发现 IPC 断开后重新拉起远控进程。退出路径（包括 `SIGTERM`）都要先锁屏再撤帘幕（同现在的 `RemoteHostServer.stop()` 与 `teardownScreenControl`）。`SIGKILL` 时来不及锁屏：gamma 表随进程恢复，若当时处于「远程解锁 + 帘幕」状态，已解锁的桌面会露出来。这一风险现在就存在（App 被强制结束时同样如此）；移入远控进程后 App 崩溃不再触发它，只剩远控进程自身被强制结束这一种情况。是否需要额外的看门进程在远控进程消失时锁屏，列入 §13 未决问题。
- **防 App Nap**：远控进程常驻后台，系统会对它做 App Nap，心跳会被拖到分钟级、中继把它摘掉（`RemoteHostServer.updateInternetActivity` 的注释）。远控进程在服务期间始终持有 `userInitiatedAllowingIdleSystemSleep` 活动，并在 Info.plist 写 `LSAppNapIsDisabled`。

### 4.5 Sparkle 替换包体时的约束

holder 能活过 Sparkle，是因为 Sparkle 整体换目录、运行中的进程映射的是旧文件（调研 §12 S4）。远控进程比 holder 复杂，额外的约束：

- **不得在启动后按需加载包内的代码**：所有 Swift 包与 C 包（libjuice、kcp、UDesignKit 等）静态链接进远控进程，发布前用 `otool -L` 核对没有 `@rpath` 指向包内的动态库；如有，启动时立即全部加载。否则替换之后再 `dlopen` 到的是新版本，符号不一致即崩溃。注意 Xcode 26.6 在某些条件下会把包产物切成动态 PackageFrameworks（`uTermTests` 踩过），新 target 不要声明会触发这一点的依赖方式。
- **不得在启动后按需读取包内资源**：本地化文案、图片、`Assets.car`、字体都在启动时加载并缓存（或改为代码内常量）。被控指示条第一次弹出往往发生在更新之后，这是最容易出错的地方，探针 D4 专门覆盖。
- **不依赖自身路径**：不重新 `exec` 自己；身份校验一律按代码签名要求，不按路径（更新后的 App、Translocation 下的 App 路径都会变）。
- **Sparkle 不应结束远控进程**：它是 `setsid` 出来、父进程为 launchd 的独立进程，Sparkle 的安装器只结束 App 本身；与 holder 一样，以 S4 式实测为准。
- **（2026-11-15 实测推翻 G1）换包之后旧远控进程不能再用**：可执行文件被新包替换后，正在跑的旧进程过不了按签名的核对——新 App 设在连接上的 `agentRequirement` 报 `-67065`（host has no guest with the requested attributes），旧进程发来的每条回话都被拒收；tccd 也不再认它的屏幕录制授权，`SCStream` 报「用户拒绝」。2.1.5 上的表现：新 App 每 5 秒重连一次，每次都把旧进程的宽限期重置，旧进程永远不退，手机开屏幕失败，终端停着。处理：远控进程在 `hello` 里看到 App 的 build 和自己不同就交出待写回的数据、立即退出（连着的设备断开重连）；App 连续 `RemoteHostAgent.unansweredHelloLimit` 次连上却等不到握手回话，就经 `SMAppService` 注销再注册（每次启动至多一次），用来换掉不会自己退出的 2.1.5 及以前的旧进程。所以更新时远控连接**会断一次**，宽限期只覆盖「App 退出到新 App 连上」这一段。

### 4.6 钥匙串与状态持久化

- App 在 IPC 握手后发 `secrets`：本机长期私钥、设备 ID、两张信任表中被控端用的那张（`.controllers`）与封锁表、根中继配置、待确认的吊销表。远控进程把它们放进内存实现的 `RemoteSecretStorage` / `RemoteSyncedStorage`（已有 `RemoteMemoryStorage` 一类的抽象），不写盘、不进日志（中继配置里有成员私钥）。
- 远控进程对存储的写入（`RemoteIdentityStore.trust`、`relayGrant` 的签发与续期、`RemoteRelayRevocations.add`、`grantInternetAccess`）经 IPC 发给 App 落盘；App 不在时排队，回来后按序重放。远控进程在托管期崩溃会丢失这些写入，后果是：新签发的中继证书在主控端可用、但 Mac 端没有记录（下次续期会被当成未知证书而拒绝，需重新配对），影响面小且可接受；托管期内的新配对一律拒绝（§6），所以不会丢配对记录。
- 远控设置（`RemoteControlSettings` 各项、`internetDevices`、本机名）由 App 每次变化时整份推送，远控进程只认最后一份。

## 5. IPC 设计

### 5.1 建连与身份

- 远控进程（S-A）或它的汇合 XPC 服务（S-B）在 `~/Library/Application Support/uTerm/remote/<命名空间>/host.sock` 监听，目录权限 0700。
- App 调 `uTermShellAgent` 新增的 `connectRemoteHost(namespace:)`，由 XPC 服务连接 socket 后把 fd 交给 App。`LocalShellAgentProtocol` 只在同一个 App 包内两端之间使用，新增方法不存在版本错配问题。
- 远控进程用 `LOCAL_PEERTOKEN` 校验对端签名，放行同团队的 `com.uozi.uTerm` 与 `com.uozi.uTerm.ShellAgent` 两个身份（理由同 holder：查到的是最后动过 socket 的进程）。
- 同一时刻只认一个 App 连接；第二个 App 连接接入时，前一个收到 `replaced`（Debug 与正式版命名空间不同，不会互相替换）。

### 5.2 线格式

`RemoteHostWire`，与 `HolderWire` 同样的分帧：`[u32 小端：kind + payload 长度][u8 kind][payload]`，单帧上限 16 MiB。

- 握手帧双方各发一次，带 IPC 协议版本、构建号、能力列表；**只加帧、不改已有帧的含义，双方忽略不认识的帧**。原因与 holder 相同：远控进程会跨越多个 App 版本运行（§7.2）。
- 控制类消息用 JSON（低频，便于扩展字段）；终端数据与快照分片用二进制头 + 原始字节。
- 帧编号、字段名用测试钉死（同 `DefaultsKeyTests` 的做法），防止无意中改动已发布的含义。

### 5.3 消息

| 类别 | App → 远控进程 | 远控进程 → App |
|---|---|---|
| 握手与生命周期 | `hello`（App 版本、终端引擎版本、能力）、`departing(update｜quit)`、`stop` | `helloReply`（远控进程版本、能力、托管期间发生的事件摘要）、`replaced`、`upgradeRequested` |
| 配置与秘密 | `secrets`、`configure`（设置快照、本机名、中继注册限制） | |
| 状态回写 | | `persistTrust`、`persistRelayGrant`、`persistRevocation`、`grantInternetAccess` |
| 会话目录 | `sessions`（整份列表，不含接管者）、`programStatus`（增量）、`restoration(restoring｜restored)` | |
| 终端通道 | `termAttached(结果)`、`termOutput`、`termSnapshot`、`termDetached(原因)` | `termAttach(会话、行列、设备名)`、`termCredit`、`termInput`、`termResize`、`termDetach` |
| App 代办 | 各请求的应答 | `openLocalShell`、`listWorkspaces`、`closeSession`、`deliverImage`、`approvePairing` |
| 状态与界面 | | `state`（监听状态、已连接设备、桌面观看者、中继状态与版本、配对请求队列），供设置页与横幅绑定 |
| 命令行透传 | `performFile(设备、请求)`、`connectedControllers` 查询 | 应答 |

App 侧以一个 `@Observable` 的代理对象镜像 `state`，字段与现在的 `RemoteHostServer` 公开属性保持同名同形，设置页、横幅、配对面板只换数据源，不改界面代码。

### 5.4 终端字节怎么走

**方案 T1（建议）：App 是唯一来源，远控进程只转发。**

```
holder ──HolderWire──▶ App: TerminalOutputPump ─▶ 影子终端 ─▶ onFed ─▶ TerminalMirrorTap.Subscriber
                                                                          │ take(maxBytes:)（有信用时）
                                                                          ▼
                       App: RemoteHostTerminalPump（IPC 队列，替代 RemoteOutputPump）
                                                                          │ termOutput / termSnapshot
                                                                          ▼
                       远控进程: 通道表 ─▶ RemoteLink.sendOnQueue（链路队列）─▶ 主控端
                                         └ 链路接走字节后回 termCredit
```

- **快照与字节的衔接不变**：快照仍在 App 的泵锁里拍（`TerminalMirrorTap` 的既有保证），远控进程只按顺序搬运，不解析。
- **流控**：远控进程给每个接入一个信用窗口（初值 256 KiB），链路接走多少（`canSendMore` 恢复、`onWritable`）就补多少。App 没有信用就不取，积压留在订阅者里，超过订阅者上限照旧丢弃积压、改发快照——带宽上限与「绝不反压 Mac 自己的终端」两条既有语义都保留。远控进程自身不缓存超过窗口的数据。
- **输入与尺寸**：`termInput` / `termResize` 到 App 后照旧走 `writeRemoteInput` / `pinRemoteGrid`（经 `TerminalInputChannel` 同一条 FIFO）。
- **仲裁移到远控进程**：现在的 `controllers` 表（会话 → 接管它的连接与通道）在远控进程里，因为只有它知道所有连接；App 只执行「为这个接入钉尺寸 / 解除」。`remoteDisconnect`（Mac 上主动断开）由 App 发 `termDetached` 通知远控进程。
- **代价**：多一次本机 socket 转发。调研 §11 S6 实测 Unix socket 中转吞吐 100+ MiB/s、回显 p50 增加约 13 µs，远低于局域网往返；探针 D7 在真实路径上复测。

**方案 T2（不建议首期做）：远控进程直接挂 holder。** holder 增加「旁听客户端」帧，远控进程链接 libghostty-vt 自建影子终端，App 不在时终端照样能看、能输入。代价：holder 要为两个客户端仲裁尺寸与输入（协议只加帧可以做到，但运行中的旧 holder 不支持，只有新开的会话受益）；程序状态、标签标题、OSC 7501 应答、通知都要在远控进程里再实现一份，违背「读状态归影子终端、应答只有一个来源」的现有约定；不在 holder 里的会话（SSH 退回进程内的情况）仍然要走 App。T2 的唯一收益是 App 缺席的那几秒到几十秒里终端也是活的，或 App 被用户退出后仍能远控终端，列为可选的 P5（§12 D8）。

### 5.5 会话目录与程序状态

- 标签标题节流（`tabTitlePushInterval`）、程序状态即时推送、标签顺序变化检测仍在 App 侧完成，App 每次只发「当前整份列表」或「程序状态增量」。远控进程填入 `controlledBy`、排位，再按各连接的订阅状态与能力（`programStatus`）扇出。
- App 刚连上（新启动或重启后）时先发 `restoration(restoring)`。此时远控进程继续对外提供上一份列表、不发任何「消失」，接入请求排队；收到 `restored` 后发新列表，真正不存在的会话才对相应通道发 `closed`。这取代现在的 `afterSessionRestoration`，并且解决了 调研 §11「P2 要记得的」两条：手机不会因为列表暂时缺会话而关标签，也不会因为接入一个还没接回的会话而收到拒绝。

### 5.6 命令行

命令行仍连 App 的控制接口（`utermctl` → App）。反方向文件请求（被控 Mac 上的 `utermctl mac …`）由 App 经 `performFile` 转给远控进程发出；`ControlMacSessions.defaultController` 改为向远控进程查询。App 不在时命令行本来就不可用，不需要额外处理。

## 6. App 缺席（托管期）的行为

| 功能 | 托管期行为 |
|---|---|
| 连接、心跳、静默判死 | 照常，同一条 `RemoteLink` |
| 局域网监听与广播、中继注册 | 照常；已认证设备可以新连进来 |
| 新设备配对（审批弹框 / 邀请凭据） | 拒绝，原因「Mac 上的 uTerm 正在重启，请稍后再试」（配对记录要 App 落盘；审批弹框在 App 里） |
| 会话列表 | 冻结在最后一份，不发「消失」 |
| 已接入的终端通道 | 暂停：没有输出；输入丢弃（§12 D6）；尺寸请求记下最后一次，App 回来后套用 |
| 新的终端接入 | 排队，App 回来后执行；宽限期结束仍未回来则回失败 |
| 程序状态 | 冻结在最后一份 |
| 远程桌面、声音、剪贴板、光标形状 | 照常 |
| 帘幕、远程解锁、锁屏状态推送 | 照常 |
| 远程文件与命令 | 照常（执行者在远控进程侧） |
| 开本机终端、工作目录列表、关会话、贴图 | 排队（上限 15 秒，与现在开本机终端的等待一致），超时回「Mac 上的 uTerm 正在重启」 |
| 中继证书续期 | 用内存里的信任表应答，写入排队 |
| 防睡眠 | 照常（由远控进程持有） |

App 回来后的顺序：`hello` → `secrets` / `configure` → `restoration(restoring)` → 接回 holder → `restored` → 远控进程依次：重放排队的写入；为每个暂停的通道按原会话 id、原行列重新发 `termAttach`（App 订阅后第一段就是新快照，主控端收到 `terminalSnapshot` 的首片会丢掉手上旧的画面再还原，这是现有能力）；执行排队的接入与代办请求；推送新列表与程序状态全量。

**终端引擎版本变了**：快照是引擎的二进制格式，握手时按当时的引擎版本校验过对端（`RemoteTerminalEngine.matches`）。新 App 的 `TerminalEngineVersion.current` 若与该连接握手时远控进程报出的版本不同，相应通道一律以 `mismatchMessage` 关闭，不发快照；之后新连进来的设备按新版本校验（远控进程在握手里报的终端引擎版本以 App 最近一次 `hello` 为准）。

**可选的提示消息**（§12 D7）：新增消息 50 `hostStatus` 与能力位 `host-status`，托管期开始与结束时各发一次，主控端在终端标签上显示一条不打断操作的提示（「Mac 上的 uTerm 正在更新，终端暂停」）。老客户端看不到提示，只会看到输出暂停，连接不受影响。

## 7. 版本兼容与远控进程自身的升级

### 7.1 三层版本

| 层 | 谁和谁 | 兼容要求 |
|---|---|---|
| 远控线协议（`RemoteProtocol`，消息 1–49） | 远控进程 ↔ 主控端 | 规则不变：新消息配能力位，老对端不认的不发。能力在握手时交换一次，所以远控进程报出的能力必须是它自己能处理的；依赖 App 的能力（`local-shell`、`program-status` 等）在 App 暂时不支持时以失败应答，而不是断连 |
| IPC（`RemoteHostWire`） | 远控进程 ↔ App | 只加帧；握手交换能力；新 App 遇到旧远控进程、旧 App（回滚）遇到新远控进程都要能工作 |
| holder 帧协议 | App ↔ holder | 不变 |

### 7.2 空闲时替换（P4 首选）

1. 新 App 连上旧远控进程，比较构建号。
2. 相同：照常。
3. 不同且远控进程**没有已认证的连接**：App 发 `upgradeRequested`，旧进程撤广播、注销中继、退出，App 拉起新版本。整个过程不到一秒，没有人受影响。这覆盖绝大多数更新（更新时恰好有人在远控是少数情况）。
4. 不同且**有连接**：继续使用旧进程（IPC 兼容）。设置页显示「远程控制组件将在没有设备连接时更新」，并提供「立即更新（将断开 N 台设备）」。最后一个连接断开 30 秒后自动替换。
5. IPC 主版本不兼容（应当极少发生，例如安全修复要求立即替换）：走 7.3；7.3 未实现之前直接替换，等同于现在的断线重连。

代价：带着连接跨越更新的那段时间里，远控相关的新功能与修复暂不生效。远控代码的发布节奏比 holder 快得多，所以 7.2 是首选但不是终点。

### 7.3 引导重连交接（P4 后半，可选）

不迁移连接，而是让对端「按计划重连并原样恢复」：

1. 新远控进程先启动但不广播、不注册中继，只开 IPC 与内部监听。
2. 旧进程向支持新能力位 `host-migrate` 的对端发消息 51 `hostMigrate`（带一次性续接令牌、新的局域网端口），然后撤广播；新进程开始广播并注册中继。中继上的同一主机 ID 重新注册会把旧的注册连接顶掉（`superseded`），旧进程此时已知在交接中，不进入 5 分钟起的退避（`RemoteRelaySupersededBackoff`）；已经建立的中继转发是各自独立的 `accept` 连接，不受影响。
3. 对端按令牌连到新进程，跳过审批（本来就是已信任设备），新进程按令牌恢复通道与会话的对应关系（重新 `termAttach` → 新快照）、桌面以关键帧重新开流、在途文件请求按幂等性重试。
4. 不支持 `host-migrate` 的老对端：与现在断线一样，自动重连。

对用户可见的中断：局域网约一次握手（百毫秒级），公网要重新信令与打洞（秒级）。前提是先发布支持 `host-migrate` 的 iOS 与 Mac 客户端，并给足一个版本周期的覆盖。

为什么不做真正的连接迁移：`NWConnection` / `NWListener` 不暴露 fd，无法经 `SCM_RIGHTS` 交给新进程；libjuice 的 ICE 状态、KCP 窗口、`RemoteCipher` 的计数器都在进程内存里。即便序列化，局域网与中继连接本身也带不走，投入与收益不成比例。

### 7.4 回滚

用户把 App 降级时，旧 App 遇到新远控进程：按 IPC 握手的能力降级工作；若旧 App 根本不认识远控进程（降级到拆分之前的版本），它会在进程内启动 `RemoteHostServer`，与仍在运行的远控进程争用 Bonjour 名称与中继注册。对策：远控进程在宽限期内没有等到兼容的 App 就退出；并在升级说明里写明降级需先关闭远控总开关。列为风险 R7。

## 8. 安全

- **新的本机攻击面**：IPC socket。目录 0700 挡住其他用户；签名要求挡住同用户的其它程序；秘密只经这条连接传递，不进 argv、环境变量、磁盘与日志（与 `uterm-ssh` 的凭据规则一致）。
- **被控指示不能缺席**：现在有人在看屏幕时 Mac 上一定有指示条。指示条移入远控进程后，App 缺席期间照样显示；远控进程无法显示指示条时（例如 AppKit 初始化失败）拒绝开流。
- **托管期不扩大权限**：托管期内不接受新配对、不接受设置变更，只延续 App 离开前已允许的能力。宽限期到期即退出，App 被用户退出（⌘Q）时默认停止服务。
- **无沙盒的网络解析**：见 §4.2。若选 S-A，认证前路径（`RemoteFrameBuffer`、握手帧、`RemoteDatagram`、KCP 输入、中继帧、STUN）加模糊测试，并作为发版硬门。
- **开发构建与正式版隔离**：命名空间与中继注册限制原样继承，测试宿主里的远控进程只用内存身份、只连回环中继（`RemoteLocalState` 的规则），否则会以正式版身份注册中继、把正在使用的正式版挤掉（2026-11-08 的事故）。

## 9. 代码组织

- **新 target**：`uTermRemoteHost`（macOS App，`LSUIElement`，hardened runtime，S-B 时带沙盒），由 uTerm target 的拷贝阶段放进 `Contents/Helpers/`；S-B 时它自己再内嵌一个文件服务 XPC。签名与公证随 App 一并完成；`verify-distribution-signing` 增加对它的核对（`Authority=Developer ID Application`、hardened runtime、无受限 entitlement）。
- **共享代码**：被控端代码（`RemoteHostServer`、`RemoteHostConnection`、`RemoteRelayHostLink`、`Features/Remote/Desktop/` 等）挪进新的同步组（如 `uTermRemoteHostCore/`），同时编进 uTerm（用于进程内回退与测试）与 `uTermRemoteHost`，对 iOS 排除——做法同 `uTermFiles/`。`uTerm/Core/Remote/` 已是两端共享，远控进程直接编入。
- **接口化**：`RemoteHostServer` 现在直接引用 `TerminalSessionRegistry`、`RemoteLocalShellOpener`、`RemoteFileAccess`、`RemoteIdentityStore` 与 `RemoteControlSettings`。P1 把这些收拢成一个 `RemoteHostAppServices` 协议（会话目录、接入 / 输入 / 尺寸、代办请求、存储读写、设置），App 内有进程内实现（今天的行为），远控进程内有 IPC 实现。现有的远控测试全部改走协议、仍在进程内跑。
- **文案**：远控进程里的界面文案（指示条、权限提示）进同一份 `Localizable.xcstrings`；`make sync-strings` 要把新 target 的 `.stringsdata` 一并喂给 `scripts/sync-strings.swift`。
- **偏好键**：新键（远控进程开关、宽限期等）先加进 `DefaultsKey`，远控进程本身不读 App 的 UserDefaults。
- **日志**：沿用 `AppLogger` 的子系统，分类 `remote-host`；IPC 断开、托管期开始 / 结束、重新接入、替换都记一条，便于 `/usr/bin/log` 对照时间线。

## 10. 分期计划

| 期 | 内容 | 完成标准 |
|---|---|---|
| **P0 探针** | §11 的 D1–D8 | 每项给出通过 / 不通过与读数；D3 不通过则先评估替代（见 R1）再继续 |
| **P1 进程内拆分** | 引入 `RemoteHostAppServices`、`RemoteHostTerminalPump`（信用流控）、内存版秘密存储与写回接口；仲裁从「会话」侧移到「连接」侧 | 不新增进程，行为不变；`make test-fast` 与远控相关用例全绿；终端回显与 `cat` 吞吐读数与改动前相同 |
| **P2 远控进程上线（App 在时等价）** | 新 target、启动与身份校验、IPC、桌面 / 文件 / 网络全部搬入；App 断开即让远控进程收尾退出（尚无托管期）；隐藏开关控制，默认进程内 | 远控测试套件在「经远控进程」模式下全绿；公证包上 TCC 三项授权、本地网络、Sparkle 下远控进程不被结束 |
| **P3 托管期** | §6 全部行为、`departing`、宽限期、重新接入、引擎版本处理、可选的 `hostStatus` | §11.2 的 XCTest 场景通过；S4 式公证版 Sparkle A→B 期间手机局域网 / 中继 / 直连三条路的终端与桌面都不断；随后默认开启 |
| **P4 升级** | §7.2 空闲替换与设置页提示；可选 §7.3 引导重连（先发客户端） | 带连接跨越一次更新、空闲后自动替换；替换过程中无连接时用户无感 |
| **P5（可选）** | 方案 T2：远控进程挂 holder | 视 §12 D8 |

与本方案独立、可以并行的一项：**主控端的断线体验**。远程桌面窗口在链路重连后自动重新开流、文件传输在重连后续传，这对网络切换等所有断线都有益，也是 §7.3 的基础。

## 11. 探针与验证

### 11.1 P0 探针（全部用 Developer ID 签名、hardened runtime、放在 `~/Applications`，独立 bundle id，方法同调研 §11–§13）

| # | 内容 | 通过标准 |
|---|---|---|
| D1 | 启动方式：A（XPC posix_spawn + disclaim）与 B（`NSWorkspace`）各起一个辅助 App | `kill -9` App 后辅助 App 存活、父进程 launchd；tccd 日志里 `responsible_path` 是辅助 App；Translocation 下可用 |
| D2 | TCC：辅助 App 内 ScreenCaptureKit 采集、`CGEvent.post`、系统录音 | 授权给辅助 App 后生效；App 已死时继续采集与注入；系统设置里显示名字与图标；记录每月重新确认的提示归属 |
| D3 | 本地网络：辅助 App Bonjour 广播 + 局域网 TCP | App 死后连接不断流（容器侧 `Send-Q` 为 0）；**改动辅助 App 源码重新签名后不再弹框**（按 bundle 身份记）；若仍按 UUID 记，量出弹框频率并进入 R1 |
| D4 | Sparkle 替换包体 | 替换后辅助 App 运行 30 分钟以上，期间首次显示指示条、首次开流、首次加载本地化文案均正常；`otool -L` 无包内动态库 |
| D5 | macOS 27 后台显示 | 记录 Dock「后台运行」、系统设置「后台 App 活动」关闭后对辅助 App 的影响 |
| D6 | 沙盒辅助 App（仅 S-B） | ScreenCaptureKit、`CGEvent.post`、`CGVirtualDisplay`、gamma 帘幕、CoreAudio 静音、锁屏状态、Bonjour 监听逐项可用；汇合 socket 经内嵌 XPC 交 fd 可用 |
| D7 | IPC 代价 | 局域网真机：按键 → 回显附加延迟 p50 增量 < 0.2 ms；`cat` 1 GB 期间吞吐与 App 主线程占用不劣于进程内；终端输出与快照衔接 1000 个随机切点一致（S5 的方法） |
| D8 | 资源寿命 | 帘幕开着、虚拟屏在用时重启 App：gamma 与虚拟屏不变，窗口不重排 |

### 11.2 XCTest（优先）

- **单元**：`RemoteHostWire` 编解码往返与「不认识的帧被忽略」；帧编号钉死；信用流控在慢链路下改发快照、在快链路下不丢字节；托管期状态机（纯函数：事件序列 → 对外动作）；宽限期与 `departing` 组合；引擎版本变化时的通道处置；写回队列的重放顺序。
- **集成（测试宿主里起真远控进程，集成测试命名空间）**：测试宿主扮演 App，经真 `uTermShellAgent` 拉起远控进程；主控端用进程内的 `RemoteMacClient` 经回环连远控进程；远程桌面用合成画面（远控进程接受仅在 Debug 且集成命名空间下生效的启动参数，换成合成的 `RemoteDesktopEnvironment`）。关键用例：
  - 测试宿主主动断开 IPC（模拟 App 被杀），断言主控端的 `RemoteLink` 没有关闭、没有重连事件；桌面帧持续到达；在途文件请求完成；新配对被拒。
  - 测试宿主以「新 App」身份重新连接并接回会话：终端画面指纹与断开前 + 断开期间输出一致；主控端标签未关闭；排队的开本机终端请求得到应答。
  - 引擎版本不同的重连：对应通道以 `mismatchMessage` 关闭。
  - 空闲替换：无连接时版本不同 → 远控进程被替换，监听端口与中继注册恢复。
- **经真实中继**：`make test-relay-e2e` 增加「IPC 断开期间中继转发不断、注册不掉」与「替换远控进程时不触发被顶替退避」。

### 11.3 需要人工的部分

- 公证 DMG 上的 Sparkle A→B（临时 EdDSA 密钥 + 本机 appcast，同调研 §12 S4），更新期间 iPhone Duo 分别经局域网、中继、直连接管终端与远程桌面，另一台 Mac 同时跑 `utermctl mac get` 大文件与 `mac run` 长命令。记录：终端暂停时长、桌面丢帧数（预期 0）、文件传输结果。
- 首次升级的授权体验：屏幕录制、辅助功能、本地网络三个弹框的时机与文案；系统设置里的显示。
- macOS 27 Dock 与「后台 App 活动」设置的表现。
- 每月一次的屏幕录制重新确认在远控进程上的表现。
- 帘幕开着时 App 崩溃、远控进程崩溃两种情况下 Mac 本地屏幕的状态。

## 12. 需要用户拍板的决策

| # | 问题 | 建议 |
|---|---|---|
| D1 | 用户 ⌘Q 退出 uTerm 后，远控是否继续服务 | 不继续。只有更新、崩溃、强制结束时进入托管期 |
| D2 | 宽限期 | 默认 120 秒，Sparkle 更新时 300 秒 |
| D3 | 远控进程是否带沙盒 | 带沙盒（S-B），文件服务放进它内嵌的无沙盒 XPC；D6 不通过再退回 S-A 并加模糊测试 |
| D4 | 接受「升级后被控相关权限要给『uTerm 远程控制』重新授权一次」 | 接受（disclaim 是保住局域网连接的唯一已知办法） |
| D5 | 远控进程升级策略 | 先做空闲替换；引导重连交接放到客户端覆盖足够之后再定 |
| D6 | 托管期内主控端敲的键 | 丢弃（画面是冻结的，延后送达容易误操作），配合 D7 的提示 |
| D7 | 是否新增消息 50 `hostStatus` 提示主控端 | 做，成本低，老客户端不受影响 |
| D8 | 是否做方案 T2（App 不在时终端仍可远控） | 首期不做 |
| D9 | 配对审批弹框是否移入远控进程 | 首期留在 App，托管期拒绝新配对 |

## 13. 风险与未决问题

| # | 风险 | 影响 | 应对 |
|---|---|---|---|
| R1 | 本地网络授权按二进制 UUID 记（D3 不通过） | 每次更新弹一次本地网络框 | 评估：把网络层拆成很少变化的小进程（协议冻结的「连接持有者」，类似 holder 的定位）；或接受每版一次；需重新决策 |
| R2 | 无沙盒网络解析（若选 S-A） | 防御纵深下降 | §4.2、§8 的缓解；优先 S-B |
| R3 | 依赖私有接口 `responsibility_spawnattrs_setdisclaim` | 系统升级后可能失效 | 已被 holder 依赖；失效时退回进程内实现（G5），并以 B 方案备选 |
| R4 | Sparkle 替换后按需加载新版本的代码或资源 | 崩溃或界面错乱 | §4.5 的约束 + D4 |
| R5 | 两个进程的状态一致性（信任表、设置、写回队列） | 设置页显示与实际不符、托管期写入丢失 | 单一写入者（App）+ 远控进程只认最后一份快照；写回带序号、App 回来后确认 |
| R6 | 交接期间 Bonjour 重名、中继被顶替退避 | 主控端短暂找不到 Mac、公网接入停 5 分钟 | §7.3 的顺序：旧进程先撤广播；交接时不进入退避 |
| R7 | 降级到拆分前的版本 | 新旧两份被控端争用名称与中继 | 宽限期内等不到兼容 App 就退出；发布说明写明 |
| R8 | 远控进程常驻内存 | 空闲约几十 MB（未测），开流时含编码器 | D7 记录读数；关掉远控总开关即退出 |
| R9 | 维护成本：两份进程、三层版本 | 改动远控代码时要考虑 IPC 兼容 | IPC 帧钉死的测试；共享代码一份、进程内与进程外同一套实现 |
| R10 | 托管期跨越 Mac 睡眠、网络切换 | 远控进程独立处理链路，App 回来时状态可能已变化 | 重新接入时以远控进程当时的连接表为准，App 只负责会话侧 |

未决问题：

- `NSWorkspace` 方案（B）在沙盒 App 中打开无沙盒辅助 App 的运行期限制，以及 LaunchServices 对包内辅助 App 的登记行为。
- 每月屏幕录制确认弹框出现在远控进程上时，用户是否容易误判（它与 uTerm 名字不同）。
- 远控进程在「远程解锁 + 帘幕」期间被 `SIGKILL` 时如何保证锁屏（例如由 App 或一个极小的看门进程在检测到它消失时调用锁屏；需确认沙盒内能否做到）。
- 远控进程是否需要自己的崩溃报告通道（现在 App 有没有崩溃收集需要另查）。
- 托管期内主控端发起的新本机终端请求，若 App 回来后用户已关闭「允许打开本机终端」，应按新设置拒绝（实现时注意以 App 回来后的配置为准）。

## 14. 探针结果与方案修订（2026-11-12）

探针：沙盒 App（`com.uozi.uTermProbe`）+ 包内沙盒辅助 App 作 LaunchAgent（`com.uozi.uTermProbe.agent`，`BundleProgram` 指向 `Contents/Helpers/…`，`MachServices`、`RunAtLoad`、`KeepAlive`），Developer ID 签名、hardened runtime，装在 `~/Applications`；局域网对端是 OrbStack 网桥（192.168.215.0/24，属于本地网络）上的一个容器，agent 每 0.5 秒向它发一行。macOS 27.2。探针源码与构建脚本在会话草稿目录，未进仓库，已注销、删除。

| 项 | 结果 |
|---|---|
| 注册 | 沙盒 App 调 `SMAppService.agent(plistName:).register()` 成功（status 1 = enabled），agent 立即由 launchd 拉起（父进程 1）；`launchctl print` 显示 `parent bundle identifier = <主 App>` |
| IPC | App 用 `NSXPCConnection(machServiceName:)` 连上沙盒 agent 的 `NSXPCListener(machServiceName:)`，双向调用正常（App 只需 mach-lookup 临时例外） |
| 局域网长连接 | `kill -9` App 后 agent 的 TCP 连接照常发送，容器侧 `Send-Q` 为 0、计数持续增长；Bonjour 广播仍在（`dns-sd -B` 可见） |
| 本地网络授权 | 首次连接先报 `localNetworkDenied`，约 1.7 秒后放行；之后换成新 UUID 的 agent（源码变化重编）直接连通，没有再报拒绝、没有再弹框 |
| 屏幕录制 / 辅助功能 | tccd：`AttributionChain: requesting=… identifier=<agent>` → `IDENTITY_ATTRIBUTION: <agent 路径> … = <主 App bundle id>` → `Handling access request to kTCCServiceScreenCapture, from Sub:{<主 App>}`。即授权记在主 App 名下 |
| 包体替换（模拟 Sparkle） | 把 App 包移走、放入新版本，旧 agent 进程继续运行、连接不断；新 App 让旧 agent 退出后，launchd 按同一路径拉起**新二进制** |
| 坑 | launchd 的任务定义在注册时缓存：新包里 plist 的改动（如环境变量）不生效，要先 `unregister` 再 `register`。所以 plist 内容要尽量稳定，改了就要在升级流程里重注册 |

据此修订（覆盖前文）：

- **进程形态**：§4.1 的方案 C（`SMAppService.agent`）改为首选，agent **必须带沙盒**（§4.2 的 S-B 成为唯一选项）。文件服务放进 agent 包内的无沙盒 XPC 服务（可复用 `uTermShellAgent` 这个 target，客户端签名要求加上 agent 的 bundle id）。
- **TCC 与本地网络**：§4.3 表中「改后记在 uTerm 远程控制」全部改为「仍记在 uTerm」；§12 D3、D4 不再需要决策；风险 R1、R3 消除。设置页的权限状态仍要在 agent 里查询（授权结果按进程缓存），但授权对象不变。
- **生命周期**：launchd 负责启动与崩溃重启（`KeepAlive`）。App 让 agent 退出即可完成二进制替换（§7.2 的空闲替换因此简化为「请 agent 退出」）。宽限期只决定「App 不在时还对外服务多久」，到期后 agent 停止服务但进程可以留着（或退出并由 App 下次启动时再拉起，需取消 `KeepAlive` 的无条件重启，改为 `SuccessfulExit = false`）。
- **IPC**：§5.1 改为 XPC mach 服务（`MachServices`）；§5.2 的自定义分帧可以不用，终端数据以 XPC 消息承载即可，需要时再经 XPC 交一对 socket 的 fd。
- **新增约束**：
  1. 同 bundle id 的 Debug 构建与测试宿主若也注册同一个 Label，会顶掉正式版的 agent。只有装在 `/Applications`、`~/Applications` 的构建才注册 agent（与 `RemoteRelayRegistrationBlock` 同一判定），其余一律走进程内实现。
  2. 用户可以在「登录项与扩展」里关掉后台项目，`SMAppService.status` 变为 `requiresApproval` / `notRegistered` 时退回进程内实现，设置页给出说明。
  3. App 被 Translocation（从 DMG 直接运行）时不注册 agent。
- **仍需在真 uTerm 上确认**：授权给 uTerm 的屏幕录制在 App 已退出时 agent 能否继续采集（探针只验证了归属，没有实际授予后采集）；每月一次的屏幕录制重新确认提示由谁弹出；`SMAppService` 在 Sparkle 真实更新（公证包）后的注册状态。


## 15. 实现记录（2026-11-12，分支 `feat/remote-host-agent`）

按 §14 修订后的方案实现：P1（进程内拆分）、P2（远控进程上线）、P3（App 缺席期间保活）与 P4 的「空闲时替换」都已落地；§7.3 的引导重连交接、P5 没有做。

- **拆分**：`RemoteHostSessions`（被控端眼里的会话：列表、观察、接入、关闭、等接回），进程内实现 `RemoteRegistrySessions`。钉尺寸的归属改成按接入记：后来的接入接管尺寸，先前那条结束时不解掉后来者的（原来靠「先 claim 再钉」的先后保证，接入变成异步后保证不了）。接入改成异步，通道号在收到请求时分配。
- **XPC**：`RemoteHostAgentXPC`（远控进程导出）/ `RemoteHostAppXPC`（App 导出，同一条连接的反方向）。控制类消息是 JSON 负载，终端数据一段一条 XPC 消息；信用窗口 512 KiB，远控进程的链路取走多少就还 App 多少，没信用时积压留在 `TerminalMirrorTap` 的订阅者里，超上限照旧改发快照。
- **远控进程**：`uTermRemoteHost.app`（带沙盒、`LSUIElement`、只有网络权限），`KeepAlive` 只在崩溃时重启，按需由 mach 服务拉起。配对审批框与被控指示条在远控进程里显示（App 不在时也有指示）。文件服务用它包内的那份 `uTermShellAgent.xpc`。
- **App 侧**：`RemoteHostAgentBridge`。注册条件见 CLAUDE.md。App 里的 `RemoteHostServer` 在 `agent` 模式下只镜像状态、转发操作。退出时告诉远控进程原因：Sparkle 重启（`TerminalQuitPolicy.isRelaunchingForUpdate`）→ 宽限期 300 秒；⌘Q → 立即结束；没说就走（崩溃、`kill -9`）→ 120 秒。
- **按需注册**：`SMAppService.register` 推迟到第一次要连远控进程时（远控打开时），注册不上就退回 App 内服务。
- **按需常驻**：远控关着时 App 不去连远控进程（launchd 也就不拉起它）；关掉远控时请它停服务退出。远控进程启动后 120 秒内等不到 App（崩溃后被 launchd 拉起、App 已不在）就自己退出。
- **退回 App 内**：运行中用户在「登录项与扩展」里关掉了后台项目，连接一断就查 `SMAppService.status`，不是 enabled 就改回在 App 里服务（审批框、指示条改由 App 显示）。
- **版本替换**：`hello` 里比构建号，不同且没有设备连着就请旧进程退出，launchd 在下一次连接时拉起包里的新二进制；有设备连着就等它们断开 30 秒后再换。
- **测试**：`RemoteHostAgentTests` 五个用例（同一进程的匿名 XPC 监听器 + 真 `RemoteMacClient` + 假终端后端）：App 离开再回来时手机连接不断、画面续上、之后的输出照常；宽限期到期停止服务；⌘Q 立即结束；分片与信用；身份镜像的排队写入。原有远控用例（83 个）在拆分后全部通过（`RemoteMirrorStallTests` 在机器负载 18 时有两例假红，单独重跑通过）。

**还没验（要装好的公证包 + 真机）**：

1. 公证 DMG 装到 `/Applications`，打开远控时才注册远控进程（系统会提示「添加了后台项目」；远控关着的用户看不到这个提示）；`launchctl print gui/$UID/com.uozi.uTerm.RemoteHost` 能看到任务。
2. iPhone Duo 经局域网、中继、直连三条路接管终端与远程桌面时，做一次 Sparkle A→B：终端暂停后续上、桌面不断、`utermctl mac` 的大文件传输不失败。
3. `kill -9` uTerm：120 秒内重开能续上；超过 120 秒远控进程退出，手机按原逻辑重连。
4. ⌘Q（三个选项都试）：远控随之结束。
5. 屏幕录制、辅助功能沿用 uTerm 的授权（App 已退出时远控进程仍能采集与注入）；本地网络不再弹框。
   **2026-11-14 实测（2.1.3，macOS 27.2）：辅助功能不成立。** 远控进程直接调 `CGPreflightPostEventAccess` 时 tccd 记
   `Handling access request to kTCCServicePostEvent, from Sub:{com.uozi.uTerm.RemoteHost} … Auth Right: Unknown`；
   同一进程直接调 `CGPreflightScreenCaptureAccess`、麦克风则是 `Sub:{com.uozi.uTerm}`。即责任归属只对部分服务生效，
   PostEvent / ListenEvent 按进程自己的 bundle id 判。重启远控进程不变（排除进程内缓存）。修法：远控进程自己申请
   （系统设置「辅助功能」里出现「uTerm 远程控制」），设置页与授权引导经 `desktopPermissions` / `requestPostEvents`
   问它（`RemoteHostPermissionSource`）；授权后「重新启动 uTerm」会让远控进程随 App 退出、下次按新授权起来。
6. 在「登录项与扩展」里关掉 uTerm 的后台项目：远控退回 App 内服务，设置页照常。
