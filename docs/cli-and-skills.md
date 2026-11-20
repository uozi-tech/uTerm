# 命令行接口与 AI 技能（维护者说明）

> 对应 uTable 的同名文档。实施规划（真值源、分期、风险）在维护者的内部资料里。
>
> **当前状态：Wave 2 已合并（`feat/cli-skills`）。** 协议、服务端、设置、门禁分发、
> pbxproj 排除清单、entitlements、app 接线、五组动作（主机 / 执行 / 文件 / 转发 /
> 终端）的业务实现、客户端与四份技能文档都已落地，没有回 `not_implemented` 的路径。
> 尚未做的是**真机联调**，见文末「已知限制」。

## 1. 组成

| 文件 | 职责 | 状态 |
|---|---|---|
| `uTerm/Core/Control/ControlProtocol.swift` | `ControlAction` / `ControlRequest` / `ControlResponse` 与全部快照类型；socket 路径；上限常量；`ControlErrorCode` | ✅ 写全 |
| `uTerm/Core/Control/ControlServer.swift` | Unix domain socket 服务端（从 uTable 逐字移植，只改标识串 + 加 `sun_path` 预检） | ✅ |
| `uTerm/Core/Control/ControlSettings.swift` | `isEnabled` / `allowMutations` / `startupError`；`observe(_:)` 起停服务端 | ✅ |
| `uTerm/Core/Control/ControlHandler.swift` | 门禁 + 按 `action.group` 分发 | ✅ |
| `uTerm/Core/Control/ControlHandler+Hosts.swift` | 主机组（`hosts` / `host-key` / `trust` / `disconnect`）+ **主机解析与建连失败响应的唯一入口** | ✅ |
| `uTerm/Core/Control/ControlHandler+Run.swift` | 执行组（`run` / `run-many` / `quick-commands` / `quick-run`） | ✅ |
| `uTerm/Core/Control/ControlHandler+SFTP.swift` | 文件组十个 `sftp-*` 动作 | ✅ |
| `uTerm/Core/Control/ControlHandler+Forward.swift` | 转发组（`forward-list` / `-start` / `-stop` / `-add` / `-remove`） | ✅ |
| `uTerm/Core/Control/ControlHandler+Terminal.swift` | 终端组（`terminals` / `terminal-read` / `-send` / `-open`） | ✅ |
| `uTerm/Core/Control/ControlFilePayloadBuilder.swift` | 文件组纯逻辑：线上形状、SFTP 错误归类（见 §8 的 Citadel 抛错形状）、mode 解析 | ✅ |
| `uTerm/Core/Control/ControlForwardSnapshotBuilder.swift` | 转发规则 → 线上快照的纯函数 + 本机端口占用探测（规则名解析复用 `HostResolver`） | ✅ |
| `uTerm/Core/Control/ControlConnectionPooling.swift` | `HostConnectionSpec` / `ControlConnectError` / `ControlExecChannel` / 连接池协议 | ✅ |
| `uTerm/Core/Control/ControlConnectionPool.swift` | `actor`：按 hostID 持有 exec 连接 + **每主机最多 4 条**借还制 SFTP 会话；主机密钥质询缓存 + `trustHostKey` | ✅ |
| `uTerm/Services/SSH/SFTPPipeline.swift` | SFTP 流水线读写（32 000 B 切片 × 64 在途）+ `SFTPPipelineFile` 抽象。**两端共用**（不进 `membershipExceptions`） | ✅ |
| `uTerm/Core/Control/HostResolver.swift` | 名字 / UUID → `ServerProfile` 的三级解析（纯函数，单测友好）。快捷命令与**转发规则**的名字解析共用同一份 | ✅ |
| `uTerm/Services/SSH/SupervisedExec.swift` | 远端命令的执行看门狗：按**静默**判卡死 + 总时长兜底，超时终止远端进程组。CLI `run*`、macOS 快捷命令 / 并行执行窗口、iOS 并行执行共用。**两端共用** | ✅ |
| `uTerm/Services/SSH/BoundedExec.swift` | 「不可取消的远端调用 + 固定上限」外壳；现在只剩看门狗发 kill 这类一次性辅助调用在用。**两端共用** | ✅ |
| `uTerm/Services/SSH/IOActivity.swift` | 「还在往前走」的 task-local 脉冲：SFTP 回包、看门狗每一拍打点，`ControlServer` 据此按静默续期。**两端共用** | ✅ |
| `uTerm/Core/Skills/SkillTarget.swift` / `SkillInstaller.swift` / `SkillManagerModel.swift` | 技能安装：直接链到 app 包内 + 启动 / 打开设置页时自动对齐（见 §5） | ✅ |
| `uTerm/Core/Skills/SkillDefinition.swift` | 4 份技能的 slug / 显示名 + `catalog`（内容在仓库文件里，构建期拷进 app 包） | ✅ |
| `uTerm/Core/Skills/SkillInstaller.swift` 里的 `BinLinkInstaller` | 可选的 `~/.local/bin/utermctl` 链接 | ✅ |
| `uTerm/Features/Workspace/TerminalSessionRegistry.swift` | 跨窗口终端会话注册表（登记 / 解析 / `waitForSession` / 开窗闭包） | ✅ |
| `uTerm/Features/Terminal/TerminalScreenReader.swift` | 把影子终端读出来的行裁成一屏文本（纯函数，单测友好） | ✅ |
| `uTerm/Features/Settings/Views/CLISettingsView.swift` | 设置 ▸ 命令行与技能 | ✅ |
| `scripts/utermctl` | Python 3 客户端（真值源） | ✅ |
| `scripts/utermctl-selftest.py` | 客户端的离线自测（`make check-cli`） | ✅ |
| `skills/uterm-{run,files,forward,terminal}/SKILL.md` | 技能文档（真值源） | ✅ |

**所有新增的 `uTerm/` 下 Swift 文件都是 macOS-only**，必须同时加进
`uTerm.xcodeproj/project.pbxproj` 里 `PBXFileSystemSynchronizedBuildFileExceptionSet`
（对象 `10C0DE0000000000000000C0`）的 `membershipExceptions`。漏一个 iOS 构建就炸在
AppKit import 上。

## 2. 传输

一次连接 = 一条 JSON 请求 + 一条 JSON 响应，无长连接、无推流。

- socket：`<Application Support>/uTerm/control.sock`（用户名超过 10 个字符时改在容器的 `Data/tmp/`，见下面「`sun_path` 104 字节」），权限 0600，仅本用户。
- 后台生命周期：设置里的 `background.launchAtLogin` 通过 `SMAppService.loginItem`
  注册内嵌于 `Contents/Library/LoginItems` 的轻量 launcher；launcher 只负责给主 App 传入
  明确的 `--background --launch-source login-item` 后立即退出，不持有 SSH/业务状态。
  `background.allowOnDemandLaunch` 独立控制 CLI 是否可以在 socket 不存在时
  用 LaunchServices 静默唤起同一个 app 进程。客户端先等 `ping` 就绪，再且只再发送一次
  原业务请求；请求已发送而结果不明时绝不自动重放。多个并发客户端由 LaunchServices
  的 app 单实例语义与服务端 socket 抢占共同收敛到一个实例。
- **按需启动的门禁在 app 里，不只在客户端。** 客户端能读到偏好 plist 时先在本地拦
  （报得准、不白起进程）；**读不到**时（macOS 27 起没给完全磁盘访问权限的进程读沙盒容器
  里的 plist 直接 `EPERM`，见 §5.1）`preference_value` 返回 `None` 而不是 `False`，照样用
  `open -gjW … --args --background --launch-source cli` 请求启动。app 的入口
  `UTermEntryPoint`（`BackgroundServiceLifecycle.swift`，`uTermApp` 因此不再带 `@main`）
  在**任何属性初始化之前**调 `BackgroundLaunchMode.cliLaunchRefusal`：来源是 `cli` 且
  「允许 CLI 按需启动」「启用命令行接口」缺一项就 `exit(0)`，Sparkle / CloudKit / SwiftData
  都来不及起。客户端靠 `open -W` 提前返回 0 认出「被拒绝」，报明确的错误而不是干等 10 秒；
  接口就绪后结束掉等待中的 `open`。手动打开、登录项（`--launch-source login-item`）不受影响。
- 无窗口时 `run`、SFTP 与转发仍使用进程级连接池；`terminal-read/send` 只作用于已经
  存在的 GUI 会话，`terminal-open` 会把当前进程转回 GUI。关闭窗口只转入后台，菜单中的
  「完全退出」才终止进程、关闭 socket 并断开服务。
- 请求体上限 `maxRequestBytes` = 1 MiB：文件内容**不走请求体**（`sftp-get` / `sftp-put`
  随请求用 `SCM_RIGHTS` 交 fd，见 §4「大文件传输」），最大的请求是 `terminal-send` 的
  长文本与续传的区间表。`readRequest` 用 `recvmsg` 收，fd 放进 `ControlRequestContext`。
  连接一行一个 JSON：处理期间的进度行、心跳空行，最后一行是响应（`ControlProtocol.encode`
  出单行 —— 早先是 pretty-print，逐行解析的客户端会读不出响应）。
  连接槽位见 §4；I/O 超时 5 s（大响应按 payload 放宽）；handler 兜底是**静默** 120 s
  ——handler 只要还在 `IOActivity.touch()`（SFTP 每个回包、`run` 看门狗每一拍）就一直续期，
  连续 120 s 没有进展才回 `handler_timeout`。处理期间每 10 s 往连接写一个 `\n` 心跳
  （持 `stateLock` 写，不会插进响应字节中间），客户端据此把 socket 超时设成静默 60 s
  （`client_timeout`），不必猜最长的命令要跑多久。
- 并发满员时新连接**不读请求体**，直接回一条 `server_busy` 再关掉 —— 客户端据此退避
  重试，而不是把空响应误报成 socket 坏了。
- 服务端可能**在客户端写完之前**就回响应并拆连接（`request_too_large` 就是）。
  AF_UNIX 上已写回的数据不会因对端 `close` 丢失，所以客户端 `sendall` 撞
  `BrokenPipeError` / `ConnectionResetError` 时**先读一次**：读到 JSON 就当正常响应，
  读不到才报 `socket_error`。
- 客户端写完请求后 `shutdown(SHUT_WR)`，服务端读到 EOF 才开始处理。读请求的 I/O 预算
  随已收字节增长（每满 1 MiB 多给一份），否则 8 MiB 的 `sftp-put` 在慢机器上会被固定
  5 s 的读预算掐成 `request_timeout`。总时长仍有界（请求体本身封顶）。
- 同一路径上已经有**连得通**的 socket 时不抢（`socket_already_served`），退避重试
  —— 否则 unlink + bind 会把先到者变成孤儿 listener，表现为「uTerm 开着但连不上」。

### `sun_path` 104 字节

`<Application Support>/uTerm/control.sock` 在沙盒容器里展开是
`~/Library/Containers/com.uozi.uTerm/Data/Library/Application Support/uTerm/control.sock`，
除用户名外固定 93 字节，`sun_path` 只放得下 103 字节（留 1 字节给 NUL），所以**用户名超过 10 个字符就放不下**
（2026-11-16 用户 `exampleuser` 报的就是这个，104 字节）。

处理：
- `ControlProtocol.socketURL(applicationSupport:temporaryDirectory:)`：默认路径放得下就用它（用户名正常的人
  什么都不变）；放不下改用 `NSTemporaryDirectory()`，沙盒里就是容器的
  `~/Library/Containers/com.uozi.uTerm/Data/tmp/control.sock`，除用户名外 63 字节，用户名到 40 个字符都放得下。
- 客户端 `SOCKET_CANDIDATES` 按同样顺序多找这一条（`ControlProtocolTests.testSocketCandidatesMatchClient` 核两边一致）。
- 两处都放不下时 `ControlServer.start()` 在 bind 前返回错误串（不进 accept 循环，否则会变成每 2 秒重试一次的死循环），
  `ControlSettings.startupError` 收下，设置页红字显示。
- 客户端连不上、而默认路径本身就超长时报 `socket_path_too_long`（不是 `uterm_not_running`）：短路径也超长，或
  uTerm 确实被拉起来了却没就绪（装的是不会改用短路径的旧版本，消息让用户更新）。被开关拒绝时照旧报开关。
- 测试用构造的主目录（`ControlProtocolTests` 的 10 / 11 / 32 / 40 / 60 字符用户名），不看跑测试那台机器的用户名。

`UTERM_CONTROL_SOCKET` **只告诉客户端去哪里找 socket，改不了 uTerm 自己的监听位置**，不要把它当成路径超长的办法。

macOS 端 Debug 与 Release **都开沙盒**，共享容器目录，但 socket 文件名隔离：
Debug 使用 `dev.sock`，Release 使用 `control.sock`。CLI 默认只发现 Release，
不回退到 Debug。调试时显式指定设置页显示的路径：

```sh
UTERM_CONTROL_SOCKET="$HOME/Library/Containers/com.uozi.uTerm/Data/Library/Application Support/uTerm/dev.sock" scripts/utermctl ping
```

请先从 Xcode 启动 Debug app；CLI 按需唤起流程面向正式版。

## 3. 门禁

三层，顺序固定，由 `ControlHandler.handle` 与各组 extension 分工执行：

1. **主开关** `control.enabled`（默认关）。关掉时 `ControlServer.stop()` 且 unlink
   socket，客户端看到「文件不存在」。除 `ping` 外一切动作都需要它
   （`ControlAction.requiresEnabled`）。
2. **改动开关** `control.allowMutations`（默认关）。管一切「会改远端、写本地信任库或
   触发副作用」的动作（`ControlAction.requiresMutation`）：`trust` / `run` /
   `run-many` / `quick-run` / SFTP 六个写动作 / `forward-start|stop|add|remove` /
   `terminal-send|open`。
   **`run` 有意归在这里**：shell 命令无法可靠分类读写，假的只读开关比没有更糟。
3. **主机级硬规则**：`ServerProfile.sftpOnly == true` 的主机拒绝
   `ControlAction.requiresExecCapableHost` 的动作（`run` / `run-many` / `quick-run` /
   `terminal-send` / `terminal-open`），回 `host_sftp_only`。这是用户在主机档案上做的
   定性，CLI 不绕。由 `ControlHandler.requireExecCapable(_:action:)` 在 `resolveHost`
   之后立刻执行。

门禁矩阵的真值源是 `ControlProtocolTests.testGatingMatrixMatchesTheSpec` ——
新增动作要同时改那张表，否则测试红。

### 不做的（明确拒绝，不留后门）

- 导出私钥 / 密码 / 口令：协议里根本没有这些字段。
- 修改 `ServerProfile` / `SSHKey`（增删改）、修改 `ForwardingRule`、给规则开自启 —— 这些是
  用户在界面里做的定性，CLI 只消费。
  例外（2026-11-12 起）：`forward-add` 新建规则、`forward-remove` 删除规则。Agent 要临时打一条
  -R 让 VM / pod 连回 Mac 时，原先只能停下来让用户去界面建，打断太重。边界：新建的规则一律
  不自启；`forward-remove` 拒绝删开着自启的规则（`rule_protected`）；技能文档要求只删自己建的。
  校验与界面编辑器同一套（`ForwardRuleDraft` 对齐 `ForwardEditorSheet.valid`，同侧冲突走
  `PortConflictChecker`，本机侧跨主机比、服务器侧只比同一台主机）。
- 长驻流（`tail -f`、交互式 shell）—— 一问一答的 IPC 承载不了。

### 主机密钥

绝不自动 TOFU。`run` 撞到未知 / 变更的密钥就拒绝并把 fingerprint 回给 CLI
（`host_key_unknown` / `host_key_changed`）；只有 `trust --fingerprint <值>` 且与当前
挑战一致才写 `KnownHost`。密钥**变更**即便 mutation 开着也不给 CLI 覆盖，必须回界面
处理 —— 这是中间人风险的最后一道闸。

`forward-start` 是唯一**不经连接池**建连的动作（走 `ForwardingCoordinator` 的专用转发
连接），挑战落在它自己的临时 `HostKeyChallengeRelay` 上。它拿到挑战后必须
`pool.recordChallenge(hostID:_:)` 补记进池，`trust --fingerprint` 才配得上对 ——
否则「拿指纹 → trust → 重试」在转发这条路上会卡在 `invalid_request`。
同理，`ForwardingCoordinator` 按 serverID 记「**当前** relay」，会话的审批闭包经
`approveHostKey(serverID:challenge:)` 间接取用：会话是按主机缓存的，第二次 `start`
复用旧会话时若还捕获创建时那个 relay，挑战就会弹到早已关掉的 sheet 上。

### 为什么没有 token 鉴权

与 uTable 一致：同用户已经能读钥匙串，token 挡不住真正的威胁模型，反而给模型制造
「去哪拿 token」的歧路。socket 0600 + 两级开关就是全部门禁。

## 4. 连接持有

```
ControlConnectionPool (actor)
  hostID → { exec: ReusableSSHConnection?,
             sftp: { idle: [SFTPSession], busy: [SFTPSession], pending: Int },  // 每主机最多 4
             lastUsedAt }
```

`ControlConnectionPooling` 的公开面（其它组按它调，别绕过去自己建连）：

```swift
func executor(for: HostConnectionSpec) async throws -> SSHCommandExecutor          // 用协议默认裁剪
func executor(for: HostConnectionSpec, maxLines: Int, maxBytes: Int) async throws -> SSHCommandExecutor
func borrowSFTP(for: HostConnectionSpec) async throws -> any SFTPProviding   // 借（必要时新建 / 到上限则等）
func returnSFTP(_ session: any SFTPProviding, for hostID: UUID) async        // 还
func disconnect(hostID: UUID) async
func disconnectAll() async
func heldHostIDs() async -> [UUID]
func lastHostKeyChallenge(hostID: UUID) async -> HostKeyChallenge?
func recordChallenge(hostID: UUID, _ challenge: HostKeyChallenge) async   // 池外路径补记挑战
func trustHostKey(host: HostConnectionSpec, fingerprint: String) async throws

// 协议扩展（nonisolated，body 留在调用方的隔离域里跑，不占着池 actor）
func withSFTP<T>(for: HostConnectionSpec, _ body: (any SFTPProviding) async throws -> T) async throws -> T
```

**SFTP 是每主机一个小池子，不是一条独占会话。** 借还制（`withSFTP` 最不容易漏还）：
有空闲直接拿；没空闲且没到 `maxSFTPChannelsPerHost`（**16**）就新建一条**独立的 SSH
连接**；到上限的借用者排队等归还。一次传输默认 8 路，16 条让同一台主机能同时跑两个
满速传输。同一主机**同时握手**的 SFTP 连接最多 `maxConcurrentHandshakes`（4）条：sshd 的
`MaxStartups`（默认 `10:30:100`）数的是未认证的连接，一口气并发建 32 条时有一部分会被
随机丢（实测吞吐掉一半），分批握手就没事。传输中途坏掉的会话用 `discardSFTP` 丢弃，
不放回空闲队列。

**IPC 槽位分两份**（`ControlProtocol.maxControlClients` 8 + `maxTransferClients` 8，
accept 时按总数 16 收）：读完请求、知道是 `sftp-get` / `sftp-put` 之后，传输已满就回
`server_busy`。所以传输再多，`run` / `ping` / `sftp-ls` 这些短请求也永远有 8 个槽位。
**一个传输槽位就是一整个并行传输**（内部自己开 8 路），8 个足够；最坏情况每个传输在途
约 8 × 16 MiB（窗口），内存要有顶。
与 exec 不同，SFTP **不**共享冷启动（那会把并行退化回单通道），上限由池里的 `pending`
计数守住；建连失败要把占住的名额还回去，否则名额会被一次次失败烧光。
`disconnect` / `disconnectAll` 关掉**全部**通道（空闲的和借出中的都算），借出中的那条
在归还时发现自己已不在表里，随即被关掉。空闲回收跳过「有会话正借在外面」的主机
—— 长传输跑到一半被抽走通道就断了。

建连是**急切**的：`makeExec` 拿到复用连接后先跑一条 `:`（shell no-op）把握手做掉，
好让「主机密钥未信任 / 认证失败」在 `executor(for:)` 就带着指纹上抛，而不是等到用户的
命令跑到一半才从 `BoundedExec` 里冒出来（那里拿不到质询，也没法把指纹回给 CLI）。

`trust` 不自己拼 `KnownHost`：连接池按**钉住的指纹**重新握手，服务器出示的密钥与指纹
逐字相同才批准，USSHKit 随即沿 `HostKeyVerifier` 现成的 TOFU 路径把它记进信任库。

主开关关闭时释放全部持有 —— `uTermApp.startControlInterface()` 里
`controlSettings.observe` 的 else 分支在 `server.stop()` 旁边跟着
`Task { await ControlConnectionPool.shared.disconnectAll() }`。

- 懒建：第一次 `run` 才建 exec 连接，第一次 `sftp-*` 才建 SFTP 会话；两者独立
  （`SFTPProviding.exec` 拿不到退出码，不能拿来跑 `run`）。
- **exec 的冷启动只建一次**：建连期间以 `Task` 占位（`pendingExec`，按 hostID），
  后到的请求 `await` 同一个 Task。没有这层占位时，同一台主机的两条并发 `run` 会各建
  一条连接、后者覆盖前者入表，前者永远关不掉（fd 泄漏 + 远端多一条看不见的会话）。
  失败要清占位（否则这台主机会一直「记得」上次失败）；清的时候只清**自己那次**的
  （`pendingExec[id] == task` 才清），搭车者恢复得晚，别把新一轮的占位误清了。
- `hosts.cliConnected` 一律走 `await heldHostIDs()`。`host_ambiguous` 那条同步路径
  （`resolveHost` 是 `throws(ControlFailure)` 的同步函数）由 `ControlHandler.handle`
  的收口统一补这一列 —— 那里是 async，一次 await 给所有组填对，不需要 NSLock 镜像。
- 认证解析在 MainActor 上做一次（`HostConnectionSpec.resolve`），产出 Sendable 快照，
  连接闭包只捕获它 —— 与 `WorkspaceCommandExecutorFactory.make` 的前半段同款。
- 与窗口无关：关窗口不影响 CLI 持有；CLI 也不改任何窗口的当前目录 / 标签。
- 空闲 10 分钟自动 `close()`；`disconnect` 显式释放；主开关关闭时全部释放。
- `ping.openHosts` 报当前持有的主机名，方便模型判断「慢是不是因为首连」。
- SFTP 借还三条硬规矩：**借不到要有上限地等**（`sftpWaitTimeout` 90 s，短于
  `ControlServer` 的 120 s 静默预算——排队期间没有进展可报；等不到抛 `SFTPChannelsBusyError`，handler
  映射成 `server_busy` + 明确文案，客户端据此退避重试）；
  **重复归还是 no-op**（判据是「它在不在 idle 里」，只看 busy 的话第二次归还会把一条
  躺在空闲队列里的活会话关掉）；**取消的等待者不能带走名额**（唤醒时跳过已取消的，
  一直传到有人接手或队列空）。
- 建连**成功**但期间这台主机被 `disconnect`：`ControlConnectError.released`（可重试），
  不是 `connectFailed` —— 握手认证密钥全过了，报成「连接失败」只会把人引去查
  不存在的网络故障。错误码同样是 `server_busy`（语义就是「稍后再来」），客户端的
  退避重试直接覆盖这一态。

### 超时

按**静默**判，不按总时长判（`SupervisedExec`）：
- `timeoutSeconds` 是静默超时（默认 60 s / 封顶 1800 s）：连续这么久没有任何输出才判定卡住；
  `maxDurationSeconds` 是总时长上限（默认 3600 s / 封顶 21600 s），只防 `tail -f` 这类永不
  静默的命令一直占着名额。
- 执行走 Citadel `executeCommandStream`（原来的 `executeCommand(maxResponseSize: 64_000)`
  超过 64 KB 输出整条抛错），只留头部（裁剪）与尾部（退出码哨兵）。
- 包装时首行打印 `$$`：sshd 给每个 exec 会话 `setsid()`，它就是进程组号。超时后另开一条
  exec 对整组 `kill -TERM -<pid>`，宽限 5 s 再 `-KILL`（ash / bash / zsh 实测过，`&`
  后台子进程一起收）。拿不到 pid 才退回「放手不等」，响应里 `killed: false`。
- exec 仍然**不可取消**：消费者是非结构化 Task，看门狗判定后直接返回，消费者等远端进程组
  被杀、channel 收到 EOF 后自己结束。
- 连接池的 10 分钟空闲回收跳过有命令在跑的主机（`execInFlight`）。
- 真 sshd 端到端：`SupervisedExecLiveSSHTests`（默认跳过，设 `TEST_RUNNER_UTERM_LIVE_SSH_PORT`
  才跑，Docker 配方在文件头）。

上限：输出默认 200 行 / 16 KB，`--max-bytes` 封顶 1 MiB；
`sftp-cat` 1 MiB、`sftp-get|put` 不限大小（见下）；
`run-many` 并发 6。

### 大文件传输（`sftp-get` / `sftp-put`：交 fd，uTerm 内部并行）

**一次传输 = 一条 IPC 请求。** 客户端打开 / 建好本地文件，`sendmsg` 时用 `SCM_RIGHTS`
把 fd 挂在请求上；`ControlServer` 收进 `ControlRequestContext`，handler 取出来交给
`ParallelTransfer`：用 `parallel`（缺省 8，封顶 16）条 SFTP 会话并发跑流水线，**每到
一个 32 000 B 的回包就直接 `pwrite` 进那个 fd**（上传反过来 `pread` 出来发走）。文件
字节不经过 IPC、不做 base64、不在内存里攒段。

| 字段 | 语义 |
|---|---|
| `path` | 远端路径 |
| `parallel` | 这次用几条 SFTP 会话，1…16，缺省 8；超范围 → `invalid_request` |
| `ranges` | `[{offset, length}]`：只传这些区间（续传）；缺省整份。越界 → `invalid_request` |
| `force` | 只对 `put`：覆盖已存在的远端文件；缺省撞上就 `file_exists` |

- 没随请求交 fd → `invalid_request`（消息里点名 `SCM_RIGHTS`）。fd 由 handler 关；没被
  取走的由服务端在 handler **真正返回后**关（不是在 `handler_timeout` 时，否则仍在跑的
  传输会写进一个已关闭、号码随时被复用的 fd）。
- `get` 先把 fd `ftruncate` 成远端大小（续传时已写的部分不受影响）。`put` 在整份上传时
  用 `create`（EXCL）或 `overwrite`（`force`）打开一次定下覆盖语义，之后所有工作者都用
  不截断的 `.write` 并行写；给了 `ranges` 就不再动远端已有内容。传完核对远端大小。
- **工作分配**：待传区间切成 8 MiB 的段放进共享队列，每个工作者（= 一条借来的会话，
  文件只开一次）领一段、把段内请求接在自己的流水线后面**连续**发，段与段之间不排空。
  整段落盘后记进 `ControlRequestContext`（`recordSegment`）。某条会话出错：它手上没做完
  的段退回队列交给别的工作者、这条会话丢弃；同一段最多重试 2 次，所有工作者都倒下才
  整体失败。借会话遇到建连失败退避重试 2 次。
- **进度**：监督定时器每 0.5 s 把自上一行以来新完成的段拼成一行
  `{"event":"progress","bytes","totalBytes","done":[{offset,length}]}` 写回连接（写一半的
  留在 `pendingOutbound` 下一拍续，收尾时先写完、再补最后一批段、再写响应 —— 客户端的
  续传账一段不缺）。写的时候撞 EPIPE（客户端走了）就取消 handler，实测 ~1 s 内停下
  （杀掉客户端后第 1 秒容器还发出 126 MiB = 8 × 16 MiB 在途窗口，之后归零）。
- **沙盒与 quarantine**：沙盒进程往 fd 里写过的文件照样被系统打上
  `com.apple.quarantine`（实测 `0086;…;uTerm;`，哪怕文件是客户端建的）。客户端不在沙盒
  里，下载成功后 `removexattr` 掉。
- 成功响应：`transfer: {path, bytes（这次实际搬的，续传只算补的区间）, totalBytes,
  seconds, channels}`，不带 `file`。

**参数是量出来的**（`ParallelTransferBenchmarkTests`，Docker sshd，`tc netem` 加 50 ms
延迟、队列放开，1 GiB，单位 MiB/s）：

| 通道 | 在途 64 · 窗口 1 MiB | 在途 256 · 窗口 4 MiB | 在途 640 · 窗口 16 MiB |
|---|---|---|---|
| 1 | 8.8 | 33.1 | 55.4 |
| 4 | 33.2 | 90.2 | 182 |
| 8 | 57.9 | 219 | **279** |
| 16 | 51.4 | 80.9 | 287 |
| 32 | 32.3 | 32.1 | 182 |
| 64 | — | — | 105 |

- **窗口是 WAN 下的主旋钮**：单条连接 1 MiB 窗口只有 8.8，16 MiB 窗口 55。所以传输用的
  SFTP 连接单独开 16 MiB 窗口（`Connector.live(transferWindowBytes:)`；终端 / 转发 / exec
  仍 1 MiB），下载在途 640 个请求（≈ 20 MB，压满窗口）。
- **上传**的在途量由服务端的接收窗口（OpenSSH 约 2 MiB）封顶，我们的窗口不起作用：在途
  128 与 640 同速（8 路约 110），取 128。
- **8–16 路是顶**，再多每条连接的加解密与拥塞窗口争抢只会更慢；所以不做成能开到上百路。
- 对照：旧的「每片一条 IPC 请求 + base64」协议（已删）同条件下 4 / 8 / 16 / 32 路是
  28 / 52 / 82 / 93，进程峰值内存 0.8–1.5 GB；LAN 下 32 路起开始撞 `MaxStartups`
  （`connect_failed`）。端到端（真 utermctl → 测试宿主里的真 `ControlServer`）1 GiB 下载
  8 路 3.9 s / 261 MiB/s。本机负载高时同一组合能掉到 60–120，比较要在同一时段做。
- 端到端夹具 `ControlLiveServeHarnessTests`（默认跳过）：在测试宿主（同一个沙盒容器）里
  起真服务端，从沙盒外用 `scripts/utermctl` 打，配方在文件头。

新错误码 **`file_exists`**：`create` 撞上已存在的路径。SFTP v3 撞 EXCL 只回
`SSH_FX_FAILURE` + 依实现而定的文案，所以映射有三条来源（强类型
`SFTPFileExistsError`、errno `EEXIST`、文案里的 "file exists" / "already exists"），
落到兜底 `operation_failed` 时 handler 再 `stat` 一次确认路径确实存在。

⚠️ 那次 stat 兜底**只对打开阶段的失败**做。EXCL 打开成功之后文件就已经建出来了，
写阶段失败（磁盘满、配额、断线）时再 stat 必然命中 —— 不加这道门就会把
「No space left on device」报成 `file_exists`，用户照提示加 `--force` 重传再失败一次。
阶段由 `SFTPSession.openTransferHandle` 用 `SFTPWriteStageError(stage: .open)` 标出来，
写阶段的错误原样上抛。本地 fd 读写失败回 `local_write_failed`（get）/
`local_read_failed`（put）。

### SFTP 流水线读写（`SFTPPipeline`，GUI 传输一并受益）

瓶颈从来不是带宽，是**串行往返**：Citadel 的 `SFTPFile.write(_:at:)` 内部按 32 000 B
「发一片 → 等 ack → 再发下一片」，8 MiB = 262 个往返，13 ms RTT 就是 3.9 s。

但 `SFTPClient.sendRequest` 是按 requestId → promise 映射的，同一条 SFTP 通道天生允许
多请求并发。于是 `SFTPPipeline` 把切片摊进 TaskGroup：最多 `inFlight`（默认 **64**，
≈2 MiB 在途）个 32 000 B 请求同时压在通道上，耗时退化成 `总片数 / inFlight × RTT` +
带宽时间。两个常量不要乱调 —— 32 000 B 是 Citadel 照 swift-nio-ssh #99 定的单请求上限，
64 再往上只是压通道窗口。

`SFTPSession` 的**所有**读写路径都走它：`upload(data:)` / `upload(localURL:)` /
`write` / `writeRange` / `download(remotePath:)` / `download(toLocalURL:)` /
`readRange`。本地按 4 MiB 分段进出（内存有界），段内并发。因此 GUI 的 SFTP 上传下载
自动受益，不必改 `FileBrowserModel` 一行。

三条语义纪律：

- **任一片失败取消其余**，抛的是**原错误**（不包一层 —— `ControlFilePayloadBuilder`
  还要认服务端状态码）。唯一的例外是 `writeRange` 给**打开阶段**的失败包了一层
  `SFTPWriteStageError`（见下），归类前统一 `unwrap`。
- **短读补发**：SFTP 允许服务端少给，段内在**同一 offset** 上补发直到读满或读到
  0 字节。只有「读到 0 字节」才是这一段的终点。
- **不许有空洞**：拼装时第一个「没读满」的段是 EOF，它**之后**的段必须也是空的；
  后段还有数据说明中间凭空多了个洞 → 抛 `SFTPShortReadError`。
- **长度已知就必须读满**：下载先 `stat` 拿 size，按 size 精确分段并要求每段读满
  （`requireFullLength`），短了直接抛 `SFTPShortReadError`；`size` 之后再非严格地
  把「传输期间长出来的尾巴」读完（先用一个 32 000 B 的请求探，确认在长才切回整段）。
  以前的判据是「返回的比要的少 = EOF，收工」—— 服务端一次短读 / 空读就能让 12 MiB
  的下载在 116 KiB 处**报成功**，本地文件缺 99% 而且没有任何人报错。区间读
  （`readRange`）仍是非严格的：那里短读本来就是合法的「到头了」。

### 多主机动作的成败语义

`run-many` / `quick-run` **不恒 `ok: true`**（早先版本全失败也退出 0，`utermctl
run-many … && 下一步` 就成了陷阱）：

| 顶层 | 条件 | 退出码 |
|---|---|---|
| `ok: true` | 每台都 `errorCode == nil && exitCode == 0` | 0 |
| `run_partial_failure` | 有成有败 | 7 |
| `run_failed` | 一台都没成 | 5 |

`results` 三种情况都在，按请求顺序、**按 hostID 去重后**一台一条（`-H web1 -H web1`、
名字 + UUID、大小写变体都指同一台；不去重的话同一条命令会在同一台上跑两遍，`quick-run`
的端点字典还会因重复键 trap）。合并了几个会写进 message。

主机密钥两态逐条带 `results[].hostKey`，顶层 `hostKey` 取第一台 —— 顶层只报得了一台，
多台首连时模型要靠逐条那份才知道每台该 `trust` 什么。

### 终端会话注册表（`terminals` / `terminal-read` / `terminal-send`）

与连接池并列的**另一种持有**：`TerminalSessionRegistry`（app 级单例，注入 environment）
枚举的是**用户自己开着的窗口**里的会话，不是 CLI 建的连接。四条纪律：

- **只列活会话。** `PaneModel` 观察 `TerminalSession.connectionState`：翻到
  `.connected` 登记，翻到别的（`.disconnected` / `.failed` / `.idle` / 重连中的
  `.connecting`）立刻注销。远端退出后那条会话就从 `terminals` 里消失，而不是顶着
  「活着」的身份让 `terminal-read` 一直回同一张冻结的画面。
- **绝不延长会话寿命。** 会话本体只以弱引用存在注册表里。窗口没走 `dispose` 就没了
  的情况（SwiftUI 拆除路径），读取入口（`snapshots` / `matches` / `session(for:)`）
  会把「弱引用已死」的槽位连同它的 entry 一起清掉 —— 只清槽位不清 entry 的话，
  `terminals` 会永远列着一条读不了也写不了的幻影行。
  因此**已关掉的会话给的是 `terminal_not_found`**（它不在表里了），
  `terminal_disconnected` 留给「列表之后、操作之前正好断了」的竞态。
- **`title` = 标签自定义名（`UPaneTab.customTitle`），没有才回落服务器名。** 窗格自己
  不知道挂在哪条标签上，所以 `WorkspaceModel.attachSessionRegistry` 往
  `TerminalSessionRegistrar` 注入一个 `paneID → customTitle` 的查询钩子；标签标题
  事后变化由 `WorkspaceModel.syncTerminalTitles()` 推给 `update(id:title:)`
  （注入注册表 / 开新标签 / 切前台标签三处各调一次）。
  它**不是**当前目录，也不是提示符 —— 技能文档里也这么写。
- **`isKeyWindowFocused` 读取时现算**，不在 entry 里存缓存副本：唯一真值是注册表里
  每个窗口的 `{isKey, focusedSessionID}`，`snapshots()` / `isKeyWindowFocused(_:)`
  当场算。以前是四个 mutator 手工同步一份副本，漏一个就说谎。

读屏本身（`TerminalSession.snapshotScreen`）：先用二分反推缓冲区末行
（`getScrollInvariantLine` 越界回 nil，右端直接取 `buffer.getCorrectBufferLength(rows)`
这个硬容量，不必指数上探），再**从末尾往前跳过空行**、然后往上取 `lines` 行。
跳空行这一步不能退回「多取一屏」那种写法：`clear` 之后、TUI 退出之后的空白尾巴可以
有几百行，而 `TerminalScreenReader.trim` 会把尾随空行全部去掉，多取的那一屏会被裁光，
读屏返回空数组。

### 配对过的 Mac（`macs` / `mac-*`）

第三种持有：对象不是 SSH 主机，是配对过的另一台 Mac，走远控链路（`RemoteLink`，局域网 /
打洞 / 中继），那台 Mac 不用开 SSH。主控端经 `utermctl mac …`，被控端由它的 uTerm 执行。

```
utermctl ── socket ──▶ ControlHandler+Mac ──▶ RemoteMacFileProvider ──▶ RemoteMacClient
                                                                            │ fileRequest(48) / fileReply(49)
                                                                            ▼  专用通道 0xFFFFF11E
被控端：RemoteHostConnection.handleFileRequest ──▶ RemoteFileAccess ──XPC──▶ uTermShellAgent
                                                                            └▶ RemoteFileService.handle
```

- **线格式**（`uTermFiles/RemoteFileWire.swift`，主程序、iOS、辅助程序三个 target 共用）：
  `[u32 头长][JSON 头][正文]`。请求头带 `id`（应答原样带回，一条链路上并发多条请求靠它配对）；
  正文是文件字节 / 命令输出，头里声明了 `lzfse` 时是压过的（不小于 1 KiB、压完小于九成才压）。
- **执行在辅助程序里**。主程序在沙盒里读不了用户的主目录；`uTermShellAgent.xpc` 没有沙盒，
  本来就在替远控开本机终端。`RemoteFileService`（`uTermFiles/`，不编进 iOS）在那里做全部
  操作：POSIX 文件操作、按行读、`grep`（`NSRegularExpression`）、`find`、目录树、`sha256`、
  原子写（临时文件 + `rename`）、`edit`、`/usr/bin/patch`、FSEvents 等变化、`posix_spawn`
  跑命令（登录 shell、独立会话、静默超时 + 总时长上限、超时杀进程组）。主程序不解释请求，
  只为门禁和日志看一眼头。
- **门禁**。被控端：`RemoteFileAccess.live` 要求「允许打开本机终端」开着（能开终端就已经能
  做这一切，不另设开关），关着回 `disabled`，连接不断。主控端：`ControlAction.requiresMutation`
  把 `mac-run` 与全部写动作归到「允许执行命令与写入」下；`mac-xattr` 读写共用一个动作，
  `set` / `remove` 在 handler 里补判。
- **老版本**。新消息号老版本不认识、会直接断开，所以握手带 `files` 能力，
  `RemoteMacClient.performFile` 发现对端没有就在本地回 `unsupported`，不发请求。
- **不饿死终端**。文件应答走专用通道（`RemoteLinkFlow` 按通道轮转），不计入终端输出的背压；
  传输是 256 KiB 一片、窗口 8（`RemoteMacTransfer`），单片失败按 `unreachable` / `timeout`
  重试 3 次。
- **连接**（`ControlMacSessions`）：连接归 `RemoteMacDirectory` 管，和「我的 Mac」窗口共用
  一条，命令行只是多一个使用者；命令行握着的空闲 10 分钟放掉，正在做的动作（`busy`）不算空闲。
  用户没打开过「我的 Mac」时不在局域网里找（免得命令行触发「本地网络」授权框），只走中继。
- **单文件传输**与 `sftp-get` / `sftp-put` 同一套约定：fd 经 `SCM_RIGHTS` 交来、`ranges`
  续传、进度段。**目录**的 `get -r` / `put -r` / `sync` 由客户端编排（本地那一半只有它碰得到）：
  逐层 `mac-ls` 列远端、`os.walk` 列本地，文件逐个走单文件传输（4 个一起），`sync` 按
  「大小 + 修改时间」判断、传完用 `mac-touch` / `os.utime` 把时间对齐。
- **等变化**的坑：FSEvents 会把调用**之前**刚发生的写入送过来（「写完就等」是最常见的用法）。
  启动后先 `FSEventStreamFlushSync` 排空丢掉，之后的事件再按文件的 ctime 核一遍，早于开始
  时刻的不算。
- **子进程的退出状态不能靠 `waitpid`**。辅助程序把 `SIGCHLD` 设成了忽略（它起的 holder 退出时不留
  僵尸），那种进程里子进程一退出就被内核收掉，`waitpid` 只回 `ECHILD`、状态恒为 0：`exit 7` 报成
  成功，`git ls-files` 失败被当成「仓库里一个文件都没有」（`grep` 搜到 0 个文件）。测试宿主里
  `SIGCHLD` 是默认处置，进程内跑的用例全绿，只有真经辅助程序才露出来。`RemoteFileService.spawn`
  因此用 kqueue 的 `NOTE_EXITSTATUS` 拿状态（`ExitWatch`；子进程先挂起、监视装好再 `SIGCONT`），
  回归用例 `test_exit_status_survives_ignored_sigchld`。
- **两台 Mac 联调**：`RemoteFilesHarnessTests`（默认跳过）是一对夹具，各跑在一台 Mac 的测试宿主里，
  身份是内存里现造的、配对只在夹具里自动允许，不碰真实的配对记录、钥匙串和正式版的设置；其余全是
  线上那一套（跨局域网的真链路、`ControlMacSessions` + `RemoteMacDirectory` 的调试直连、被控端的
  真门禁与辅助程序）。被控端打印 `FILES_HARNESS_PORT=`，主控端起一个真的命令行服务端
  （`~/Library/Containers/com.uozi.uTerm/Data/tmp/umac.sock`），从沙盒外用真的 `utermctl` 打。
  被控的 Mac 要有 Xcode，且设备号在 Debug 签名的描述文件里（`build-for-testing` 的产物连同
  `.xctestrun` 打包传过去，`xcodebuild test-without-building -xctestrun …`）。

### 反方向：被控的 Mac 读写主控端共享的文件夹

场景：用户在手边的 Mac（主控端）上远程接管另一台 Mac 的终端，在那个终端里跑 Agent；Agent 要回头读
用户手边那台 Mac 上的项目。同一条远控链路，请求和应答的方向反过来，消息号不变（48 / 49）。

```
被控的 Mac：utermctl ─▶ ControlHandler+Mac ─▶ RemoteMacFileProvider(send:) ─▶ RemoteHostConnection.performFile
                                                                                │ fileRequest(48) ▲ fileReply(49)
                                                                                ▼
主控端：RemoteMacClient.handleSharedFileRequest ─▶ RemoteFileSharingAccess ──XPC──▶ uTermShellAgent.scopedFileRequest
                                                   （范围：RemoteFileSharingStore）          └▶ RemoteFileService.handle(_, scope:)
```

- **只开放共享的文件夹**。这个方向没有「能开终端就等于能读写一切」那层等价关系：被控的 Mac 可能是
  别人的（邀请可以跨 Apple ID）。主控端在「我的 Mac」详情里一台一台、一个文件夹一个文件夹地加
  （`RemoteFileSharingStore`，`DefaultsKey.remoteSharedFolders`，只存本机），默认没有、默认只读。
  忘记那台 Mac 时一并收回。每条请求现查范围，改了立刻生效。
- **范围检查在辅助程序里做**（`RemoteFileService.confine`）：路径要解析掉符号链接才能判断在不在
  范围里，沙盒里的主程序做不了。范围随 XPC 调用单独传（`scopedFileRequest(_:scope:)`），不从请求头里
  读；解不开就什么都不放行。规则：
  - 上级目录解析掉符号链接、最后一段按操作决定跟不跟（读写内容的跟，删除 / 改名 / `readlink` 这些动
    条目本身的不跟）；解析结果必须落在某个共享目录里，嵌套时取最里面那个定读写。检查过之后请求里的
    路径换成解析好的那个，执行用的就是检查过的路径。
  - 悬空的符号链接不能写（跟着写会在外面新建文件）；`rename` / `copy` 两头都要在范围里；新建的符号
    链接只能指向同一个共享目录里面。
  - `exec`、`patch` 一律拒绝（起别的程序，圈不住）；`grep` / `find` 带上 `noGit`，不调 git 列文件——
    仓库里的 git 配置（`core.fsmonitor` 之类）能让 git 去跑别的程序。遍历本来就不跟符号链接。
  - **没堵住的**：对端有写权限时，可以在检查和执行之间把目录里的东西换成符号链接来抢这个空当。读写
    共享本来就等于信任那台 Mac 改这个目录，不要把读写共享开给不信任的机器。
- **握手**。主控端（只有 Mac）在 hello 里多声明一项 `file-sharing`；被控端只对声明了的设备发请求，
  手机和老版本的 Mac 在本地就回 `unsupported`。没共享任何文件夹时照样声明，请求回 `disabled`（只有
  `roots` 回空列表），这样被控端的 Agent 拿得到「让用户去加共享」的提示。
- **几台设备同时连着**（`ControlMacSessions.defaultController`）。被控端的 `macs` 把连着它的主控设备
  也列出来（`role: controller`，`id` 是 `controller:<设备 UUID>`，和「配对过的 Mac」那条路分开）。
  没写 `--mac` 时：
  1. 发命令的终端此刻被谁接管就是谁——`RemoteHostServer.controllers` 里一个终端同一时刻只归一台设备，
     换了设备接管，同一条命令就落在新的那台上。它不提供文件（手机）就直说，不换别的设备顶上。
  2. 认不出终端、或终端此刻没人接管：只有一台肯提供文件的设备连着就用它。
  3. 否则 `host_ambiguous`，列出候选的 `id`。
- **终端怎么认出来**：辅助程序起本机 shell 时写一个环境变量 `UTERM_SESSION_ID`（就是
  `TerminalSessionRegistry` 里那个会话的 id，也是 holder 的会话 id，重启接回后不变），`utermctl` 把它放进
  `mac.session`。环境变量里**只放终端的编号、不放设备名**：变量在 shell 启动时就定死了，而接管的设备
  会换。`tmux` / `ssh` 嵌套之后变量会丢，那时落到上面的第 2、3 条。
- **每条请求现找连接**：被控端不握着到主控端的连接（那是主控端建的），`RemoteMacFileProvider(send:)`
  每次按设备 ID 取它此刻最新的那条；主控端断了重连之后接着能用。
- 用例：`RemoteFileScopeTests`（越界、符号链接、只读、跨界移动）、`RemoteFileSharingEndToEndTests`
  （真链路上两三台主控设备同时连着一台被控端）；联调夹具 `test_share_folders_for_manual_check`
  （主控端，扮几台设备各共享一个文件夹）配 `UTERM_FILES_HARNESS_CLI=1` 的被控端夹具。

## 5. 技能安装

- **`~/.<tool>/skills/<slug>` 是一条直接指向 app 包内 `uTerm.app/Contents/Resources/Skills/<slug>`
  的符号链接**，app 不写出任何技能文件。包里的技能由构建阶段从仓库拷入（§5.1），随 app 签名、
  公证；Sparkle 原地替换 app，技能内容自动跟着升级。
- 沙盒下 `NSHomeDirectory()` 是容器，必须走 `SkillTarget.realHomeDirectoryURL`
  （passwd 里的真实家目录）；并且 `uTerm.entitlements` 里要有
  `com.apple.security.temporary-exception.files.home-relative-path.read-write`
  （`/.claude/`、`/.codex/`、`/.cursor/`、`/.codebuddy/`、`/.gemini/`、`/.local/bin/`），否则链接建不了。
  链接**目标**（app 包）不需要任何例外。
- 新增一个工具（如 CodeBuddy）要改三处：`SkillTarget` 加 case（`rawValue` 即
  `~/.<rawValue>` 目录名）、entitlements 加 `/.<rawValue>/`、技能里定位
  客户端的 `"$HOME"/.{…}/skills` 循环（`skills/uterm/SKILL.md`）。后两处漏了都不会编译
  报错，由 `SkillDefinitionTests.testEveryTargetIsCoveredByEntitlementsAndClientLookup` 兜住。
- 只认自己建的链接：同名真实文件 / 目录、指向别处的链接判 `conflict`，绝不覆盖用户文件。
  指向 `<X>.app/Contents/Resources/Skills/<slug>`（app 搬家、另一份 uTerm）或
  `…/uTerm/Skills/<slug>`（1.12 – 1.16 物化在容器里的旧副本）的链接判 `brokenLink`：
  是我们建的，只是没指向当前 app 包。
- 一份技能 `uterm`（带 `bin/utermctl`）：`SKILL.md` 讲共用部分（定位客户端、探活、开关、
  主机、主机密钥、错误码）与远程执行，文件 / 转发 / 终端会话放 `references/files.md`、
  `forward.md`、`terminal.md`，由 `SKILL.md` 直接链一层。设置页按**工具**整包装
  （`SkillManagerModel` 把一个工具下 catalog 的状态聚合成一个），不做逐技能勾选。
- **四份技能并成一份（2026-10）**：以前是 `uterm-run` / `uterm-files` / `uterm-forward` /
  `uterm-terminal` 四份，后三份靠「前置见 uterm-run」跨技能引用，单独触发时模型常漏读前置。
  旧 slug 记在 `SkillDefinition.retiredSlugs`：`reconcile` 把「只有旧链接」也当成装过，装上
  `uterm` 并摘掉 uTerm 建的旧链接（只认指向技能目录形态的符号链接，用户自己的同名东西不动）；
  设置页装/卸时也顺手摘。

### 5.1 为什么链到 app 包内

**沙盒容器里的文件，别家开发者的进程读不到。** macOS 14 起 app 数据容器受 SIP 保护；
macOS 27 发布说明（System Integrity Protection 一节）写明：访问别家开发者的 app 数据
容器 / app 组容器**不再弹窗、默认拒绝**，只能用户去「隐私与安全性」里放行；已知问题里
还写着没有 bundle ID 的进程（命令行 Agent 正是）没法单独放行某个容器，只能给完全磁盘
访问权限。1.12 – 1.16 把技能物化在 `<容器>/Application Support/uTerm/Skills/`，
没给完全磁盘访问权限的 Codex / Claude Code 顺着链接读 `SKILL.md` 直接 `EPERM`。

实测（macOS 27.0，一个 ad-hoc 签名、无 bundle ID、由 launchd 拉起的探针进程，即自己
就是责任进程、没有任何授权；对照组是有容器访问权限的 shell）：

| 操作 | 无授权进程 |
|---|---|
| 读容器里的文件（直接读，或经 `~/.claude/skills/…` 链接读） | ❌ `EPERM` |
| 列容器里的目录 | ❌ `EPERM` |
| 读容器里的偏好 plist（`utermctl` 的 `preference_value`，读不到时交给 app 把关，见 §2） | ❌ `EPERM` |
| `stat` / `lstat` 容器里的 unix socket | ✅ |
| **连接容器里的 unix socket 并收发** | ✅ |
| 顺着穿过容器的链接读最终落在 app 包里的文件 | ✅（看的是最终目标） |
| 读 / 列 `/Applications/uTerm.app` 包内、`~/.codex/…`、普通 `~/Library/Application Support/<App>/…` | ✅ |

所以 **socket 留在容器里没问题**（`control.sock` 照常可连），出问题的只是**文件内容**。
另两条约束早就有：沙盒 app 写出的每个文件都带 `com.apple.quarantine`，可执行文件直接
exec 必 `EPERM` 且沙盒进程摘不掉（`SkillInstallerTests.testAppWrittenFileIsQuarantinedAndCannotBeExecuted`
逐条量着）。包内文件随 app 签名、公证，两个问题都没有 —— 与 VS Code 的 `code` 命令同一套路。

**构建**：`uTerm`（macOS）target 的 Run Script 阶段 **`Copy utermctl CLI and Skills`**
（`CFCFCFCF000000000000F0F5`，挂在 `Set Build Number` 之后、即签名之前，`alwaysOutOfDate`）
把 `scripts/utermctl` 拷成 `Contents/Resources/utermctl`（`~/.local/bin` 链这份）与
`Contents/Resources/Skills/uterm/bin/utermctl`，把 `skills/*/` 下全部 `.md`（`SKILL.md` 与
`references/*.md`）拷进 `Contents/Resources/Skills/<slug>/`，并删掉仓库里已经没有的技能目录与文档。只在内容变了时才
`cp`，增量构建不会因此重签。**只加在 macOS target**，`uTermMobile` 没有 CLI。

**自动对齐（用户不用手动修）**：`SkillInstaller.reconcile(_:target:)` —— 一个工具下只要
有任一条 uTerm 建的链接（`installed` 或 `brokenLink`），就整包改指到当前 app 包、补上
catalog 里缺的技能；一条都没有（没装过、用户卸载了）的工具不动；冲突的位置不动、其余照样
对齐。两处触发：

1. `SkillInstaller.reconcileOnLaunch()`：`applicationWillFinishLaunching` 里（测试宿主除外）
   后台跑一次，与命令行接口开没开无关。顺带对齐开关开着的 `~/.local/bin/utermctl`，最后在
   **没有任何链接再指向**旧副本时删掉 `<容器>/Application Support/uTerm/Skills/`。老用户
   升级后第一次启动就自动改指，不用打开设置页、也不用重装。
2. `SkillManagerModel.load()`（打开设置页）：覆盖启动之后才发生的变化（运行中 app 被挪走、
   外部删了几条链接）。

**正在运行的那份 uTerm 说了算**：Debug / Release 或两份拷贝并存时，谁最后启动链接就指谁
（两份包里的技能都可读，不存在「抢坏」）。开发机上从 Xcode 跑一次 Debug，本机真实的
`~/.claude/skills` 等就会指到 DerivedData 里的构建；再启动一次 Release 即指回。测试宿主
不对齐（`BackgroundLaunchMode.isRunningInTestHost`），跑测试不会动真实目录。

**不在临时位置建链接**：app 从磁盘映像里直接运行、或下载后没拖进「应用程序」（App
Translocation，挂在随机只读路径上）时，`transientBundleReason` 拒绝安装、自动对齐也跳过，
免得把能用的链接改指到马上会消失的路径。判据是 bundle 所在卷只读，`/AppTranslocation/`
再兜一道。包里缺技能文件（构建阶段坏了）同样拒绝。

### 可选的 `~/.local/bin/utermctl`

技能自带的 `~/.<tool>/skills/uterm/bin/utermctl` 是**主路径**：装了技能就一定能跑，
不依赖用户的 shell 环境（Claude Code / Codex / Cursor / CodeBuddy / Antigravity 起的是非登录 shell，PATH 常与
用户终端里的不一样）。PATH 只是兜底，所以技能文档里的定位代码是「先 `command -v`，
再逐个工具目录循环」，两条都找不到才报错。

`BinLinkInstaller`（住在 `SkillInstaller.swift` 里，不单独成文件，省一次 pbxproj 改动）
把 `~/.local/bin` 当成第四个安装目标：默认**关**，设置页开关落 `UserDefaults` 的
`control.linkToLocalBin`（`BinLinkInstaller.enabledDefaultsKey`）；链接目标是
`uTerm.app/Contents/Resources/utermctl` —— 与技能目录里那份同源，app 升级两边同时更新。
链接绑死 app 路径，app 搬家后由启动期对齐自动改指。指向另一个 `.app` 里的
`Contents/Resources/utermctl` 或 1.12 – 1.16 物化出的 `…/uTerm/Skills/uterm-run/bin/utermctl`
（`SkillDefinition.legacyClientSlug`）的链接判 `brokenLink`（我们建的、只是指着旧位置）。冲突规则与 `SkillInstaller` 一字不差：
同名真实文件（用户自己编译的同名工具）判 `conflict` 且绝不覆盖。`~/.local/bin` 不存在就创建。

开关记在 UserDefaults 里、链接却可能被外部删掉，所以设置页 `.task` 里除了 `load()`
还会 `reconcileBinLink(enabled:)`：开关开着但链接没了就补一条，关着时什么都不做。

## 6. 真值源校验

技能文档与客户端的**唯一真值源是仓库文件**（`skills/<slug>/` 下的 `SKILL.md` 与 `references/*.md`、`scripts/utermctl`），
Swift 里不再有它们的副本。`uTermTests/Core/Skills/SkillDefinitionTests` 守着构建产物：

- 宿主 `uTerm.app` 包内每份文档、两份 `utermctl` 与仓库文件**逐字节相同**，客户端带
  可执行位，旧技能目录不再残留（守着「Copy utermctl CLI and Skills」阶段没漏、没坏）；
- `SkillDefinition.catalog` 与仓库 `skills/` 下的目录一一对应（构建按目录拷、安装按 slug 链）。

```sh
make check-skills     # = check-cli + 只跑 SkillDefinitionTests / SkillInstallerTests
```

发版 skill 要跑它。`check-skills` 依赖 `check-cli`，后者不需要 Xcode、也不需要 uTerm
在跑：`scripts/utermctl-selftest.py` 起一个假的 Unix socket 服务端，把每个子命令都过
一遍，校验请求编码（字段名 / action rawValue 与 `ControlProtocol.swift` 对得上）、
输出格式化与退出码映射。

`SkillDefinitionTests` 还顺手挡住几类文档漂移：frontmatter 的 `name` 必须等于 slug、
`description` 不能空（那是模型决定用不用这份技能的唯一依据）、文档里出现的每个
`"$UTERMCTL" <子命令>` 都得在客户端里真有、每份 reference 都由 `SKILL.md` 直接链到且 reference
之间不互链。

## 6.1 客户端 `utermctl`

Python 3 标准库，零依赖，`scripts/utermctl` 是真值源（构建期拷进 app 包的两处）。

```
utermctl ping | hosts | host-key -H H | trust -H H --fingerprint F
utermctl run -H H [-c CMD | -- CMD…] [--timeout N] [--max-duration N] [--max-lines N] [--max-bytes N]
utermctl run-many -H A -H B [-c CMD | -- CMD…]
utermctl quick-commands | quick-run NAME [-H H…]
utermctl sftp ls|stat|cat|mkdir|rm|rmdir|mv|chmod -H H <路径…>
utermctl sftp put -H H <本地> <远端> [--force | --resume] [--parallel N]
                     [--no-verify] [--quiet]
utermctl sftp get -H H <远端> <本地> [同上]
utermctl forward list|start|stop|remove [-r RULE] [-H H]
utermctl forward add -H H -n NAME --kind local|remote|dynamic --listen [HOST:]PORT
                     [--dest HOST:PORT]
utermctl terminals | terminal read|send|open [-t ID] [--lines N] [--enter] [-H H]
utermctl disconnect [-H H]
```

几条与 uTable 不同的地方：

- **本地文件由客户端打开**。沙盒里的 uTerm 打不开任意本地路径，所以 `sftp get` 是客户端
  建好 `<本地>.part`（已存在则拒，除非 `--force` / `--resume`），`sftp put` 是客户端打开
  本地文件，再把 fd 随请求交给 uTerm（见下面「客户端传输」）。
- **`get` / `put` 走单独的一条路**：要 stat、交 fd、收进度、续传、校验，不走
  `make_request` 那条一请求一响应的路，而是 `main()` 里单独分出去的 `do_get` /
  `do_put`；它们自己合成一条 `{ok, code, message, transfer:{…}}` 的本地响应交给
  `render_transfer`，退出码仍走同一张 `exit_code_for` 映射表。
- `--` 之后的 argv 用 `shlex.join` 拼成 `command`，省掉引号地狱；也接受 `-c "…"`。
  argv 里的 `--` **原样保留**（`grep -- --include`、`git log -- <路径>` 都要它）；
  实测 argparse（3.9 / 3.10 / 3.13 / 3.14，含子解析器）只吃掉分隔用的第一个 `--`，
  客户端只对开头那一个做防御性剥离。所以 `--format` 之类客户端自己的选项**必须写在
  `--` 之前**。
- `-H/--host` 在 `run-many` / `quick-run` 上可重复，编成 `hosts` 数组。
- `table` 格式对 `hosts` / `entries` / `rules` / `terminals` / `quickCommands` 各出一张
  表；`run` / `run-many` 改成逐主机分段打印（输出削到 60 字符的表格没人看得懂），
  `terminal-read` 直接打印屏幕行，`sftp cat` 直接打印文本。`json`（默认）一律原样。
- 失败响应**一律原样打 JSON**，不管 `--format` 是什么 —— 模型要读 `hostKey.fingerprint`
  这类字段。唯一例外是 `run_failed` / `run_partial_failure`：这两个码带着完整的
  `results`，非 json 格式照常逐主机渲染再附上 message，否则表格就被 JSON 吞了。

### 客户端传输（`get` / `put`）

逐动作的请求形状：

| 动作 | 客户端发的字段 | 什么时候 |
|---|---|---|
| `sftp-stat` | `host`、`path` | `get` 每次都先发（远端身份 = size + mtime，续传前核对） |
| `sftp-get` / `sftp-put` | `host`、`path`、`parallel`（+ `put` 的 `force`，+ 续传的 `ranges`），**`SCM_RIGHTS` 挂一个 fd** | 一次传输一条；可重试的失败自动再发，只补缺的区间 |
| `run` | `host`、`command`、`timeoutSeconds: 1800`（静默；sha256sum 算完前不出声）、`maxLines: 5` | 文件 ≥ 8 MiB 且没给 `--no-verify` 时发一条 |

- **交 fd**：`sock.sendmsg([payload], [(SOL_SOCKET, SCM_RIGHTS, array("i", [fd]))])`，没发完的
  部分 `sendall` 补齐。`get` 的 fd 是 `<本地>.part`（`O_RDWR | O_CREAT`，非续传再加
  `O_TRUNC`），`put` 的是本地文件（`O_RDONLY`）。
- **读响应**：一行一行读，空行是心跳，`event == "progress"` 的交给进度回调，其余那一行
  是结果（兜底：没读到单行结果时把剩下的行拼回去再解一次）。
- **续传状态 sidecar**（v2）：`<本地>.utermctl-transfer.json`，字段 `version` / `direction` /
  `remotePath` / `localPath` / `totalBytes` / `identity` / `done`（已完成区间，合并存）/
  `updatedAt`。进度行一到就并进 `done`，节流 0.5 s 原子落盘（写 `.tmp` 再
  `os.replace`），整趟结束（成功或校验不过）删掉。`identity` 是 `put` 的本地
  `size + mtimeNs` 或 `get` 的远端 `size + modifiedAt`。写不了状态文件不算失败，但在
  `verifyNote` / stderr 里说明「这趟不能续传」。
- **自动续传与重试**（`run_transfer`）：第一次按原样发（`put` 的覆盖语义就在这次定）；
  之后每次重试只要 `done` 非空就改发 `ranges = 缺的区间` 且去掉 `force`，服务端不再动
  已有内容；`done` 还是空的（比如 `server_busy` 在开工前就拒了）就原样重发。普通可重试
  码 2 次（0.5 / 1 s），`server_busy` / `empty_response` 约 1 分钟（0.5 / 1 / 2 s 后每
  4 s 一次）。门禁 / `*_not_found` / `host_key_*` / `file_exists` / `local_*` 不重试。
- **`--resume`**：与 `--force` 互斥（argparse 层报错，退出码 2）。有 sidecar 且身份对得上
  → 只请求缺的区间；身份对不上、没有 sidecar、`get` 的 `.part` 不见了 → 拒绝（退出码 2）。
  `checksum_mismatch` 不在 `--resume` 的能力范围内（区间都传完了，错的是内容）。
- **落盘与改名**：`get` 成功后先 `removexattr("com.apple.quarantine")`（沙盒进程写过的
  文件会被打上），再校验，通过了才 `os.replace` 成目标名 —— 「目标名存在」== 完整且
  校验过。
- **校验**：本地 `hashlib.sha256` 流式，远端 `sha256sum -- <shlex.quote(path)>
  2>/dev/null || shasum -a 256 -- …`，取第一个 64 位十六进制串。只对 ≥ 8 MiB 的文件做
  （`run` 归 mutations 开关管，不该拖累小文件的只读下载）。远端两个工具都没有 →
  `verified: false` + 说明，不算失败；对不上 → 本地码 `checksum_mismatch`，退出码 1。
- **进度**在 stderr（stdout 留给 JSON）：tty 上 `\r` 原地刷新，非 tty 或 `--quiet`
  时不刷，结束都打一行汇总。
- **EOF 分帧的一个坑（macOS）**：请求以 `shutdown(SHUT_WR)` 收尾，而 macOS 上
  AF_UNIX 的 `shutdown(SHUT_WR)` **唤不醒一个已经睡在阻塞 `recv()` 里的对端**。
  真的 `ControlServer.readRequest` 不吃这一发（`poll(POLLIN)` + deadline +
  `recvmsg(MSG_DONTWAIT)`）；`utermctl-selftest.py` 的假服务端用短超时轮询
  （`recv_request()` / `recv_request_with_fds()`）。以后写假服务端别再用裸阻塞 recv。

成功输出：

```json
{"ok": true, "code": "ok", "message": "下载完成：…",
 "transfer": {"action": "get", "localPath": "…", "remotePath": "…",
              "bytes": 0, "totalBytes": 0, "parallel": 8,
              "seconds": 0.0, "mbps": 0.0, "resumedFrom": 0,
              "sha256": null, "verified": false, "verifyNote": null,
              "incomplete": false, "resumable": false,
              "statePath": null, "partPath": null}}
```

失败时后四个字段才有内容：`incomplete` = 目标现在是半截的、`resumable` = 有可用的
续传状态、`statePath` = sidecar 路径、`partPath` = `get` 的半成品路径。

`--format table` 给一张「字段 / 值」两列表；失败仍一律原样打 JSON。

退出码：

| 码 | 含义 |
|---|---|
| 0 | `ok` |
| 1 | 其它非 ok（`operation_failed` / `invalid_request` / `not_implemented` / `file_exists` / 客户端的 `checksum_mismatch` …） |
| 2 | 连不上 uTerm（`uterm_not_running` / `uterm_socket_stale` / `socket_path_too_long` / socket 错误 / 空响应 / `server_busy`）、客户端的本地 I/O 失败（`local_read_failed` / `local_write_failed` / `local_failure`），或客户端自己的前置检查没过（本地文件不存在 / 本地目标已存在 / `--resume` 无从续起或身份对不上或没有续传状态 / `--parallel` 超范围 / `--force` 与 `--resume` 同时给） |
| 3 | 门禁：`control_disabled` / `mutations_disabled` / `host_sftp_only` |
| 4 | `*_not_found` / `*_ambiguous` |
| 5 | `connect_failed` / `auth_failed` / `host_key_*` / `forward_failed` / `*_refused` |
| 6 | `command_timeout` / `handler_timeout` / `client_timeout` |
| 7 | `run_partial_failure`（多主机有成有败；全失败是 `run_failed`，归 5） |

## 7. 测试

| 文件 | 覆盖 | 状态 |
|---|---|---|
| `uTermTests/Core/Control/ControlProtocolTests.swift` | Codable 往返（含 `force` / `ranges` / `parallel`）、续传字段的线上形状、进度行的线上形状、socket 路径 < 104、rawValue 全 kebab、每个动作有归组、门禁矩阵、上限常量（请求上限装得下上万个续传区间、并行通道默认 ≤ 封顶 ≤ 每主机池子）、`file_exists` 在错误码总表里 | ✅ |
| `Core/Control/ControlServerTests.swift` | 并发上限、I/O 超时、handler 超时后晚到不双关 fd、stop 时 unlink、路径超长不 bind | ✅ 8 例 |
| `Core/Control/HostResolverTests.swift` | 三级解析 + 歧义 + UUID 直达 | ✅ 11 例 |
| `Core/Control/ControlHandlerTests.swift` | 门禁矩阵（两开关 × sftpOnly × 各动作）、host-key 三态、超时语义、run-many 顺序 / 去重 / 三态成败 / 逐条 hostKey、quick-run 写日志 | ✅ 40 例 |
| `Core/Control/ControlConnectionPoolTests.swift` | 懒建 / 复用 / **exec 并发冷启动只建一条** / 失败清占位 / 空闲回收 / disconnect / disconnectAll / 质询缓存与 trust 配对；**SFTP 多通道**：4 并发 → 4 条会话、第 5 个等待并复用归还那条、顺序借还只用一条、`withSFTP` 抛错也归还、`disconnectAll` 关全部、借出中的不被空闲回收、建连失败还名额 | ✅ 19 例 |
| `Services/SSH/SFTPSessionPipelineTests.swift` | 流水线的**并发形状**（可注入的假文件计数）：切片恰好覆盖不重叠、每片 ≤ 32 000 B、base offset、在途数 ≤ inFlight 且真用满、`inFlight: 1` 退化成串行、某片失败抛原错误并取消其余、空写不发请求；读的分段拼装、offset/length、短读补发、EOF 短返回、越 EOF 空、取消即停 | ✅ 14 例 |
| `Services/SSH/SFTPSessionServerIntegrationTests.swift` | 对**进程内 Citadel SFTP server**（真 TCP + 真 SSH 握手 + 真 SFTP 线格式，内核分配端口）：20 MiB 上传→下载 sha256 一致、本地文件流式往返、8 段并行 `writeRange(.write)` 拼成整文件、`readRange` 精确切片 + 越 EOF 短读 | ✅ 4 例（20 MiB 往返 0.5 s） |
| `Core/Control/BoundedExecTests.swift` | 不可取消任务下超时能返回、结果晚到不崩不泄漏 | ✅ 5 例 |
| `Core/Control/ControlSFTPHandlerTests.swift` | 十个 `sftp-*` 的正常路径、上限、错误映射、门禁；**传输**（fd 挂进 `ControlRequestContext`，引擎跑在 `MockSFTP` 上）：`get` 整份写进 fd 且进度账覆盖全文件、`ranges` 只补那段且区间外不动、越界区间被拒、没交 fd / `parallel` 超范围是 `invalid_request`、远端不存在是 `file_not_found`；`put` 经 fd 读进远端（首次 `create`、之后一律 `write`）、默认不覆盖、`force` 覆盖并截断、续传只写区间不截断、写阶段失败不误报 `file_exists`、打开阶段失败仍兜底成 `file_exists`；传输借几条会话就还几条 | ✅ |
| `Core/Control/ControlServerTests.swift`（传输相关） | `SCM_RIGHTS` 交来的 fd 到得了 handler 且是同一个文件；进度行排在响应前、一行一个 JSON、收尾时攒着的最后几段不丢；传输槽位满时新传输 `server_busy` 而 `ping` 照进 | ✅ |
| `Core/Control/ParallelTransferBenchmarkTests.swift` | 引擎压测（默认跳过，`TEST_RUNNER_UTERM_BENCH_SSH_PORT`）：扫「通道 × 在途 × 窗口」，第一次下载与远端 `sha256sum` 比对 | 手动 |
| `Core/Control/ControlLiveServeHarnessTests.swift` | 端到端服务夹具（默认跳过，`TEST_RUNNER_UTERM_SERVE_SSH_PORT`）：测试宿主里的真服务端，沙盒外用真 utermctl 打 | 手动 |
| `Core/Remote/RemoteFileServiceTests.swift` | 被控端文件服务，临时目录里真做：列目录 / 属性 / 分段读写 / 新建不覆盖 / 原子写与 `ifMatch` / 建删改名 / 权限 / 复制 / 链接 / 哈希 / 扩展属性；按行读与截断落在行尾、`grep`（正则、字面量、上下文、过滤、上限）、`find`、目录树、`.gitignore`；`edit` 唯一性、补丁（试打 / 打上 / 冲突不留 `.rej`）、等变化不被调用前的写入骗到；跑命令的退出码 / 静默超时杀进程 / 总时长上限 / 只留结尾；坏请求回错误、文本应答压缩 | ✅ 25 例（git 那条沙盒里跳过） |
| `Core/Remote/RemoteMacFilesEndToEndTests.swift` | 真实链路（本机回环、真握手配对）上的 `RemoteMacFileProvider`：浏览与改动、5 MiB 上传下载逐字节一致、错误类别过链路不丢、被控端关开关即拒绝且不断开、老版本本地挡住、断链时在途请求失败；命令行 handler（假的 `ControlRemoteMacs`）：列 / 读 / 搜、写 / 改 / 跑命令 / 超时、第二个开关、fd 传输与续传区间、找不到 Mac；文件窗口模型（从主目录开始、共享 `FileBrowserModel` 的进目录 / 建 / 传 / 改名 / 删、被拒与老版本的说明） | ✅ 13 例 |
| `Core/Remote/RemoteFilesHarnessTests.swift` | 两台 Mac 联调夹具（默认跳过，`TEST_RUNNER_UTERM_FILES_HARNESS_SERVE` / `…_CONNECT`） | 手动 |
| `Core/Control/ControlForwardHandlerTests.swift` | 规则解析（`HostResolver` 语义）+ 歧义、`forward-list` 拼装、`stop` 幂等、`start` 端口预检（规则冲突 vs 知名端口）、挑战补记进池、`.inactive` 立刻收工 | ✅ 25 例 |
| `Services/SSH/Forwarding/ForwardingCoordinatorRelayTests.swift` | 会话复用时审批走**当前** relay；teardown / 未知主机一律拒绝 | ✅ 3 例 |
| `Core/Control/ControlTerminalHandlerTests.swift` | 终端四动作的门禁与语义（真 `TerminalSession` + 离屏 `TerminalView`）、超长空白尾巴仍读得回内容、断开 / 释放的会话退出 `terminals` | ✅ 25 例 |
| `Features/Workspace/TerminalSessionRegistryTests.swift` | 登记 / 注销 / 前缀解析 + 歧义 / `waitForSession` / 幻影行清扫 / 焦点现算 / 断线自动注销 | ✅ 22 例 |
| `Features/Workspace/WorkspaceTerminalTitleTests.swift` | `title` 取标签自定义名、事后 `syncTerminalTitles()` 补推 | ✅ 4 例 |
| `App/AppServicesGateTests.swift` | 应用级服务只安装一次、第一个出现的窗口装（不必是 Welcome） | ✅ 3 例 |
| `Features/Terminal/TerminalScreenReaderTests.swift` | 读屏行数、尾部空行裁剪、字节上限 | ✅ 12 例 |
| `Core/Skills/SkillDefinitionTests.swift` | **包内技能 / 两份 `utermctl` ↔ 仓库文件逐字节一致**（守着「Copy utermctl CLI and Skills」阶段）、catalog ↔ `skills/` 目录、frontmatter、子命令面 | ✅ 12 例 |
| `Core/Skills/SkillInstallerTests.swift` | 临时 home + 假 app 包下安装 / 卸载 / 冲突 / `~/.local/bin` 链接；**直接链到包内**、自动对齐（容器旧链接改指 + 补缺、app 搬家、另一份 uTerm、冲突旁路、打开设置页即对齐、没装过的工具不动）、临时位置 / 包内缺技能时拒装且不动既有链接、旧副本无人引用才删、沙盒摘不掉自己 quarantine 的实测 | ✅ 32 例 |
| `scripts/utermctl-selftest.py`（纯 Python，非 XCTest） | 客户端的请求编码（含命令里的 `--` 原样保留）/ 格式化 / 退出码 / 服务端中途拒收时先读响应 / **按需启动决策**（偏好读不到 → `None`、带 `--launch-source cli` 请求启动、`open -W` 返回 0 即被拒、就绪后结束等待） | ✅ 127 断言 |

跑法（隔离 DerivedData、离线依赖，参考 memory `uterm-tests-cli-uncompilable`）：

```sh
xcodebuild build-for-testing -project uTerm.xcodeproj -scheme uTerm \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  -disableAutomaticPackageResolution -skipPackageUpdates -enableCodeCoverage NO
xcodebuild test-without-building -project uTerm.xcodeproj -scheme uTerm \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  -disableAutomaticPackageResolution -skipPackageUpdates -enableCodeCoverage NO \
  -only-testing:uTermTests/ControlProtocolTests
```

**不要**给这两条加 `CODE_SIGNING_ALLOWED=NO`（测试宿主要签名才跑得起来）。
测试期的 CloudKit「Service Unavailable」是常态噪声，不是失败。

## 7.1 Citadel 的 SFTP 抛错形状

归类 SFTP 失败时**只认 `SFTPError.errorStatus` 是不够的**，真机上一条都命中不了：

- `SFTPClientInboundHandler.channelRead` 对一切非 `ok` / `eof` 的响应直接
  `promise.fail(status)`，抛出来的是**裸的 `SFTPMessage.Status`**；
- 全库只有 `SFTPClient.setAttributes`（与 `openFile` 的一处）显式包成
  `SFTPError.errorStatus(_:)`。`remove` / `rmdir` / `rename` / `createDirectory`
  甚至**根本不检查响应**（`let _ = try await sendRequest(...)`），失败完全靠上面
  那条 promise 失败传出来；
- `SFTPMessage.Status` 是 `Error` 但**不是** `LocalizedError`，它自己声明的
  `localizedDescription` 只在静态类型是 `Status` 时可见。经 `any Error` 拿到的是
  NSError 桥接的「操作未能完成」，所以文本兜底匹配也救不了。

结论：`ControlFilePayloadBuilder.sftpStatus(of:)` 两种装法都认，`errorDetail(for:)`
优先给服务端自带的 message + `SSH_FX` 码。`SFTPMessage.Status` 的 memberwise init
是 internal，测试构造不出来 —— `ControlSFTPHandlerTests` 用 `@testable import Citadel`
拿到它。

## 8. 已知限制

合并 Wave 3（三支修复分支）时逐条复核过、**有意留着**的缺口。改动相关代码前先读这里。

- **`ControlConnectError.algorithm` 生产路径恒为空串。** `ControlConnectionPool` 从
  `HostKeyChallenge` 只拿得到指纹，拿不到密钥算法，于是失败响应里
  `hostKey.algorithm` 是 nil（`response(for:)` 把空串映射成 nil）。`host-key` 动作走
  `KnownHost.keyTypeRaw`，那条路径**有**算法。模型只需要指纹去 `trust`，所以不补；
  要补的话得让 `HostKeyVerifier` 把算法一起带进质询。
- **`sftp-cat` 超限不截断。** `cat` 是先 `stat` 再决定：声明大小超 1 MiB 直接回
  `file_too_large`，让模型改用 `sftp-get`（不限大小）或 `run -- tail`。`ControlFilePayload.truncated` 只在「stat 之后文件又长大了」
  的竞态里才为 true。（`SFTPProviding` 现在**有**部分读原语 `readRange`，`cat` 只是
  刻意不用它做截断 —— 半截文本比明确的拒绝更容易误导模型。）
- **1 MiB 的子通道窗口是**每条 SSH 连接**级别的，PTY 与端口转发通道一并吃到。**
  `SSHClientFactory.channelWindowOptions` 把 `maximumPacketSize` 提到 1 MiB，是为了
  让 SFTP 的读流水线（64 × 32 000 B ≈ 2 MiB 在途）不被 NIOSSH 默认的 128 KiB 入站窗口
  卡住（否则只放得下 4 个在途读，吞吐砍到 1/16）。代价是**同一连接上的每条子通道**
  最多能多缓冲约 1 MiB 还没被读走的数据：终端 PTY 上一条 runaway 的输出（`yes`、
  `cat 大文件`）在按下 Ctrl-C 之后，还得先把已经在窗口里的这最多 1 MiB 吐完才停，
  比 128 KiB 窗口时慢一截；端口转发通道同理，慢消费者那侧的内存峰值也高一些。
  纯粹是缓冲变大，没有行为变化，所以有意留着 —— SFTP 的吞吐收益（同一台机器
  8 MiB put 从 3.9 s 降到亚秒级）远大于这点滞后。要单独给 PTY 调小得让
  NIOSSH 支持 per-channel 窗口，它现在把窗口钉死成连接级的 `maximumPacketSize`。
- **`terminal-open` 可能回空 `terminals`。** 开窗是同步返回的，会话是异步注册的：
  6 秒内没等到就仍回 `ok` + 空数组 + 一句解释（窗口确实开了）。客户端此时打
  `message` 而不是空表。
- **`terminal_disconnected` 只剩竞态窗口。** 会话被关掉 / 断开后就不在 `terminals` 里，
  拿旧 id 去操作得到的是 `terminal_not_found`；`terminal_disconnected` 只在「列表之后、
  写入之前正好断了」（`injectInput` 抛出）时出现。协议里保留这个码是对的，但别指望它
  是「会话已关」的常规信号。
- **`forward-start` 的主机密钥校验只在新建会话时发生。** `ForwardingCoordinator`
  按 serverID 缓存转发会话；只要它还持有该主机的活会话（**哪怕规则已经 stop**），
  再 `forward start` 不会重新握手，也就不会重新校验密钥。真机上密钥轮换后
  `run` / `trust` 都正确拒绝、而 `forward start` 直接成功，就是这个原因 ——
  这是既有会话复用的语义，不是转发这条路上少做了校验。要让它重新校验，得先让
  该主机的转发会话真正断掉（关掉全部规则并等回收，或重启 uTerm）。

- **Citadel 自带的 SFTP *server* 会吞掉 delegate 抛的错。**
  `SFTPServerInboundHandler.openFile` 只 `map` 成功路径，没有 `whenFailure` ——
  delegate 一抛错，服务端什么都不回，客户端的 promise 永远不完成（整条用例挂死）。
  只影响**测试用的**进程内服务端（`SFTPSessionServerIntegrationTests`），生产从不
  跑 Citadel 的 server 侧。所以那套集成用例的假服务端**不能靠抛错**模拟 EXCL 冲突，
  `create` 撞已存在文件的语义只在 `ControlSFTPHandlerTests`（MockSFTP）里验。
  不改 Citadel（vendored 的理由只有 manifest，见 `CLAUDE.md`）。

- **技能直链 app 包内（§5.1）之后还没在真实分发形态下走过**：DMG 下载安装的 Release 版
  升级后首次启动的自动改指、以及真实的 Codex / Claude Code 进程（责任进程可能是终端 app）
  读包内技能，目前只有 launchd 无授权探针的实测。

- **真机联调（1.12.0 后）已做，发现的问题在 1.12.1 修掉：** 当时 app 写出的 `utermctl` 带
  `com.apple.quarantine` 导致直接执行 EPERM（1.12.1 改成链到包内脚本，见 §5.1）、顶层
  `exit N` 被误报成 `connect_failed`、SFTP 错误码没认出 Citadel 抛的裸
  `SFTPMessage.Status`、`sftp stat` 缺权限位、`--format table` 里布尔 `false`
  是空白。仍未在真环境走过的只剩 `terminal-open` 的端到端开窗。

### 登录 Helper 的签名校验

主 App 启用 App Sandbox 时，内嵌登录 Helper 也必须在实际签名中包含
`com.apple.security.app-sandbox = true`，否则 `SMAppService.register()` 会被系统拒绝。
`make verify-distribution-signing` 会检查导出包里的 Helper，避免只有构建通过、
实际登录项却不能注册。登录启动开关以系统状态为准；注册失败回退，待批准单独提示。
