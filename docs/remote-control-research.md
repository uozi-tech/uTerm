# uTermMobile 远程控制 uTerm Host（终端 + 远程桌面）调研

> **2026-11-10 说明：终端引擎已换成 GhosttyKit（画面）+ libghostty-vt（影子终端），SwiftTerm 与 `vendor/SwiftTerm` 已删除。**
> 本文里终端镜像以 SwiftTerm 为对象的部分（§2 的快照序列化成 VT 流、S4 探针、`vendor/SwiftTerm` 的补丁 #6 / #7、
> 「只带最近 1000 行」）是旧引擎上的做法，正文保留作历史。现在的做法：快照是引擎的二进制格式（消息 47 `terminalSnapshot`），
> 握手带引擎版本、两端不同就不接入终端，见 `docs/ghostty-migration-plan.md` 与 `docs/ghostty-eval/migration-log.md`。
> 字节流 tee 的位置、远程桌面、中继各节不受影响。

> 2026-11-02 · 范围：iPhone / iPad 上的 uTermMobile 控制一台运行 uTerm 的 Mac，两件事：**接管 Mac 上的终端会话**、**远程桌面**。首要约束是性能。
> 文中标「实测」的数字是在测量用的 Mac（Apple 芯片，macOS 27.2） 上跑出来的；标「估」的是预算，要靠第 6 节的 spike 去证实或推翻。

## 0. 一页结论

| | 推荐做法 | 为什么 |
|---|---|---|
| 终端 | **字节流镜像为主 + 状态快照兜底**（混合）。Mac 端在把字节喂给自己的 SwiftTerm 的同一位置 tee 给手机；手机接入、掉线重连、积压溢出时，改发一份「屏幕状态序列化成 VT 序列」的快照 | 正常打字时的附加延迟只有一次局域网往返；`cat` 大文件这类突发输出被快照截断，带宽有上限；快照与后续字节都在 MainActor 上产生，天然无缝、不重不漏 |
| 远程桌面 | **自研：ScreenCaptureKit → VideoToolbox 低延迟硬编 → QUIC → 硬解 → AVSampleBufferDisplayLayer**，光标与输入走独立通道 | 本机实测低延迟模式单帧编码 p50 ≈ 6 ms（1080p），比普通模式快一倍、码流小一半多；macOS 自带的 High Performance 屏幕共享只支持 Mac 对 Mac，iPhone 只能用 VNC 标准模式，画质和延迟都不够 |
| 传输 | **一条 QUIC 连接承载一切**：控制、每个终端各一条 stream、视频一条 stream（第二期改 datagram）。Bonjour 发现，长期设备密钥配对 | 多 stream 避免终端之间、终端与视频之间的队头阻塞；TLS 1.3 内建；Network.framework 原生支持 |
| 跨网 | **已改**：运行时优先打洞、打不通走用户自建的 TCP 中继；先实现中继。见 §15 | 苹果没有第三方可用的中继；中继是所有网络下的兜底，打洞失败也不影响跨网可用 |

**两个最大的风险**：①沙盒 + Developer ID 签名的 uTerm 能否同时拿到「屏幕录制」与「发送事件」两项 TCC 授权——**2026-11-02 已用 S1 探针证实可以**（见 §3.7），uTerm 主进程即可完成，不需要辅助进程；标准授权流程能走通，但用户打开开关后必须重启 uTerm 才生效，产品引导要专门处理。②SwiftTerm 的屏幕状态能否序列化得足够准——**S4 已证实可以逐格还原**（5 份真实语料 400 个切点，快照与续播均 100% 一致），但需要一个小 vendor 补丁（新增一个扩展文件 + 三处 `private` 改 `internal`），见 §2.5。

---

## 1. 现有可复用部件

| 部件 | 位置 | 复用方式 |
|---|---|---|
| 局域网发现 + 加密握手 | [LANSyncCoordinator.swift](../uTerm/Core/Sync/LANSyncCoordinator.swift)（`NWListener` + `NWBrowser`，`_uterm-sync._tcp`）、[LANSyncCrypto.swift](../uTerm/Core/Sync/LANSyncCrypto.swift)（X25519 + HKDF + ChaChaPoly，配对码作 salt） | 发现/配对的思路照搬；**加密不照搬**：它每帧把信封 JSON 编码、密文再 base64 进 JSON，对同步够用，对每秒几百帧的终端/视频是纯开销。远控改用 QUIC 自带的 TLS 1.3 |
| 长度前缀分帧 | [LANSyncTransport.swift](../uTerm/Core/Sync/LANSyncTransport.swift) `LANSyncFrameBuffer` | 若第一期走 TCP 而非 QUIC，可直接复用；用 QUIC 时只在控制 stream 上用 |
| 跨窗口终端会话表 | [TerminalSessionRegistry.swift](../uTerm/Features/Workspace/TerminalSessionRegistry.swift) | 手机端「Mac 上有哪些终端」的数据源（`entries` 本身是 `@Observable` 的 Sendable 值数组，可直接推增量）；`openTerminalWindow` 可用来「在 Mac 上开新终端」 |
| 会话本体 | [TerminalSession.swift](../uTerm/Features/Terminal/TerminalSession.swift) | tee 点、快照、写入、resize 都在这里（见 §2.3） |
| 终端后端抽象 | [TerminalBackend.swift](../uTerm/Services/SSH/TerminalBackend.swift)、[MobileTerminalTransport.swift](../uTermMobile/Screens/Terminal/MobileTerminalTransport.swift) | 手机端新增一个 `RemoteHostTerminalBackend: TerminalBackend`，从工厂注入，**`MobileTerminalController` 与 SwiftTerm 视图零改动** |
| CLI 控制面 | [ControlHandler.swift](../uTerm/Core/Control/ControlHandler.swift)（`terminals` / `terminal-read` / `terminal-send` …） | 它的「门禁三层」「凭据不出应用」两条纪律直接继承；但 `terminal-read` 是**按需拉文本快照**，不是流，不能拿来做实时镜像 |

---

## 2. 终端远控

### 2.1 要解决的场景

1. 手机接上 Mac 上**正在跑**的会话（长任务、Agent 正在干活、只有 Mac 能到的内网主机），看实时输出、能打字。
2. 手机让 Mac 新开一条会话（走 Mac 的网络和跳板机，而不是手机自己连）。

如果只是「手机想连那台服务器」，手机本来就能自己 SSH 过去（已有），不需要远控，延迟还少一跳。远控的价值在「同一条会话」和「只有 Mac 够得着」。

### 2.2 三种做法对比

| | A. 屏幕文本轮询（现有 `terminal-read` 那套） | B. 字节流镜像 | C. 状态同步（mosh SSP 式：Mac 端仿真器为准，按帧发屏幕 diff） |
|---|---|---|---|
| 打字回显附加延迟 | 轮询间隔（≥ 100 ms） | 1 × 局域网 RTT | 1 × RTT + 帧间隔 |
| `cat 100MB` 的带宽 | 有上限 | **100 MB 全量** | 有上限（屏幕大小 × 帧率） |
| 颜色/属性/光标/鼠标模式 | 丢失 | 完整 | 要自己编码 |
| 手机端复用 SwiftTerm | 否 | **是，原样喂字节** | 否，要自己画格子，或把 diff 再转成 VT |
| 实现量 | 已有 | 小 | 大 |

**推荐 B + C 的一个子集**：平时走 B；只在三种时刻发一份「整屏状态」（即 C 的全量帧，不做增量 diff）：

- 接入时（手机还什么都没有）；
- 手机从后台回来 / 重连时；
- **发送队列超过阈值时**：丢弃积压字节，标记脏，等队列排空后发一份新快照。突发输出因此被截成「最多每个 RTT 一份快照」，带宽有上限；这就是 mosh 的核心收益，但不用实现增量 diff。

快照就是「把当前屏幕重放成一段 VT 序列」：清屏 → 逐行输出带 SGR 属性的字符 → 恢复光标位置/样式 → 恢复模式（备用屏、应用光标键 `applicationCursor`、括号粘贴 `bracketedPasteMode`、鼠标模式 `mouseMode`）。手机端的 SwiftTerm 喂进去就得到同一张屏，**手机端不需要第二套渲染路径**。

### 2.3 Mac 端的 tee 点：放在 `flushPendingOutput`，不放在读流的地方

现在 Mac 端的数据路径：

```
SSH outputStream ──(detached feedTask)──▶ TerminalOutputBuffer(4 MB)
                                              │  MainActor flush 循环：
                                              │  空闲时 waitForData 立即唤醒，
                                              │  活跃时每 16 ms 一批，≤ 32 KB
                                              ▼
                              terminalView.feed(byteArray:)  ← Mac 的仿真器
```

tee 必须放在 `flushPendingOutput` 里、`terminalView.feed` 的旁边，理由有三：

1. **顺序正确性**。手机与 Mac 的仿真器必须在**同一个字节位置**看到 resize，否则折行不同、此后全屏错位。resize 也在 MainActor 上发生，tee 放在 feed 旁边，就能把 resize 事件以同一顺序插进同一条流。放在 detached 的读流循环里则做不到，因为那里的顺序与 Mac 仿真器实际处理的顺序无关。
2. **快照无缝**。快照（读 Mac 仿真器）与之后的 tee 都在 MainActor 上，「拍快照 → 注册订阅者」在同一个 MainActor 回合里完成，中间不可能插进字节，不会重、也不会漏。
3. **不增加打字延迟**。空闲态第一包字节到达后 `waitForData` 立即唤醒 flush，所以单字符回显不会多等 16 ms；16 ms 合批只发生在持续输出时，这时多一批延迟无所谓。

tee 本身只做一件事：把这批字节 `append` 进每个订阅者自己的有界队列（不加锁拷贝一份 `Data`），**绝不反压 Mac 自己的终端**。队列满即走 §2.2 的「丢弃 + 稍后快照」。成本参照 [TerminalSession.swift](../uTerm/Features/Terminal/TerminalSession.swift) 注释里量过的数：线上平均每批 433 B，6 个后台标签合计 142 KB/s；多一次拷贝相对 23 ms/MB 的 VT 解析可以忽略。

写入方向：手机按键 → `backend.write(Data)`。现有的 `injectInput(_ text:)` 是给 CLI 的文本注入，远控需要的是**原始字节**（方向键、Ctrl 组合），直接调 `backend.write`，绕开文本路径。

### 2.4 尺寸：同一时刻只能有一个尺寸

字节镜像要求两端仿真器 cols × rows 完全相同。三种策略：

| 策略 | 体验 | 推荐 |
|---|---|---|
| **镜像（默认）**：手机按 Mac 的尺寸渲染，字号自适应宽度，横屏 + 捏合缩放、平移 | Mac 不受影响；竖屏上 120+ 列的终端字会很小 | 默认 |
| **接管**：手机把 PTY resize 成自己的尺寸，Mac 端那个 pane 进入「被接管」态（按手机尺寸居中显示，四周留边） | 手机上好用；Mac 上同时看会别扭 | 手机上一个开关，断开时自动还原 |
| tmux 式「取最小」 | 两边都受限 | 不做 |

接管时要走现有的 80 ms resize 防抖，避免旋转屏幕时连发 SIGWINCH 让 vim/htop 反复重画。

### 2.5 快照序列化（S4 已实测，2026-11-02）

**结论：可行，逐格还原；但只用公开接口不够，必须给 vendor 打一个小补丁。**补丁很小：在 `vendor/SwiftTerm` 里**新增一个文件**（模块内扩展，能读 internal 状态），再把三个 `private` 改成 `internal`，不改上游任何逻辑。按惯例记进 `UTERM-PATCHES.md`。

#### 实验方法

用 python 的 pty 在 100×30 的伪终端里驱动真实程序，录下原始字节：shell（彩色 `ls`/`git log`、CJK、emoji、组合字符、长行折行、`\r` 进度条、制表符、256 色/真彩、反显/删除线/斜体）、vim（滚动区域、备用屏、分屏、插入/删除行、插入中文）、htop（全屏高频重绘、SGR 鼠标）、less（反向滚动 87 次）、混合（shell 输出 → DEC 画线字符集 → vim 开鼠标 → 退出回 shell 继续输出），每份 20–38 KB。

每份语料取 80 个切点：终端 A 喂到切点 → 序列化 → 喂给全新的终端 B，比较以下内容：每个格子（字符、宽度、前景/背景/样式/下划线样式与颜色）、续行标记、光标、当前画笔、滚动区域、DECSC 保存的光标、全部模式（用 DECRQM 向终端询问，连 `private` 的鼠标编码也能问到）、制表位、标题、备用屏之下的主屏，以及最近 1000 行历史。**然后两边继续喂完剩余字节，再比一次**（续播），这样能暴露所有看不见的状态差异。

#### 结果

| | 快照后立即一致 | 续播到结尾一致 |
|---|---|---|
| 仅公开接口 | 0 / 400 | 0 / 400 |
| 含内部状态（模拟 vendor 补丁） | **400 / 400** | **400 / 400** |
| 同上，切点专门落在 DEC 画线字符集生效期间 | — | **32 / 32**（字符集不复原时只有 1 / 32） |

仅公开接口之所以全军覆没，是因为以下状态读不到：
- `normalBuffer` 是 internal：TUI 在备用屏时**读不到主屏和滚动历史**。手机接入时 vim 正开着，退出 vim 后底下一片空白（混合语料 60 / 80 个切点出现这种情况）。
- 光标隐藏、应用键盘、插入模式、自动换行、原点模式、制表位、标题都是 internal。
- **鼠标编码（`mouseProtocol`）、字符集（`charset`）、跨 feed 暂存的半个 UTF-8 字符（`readingBuffer`）是 `private`**，连同模块的扩展文件也读不到，所以必须改成 internal。鼠标编码丢了，手机上点 htop/vim 发出的是旧格式上报；字符集丢了，`┌──┐` 会显示成 `lqqk`。

性能（Release）：

| 场景 | 快照大小 | 序列化 | 接收端喂入 |
|---|---|---|---|
| 一屏 30 行（各语料中位） | 1.6–10.4 KB | 50–340 µs | — |
| 1000 行彩色历史 + 一屏 | 65 KB | 1.9 ms（中位；本机负载高时测到过 4.7 ms） | 2.0 ms（Mac 上测的，iPhone 待测） |

快照的代价可以忽略：即便在 MainActor 上同步做，1000 行历史也只占一帧的零头。

#### 序列化必须遵守的规则（每一条都是实测踩出来的）

1. **换行前复位画笔**。底部的 `\r\n` 会滚屏，新行用当前背景色填充（BCE）。不复位的话，上一格的彩色背景会被带进新行。
2. **`x == cols` 表示「待折行」**，CUP 表达不了这个状态。要用「重写行末那个格子」来复原；如果最后两列是一个宽字符，就重写整个宽字符，否则会把它的后半格覆盖成普通空格。
3. **下一行是续行时，本行必须真的写满**。CUF（光标右移）最多停在最后一列，进不了待折行状态，下一个字符会覆盖末列而不是折行。
4. **宽字符在行末放不下时留下的占位格不要写**，让下一行的宽字符自己触发同样的折行。
5. **孤儿格**（宽字符的前半格被覆盖后留下的后半格，宽度 0）要**重演**：先在那个位置放一个宽字符，再回来覆盖它的前半格。渲染器会把孤儿格按反显背景画出来，所以它不是「看不见的差异」，不能跳过。
6. **制表位每个缓冲区各一份**，主屏和备用屏要分别复原，否则退出 TUI 后制表位就不对了。
7. **备用屏首行如果是续行**（它的上一行已滚走），要先垫一行满宽占位，让首行自然续上，占位行最后会被滚出屏幕。
8. 默认属性的空格子用 CUF 跳过，保留它们是「空格子」而不是「空格字符」的语义。

#### 拍快照的时机

只能在**解析器处于 ground 状态、且没有暂存半个 UTF-8 字符**时拍。实测原始切点有 9%–38% 落在转义序列中间（7–30 / 80）；专门切在「半个汉字」处的 300 个切点里，有 112 个续播后不一致。生产上放在 `flushPendingOutput` 里：每次 `feed` 之后检查一下，不满足就推迟到下一次 flush（16 ms 内必然遇到合适的时机）。这个检查要读 `parser.currentState`（internal）和 `readingBuffer`（private），也由补丁里的扩展文件提供。

#### 已落地（2026-11-02）

- `vendor/SwiftTerm/Sources/SwiftTerm/TerminalSnapshot.swift`（新增）：`isAtSnapshotBoundary`、`snapshotSequence(scrollbackLimit:)`，以及做测试对照基准用的 `snapshotFingerprint(historyLines:)`。在实验版基础上补了左右边距、G0–G3 字符集 + SO、Kitty 键盘标志位（只复原当前生效的标志位，不复原栈深度）、同步输出（?2026）。
- `Terminal.swift` 里去掉 4 个 `private`：`mouseProtocol`、`gCharsets`、`readingBuffer`，以及 `readingBuffer` 的类型 `ReadingBuffer`（属性的访问级别不能比它的类型更宽）。补丁说明在 `UTERM-PATCHES.md` 第 6 条。
- 测试：`uTermTests/Features/Terminal/TerminalSnapshotTests.swift`，语料在 `uTermTests/Support/Fixtures/TerminalCorpus/`，用 `record.py` 重录。语料刻意保持中性：固定提示符、git 只输出哈希和标题、htop 只监视自己起的 sleep 进程。单测里每份语料取 16 个切点（Debug 下解析慢约 9 倍）；400 切点的全量交叉核对已用正式 API 跑过，结果仍是 400/400。
- 还没接到 `TerminalSession` 上：等远控传输层就绪后，再在 `flushPendingOutput` 里调用。

顺带发现：直接以 100 列创建的终端，主屏制表位只设到第 72 列（按默认 80 列初始化后没有补齐）。这对 uTerm 实际有没有影响，没有核实。

### 2.6 终端延迟与带宽预算（估）

| 环节 | 估值 |
|---|---|
| 手机按键 → Mac（QUIC，同一 5 GHz Wi-Fi） | 2–10 ms，Wi-Fi 抖动时 20+ |
| Mac → SSH 服务端 → Mac | 与 Mac 上本来就一样 |
| Mac tee → 手机 → SwiftTerm feed | 2–10 ms + 一次 SwiftTerm 解析（433 B 约 10 µs） |
| **相对 Mac 本地的附加回显延迟** | **≈ 1 × 局域网 RTT** |
| 接入：快照大小 | 80 列 × (屏幕 + 最近 1000 行) 带 SGR，一般 < 200 KB；目标 100 ms 内出画面 |
| `cat` 突发 | 封顶为「每个 RTT 最多一份快照」 |

跨网高延迟时，第二步可以加 mosh 式的**本地回显预测**（手机先画出预测的字符，带下划线，确认后转正）。只在 RTT > 50 ms 时启用，局域网不需要。

---

## 3. 远程桌面

### 3.1 路线对比

| | 优点 | 缺点 | 结论 |
|---|---|---|---|
| iOS 内置 VNC 客户端，连 macOS 自带「屏幕共享」 | 不碰 TCC，锁屏、登录窗口也能用 | 需要用户开屏幕共享并输入 Mac 账户密码；High Performance 模式只支持两台 Apple silicon Mac 之间（[Apple](https://support.apple.com/guide/remote-desktop/apdf8e09f5a9/mac)），iPhone 只能走标准 VNC，画质和延迟都差 | 作为**锁屏救援**的兜底，不当主路径 |
| **自研 SCK + VideoToolbox** | 延迟、画质、带宽全可控；与终端共用一条连接、一套配对 | 两项 TCC 授权；Mac 锁屏后不可用 | **主路径** |
| 集成第三方 SDK | 省事 | 闭源、计费、数据出境 | 不考虑 |

### 3.2 采集：ScreenCaptureKit

- `SCStream` 输出 `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` 的 IOSurface，**直接交给编码器，零拷贝**。
- `SCStreamConfiguration.width/height` 让 GPU 在采集阶段缩放到目标分辨率（按手机屏幕像素与当前缩放算），不在 CPU 上缩。
- `minimumFrameInterval = 1/60`，`queueDepth` 取 3–4。**屏幕静止时 SCK 不出新帧**（帧状态是 idle），于是不编码、不发送，空闲带宽约等于 0。这是相对 VNC 轮询最大的结构性优势。
- `showsCursor = false`：光标单独发（见 §3.6），光标移动不触发编码。
- **缩放取清晰度**：用户在手机上放大时，改 `sourceRect` 只采被放大的那块区域，并按原生分辨率输出。码率不变，文字是真实像素而不是放大后的糊图。远控里看代码、看终端，这一点比任何编码参数都管用。
- 只在有客户端连接时才建 stream。断开立即 `stopCapture`，不在后台空转（常驻动画在窗口不可见时照样烧 CPU，同一类教训）。

### 3.3 编码：VideoToolbox 低延迟模式（实测）

探针：在测量用的 Mac 上用 VTCompressionSession 硬编 240 帧（高熵合成画面，属于压力场景），逐帧同步等输出，统计单帧编码耗时。

| 配置 | 单帧编码 p50 | p95 | 平均每帧 | LTR |
|---|---|---|---|---|
| H.264 1080p，**低延迟** | **5.8 ms** | 13.0 ms | 26 KB | ✅ |
| H.264 1080p，普通 | 10.3 ms | 32.4 ms | 69 KB | ✗ (-12900) |
| HEVC 1080p，**低延迟** | **6.4 ms** | 13.5 ms | 24 KB | ✅ |
| HEVC 1080p，普通 | 14.1 ms | 19.3 ms | 60 KB | ✗ |
| HEVC 1440p 4:4:4 输入，低延迟 | 9.3 ms | 16.9 ms | 25 KB | ✅ |
| HEVC 1440p 4:4:4 输入，普通 | 20.8 ms | 33.2 ms | 100 KB | ✗ |
| H.264 1440p，低延迟 | 8.2 ms | 20.2 ms | 26 KB | ✅ |

结论：

1. **低延迟模式（`kVTVideoEncoderSpecification_EnableLowLatencyRateControl`）在这台机器上 HEVC 也可用**。WWDC21 当时只写了 H.264（[WWDC21 10158](https://developer.apple.com/videos/play/wwdc2021/10158/)），现在已经不止。它把编码延迟减半，同时提供 LTR（长期参考帧），这正是丢包恢复要用的。
2. **陷阱：低延迟模式会静默降成 4:2:0**。喂 4:4:4 输入、即使显式设 profile，输出的 hvcC 仍是 Main profile、`chroma_format_idc=1`；只有普通模式才输出 RExt 4:4:4（profile 4、chroma 3），代价是延迟翻倍。4:2:0 会让彩色小字发糊。缓解靠两招：一是 §3.2 的按原生分辨率采集 + sourceRect 放大；二是**静止精修**：屏幕静止约 200 ms 后，强制编一个关键帧，并把 `MaxAllowedFrameQP` 压低（低延迟模式下才生效），让静止画面变清楚。
3. 默认用 HEVC 低延迟（同画质码率更低）。H.264 低延迟留作兼容开关，给老设备和需要排查问题时用。

参数：`RealTime = true`、`AllowFrameReordering = false`、无限 GOP（低延迟模式强制）、按需 `ForceKeyFrame`、`AverageBitRate` 与 `DataRateLimits` 由接收端反馈的吞吐动态调整。

**拥塞时的铁律：在编码之前丢，绝不在编码之后丢。** 无限 GOP 里每个 P 帧都依赖上一帧，编码后丢掉任何一帧，后面全花屏，只能等 IDR。所以发送队列里的未发送数据超过约 1 帧时，直接跳过新到的采集帧，不送进编码器。SCK 的 `queueDepth` 本身也会丢旧帧。

### 3.4 传输

- **第一期（局域网）**：视频走一条可靠的单向 QUIC stream，每帧是「长度 + 时间戳 + NAL」。局域网丢包少，可靠传输加编码前丢帧就够了。
- **第二期（跨网 / 弱 Wi-Fi）**：视频改走 QUIC datagram（`NWProtocolQUIC.Options.isDatagram`，iOS 16+，每条连接只能有一个 datagram flow），按 MTU 分片，接收端 NACK；丢帧时请求以最近一个已确认的 LTR 为参考重编，而不是请求 IDR，避免恢复时出现一大帧、卡一下。Apple 论坛有人报告 datagram 配合 `NWConnectionGroup` 出过问题（[forums](https://developer.apple.com/forums/tags/quic)），要在 spike 里实测。
- 优先级：输入与控制 > 光标 > 终端 > 视频。QUIC 多 stream 保证一条终端流的重传不会卡住视频，反之亦然。

### 3.5 解码与显示（iOS）

`VTDecompressionSession` 硬解 → `AVSampleBufferDisplayLayer`，sample 带 `kCMSampleAttachmentKey_DisplayImmediately`，不排队，到了就显示。要做精确的 vsync 对齐或叠加光标时，再换 Metal（`CAMetalLayer` + `CVMetalTextureCache`）。iPhone 的解码耗时要在 spike 里量（估 2–4 ms）。

### 3.6 光标与输入

- **光标**：Mac 端把光标形状（变化时发一次）和位置（≤ 120 Hz，几十字节）发给手机，手机自己画。手机处于触控板模式时，**光标完全由手机本地预测**，用户看到的光标延迟为 0；Mac 只回报最终位置用于校正。
- **指针**：移动按显示帧合并，每帧只发最新位置；点击、拖拽开始/结束走可靠通道。Mac 端用 `CGEvent(mouseEventSource:…)` 加 `CGEvent.post`。
- **滚动**：`CGEvent` 的像素级 scroll wheel 事件，带惯性阶段，触控板手感才对。
- **键盘**：iOS 软键盘的文字（含中文输入法上屏的结果）用 `CGEventKeyboardSetUnicodeString` 直接发 Unicode，绕开 Mac 端的输入法；快捷键（⌘C、⌘Tab）用虚拟键码加修饰键；iPad 硬件键盘从 `UIPress.key.keyCode`（HID usage）映射到 Mac 虚拟键码。
- 键盘条可以复用手机终端已有的增强键盘条（Ctrl/Alt 粘滞、F1–F12）。

### 3.7 权限与沙盒（必须先 spike）

uTerm 是**沙盒 + Developer ID** 分发（[uTerm.entitlements](../uTerm/uTerm.entitlements)：`app-sandbox`、`network.server` 都已开）。

| 能力 | TCC 项 | 沙盒下能否用 | 备注 |
|---|---|---|---|
| ScreenCaptureKit | 屏幕录制 | 能 | macOS 15 起会**每月**重新确认；免确认要 `com.apple.developer.persistent-content-capture`，需向 Apple 提交表单申请（[TidBITS](https://tidbits.com/2024/08/19/apple-reduces-excessive-sequoia-permission-requests-shifts-to-monthly)，[Jump Desktop](https://support.jumpdesktop.com/hc/en-us/articles/29070118000781-macOS-Sequoia-Screen-Recording-Policies-and-Jump-Desktop-Connect)）|
| `CGEvent.post` | PostEvent（设置里显示为「辅助功能」） | Apple DTS：能，是独立于 Accessibility API 的权限，可用 `CGPreflightPostEventAccess` / `CGRequestPostEventAccess` 管理（[forums 789896](https://developer.apple.com/forums/thread/789896)） | 旧版沙盒指南说不行，也有开发者报告在沙盒里静默失败（[dev.to](https://dev.to/quicopy/shipping-global-keyboard-shortcuts-on-macos-sandbox-the-part-apple-doesnt-document-57no)）——**以真签名沙盒包实测为准** |

#### S1 实测结论（2026-11-02，macOS 27.2）

探针的签名方式与正式版 uTerm 完全一致：Developer ID Application（同一团队）+ hardened runtime + `app-sandbox` + `network.client/server`，经 LaunchServices 启动，所以 TCC 的归属就是探针自己。另做了一个只去掉沙盒的对照组。

| 项 | 结果 |
|---|---|
| ScreenCaptureKit | ✅ 授权「录屏与系统录音」后：能枚举 28 个他人窗口（其中 23 个读得到标题）；1920×1080 采 2 s 得到 117–118 帧完整画面（≈ 60 fps），首帧 27–47 ms，帧放在 IOSurface 里；画面亮度标准差 ≈ 38，确实是桌面内容而不是黑屏 |
| `CGEvent.post` 鼠标 | ✅ 光标被移到目标点，读回的系统光标位置逐像素一致 |
| `CGEvent.post` 键盘 | ✅ 用 `keyboardSetUnicodeString` 往 TextEdit 打「uterm-probe 你好 ✓」，并用 ⌘S 保存，探针读回文件内容一致（首字母被 TextEdit 的自动大写改成了 U：注入的字走的是目标 app 正常的文字输入通道，跟真人打字一样会被自动更正处理） |
| 沙盒 vs 无沙盒 | 行为相同。**沙盒不是障碍**，不需要 LaunchAgent 辅助进程 |

**授权流程（全新 bundle id、实时抓 tccd 日志的干净复现，探针放在 `~/Applications`）**：

| 时间 | 事件 |
|---|---|
| 22:48:26 | 探针调用 `CGRequestPostEventAccess()`，返回 false，弹出系统授权框 |
| 22:48:27 | **系统自己**（`com.apple.accessibility.universalAccessAuthWarn`，授权弹窗进程）写入 `kTCCServicePostEvent = Denied`。用户什么都没点，这是正常行为，相当于在列表里先登记一个关着的开关 |
| 22:56:14 | 用户在「辅助功能」里打开开关，写入的是 `kTCCServiceAccessibility = Allowed`（不是 PostEvent） |
| 22:56:33 | **同一个进程**：`CGPreflightPostEventAccess()` 和 `AXIsProcessTrusted()` 仍为 false，注入无效。授权结果被缓存在进程内，开关打开后它每秒的查询根本没有发到 tccd |
| 22:57:13 | **重启 app**（不再发起请求）：两者都为 true，注入生效。tccd：`composed authorization from kTCCServicePostEvent to parent service kTCCServiceAccessibility: Allowed`，也就是 PostEvent 沿用了 Accessibility 的授权，那条自动写入的 Denied 不再起作用 |

结论：**「请求 → 去设置里打开开关 → 重启 uTerm」这条标准流程能走通**，唯一的坑是打开开关后**必须重启进程**才生效。产品上的做法：

- 只在用户打开「允许远程桌面控制」时才调用 `CGRequestPostEventAccess()`，不要一启动就调。
- 用户从系统设置回来后，不能靠轮询 `CGPreflightPostEventAccess()` 判断（进程内的值不会变），要明确提示「授权后需重启 uTerm」，并给一个「重新启动」按钮。也可以试试监听分布式通知 `com.apple.accessibility.api`（不少辅助功能类 app 用它感知授权变化，**未验证**），收到后再提示重启。
- 屏幕录制同理，系统本身就会提示「退出并重新打开」。

**还没解释清楚的现象**：第一轮测试里，探针放在 `/private/tmp`，打开开关并重启后依然失败，tccd 一直对 PostEvent 回 `auth_value=0 auth_reason=4`，直到用 `tccutil reset PostEvent` 清掉才好。推测是 LaunchServices 不收录临时目录里的 app，系统在打开 Accessibility 开关时没能顺带处理它的 PostEvent 记录；同一批探针用 `tccutil reset … <bundle id>` 也一直报 `-10814`（找不到这个 bundle id），是同一个原因。正式版 uTerm 装在 `/Applications`，不受影响；但用 Debug 构建（DerivedData 里的 app）做远控联调时要留意这一点。

保留的退路（目前不需要）：如果将来某个系统版本收紧沙盒里的 PostEvent，就改成一个**不沙盒的 LaunchAgent 辅助进程**（`SMAppService.agent`，由 launchd 启动，不继承父进程沙盒；Developer ID 分发允许），只负责注入事件，与主 app 走 XPC。现有登录项辅助程序 `uTermBackgroundLauncher` 是沙盒的，那是 `SMAppService.loginItem` 的要求，agent 不受这条约束。

**硬局限**：Mac 锁屏或停在登录窗口时，用户会话里的 app 采不到画面，安全输入下也注入不了密码。这种情况引导用户用 §3.1 的系统 VNC 兜底，或者干脆不支持。另外远控期间要持有 `IOPMAssertion` 防止 Mac 睡眠，结束即释放。

### 3.8 远程桌面延迟与带宽预算（估，待 spike 证实）

| 环节 | 估值 |
|---|---|
| 屏幕变化 → SCK 交帧 | 0–16 ms（取决于在刷新周期的哪个位置） |
| 编码（实测 p50） | 6 ms |
| 局域网传输 1 帧（约 25 KB @ 300 Mbps） | 1 ms + 2–10 ms 网络 |
| iPhone 硬解 | 2–4 ms |
| 显示（DisplayImmediately，下一个 vsync） | 0–8 ms（120 Hz ProMotion） |
| **端到端（glass-to-glass）p50 目标** | **≤ 50 ms**（局域网 5 GHz） |
| 带宽 | 静止约 0；滚动、视频约 5–15 Mbps（1080p60 低延迟，估） |

---

## 4. 传输层（终端与桌面共用）

- **协议**：Network.framework 的 QUIC（`NWProtocolQUIC`），一条连接，按用途开 stream：控制 1 条（双向，长度前缀帧）、每个被接入的终端 1 条（双向，原始字节 + 内联的 resize/快照标记）、视频 1 条（第二期换 datagram）、光标/输入 1 条。
- **发现**：Bonjour 新服务类型 `_uterm-remote._udp`。两端 Info.plist 的 `NSBonjourServices` 都要加，现在只有 `_uterm-sync._tcp`；同时要改 `NSLocalNetworkUsageDescription` 的文案。
- **身份与配对**：每台设备生成一个长期 Curve25519 身份密钥（Mac 端存钥匙串，**不同步**）。首次配对时显示 6 位码并交换公钥，之后 QUIC 的 TLS 层用自签证书，在 `sec_protocol_options_set_verify_block` 里**钉住对端公钥**，不再需要配对码。可选：同一 iCloud 账户的设备，通过已有的同步钥匙串 / KVS 预先交换公钥指纹，免输配对码；但 Mac 端第一次被控时仍要本地确认一次。
- **跨网**：不再按这里最初的设想做（手动填地址、QUIC 中继）。实际方案见 §15。
- **iOS 生命周期**：进后台后连接会被挂起，回前台时终端走快照重同步（§2.2），桌面请求一个关键帧。

## 5. 安全与门禁（继承 ControlHandler 的纪律）

- Mac 端两个独立开关：「允许远程查看/控制终端」「允许远程桌面」，默认都关。
- 首次被某台设备控制时 Mac 本地弹窗确认，之后按设备授权，可在设置里撤销。
- 被控期间 Mac 上常驻明显的指示（菜单栏图标与浮层「正在被 ××的 iPhone 控制」），一键断开。
- 手机端开始远控前复用现有应用锁（Face ID）。
- 凭据不出 Mac：手机只拿到终端字节和画面，协议里没有任何导出密码、私钥的字段（与 CLI 同一原则）。
- 出口合规：QUIC/TLS 与 CryptoKit 都是系统密码学，`ITSAppUsesNonExemptEncryption = NO` 不受影响（依据见 Info.plist 注释）。

## 6. 分期与验证门槛

先做 spike，每个都带通过标准，不过就改方案：

| # | Spike | 通过标准 |
|---|---|---|
| S1 ✅ | 签名沙盒版 uTerm 内：SCStream 采集 + `CGRequestPostEventAccess` + `CGEvent.post` 点击别的 app | **已通过（2026-11-02）**：两项都能拿到且生效；标准授权流程可走通，但授权后须重启进程，见 §3.7 |
| S2 | Mac ↔ iPhone 局域网 QUIC：多 stream 吞吐、RTT、datagram 可用性 | 5 GHz 下 RTT p50 < 10 ms；吞吐 > 100 Mbps |
| S3 | iPhone 端 HEVC 低延迟流硬解 + AVSampleBufferDisplayLayer，加 glass-to-glass 测量（对着两块屏拍高速视频，或画面内嵌时间码） | p50 ≤ 50 ms |
| S4 ✅ | SwiftTerm 快照序列化：语料喂 A → 序列化 → 喂 B → 指纹比对 | **已通过（2026-11-02）**：含内部状态版 400/400 立即一致且续播一致，画线字符集 32/32；仅公开接口 0/400 → 需 vendor 补丁，见 §2.5 |

然后：

1. **P1 终端镜像（局域网）**：Mac 端 tee + 订阅者队列 + 快照；手机端 `RemoteHostTerminalBackend`；会话列表；镜像/接管两种尺寸。
2. **P2 远程桌面（局域网）**：可靠 stream 版本，加 sourceRect 缩放、静止精修、本地光标。
3. **P3 跨网**：见 §15。公网直连上的 datagram + NACK + LTR 恢复已做；终端本地回显预测仍未做。

每期都要有性能探针（照 `docs/scroll-perf-findings.md` 的探针纪律）：终端测「按键 → 手机上出现回显」的附加延迟、接入出画面耗时、`cat` 1 GB 期间的带宽与 Mac 主线程占用；桌面测 glass-to-glass、Mac CPU / 编码器占用、静止带宽。

## 7. 未决

- 远控 Mac 端「授权后需重启」的体验：能否用 `com.apple.accessibility.api` 分布式通知感知授权变化，从而自动提示重启？
- iPhone 能否硬解 HEVC RExt 4:4:4？只有在要走「普通模式 4:4:4」那条路时才相关，按现在的推荐不需要。
- `persistent-content-capture` 授权是否申请（取决于能否接受每月确认一次）。
- 多显示器：第一期只做主显示器，或者让手机选一块。
- 「接管尺寸」时 Mac 端 pane 的视觉怎么处理，需要出设计稿。（P1 先做了：终端按手机尺寸贴左上角，超出部分裁掉，窗格右上角有「正在接管 · 断开」指示条。）

## 8. P1 终端远控实施记录（2026-11-03，分支 `feat/remote-control`）

用户定的三项：**手机接管尺寸**、**Mac 上确认 + 两端核对 6 位码**配对、本轮**只做终端**（局域网）。

### 落地内容

| 层 | 文件 | 说明 |
|---|---|---|
| 共享（两端都编译） | `uTerm/Core/Remote/` | `RemoteProtocol`（二进制消息 `[类型][通道][负载]`、长度前缀分帧）、`RemoteCrypto`（ee‖es‖se 派生会话密钥、核对码、计数器 nonce 的 ChaChaPoly）、`RemoteIdentityStore`（长期密钥与已信任设备，钥匙串不同步 / ThisDeviceOnly）、`RemoteLink`（NWConnection：握手、加解密、在途字节统计、发完再关）、`RemoteMacClient` 与 `RemoteTerminalBackend`（手机侧客户端与终端后端，放在共享目录是为了让 Mac 单测能端到端驱动它们） |
| Mac | `uTerm/Features/Terminal/TerminalMirrorTap.swift`、`TerminalSession+RemoteGrid.swift`、`uTerm/Features/Remote/` | 镜像接入点在 `flushPendingOutput`；尺寸钉在 `CopyableTerminalView.pinnedFrameSize`、容器布局按它摆放；`RemoteHostServer` / `RemoteHostConnection`（监听、配对审批、接管登记、防闲置睡眠、输出泵在连接队列上合并发送）；`RemotePairingPanel`（独立 NSPanel）；设置 › 高级 › 远程控制；窗格「正在接管 · 断开」指示条 |
| iOS | `uTermMobile/Screens/Remote/` | `RemoteMacDirectory`（Bonjour 浏览，推迟本地网络授权）、主机页「我的 Mac」区与 Mac 面板（配对 / 会话列表）、`TermTab(host:remote:)` 与 `MOpenTarget.remote`、连接中页的远控文案、`.remote` 传输工厂 |
| vendor | 补丁 #6 扩充、新增 #7 | 见 `vendor/SwiftTerm/UTERM-PATCHES.md` |

与计划的出入：传输用 TCP（`noDelay`）而不是 QUIC（理由见计划：Network.framework 的 QUIC 需要 X.509 身份）；Agent 模式对远控标签照常可用（它走手机自己的 SSH，与远控通道无关），没有隐藏。

### 验证

- Mac 单测 52 个（其中联调服务 1 个默认跳过）：协议、加密（冒用公钥、中间人核对码不同、重放 / 乱序 / 篡改）、回环收发、服务端全流程（配对 → 列表 → 接入 → 输入 → 断开 → 再连直接放行 → 撤销后要重新审批 / 拒绝即断）、端到端（真实手机客户端 + 后端连真实服务端：接入画面逐格一致、改尺寸重发快照、断线自动重连再对齐、会话结束时手机端退出）、镜像（流、积压溢出重发快照、清屏、接管尺寸）、快照回归（含新增的「重排后再拍快照」五种尺寸 × 三份语料）。
- iOS 模拟器联调（专用模拟器，测完删除）：主机页「我的 Mac」→ 发现 Mac → 配对（核对码 141949 两端一致）→ 会话列表 → 打开远控标签、快照画面正确 → 打字回显 → 转横屏后按新尺寸重排、继续打字正常。
- **回环读数**（Debug、本机）：接入到首帧 3.4 ms；空闲时输出到手机 p50 0.32 ms / p95 0.46 ms；按键到 Mac 后端 3.1 ms（其中 2 ms 是测试轮询粒度）。连续输出时 Mac 自己按 16 ms 一帧合批，那部分延迟本地显示同样有，不是远控引入的。

### 联调踩出来的问题（都已修）

- **macOS 的「本地网络」权限**：Mac 端广播 Bonjour 被拒时报 `NoAuth (-65555)`，手机就发现不了这台 Mac。设置页现在把它翻成「系统设置 › 隐私与安全性 › 本地网络 里打开 uTerm」。Debug 测试宿主通常没有这个权限，联调改走回环：手机 Debug 构建支持启动参数 `-RemoteDebugEndpoint 127.0.0.1:<端口>`。
- 快照：变窄重排切出的空续行会丢一行（续行首格必须真的打印）；改尺寸后 DECSC 的行号可能为负（按 DECRC 夹回的值处理）；直接按超过 80 列创建的终端，备用屏制表位只到第 72 列（两块缓冲区的制表位无条件写）；放宽后右边距不扩（vendor 补丁 #7）。
- 手机端：接入请求在路上时报来的真实尺寸要补发；「已激活」「已配对」必须是可观察的存储属性，否则列表不刷新；「我的 Mac」区的宽度与上下内容对齐（`MInsetGroup` 自带左右边距）。

### 还没验证 / 下一步

- **真机**：iPhone 与 Mac 在真实 Wi-Fi 上的回显延迟、App 切后台再回来的重连、Mac 睡眠唤醒后的重连。
- **正式签名的 Mac 版**第一次打开远控时，系统「本地网络」授权弹窗的实际体验。
- 接入要求那台主机已同步到手机（按 `serverID` 找本机的 `ServerProfile`）。没开 iCloud 的用户需先做一次局域网同步。
- P2 远程桌面（复用本轮的配对、身份、连接；视频改走 QUIC datagram）；P3 跨网。

## 9. P2 远程桌面实施记录（2026-11-03，分支 `feat/remote-desktop`，基于 P1 `7bc56e47`）

范围：局域网内 iPhone / iPad 看并控制 Mac 主显示器。跨网 / NAT（P3）、多显示器切换（协议留了 `displayID`）、音频、剪贴板都不在本轮。

### 落地内容

| 层 | 文件 | 说明 |
|---|---|---|
| 共享（两端都编译） | `uTerm/Core/Remote/RemoteDesktopProtocol.swift` | 新消息体：开流请求 / 结果（JSON），视频帧、确认、光标、输入（定长大端二进制）；`RemoteByteWriter/Reader` |
| | `RemoteDesktopFlow.swift` | 纯函数：`RemoteDesktopPacer`（背压与丢帧）、`RemoteRateController`（码率 / 帧率）、`RemoteDesktopGeometry`（视频尺寸、归一化 ↔ 全局坐标）、`RemoteDesktopViewport`（缩放平移）、`RemoteTrackpad`（相对移动 + 加速） |
| | `RemoteKeyMap.swift` | HID usage → kVK（外接键盘）、字符 → kVK（US 布局，修饰键条上膛时用） |
| | `RemoteVideoDecoder.swift` | `VTDecompressionSession` 同步硬解；关键帧换参数集时重建；无关键帧 / 出错后拒解 P 帧；`displaySample` 生成带 `DisplayImmediately` 的显示样本 |
| | `RemoteDesktopSession.swift` | 手机侧一条桌面流：开流、解码队列、每帧回确认、关键帧请求（限频 500 ms）、断线退避重连（300 ms → 4 s）、发输入；`RemoteMacClient` 增 `startDesktop/stopDesktop/supportsDesktop`，`RemoteChannelSink` 增 `onMessage` |
| Mac（加进 uTermMobile 的 `membershipExceptions`） | `uTerm/Features/Remote/Desktop/` | `ScreenCaptureFrameSource`（SCK，420v、`showsCursor = false`、60 fps、`queueDepth 6`）、`RemoteVideoEncoder`（低延迟码控）、`RemoteDesktopStreamer`（采集 → 节拍 → 编码 → 发送，确认 / 输入 / 光标）、`RemoteEventInjector`（CGEvent）、`RemoteDesktopEnvironment`（生产 = SCK + CGEvent + 开关；测试换夹具）+ `RemoteDesktopPermissions` / `RemoteDesktopPermissionState`、`RemoteDesktopIndicator`（屏幕顶部常驻「×× 正在查看 / 控制这台 Mac · 断开」） |
| | `RemoteHostServer` / `RemoteHostConnection` | 同一时刻一路桌面流、后来者接管；有人看屏幕时 `idleDisplaySleepDisabled`；确认 / 输入 / 关键帧请求经 `RemoteDesktopRoute` 在连接队列上直达发送端，不经主线程 |
| | 设置 › 高级 › 远程控制 | 「允许远程桌面」开关（`remote.desktopEnabled`，默认关，在终端远控总开关之下）；屏幕录制 / 辅助功能两项授权状态 +「授权」「打开系统设置」「重新启动」；正在查看的设备 +「断开」 |
| iOS | `uTermMobile/Screens/Remote/RemoteDesktopScreen.swift`、`RemoteDesktopCanvas.swift` | 全屏覆盖（`MobileStore.remoteDesktop`）；`AVSampleBufferDisplayLayer` 在解码队列上直接 enqueue；本地画光标；触控板手势；隐藏 `UIKeyInput` + 外接键盘 `pressesBegan`；修饰键条；回前台要关键帧；常亮 |
| | `RemoteMacSection.swift` | Mac 面板加「屏幕」组；Mac 不支持时置灰并提示更新 |
| 测试 | `uTermTests/Core/Remote/RemoteDesktop*Tests.swift`、`RemoteVideoCodecTests.swift`、`RemoteDesktopTestSupport.swift` | 见下；`RemoteSimulatorHarnessTests` 增 `UTERM_HARNESS_DESKTOP=1` |

**协议**：不升版本号。`RemoteHello` 加可选 `features`（Mac 带 `"desktop"`），P1 的对端解码时忽略该键。手机只在 `supportsDesktop` 时才发桌面消息——老 Mac 收到未知消息类型会断开整条连接，这一条在 `test_old_mac_without_desktop_feature…` 里验证了连接不受影响。消息编号：手机 → Mac `desktopStart 10 / desktopStop 11 / desktopInput 12 / desktopAck 13 / desktopKeyframe 14`，Mac → 手机 `desktopStarted 25 / desktopFrame 26 / desktopCursor 27`，结束复用 `closed 23`。帧 = 18 字节头（标志、编码、序号、Mac 采集时刻 ns、宽高）+ 关键帧的参数集 + AVCC 码流。坐标一律是显示器归一化坐标，与采集分辨率、手机缩放无关。被拒（没开开关 / 没屏幕录制授权 / 采集起不来）回带 `failure` 的 `desktopStarted`，连接不断。

**背压与码率**：
- 在途 = 已送编码器、还没收到手机「解码完」确认的帧。≥ 2 帧或 ≥ 768 KB 时新画面不送编码器，只留最新一张；确认一回来立刻编它。确认在手机**解码之后**发，所以背压是端到端的（网络慢、手机解码慢都会让 Mac 少编）；Mac 用自己的单调时钟算「采集 → 手机解码完 → 确认回到 Mac」。
- `RemoteRateController`：编码前丢帧或上面那段往返 > 120 ms 算拥塞，码率 ×0.7（两次下调至少隔 500 ms），码率到下限 1 Mbps 还拥塞则帧率减半到 30；连续 2 s 无拥塞先恢复 60 fps 再 ×1.15，上限每像素 12 bit/s。起始每像素 4.5 bit/s（1856×1206 ≈ 10.1 Mbps）。
- 静止精修：画面静止 300 ms 且链路空闲时，把最后一帧以 P 帧重编一次，临时把 `MaxAllowedFrameQP` 压到 28，编完恢复 51。
- 视频尺寸：手机按自己的屏幕像素要（至少 1920×1080，与方向无关），Mac 把显示器原生像素等比塞进去、不放大、取偶数。iPhone 17 Pro（2622×1206）看 3024×1964 的 Retina 屏 → 1856×1206。

### 测试与实测读数（测量用的 Mac（Apple 芯片，macOS 27.2），Debug，回环 127.0.0.1）

新增 34 个 Mac 单测全部通过（协议 8、纯函数 14、编解码 6、端到端 6，含 1 个探针）；P1 的 Remote* / 镜像 / 快照 / 右边距回归 33 个通过（加密 6、端到端 1、服务端 3、链路 2、协议 7、镜像 5、快照 7、右边距 2），1 个联调服务按设计跳过。端到端用例覆盖：Mac 没开开关被拒且连接不断 → 开流、首帧关键帧逐块一致 → 后续只有 P 帧 → 输入顺序与取值原样到注入器、Mac 指示从「查看」变「控制」→ 光标归一化回报 → 静止后精修且只一次 → 手机要关键帧时静止画面也补一个 → 断线自动重连、Mac 重新采集、首帧关键帧 → Mac 上断开后手机显示「已结束」不重连、采集停止；背压（原始链路扮演不回确认的手机：10 帧新画面只发出 2 帧，确认后发出的是最新那张且不是关键帧，重复确认不扣计数）；老 Mac；没屏幕录制授权 / 只能看（越过手机门禁硬发输入，Mac 也不注入）；第二台设备接管。

探针读数（只记录，不设断言；同一配置跑了五次，列范围）：

| 项 | HEVC | H.264 |
|---|---|---|
| 编码耗时 p50 / p95（1856×1206，满屏高细节每帧全变） | 5.7–6.1 / 5.9–6.5 ms | 5.4–5.7 / 5.6–6.3 ms |
| 采集 → 手机解码完 → 确认回到 Mac p50 / p95 | 7.9–8.8 / 9.2–25.8 ms | 8.9–9.5 / 10.0–39.2 ms |
| 手机侧解码（Mac 上的同一份解码代码）p50 / p95 | 1.5–1.7 / 1.8–2.3 ms | 2.4–2.6 / 2.9–3.4 ms |
| 60 fps 采集 3 s 的实发帧率 | 31.3–34.0 fps（码控丢 86–94 帧，拥塞丢 0） | 25.0–33.7 fps（码控丢 87–117，拥塞丢 0–1） |
| 码率 | 10.1 → 13.3 Mbps，实发 ≈ 12.3–12.6 Mbps，≈ 45 KB/帧 | 实发 ≈ 10.1–12.4 Mbps |
| 静止 1 s 的发送量 | 2 帧（1 帧精修）≈ 290 KB | 2 帧（1 帧精修）≈ 300–370 KB |
| 编解码往返（色块平均亮度，容差 6） | 1856×1206 每帧通过 | 1280×800 每帧通过 |

静止精修（`test_refine_frame_improves_static_quality`，1856×1206 高细节画面）：PSNR 19.4 → 38.1 dB；精修帧约 330 KB。码率 1 Mbps 时，码控为这一帧还账，之后**连丢约 500 ms** 的帧；10.1 Mbps 时只丢 16 ms（1 帧）。

模拟器联调（专用模拟器 uTerm-P2-smoke，测完已删除）：harness 提供合成桌面，App 以 `-RemoteDebugEndpoint 127.0.0.1:<端口> -RemoteDebugOpenDesktop YES` 启动后自动配对、开流（1856×1206），截图确认画面正确显示、本地光标在中心、每秒换一张的画面跟着更新（P 帧解码正常）。**手势没有在模拟器里点过**（模拟器控制工具的访问授权没人确认），只验证了显示链路。

读数怎么看：编码 6 ms、解码 2 ms、回环往返 p50 8–9 ms 与 §3.3 / §3.8 的估值一致。实发帧率只有 30 出头是这个探针画面造成的：每帧整屏高频细节全变，相当于全屏播放噪声视频，13 Mbps 下码控只能每两帧丢一帧；桌面上的滚动、打字远没有这么重。p95 往返有时 9–10 ms、有时 25–39 ms，未细查，推测是测试宿主里与其它工作争 CPU，要在真机上重量。

### 偏离调研 / 草案的决定

1. **传输仍是 P1 的加密 TCP，不是 QUIC**。理由同 P1（Network.framework 的 QUIC 要 X.509 身份），桌面在同一条连接上独占一个通道。代价是视频与终端共享一条 TCP 的队头；局域网上可接受，P3 跨网时再评估 datagram。
2. **链路追上时不强制关键帧**（调研 §3.3 写的是「静止后强制关键帧」，草案也提过追上时补关键帧）。TCP 不会丢掉已经编好的帧，编码前丢帧也不打断参考链，所以追上时直接编最新那张 P 帧就是对的；关键帧只在开流和手机请求（解码出错、回前台、重连＝新开流）时出。好处是追上那一刻不会冒出一个大关键帧又把链路堵住。用例里断言了「确认后发出的那帧不是关键帧」「整段播放只有开流那一个关键帧」。
3. **静止精修用 P 帧 + QP 上限 28，不用关键帧**；并且**码率低于 4 Mbps 时不精修**。依据是上面的实测：1 Mbps 下一帧精修约 330 KB，码控随后连丢约 0.5 s 的帧，用户此时一动就卡半秒；10 Mbps 时只丢 1 帧。精修帧若被码控丢掉，100 ms 后重试精修（最多 10 次），不当普通帧重发。
4. **码控主动丢帧（`kVTEncodeInfo_FrameDropped`）单独处理**：草案没预料到低延迟码控会自己丢帧。丢帧不断参考链，所以不要关键帧（关键帧更大，只会丢得更多）；但那张画面没发出去，屏幕若就此静止手机会停在旧画面上，所以没有更新的帧在等时，16 ms 后把它再送一次。码控丢帧不计入拥塞（不是网络问题）。
5. **不设 `DataRateLimits`**：一开始按调研设了「1 秒内不超过 1.5 倍」，排查精修后丢帧时去掉对比，丢帧现象不变，说明丢帧来自低延迟码控本身；这个硬上限没有看到收益，留着只多一种丢帧来源，所以去掉。
6. **光标只同步位置，不同步形状**：采集不带光标，手机画一个固定箭头；I 形光标、调整大小光标等形状变化本轮没做。触控板模式下光标由手机本地预测（手指一动就动），手指离开 0.4 s 后才采用 Mac 回报的位置。
7. **没做 sourceRect 区域采集**（调研 §3.2「放大时只采放大的那块」）。本轮放大是手机端放大整帧，帧尺寸按手机屏幕像素要（1856×1206 看 1512×982 点的屏，约 1.23 像素 / 点），小字在放大后会比原生糊。协议里坐标都是显示器归一化的，以后加区域采集只需在帧头带上区域，不影响输入映射。
8. **点击次数手机自己数**（0.35 s 内同位置连点 → clickCount 2 / 3），不用系统双击手势，否则每次单击都要等 300 ms 判定。
9. **输入事件与确认在连接队列上路由**，不经主线程（草案即如此）；开流 / 停流这类低频控制才回主线程。
10. **指示条做成独立 `NSPanel`**（屏幕顶部正中、所有空间可见、不抢焦点），理由同 P1 的配对面板（uTerm 常在无窗口的后台模式运行）。它本身会被采进画面，手机上也看得到。
11. `UDSplashTests` 里引用的 `UDSplashNebula` 已在 `7b4cc476` 改名为 `UDSplash`，基线 `7bc56e47` 的测试 target 因此编不过；顺手把测试里的类型名改了（只改名，断言不变），否则 `build-for-testing` 无法进行。

### 还没验证 / 需要真机

- **TCC 全流程**（测试进程没有授权，采集与注入在单测里全换成了夹具）：签名版 uTerm 在设置里点「授权」→ 系统弹窗 → 去系统设置打开「录屏与系统录音」「辅助功能」→ 点「重新启动」→ 新进程里两项变成「已授权」。`RemoteDesktopPermissions.relaunch()`（`NSWorkspace` 拉新实例后退出自己）在沙盒里能不能正常拉起**没有验证**。
- **真实 SCK 采集与 CGEvent 注入**：`ScreenCaptureFrameSource`、`RemoteEventInjector` 只编译过、没跑过。特别要看：滚动的方向与阶段（带 `scrollPhase / momentumPhase` 的像素滚动在 Safari / Xcode 里的手感）、长按拖拽、⌘ 单击、`.text` 中文注入、修饰键条组合（⌘C / ⌘Tab）。
- **真机延迟**：iPhone 硬解耗时（这里的 2 ms 是 Mac 上解的）、真实 Wi-Fi 下的「采集 → 解码完」往返与 glass-to-glass（调研 S3 的方法：画面内嵌时间码或高速摄像）、码率控制在真实拥塞下会不会来回振荡。
- **手势**：判定规则已抽成 `RemoteTrackpadGesture` 并有单测（2026-11-04），但触控板移动、点按、双指右键、双指滚动 + 惯性、长按与轻点拖拽、捏合缩放 / 平移的手感仍没在设备上操作过。外接键盘（iPad）的 `pressesBegan` 路径没验证。
- **软键盘中文输入**：隐藏视图只实现了 `UIKeyInput`（没有 `UITextInput` 的 marked text），系统中文输入法在这种视图上的行为未知，可能直接上屏拼音字母；需要时改成 `UITextInput`，或引导用户在 Mac 端切中文输入法、手机发英文按键。
- 回前台要关键帧、App 被挂起后的重连、Mac 睡眠 / 锁屏（锁屏时采不到画面，调研 §3.7 的硬局限）、显示器分辨率在流中途改变（当前不会重建采集，画面会被拉伸）、Mac 外接多块屏时光标移到别的屏上（光标标为不可见）。
- 授权后「需重启」的提示目前靠用户手动点；`com.apple.accessibility.api` 分布式通知仍未试（§7）。

## 10. 手机新建 Mac 本机终端（2026-11-03，分支 `feat/mac-local-shell`）

需求：手机在「我的 Mac」里直接新建一个 **Mac 系统终端**（用户的登录 shell），而不是只能接入 Mac 上已经开着的 SSH 终端。

### 为什么要辅助进程

uTerm 主程序是沙盒 app，它派生的子进程继承沙盒：直接 `forkpty` 出来的 shell 读不到主目录、很多命令跑不了。三条路里选了「不带沙盒的 LaunchAgent」（另两条：SSH 到本机要用户开「远程登录」并手动放公钥；主程序去掉沙盒影响面太大）：

- `uTermShellAgent.xpc`（XPC 服务 target，hardened runtime，**无沙盒**）由 uTerm target 的「Embed Shell Agent」阶段拷到 `Contents/XPCServices/`；主程序 `NSXPCConnection(serviceName: "com.uozi.uTerm.ShellAgent")` 连接时由系统按需拉起、主程序退出时一起结束，**不需要注册、不需要用户授权**。
- ⚠️ 第一版用的是 LaunchAgent + `SMAppService.agent`，真机上注册直接报 `Operation not permitted`：**沙盒 app 不能用 SMAppService 注册不带沙盒的代理**（macOS 14.2 起后台任务管理强制，见 Apple 论坛 thread 761249 / 743395），否则就是沙盒逃逸口子。内嵌 XPC 服务没有这条限制（Sparkle 的安装器服务同理），也就不用 mach-lookup 例外。辅助程序用 `setCodeSigningRequirement` 只认同团队签名的 `com.uozi.uTerm`。验证：`LocalShellIntegrationTests` 在沙盒测试宿主里经内嵌服务起登录 shell，`ls ~/Library` 成功（沙盒里读不到）、调尺寸与结束生效。
- XPC 只管低频的事：起 shell（`forkpty` + `execve` 登录 shell `-zsh`，工作目录主目录，补 `TERM` / `COLORTERM` / `LANG`）、调尺寸（辅助进程留一份主端 fd 做 `TIOCSWINSZ`）、结束（SIGHUP 整个进程组，3 s 后 SIGKILL）。伪终端主端经 XPC **交 fd** 给主程序，之后的读写主程序直接对 fd 做（`LocalShellBackend`），不经过辅助进程。主端 fd 一律 `FD_CLOEXEC`，否则后开的 shell 继承前面的主端、前面的终端关了收不到挂断。主程序那条连接断了（退出 / 崩溃），它开的 shell 一并结束。
- 协议文件 `uTermShellAgent/LocalShellAgentProtocol.swift` 两边共用：`uTermShellAgent` 文件夹同步组也挂在 uTerm target 上，用例外列表只放行这一个文件。

### 流程

手机 `openLocalShell`（通道 0，JSON 带 requestID；只发给 `features` 带 `local-shell` 的 Mac）→ Mac `RemoteLocalShellOpener.live`：查「允许打开本机终端」开关（默认关）→ `openLocalShellWindow` 开一个 `LocalShellWindowID` 窗口 → 等会话登记（≤ 15 s）→ 回 `localShellOpened(sessionID)`；手机拿到 id 走普通 `.attach`。本机会话的 `serverID` 是哨兵值 `RemoteConstants.localShellServerID`，手机见到它不去自己的主机列表找，而是造一个不入库的临时 `ServerProfile` 代表这台 Mac；工作区「主机被删就收标签」、终端控制器「记最近连接」两处都按 `modelContext == nil` 跳过它，远控标签不显示 Agent 开关。

### 验证

- `RemoteLocalShellTests`（4 个）：开启 → 列表里认得出本机 → 接入、输入到达、输出回来、Mac 端标出被接管；开启器失败原因原样到手机且不断连；老 Mac（无 `local-shell`）手机端直接挡住；线上编号与负载形状。
- 辅助进程探针（沙盒外，进程内匿名 XPC 监听器挂 `ShellAgentServer`，`clientRequirement: nil`）：起 shell 4 ms，`$0=-zsh`、`$HOME` / `$PWD` 为主目录、`TERM=xterm-256color`；XPC 调尺寸后 `stty size` 读到 `31 101`；`seq 1 20000` 完整读回；terminate 后主端读到结束、进程被收走。
- **未验证**：手机端整条链路在真机上的体验。

## 11. 重启不断终端：探针结果（2026-11-04）

目标：重启、崩溃、Xcode Stop、部署时，本机 shell 和 SSH 终端都不断。设计是每个会话一个不懂终端也不懂 SSH 的 `uterm-holder` 进程持有 PTY，App 经内嵌 XPC 服务拉起它。动手前先用一次性探针验证（沙盒 App + 无沙盒 XPC 服务 + holder，Developer ID 签名、hardened runtime，放在 `~/Applications`，与正式版配置相同；未合入主线）。

| # | 验证内容 | 结果 |
|---|---|---|
| S1 | XPC 服务用 `posix_spawn(POSIX_SPAWN_SETSID)` 拉起 holder + 登录 shell，`kill -9` App | **通过**。holder 与 shell 存活，父进程变 launchd；XPC 服务随 App 退出。shell 里 `launchctl managername`（Aqua）、`pbcopy`/`pbpaste`、`open`、`security`（缺失项返回 44，不是 36）、`curl https`、`osascript`、`dscacheutil`、`defaults`、`xcrun` 与 App 活着时结果一致。担心的 bootstrap 域失效没有出现，不需要 `launchctl submit`。30 分钟复测见下 |
| S2 | App 已死、被删除、被重新部署后访问 `~/Documents` | **通过**。tccd 日志：`responsible_path` 仍是 App 可执行文件，`Sub:{com.uozi.uTerm.holderprobe}`，算原 App 的身份，不是新身份。已授权的继续可用，App 被删除和重新部署期间也可用；未授权的目录弹的是 App 的授权框 |
| S3 | App 活着和死了时的 CPU、磁盘 | **通过**。CPU 约 6.3 亿次循环，磁盘写 800 MB 约 0.14 s，差异在正常波动内（磁盘数字主要是页缓存）。holder 所在的 jetsam coalition 状态变成 `terminated`；内存压力下的行为没有实测 |
| S4 | 公证 DMG、quarantine、Sparkle 更新 | **未做，放到 P2 验收**。要用真 App 才有意义；失败也有退路（XPC 服务把 holder 复制到 Application Support 并去掉 quarantine），不影响架构 |
| S5 | 检查点 + 之后字节恢复，1000 个随机切点 | **通过**。恢复后 1000/1000 一致，续播 1000/1000 一致。再改尺寸有 69 次不一致，集中在 shell 语料一行中文：宽字符落在折行处，重排后多一个空格（再次缩小时有 2 次波及屏幕）。只影响显示，接受 |
| S6 | PTY 经 Unix socket 中转（含写环形缓冲） | **部分**。吞吐 100+ MiB/s（直读最高约 146），高于 App 解析速度（约 43 MB/s）；回显 p50 16 → 29 µs。`uterm-ssh` 原型（Citadel 路径）没测，放到 P3 开头 |

S1 补充：App 被杀 30 分钟后复测，上述结果不变。

**一个没查清的差异**：探针 shell 里 `gh` 从钥匙串拿到的 token 是空的（`gh auth token` 长度 0，`gh auth status` 报 token 无效，API 返回 401），普通登录 shell 正常。App 活着时就这样，与 App 退出无关，所以不是 holder 引入的。这个 shell 与现在 uTerm 本机终端都由内嵌 XPC 服务起，可能本机终端也有同样的问题，要在真 uTerm 里核实。进一步读钥匙串的诊断被工具权限拦下，没有做。

几个事实：

- zsh 里 `log` 是内建命令，查系统日志要写 `/usr/bin/log`。
- 沙盒进程对沙盒外进程调 `kill(pid, 0)` 恒返回 EPERM，判断存活要用 `sysctl(KERN_PROC_PID)`。`LocalShellIntegrationTests` 的「结束后进程不在」断言原来因此恒真，已改。
- 跑探针时 App 本身可能在授权框弹出期间阻塞对应的 `ls`，看到 exit=142 是 `alarm` 超时。

### P2 要记得的

- 手机接管后，「列表里出现过又消失的终端」标签会被关掉（`RemoteMacClient.listedSessionIDs`）。Mac 重启后要等会话全部接回再发列表，否则手机标签会被误关。
- 同理，Mac 刚重启时接入一个还没恢复的会话会收到「已被拒绝」，手机标签会结束。接回完成前要让接入等一等或按「连不上」处理。

## 12. 重启不动终端：P2 实现结果（本机 shell）

结构：`uTerm.app` → XPC（`uTermShellAgent.xpc`，只负责拉起和交 fd）→ Unix socket → `uterm-holder`（每会话一个进程）→ PTY → 登录 shell。socket 在 `~/Library/Application Support/uTerm/sessions/<命名空间>/`，正式版 `release`，Debug 按 App 路径哈希。协议见 `uTermHolder/HolderWire.swift`，**只能加帧，不能改已有帧的含义**：运行中的旧 holder 会遇到新 App。

已验证（真沙盒 App 进程 + 真 XPC + 真 holder）：

- 跑着 `vim` 时 `kill -9` App，再重新构建一次：holder 父进程变 launchd，接回耗时 65 ms，同一个 shell pid，vim 还在备用屏并响应按键，App 不在时后台任务照常跑完。
- 断开期间的输出能回放；历史里的终端查询、OSC 52 不会被再执行一遍；`terminate` 结束 shell 并清掉 socket；App 不在时 shell 退出，接回拿到最后一屏后会话消失；第二个客户端接入时第一个收到 `replaced`；40 万字节粘贴完整到达。
- Release 归档：holder 在 `Contents/Helpers/`，hardened runtime，`codesign --deep --strict` 通过。holder 常驻内存约 9.6 MB。

**S4 结果（2026-11-04，通过）**：用两个真实公证的版本 A、B（notarytool Accepted，DMG 已 staple），在临时分支上加了测试钩子，用临时 EdDSA 密钥和本机 appcast，没有碰正式私钥和 OSS。

- 带 quarantine 的 DMG 安装后 `spctl` 判定 `Notarized Developer ID`，App 跑在 App Translocation 路径下，holder 也带 quarantine，没被 Gatekeeper 拦。`kill -9` 后等 30 秒再启动：同一个 shell，画面还原，后台任务不断。
- Sparkle 真实流程（下载 DMG、验 EdDSA、安装、重启）A→B：几秒完成，不弹 ⌘Q 询问，旧 holder 不受影响（它映射的是旧文件），新 App 接回同一个 shell 并能读写，后台任务不断。
- ⌘Q 的「取消 / 保留并退出 / 全部结束并退出」都走过真实对话框，行为符合预期。
- 该环境里 `security list-keychains` 与 `gh auth status` 退出码都是 0。探针里 gh 读不到 token 是探针的问题，不是这个架构的问题。

没测：真正断网时的首启；正式 appcast 和正式密钥（流程相同，只差这两个值）；手机接回同一会话的真机流程。

踩到的坑：

- 系统恢复 `WindowGroup(for:)` 的窗口时，第一次 `.task` 里值是 nil，几十毫秒后才到；我们请求打开的窗口第一次就有值，可以据此区分。系统恢复的窗口之前一直是没有标签的空窗口，每崩溃一次多一个；`open(value:W)` 还会复用它，导致接回根本没发生。这个问题只有端到端才抓得到，单测全绿。现在 nil 窗口直接关，只由 `LocalShellRestorer` 接回，同时 `.restorationBehavior(.disabled)`。
- `LOCAL_PEERTOKEN` / `LOCAL_PEERPID` 查到的是**最后动过对端 socket 的进程**，不是建连接的进程。fd 从 XPC 服务交给主程序后，主程序抢在 holder `accept` 之前发了数据，查到的就是主程序。表现是偶发 `errSecCSReqFailed`（-67050）。所以签名要求要同时放行两个身份。
- `SecCodeCheckValidity` 不收 `kSecCSBasicValidateOnly`（报 `errSecCSInvalidFlags`，-67070）。
- XPC 服务 `SIGCHLD` 设为忽略、工作线程可能屏蔽信号，这些都会经 `posix_spawn` / `exec` 继承。要用 `POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK` 清掉，否则 `waitpid` 拿不到退出码，holder 也收不到 SIGTERM（探针里 SIGTERM 不生效很可能就是它）。
- 沙盒 App 的 Swift 里没有 `connectat`，agent 用 `chdir` + 相对路径绕开 `sun_path` 上限（只在串行队列上做）。
- 测试宿主和 Debug App 路径相同，命名空间也相同，集成测试要用单独的命名空间；恢复逻辑在测试宿主里不自动跑。

已知限制：恢复时分屏布局不还原（同一窗口单组标签）；App 不在时没人回答终端查询；`terminal wait` 的跟踪状态重启后查不到；恢复的窗口用默认大小和位置，不记原来的。

没做：前台进程名和当前目录（方案里「顺带借鉴」的一项，协议可以后加帧）。

## 13. 重启不动终端：P3 实现结果（SSH）

结构：`uterm-holder` 的 PTY 里跑 `uterm-ssh`（相当于我们自己的 ssh 命令）。XPC 服务多建一对 socket 当控制通道，放在 holder 的 fd 3，holder 留给子进程。App 经它交连接参数和凭据、回答主机密钥问题；连上之后 `uterm-ssh` 就关掉它，之后 App 重启与它无关。

- 凭据只在这条通道上走：不进 argv、环境变量和磁盘，`uterm-ssh` 不碰钥匙串。
- 接回不解析凭据、不握手，走 `openSSHSession` 得到已有会话，立刻发一次 `probe`。
- 会话 id 就是窗格 id；工作区快照的标签里记会话 id。SSH 与本机 shell 的 socket 目录分开（`<namespace>-ssh`）。
- 归属（窗口、服务器、标题、先后）存在 holder 里，`SSHSessionRestorer` 清点后交回窗口；快照来不及存的、系统没恢复的窗口也能回来。
- 贴图走 App 自己的共享连接（`uterm-ssh` 里开不了 SFTP）。
- 辅助程序连不上时退回 App 进程内的 `SSHConnection`：只是活不过重启，不能连不上服务器。

**S6 原型（本机 docker，Release，对比 `/usr/bin/ssh`）**：回显中位数 0.47–0.65 ms 对 0.47–0.55 ms；吞吐约 65–68 对 72–77 MB/s；空闲内存 17.6 MB 对 3.5 MB，洪水时约 85 MB。Citadel 的输出流没有背压，慢读者时曾涨到 655 MB，加 16 MiB 有界队列后 94 MB（超了丢最旧的，吞吐数字因此不完全等价）。

**端到端（2026-11-04，真 GUI + 真 sshd，Debug 构建 + 独立数据库，通过）**：

- `kill -9` 后重开：纯终端和工作区两种窗口都回来，同一个远端 shell（`echo $$` 相同），屏幕完整，输入可用，远端后台任务不断。接回 28–173 ms。
- ⌘Q：「还有 N 个终端在运行」。保留：重开接回。全部结束：进程、socket、远端 shell 全部消失。
- 主机密钥首连：`uterm-ssh` 发起，现有弹层显示，指纹与容器一致。
- 远端断开：标签显示「连接已断开」，重新连接得到新会话。
- App 不在时网络静默断（`docker pause`）：重开后约 10 秒判死，标签转为已断开。
- 集成测试（`HeldSSHIntegrationTests`，要测试 sshd）：错误密码、拒绝主机密钥、跳板机、跳板机缺凭据、同 id 立刻重开、resize、并发新主机只问一次。带口令的 ed25519 / RSA 私钥另外手动验过。

**新标签耗时（已知退步）**：同主机原来复用连接约 60 ms，现在每个标签握手一次。本机 docker 上 429 ms（holder 30、钥匙串 14、握手 361，Debug 构建）；小规格实例估计约 2 秒（§「SSH 连接共享」的数字），未实测。每个 SSH 标签多约 27 MB 内存（holder 9.6 + uterm-ssh 17.6）；DMG 增大约 30 MB（压缩前）。

踩到的坑：

- **局域网第一次连接**：`uterm-ssh` 第一次连局域网报 EHOSTUNREACH（errno 65），看起来像权限被拒。TN3179 明说系统可能先拒绝，再确认权限或弹框；用户点允许要几秒（实测 1.4–2.8 秒）。所以 `uterm-ssh` 对 errno 65 重试约 15 秒，点了允许就自己连上；代价是真的没有路由时要多等 15 秒才报错。192.168.215.0/24（OrbStack 的 bridge）也算本地网络，可以用来测这条路径。
- **局域网连接活不过 App（本期最大的坑）**：本地网络权限按责任进程放行，默认责任进程是 App。App 一死，系统立刻丢弃这条已建立连接上的包：容器一侧 `Send-Q` 按输出速度一直涨（100 秒 5876 字节），Mac 一侧还显示 ESTABLISHED。App 重开也恢复不了，`uterm-ssh` 一写就断。公网和回环地址不受影响。修法：XPC 服务拉起 SSH 的 holder 时用 `responsibility_spawnattrs_setdisclaim`（Terminal、iTerm、lldb 同款，SPI，按名字找），holder 自己当责任进程，`uterm-ssh` 继承；holder 内嵌 Info.plist（`Config/uterm-holder-Info.plist`）带 `NSLocalNetworkUsageDescription`。效果：`kill -9` 后 `Send-Q` 一直是 0，重开接回同一个 shell。权限框按 holder 单独弹一次，权限按 holder 的 UUID 记：两次构建只改 App 时 holder 的 UUID 不变（实测相同），Sparkle 更新不再弹；改了 holder 的源码才会再弹一次。
  （2026-11-14 起 holder 是 App 包 `Helpers/uterm-holder.app`：裸可执行文件在 tccd 里只按路径记，系统设置的「辅助功能」等列表里只显示「uterm-holder」和通用图标；做成包后按 bundle id `com.uozi.uTerm.holder` 记，显示「uTerm 终端」和图标。Xcode 不给 App 包内嵌 Info.plist，说明文字改从包的 Info.plist 读。）
- **结束请求会丢**：`HolderProbe.terminate` 原来发完就关连接。holder 刚起来还没 accept 时对端已经关了，取 `LOCAL_PEERTOKEN` 失败，连接被当成身份不明拒掉，会话留在机器上（实测 6 轮漏 9 个）。现在先等 hello 回复再发结束（10 轮 30 个用例不再漏）。
- 同时开几个标签连一台新主机：每个各握手、各问主机密钥，但一个窗口同时只能弹一个 sheet，后来的永远卡在「连接中」。以前靠连接池的 single-flight 避开了；现在 `HostKeyApprovalCoalescer` 合并同一把密钥的询问。第一个问的标签如果被切到后台，弹层要切回去才看得到（行为与之前相同）。
- `UPaneTab.id` 不是 `payload.id`。按窗格 id 找标签要看 `payload.id`，`groups.tab(id)` 找不到。
- 关窗口后立刻重开（快照里还是同一个 id）会接上将死的 holder。holder 收到 `terminate` 时马上删 socket，退出时不能再删一次（这个名字可能已经属于新 holder）。
- 窗格只有显示时才连接，后台标签恢复后一直不接回：手机、CLI 看不到它，⌘Q「全部结束」也关不到它。公证版端到端才测出来。恢复时不等显示，立刻接回（`reattachHeldSessions`）。
- 探活信号 SIGUSR1 的默认处置是杀进程：`uterm-ssh` 启动就忽略它；holder 只在有控制通道时才转发，所以本机 shell 不会被误杀。

已知限制：纯终端窗口的分屏布局不还原（标签按打开先后排在一组，工作区窗口的布局在快照里，能还原）；没有归属或服务器已删除的会话启动时直接结束；断开页不显示最后一屏（现状如此）。

**公证版（2026-11-04，Developer ID + hardened runtime + 公证 + staple，通过）**：测试包用独立 bundle id、独立数据库和本机 appcast，spctl 判定 `Notarized Developer ID`。

| 路径 | 结果 |
|---|---|
| `kill -9`，45 秒后重开 | 局域网和回环会话都 `restored=true`，同一个 shell，接回 19–34 ms；App 不在期间容器 `Send-Q` 为 0 |
| Sparkle A→B（build 600→601） | 下载、替换、重启，局域网和回环都接回同一个 shell，没有再弹权限框 |
| ⌘Q 取消 | 全部照旧 |
| ⌘Q 保留并退出 | App 没了，holder、`uterm-ssh`、远端都在；重开接回 |
| ⌘Q 全部结束并退出 | holder、`uterm-ssh`、远端 sshd 全部消失，socket 清空 |
| quarantine + App Translocation | 能跑，局域网 `kill -9` 后接回 |

判定方法：会话连上时往远端写一行 `name= build= restored= shell=`，再起一个 ticker 每秒写文件和打到终端。

合入 main（贴图权限、真彩、关标签确认、Agent 状态）时补的：连接在 `uterm-ssh` 手里，App 要在上面跑命令，所以 holder 加了一条通用转发（帧 `childRequest` / `childReply`，子进程 fd 4，holder 不看内容）。前台探测和真彩探测都走它，接回后也能用，不碰钥匙串、不握手；每个标签各一条连接，所以不用认 pty。旧 holder 不认这个帧，探测超时后回 `.unknown`，关标签时多问一句。回放期间程序状态和 OSC 9 / 777 通知一律忽略；检查点里也没有状态，所以接回后标签上的状态要等程序下次上报。

本机 shell 里跑着的局域网长连接（比如手动 `ssh 192.168.x.x`）默认同样会在 App 死后断流，重开也恢复不了；App 不在时新连接正常（实测 `nc` 每 2 秒一次）。公网和回环不受影响。给 holder 也 disclaim 能解决，代价是 shell 访问文稿等的授权改记到 holder 名下（探针实测：会正常弹框，允许后可用，`pbcopy`、`security` 不受影响）。这是用户的取舍：第一次手动新开本机终端时问一次（手机、命令行发起的不弹框，按没选算），设置 › 终端可以改，只影响之后新开的终端（`LocalShellNetworkPolicy`）。

没测：真实小规格实例的新标签耗时；从 Finder 拖 DMG 安装的完整首启流程（这里用打了 quarantine 的副本直接打开）。

## 14. 远程桌面：刷新率、色彩、画质（调研，2026-11-04）

只调研、未改代码。探针都在本机（macOS 27.2，主屏是 60 Hz 的 5K 外接屏，内建屏 120 Hz）上跑，素材是 SCK 真实采到的这块屏（原生 5K，按 iPhone 17 Pro 适配算出流尺寸 2144×1206）。画质指标：解码后转回 RGB，与「Lanczos 缩到流尺寸的原图」比 PSNR；「彩色误差」= 参考里饱和像素（max−min>60）的 RGB 平均绝对误差。iPhone 侧没有真机读数。

### 14.1 一页结论

| # | 问题 | 证据 | 改法 | 代价 |
|---|---|---|---|---|
| 1 | **颜色发灰（bug）**：SCK 默认按显示器自己的色域出码值（Studio Display / 内建屏都是 P3 级广色域），但采集帧和编码器都标成 BT.709 原色 + BT.709 传递函数 | 同一画面：默认 vs `colorSpaceName=displayP3` 的码值 MAD 0.14（就是 P3），vs sRGB 0.69；YUV 按 709 矩阵手解与同色域 BGRA 一致（MAD 0.47）。手机按 709 原色解读 P3 码值 → 饱和度约 −17%（码值层面 0.836×） | SCK 显式 `colorSpaceName = displayP3`；编码器标 `ColorPrimaries_P3_D65` + `TransferFunction_sRGB`（矩阵仍 709）。已验证 VT 把这两个写进 hvcC/VUI，解码输出原样带回 | 两三行；需真机目测 |
| 2 | **8-bit 浪费码率** | 低延迟 HEVC **接受 Main10**（hvcC profile 2、10 bit），编码耗时不变（6.4 vs 6.3 ms）。滚动同码率 PSNR：6 Mbps 36.6→38.0，10 Mbps 37.5→39.4，20 Mbps 38.3→40.9 dB。**10-bit 10 Mbps 好过 8-bit 20 Mbps**。全范围 420f 也有 +0.4–0.6 dB | SCK 直接出 `x420`，编码器 `HEVC_Main10_AutoLevel`，解码器输出 `x420` 交给显示层。iOS 18 起步机型（A12+）都有 Main10 硬解 | 小；要量 iPhone 解码耗时 |
| 3 | **放大后糊**：放大是把整帧拉大 | 2× 放大左上 1/4：现状 27.1 dB；按原生像素采这块区域再 10 Mbps 编码 37.4 dB（+10 dB，见对比图） | 调研 §3.2 原计划的 `sourceRect` 区域采集：放大停稳后 `updateConfiguration` 只采可见区域，帧头带区域，手机按区域摆画面 | 中：协议加区域字段、视口与显示层解耦、切换时防跳 |
| 4 | **静止精修几乎没起作用** | 真实桌面 10 Mbps 下首帧已接近 QP 28：QP≤28 精修帧只有 5 KB、+0 dB。QP≤24 +1.1 dB/46 KB，**≤20 +1.9 dB/92 KB**，≤16 +2.5 dB/150 KB，≤12 +2.8 dB/221 KB（P2 的 19→38 dB 是合成噪声画面，不代表桌面） | 码率 ≥10 Mbps 时精修 QP 上限改 18–20；4–10 Mbps 用 24 | 改常量 + 重跑精修丢帧实验 |
| 5 | **iPhone 卡在 60 Hz** | `uTermMobile-Info.plist` 没有 `CADisableMinimumFrameDurationOnPhone`；没有它 iPhone 上的 Core Animation（含 `CADisplayLink` 120 的请求）封顶 60 Hz。iPad 不受影响 | 加这个键 | 一行；真机确认 `AVSampleBufferDisplayLayer` 是否跟着上 120 |
| 6 | **Mac 采集写死 60 fps** | `ScreenCaptureFrameSource` 默认 60、`RemoteRateController.fullFrameRate = 60`。内建屏 120 Hz | 手机报 `maximumFramesPerSecond`，Mac 取 min(手机, 显示器)；节拍器在途上限 120 fps 时 2→3；光标轮询 16→8 ms | 小 |

### 14.2 刷新率

- **真实桌面在 60 fps 不受码率限制**：滚动（每帧 12 点）6 Mbps 实发 59 fps，10 Mbps 起 60/60、码控 0 丢帧。P2 记录的「实发 31–34 fps」是满屏噪声探针造成的，不是正常桌面的上限。码控在这块内容上实发到约 25 Mbps 就饱和（给 40–80 Mbps 也只用 25），所以再抬码率上限对桌面没意义。
- **120 fps 可行**：低延迟 HEVC 单帧耗时 1512×850 4.1 ms、2144×1206 6.3 ms、2560×1440 7.5 ms、3024×1700 11.1 ms、5120×2880 26.2 ms（p95 都只多 0.3–0.7 ms）。120 fps 的预算是 8.3 ms，到 2560×1440 都够；同样的滚动速度下 120 fps 10/20/30 Mbps 实发 119/120/120 fps。画质换算：120 fps 20 Mbps（37.8 dB）≈ 60 fps 10 Mbps（37.5 dB），即**要翻倍码率才保住单帧画质**。
- 节拍器在途上限 2 帧：吞吐上限 ≈ 2 帧 /（编码 + 传输 + 解码 + 确认回程）。回环实测这段 8–9 ms，60 fps 下宽裕；120 fps 只有 16.7 ms 两帧的窗口，Wi-Fi 往返稍抖就会被背压卡掉帧，所以 120 fps 时放到 3。
- 120 只在两端都 120 时开：主屏外接屏是 60 Hz，此时没有收益只有码率代价。

### 14.3 色彩

- SCK 的帧标注**不随 `colorSpaceName` 变**：420v / 420f 一律标 709/709/709，10-bit x420 和 BGRA 什么都不标。所以标注只能由我们在编码器上写，必须和 `colorSpaceName` 成对设置。
- 不设 `colorSpaceName` = 跟显示器走，外接 sRGB 显示器时码值又变成 sRGB，固定标 P3 就会过饱和。所以要**显式设 `displayP3`**，而不是依赖默认。
- 传递函数：码值是 sRGB 曲线（P3 色域也用 sRGB 曲线），应标 `IEC_sRGB`（HEVC VUI transfer 13），不是 709。709 曲线在 Apple 的色彩管理里按视频场景处理，暗部会有偏差；具体偏多少要在 iPhone 上对比（CoreImage 的结果不能代表 `AVSampleBufferDisplayLayer`，没有拿它下结论）。
- 4:2:0 本身的色彩损失：不编码只做色度抽样，彩色误差 3.5（4:4:4 是 1.1）；编码后 8-bit 4:2:0 是 4.9–5.2。普通模式（非低延迟）喂 444v 确实出 RExt 4:4:4（profile 4、chroma 3），这块桌面上编码 6.8 ms，彩色误差 4.3。但普通模式没有 LTR、码控行为不同，而且 **iPhone 能否硬解 HEVC 4:4:4 没验证**，排在最后。替代思路是 RDP 的 AVC444 做法（两路 4:2:0 合成 4:4:4，需要换 Metal 合成），成本高，彩色小字真成问题再做。

### 14.4 画质

1. 区域采集（14.1 #3）是放大看代码 / 终端时最大的收益，+10 dB 量级，比任何编码参数都大。对比图没有入库（素材是个人桌面），按 14.6 的方法可以重做。
2. 10-bit（#2）是全程收益：同码率 +1.4–2.6 dB，不加编码耗时。
3. 精修 QP（#4）：静止画面最终清晰度的上限。
4. 适配模式下流尺寸已经等于手机像素（2144×1206 对 2622×1206 的屏），再提高分辨率只在放大时有用，而放大由区域采集解决，不必整体提分辨率。

### 14.5 建议的落地顺序

1. #1 色彩标注 + #5 Info.plist 键：几行改动，先真机目测颜色、确认 120 Hz。
2. #2 10-bit + #4 精修 QP：一起做，测试里的编解码往返用例要加 x420 分支；真机量 Main10 解码耗时。
3. #6 120 fps 协商：等 #5 真机确认后再做。
4. #3 区域采集：单独一期，协议改动（帧头带区域，旧手机忽略）。
5. 4:4:4：先在 iPhone 上 spike 硬解能力再决定。

### 14.6 复现

探针是一次性的 Swift 脚本（未入库）：SCK 抓一帧原生 5K BGRA 存 PNG；`VTPixelTransferSession` 转各种 YUV 格式；`VTCompressionSession` 低延迟 / 普通模式同步逐帧编码，读 hvcC 第 1、16、17 字节判 profile / chroma / 位深；`VTDecompressionSession` 解回 BGRA 算 PSNR。滚动序列 = 原图上下拼接后每帧平移，按 1/fps 的时间戳喂给编码器（低延迟码控按时间戳记账，不必真等）。

### 14.7 码控：真机 Wi-Fi 读数（2026-11-05）

Mac 端每 2 s 记一行 `桌面码控：…`（`log show --info --predicate 'subsystem == "com.uozi.uTerm" AND category == "remote"'`；
zsh 里 `log` 是内建命令，要写 `/usr/bin/log`）。iPhone Duo 用 `devicectl device process launch … -- -RemoteDebugEndpoint <Mac IP>:<端口> -RemoteDebugOpenDesktop YES`
直接开桌面，Mac 上开个 Terminal 循环 `ls -la /usr/bin` 当滚动画面。

1. **Wi-Fi 抖动不是排队**：1 Mbps 几乎空载时往返基线 30 ms、p50 50、p95 110 ms，与码率无关。按绝对耗时或「连续 3 帧超阈值」判拥塞，码率钉死在 1 Mbps、帧率 30。现在按「最近 300 ms 内最快那帧比基线慢多少」判（`RemoteRateController`），同一链路上目标码率涨到上限 91 Mbps，偶发真排队（p95 253 ms）时降到 45、2 s 内涨回。
2. **低延迟编码器不花预算**：目标 90 Mbps、滚动终端文字，不设 `MaxAllowedFrameQP` 每帧 3–4 KB（1–2 Mbps），字糊。上限 30 → 18 KB/帧不丢帧；≤ 26 → 35–100 KB/帧但码控丢一半帧。
3. **QP 上限一压就透支**：复杂画面上压到 30 每帧近 1 MB，写回 51 放开后还要丢帧还账 4 s 以上（50 Mbps）；写 nil 清属性不生效。所以 `RemoteQualityCap` 从不限起步、每 0.5 s 收一档，非关键帧超每帧预算 1.5 倍或丢 3 帧当场放宽。真机滚动时收到 24、实发 8–14 Mbps、码控丢帧 0；回环高细节画面 60 fps 不丢帧。
4. 在途上限按基线 + 80 ms 抖动余量算（2–8 帧），字节上限 = 目标码率 × 同一段时间（不低于 768 KB）。往返里大头是确认回程（手机上行省电时攒包），画面早到了：上限 4 帧时每 2 s 因在途满丢 10–19 帧、实发约 50 fps；放到 8 帧丢帧归零，往返 p50 / p95 不变（没有排队）。现在实发 = 采集（53–56 fps），再往上要看采集侧：屏幕没变的那一拍 SCK 不出帧。
5. **公网直连上帧往返高不等于网络排队**（2026-11-08，MBP 看无显示器 mini 的 3840×2160 HiDPI 虚拟屏，打洞直连 srflx-v4，两台 Mac 不在同一网段）：链路层丢包 0%、往返 27–85 ms，帧往返 p50 却常在 1.0–1.2 s、p95 1.1–2.0 s，码率被一路压到 1.2–2 Mbps、QP 顶在 51。桌面基本静止（菜单栏时钟和网速图标每秒变），每 2 s 实发 2–3 帧却有 10–14 Mbps：大头是旁路精修——每次静止 300 ms 就把 4K 画面重编成 10-bit 关键帧，走可靠通道（KCP，发送队列里优先级高于视频），几百 KB 一张，它自己的确认要等它发完，之后的主流帧也排在它后面。这些耗时都是我们自己的大帧在发送队列里排着，网络并没有排队。改法：
   - 精修帧的确认不进码控、不进往返读数（`RemoteDesktopStreamer.refineSequences`）；
   - 有链路层估计（视频走数据报）时，帧耗时高只在链路层也量到排队（`RemoteLinkState.queueDelayNanos` > 60 ms）时才算拥塞，否则照常往上试（`RemoteRateController.observe(…, linkQueueing:)`）。编码器拿到的码率本来就和链路节奏 × 0.9 取小，网络真扛不住时由链路层退节奏；
   - 下限从 1 Mbps 改成每像素 1 bit/s、夹在 2–8 Mbps（`minimumBitrate`）；中继转发（TCP，没有链路节奏兜底）仍是 1 Mbps；
   - 码控日志多了「编码器」实际码率和每 2 s 的关键帧 / 精修数。

   没动的：精修本身的频率（静止的屏幕上时钟每跳一次就精修一张 4K）与它在发送队列里的优先级，是下一步可省的流量。

## 15. 跨公网：自建中继 + 打洞（2026-11-05，分支 `feat/remote-wan`）

运行时顺序：局域网 → 打洞 → 约 3 秒后走中继。实现顺序相反：先中继，因为打洞交换地址也要这台服务器，而且中继是兜底。计划全文见提交说明，分四步：G0 基础设施、G1 中继、G2 打洞可行性、G3 P2P 可靠层、G4 体验。**目前完成到 G3 的代码，只在模拟链路和本机真实 ICE 上验证过，真机数据还没有；G4 没开始。**

### 落地内容

- **传输抽象**：`RemoteTransport`（`RemoteLink` 脚下的可靠有序字节流）。发送完成回调必须表示数据已被链路接走，`canSendMore` 和快照兜底都靠它。
- **密钥确认**：`.keyConfirm` 帧。Mac 收到第一个合法密文才授权、才写信任；公网路径强制要求。
- **中继 `relay/`**：Go 标准库，一个端口号同时开 TCP 和 UDP（STUN）。协议见 `relay/PROTOCOL.md`。只转发不解密。
- **信令**：`RemoteSignalBox`，两端长期密钥 X25519 → HKDF → ChaChaPoly，AAD 绑定方向和会话，带重放窗口。会话握手密钥从两端随机数派生，包住明文握手帧，中继看不到设备名和公钥。
- **公网门禁**：总开关默认关，每台设备单独勾选，名册设备也不例外；不弹审批框；不认识的设备收不到任何回应；未勾选的得到可重试的 `notAllowed`；未认证连接最多 8 条；公网连接永远开静默判死。
- **桌面**：公网起始 6 Mbps，上限和局域网相同（不设固定额度），在途上限放宽到 30 帧、由字节上限（带宽时延积）约束。
- **打洞诊断**：`vendor/libjuice` + `RemoteICEProbe`，手机上长按 Mac 那一行进入。只量不接业务，记录不含 IP。
- **直连**（`RemotePathDialer` + `RemoteDirectAttempt` + `RemoteP2PTransport`）：手机把地址放进 offer，Mac 回自己的地址，ICE 打通后再用带认证、填满到 1200 字节的一来一回确认路径。任何一步不成走中继。旧版本对端不带地址，自然走中继。
- **分块粘贴**：`desktopPasteChunk`，32 KB 一块，新能力位 `desktop-paste-chunks`。公网上一张图要传十几秒，整条发的话按键和确认都得排在它后面。
- **在途额度分开**：视频不再计入 `canSendMore`。一个关键帧就几百 KB，算进去终端会以为链路堵了、改发快照。

### 丢包策略

**核心判断：丢包不等于拥塞。** 蜂窝和跨省链路随机丢 1–5% 很常见，这时降速不会少丢一个包，只会白白损失带宽。TCP 就栽在这里。所以三层各管各的：

| 层 | 内容 | 丢了怎么办 |
|---|---|---|
| 链路（`RemoteDatagram` / `RemoteLinkEstimator`） | 每个包 AEAD + 防重放窗口；接收方每 50 ms 报告；令牌桶发送节奏，控制消息优先于视频 | 只有排队（最快往返比基线慢 40 ms）或大量丢包（≥20% 持续 1 秒）才算拥塞。随机丢包不降速 |
| 控制和终端（`RemoteKCP`） | KCP 可靠重传，和视频完全分开，互不阻塞。完成回调等对端确认 | 重传。按带宽时延积调窗口 |
| 视频（`RemoteVideoDatagram`） | 分片，每片带完整帧信息 | 依次：XOR 纠错（不用等往返）→ NACK 重传 → 尾部探测 → 分片还在到就继续等 → 超时放弃 → LTR 恢复帧 → 最后才是关键帧 |

纠错强度按实测丢包调：<0.5% 不开；<2% 每 16 片一个；<5% 每 8 片；<10% 每 5 片；再高每 3 片。往返 <20 ms 且丢包 <5% 时重传够快，不开。

编码码率不超过发送节奏的 90%，再扣掉纠错分片的份额。旁路精修帧不在参考链里，走可靠通道。

**LTR 探针（硬编硬解）：** 每帧都拿 token。HEVC 恢复帧约 68 KB（IDR 518 KB），H.264 约 81 KB（IDR 510 KB），图像误差和普通帧相当。**把缺参考的 P 帧喂给 HEVC 硬解会让它进入 -12909 的粘性错误，之后连恢复帧也解不了**，所以手机在恢复期跳过所有帧，直到收到关键帧或恢复帧。iOS 解码器和 Main10 没验证，恢复帧解不出来会退回关键帧。

### 读数（Debug，回环 + `RemoteFaultProxy`）

| 场景 | 结果 |
|---|---|
| 终端，往返 100 ms、丢包 1% | 按键→回显 p50 约 120 ms，p95 约 129 ms |
| 桌面，10 Mbps、往返 100 ms、丢包 1%，高细节滚动 | 码率 6.0 → 7.5 → … → 收敛到 1.1–1.7 Mbps，12 秒显示 89 帧，最长间隔 1.76 s，往返 p50 214 ms |
| 经真实 `uterm-relay` 的端到端 | 9 个用例全过（`make test-relay-e2e`） |
| libjuice 本机打通 | 往返约 0.25 ms，零丢包 |
| 局域网回环，改动前（11c4e6da）→ 改动后，各 3 次 | 按键→后端 p50 3.03–3.19 → 2.93–3.15 ms；输出→手机 p50 0.39–0.43 → 0.29–0.42 ms；接入到首帧 14.1–16.6 → 16.3–20.1 ms |

**直连，同样的链路**（`RemoteMemoryDatagramPath` 模拟，真实编码器和解码器）：

| 场景 | TCP 中继 | 直连数据报 |
|---|---|---|
| 桌面，10 Mbps、往返 100 ms、丢包 1%，高细节滚动，12 秒 | 约 1.4 Mbps，显示 89 帧，最长间隔 1.76 s | 6.9 Mbps，显示 206 帧，最长间隔 0.28 s，放弃 0 帧，关键帧只有开流那 1 个 |
| 可靠流，同上 | 约 1.4 Mbps | 约 6 Mbps，瓶颈缓冲丢包 0，往返约 150 ms |
| 视频占满上行时的按键（手机→Mac），单程 | 未测 | p50 54 / p95 58 ms |
| 丢 50% 持续 1.5 秒之后 | 未测 | 0.2 秒恢复画面，不断连，没有新增关键帧 |
| 丢包模拟（300 帧，往返 60 ms，确定性） | | 1%：放弃 0，开销 14%；5%：放弃 0，开销 30%；20%：放弃 10，开销 51% |
| 真实中继 + 真实 libjuice + 终端（本机） | | 拨号到连上 685 ms，2 MB 输出完整通过 |

这些都是本机模拟，不是真实网络。真实蜂窝的抖动、限速器和打洞成功率都没量过。

桌面收敛到约 1.4 Mbps 不是码控保守：TCP 在往返 100 ms、丢包 1% 时的理论吞吐（Mathis：MSS / (RTT·√p) × 1.22）就是约 1.4 Mbps。这也是中继路径的硬限制：**打洞失败时走 TCP 中继，上面的丢包策略帮不上忙。**代理按「每次丢包晚 200 ms」模拟重传，不模拟拥塞窗口，所以这只是吻合，不是证明；真实链路要真机读数。

### 踩到的坑

1. **`asyncAfter` 不保序**：`dispatch_after` 的容差约为延迟的 10%，后挂的短定时器会抢在先挂的长定时器前面。故障代理原来给每段数据各挂一个定时器，排队一长字节流就乱，解密失败、连接反复重连，看上去像码控 bug。现在每个方向一条 FIFO、只挂一个定时器。
2. **`serve` 与 `config` 同时启动各生成一把密钥**：导出的配置和服务器手里的公钥对不上，全部 `auth` 失败。用户 `docker compose up -d` 后立刻取配置就会撞上。现在生成密钥持文件锁。
3. **握手 Task 比 server 活得久**：`RemoteHostConnection.server` 是 unowned，公网路径多了等密钥确认这一步，server 先释放就崩。握手期间强持 server。
4. **丢弃 `RemoteLink` 就看不到断开**：释放后回调不再触发，测试里 `let (_, inbox) = …` 会把「被断开」测成超时。
5. **一帧的时限不能只按预估算**：节奏刚被压下去时，一帧发得比预估慢，时限一到就判丢；丢帧又触发降码率，码率被压到 1.2 Mbps。改成分片还在到就继续等，总时长封顶 1.5 秒。
6. **探测上限不能只靠排队信号**：节奏每个往返涨 25% 的话，等排队信号回来已经冲过头，瓶颈丢了 570 个包。改成撞过一次之后每个往返只涨 5%，且不超过实际送达的 1.25 倍，瓶颈丢包降到 0。
7. **一把握手密钥不能在两条路径上各加密一遍**：会造成 ChaCha nonce 重用。手机只在路径确认之后才在直连上发握手，确认没过才走中继，一个会话只会走一条。
8. **`KCP` 发送前要先更新时钟**：空闲一阵之后不更新，时间戳是旧的，往返全算错。
9. **抖动不是排队，乱序不是丢包**（2026-11-09，弱网矩阵「高延迟抖动」10 Mbps、往返 300 ± 150 ms，直连四种画面全 0 fps）。三处一起改：
   - 节奏估计：150 ms 窗口里只有两三份报告，最快的往返也常比基线慢上百毫秒，被当成排队一路退到下限 0.2 Mbps。现在排队门槛加 3 倍抖动（抖动只从往返变短那一步量，排队涨起来时不会把门槛抬高），量满 10 次往返之前不判排队。
   - 接收端乱序窗口：固定 6 ms 时几乎每个分片都被当成丢了去要重传。现在按 RACK 的思路，没被要过重传的分片（或要了不到半个往返就到的）晚到多久，窗口就撑到多大，之后慢慢收回；整帧没见过的也等过窗口再要。
   - 关键帧时限：接收端没有能用的参考帧时，放弃关键帧只能再要一个一样大的。以前封顶 5 s，184 KB 的首帧在被压低的节奏上要 6 s，每次都被放弃。现在关键帧的时限至少 5.001 s（接收端靠「超过 5 s」认出它），封顶 30 s，发送端也留到同样久；分片停了照样按「最后一片后两轮重传」放弃。
   - 读数（直连，各 3 轮中位数）：首帧 > 20 s → 0.93 s；打字 0 → 9.9 fps、交付 99%、延迟 p95 249 ms；局部滚动 / 小区域 0 → 29.6 fps；满屏 0 → 16.7 fps（同链路中继 9.9 / 29.4 / 29.6 / 20.0）。

10. **重传不能压在声音前面，尾部探测要从真正发出去算起**（2026-11-09，弱网矩阵 3G 直连声音欠载 4–12 次、局部滚动 3–4 fps）。临时计数器读到的根因：尾部探测从「交给发送节奏队列」那一刻计时，3G 上节奏队列排好几秒，排着的帧每个往返都被探一次；探测插在新视频前面，接收端见到尾片就把整帧要一遍，连还没发出去的分片也重传。稳态丢包 0.5–3% 时，重传与新视频一样多（每 2 s 40–160 KB 对 25–130 KB），节奏队列堆到 287 KB（约 3 s）。以前重传排在控制队列里、压在声音前面，所以声音欠载。三处一起改：
    - 节奏队列分四级：控制 > 声音 > 视频重传（含尾部探测）> 新视频。只做这一条：声音好了，视频照样被重传流冲垮（3G 局部滚动 0.1–0.3 fps）。
    - 尾部探测从每帧最后一片离开节奏队列时开始计。
    - 发送端对重传去重：一片的上一份重传还在队列里、或发出去不到一个往返（还在路上），就不再排一份。开流时 254 KB 的首个关键帧，以前被要了约 530 KB 的重传，现在约 270 KB。
    - 读数（直连，main 与修复交替各 3 轮）：3G 满屏 0.1–0.3 → 1.5–3.4 fps，局部滚动 2.9–4.0 → 15.7–16.7，小区域 5.6–7.9 → 16.7–17.5，打字 9.3–9.8 → 8.0–9.5，首帧 4.0–6.7 → 3.4–3.6 s，声音欠载 0–12 → 0–3；高延迟抖动四种画面与声音补洞两边持平。

### 负载敏感的用例（2026-11-09）

`RemoteDesktopDatagramTests`（直连门槛：声音 + 视频、随机丢包、重度丢包、按键）用真实编码器跑十几秒，读数跟着机器负载走，**单看红绿会误判**：

- 基线（47ef9371）整组跑 3 次红 2 次。声音 + 视频那条的收包数取决于升到 384k / 10 ms 那一档的时机；重度丢包时关键帧数忽高忽低。
- HEAD 与「只回退帧时限那一笔」交替各跑 20 次：随机丢包闸门单跑 40/40 对 39/40；整组跑的失败数是声音 + 视频 5 对 4、重度丢包 2 对 5、随机丢包 0 对 1。两边的失败都是噪声，跟改动无关。
- 对照改动前后：**交替跑**（前、后、前、后……），每次记平均负载，看输出里的 `[直连探针·…]` 那几行（显示帧数、最长间隔、放弃、编码器丢、码率曲线），不要只数红绿。一次红不能说明退化，一组读数整体变差才算。
- 全量并行跑（`make test-fast`）时这一组和性能探针一样会假红，以串行复核为准。

### 需要真机

**G1 闸门**：手机走蜂窝连家里的 Mac，经中继控制终端和桌面。

**G2 矩阵**：手机 设置 › 关于 › 网络诊断（或长按 Mac → 网络诊断），填网络备注，选轮数后开始：IPv6 直连、IPv4 直连、中继各跑 N 轮，页面上给每条路的通过率、建立耗时、往返 p50 / p95 与丢包，「复制全部」发回来。

| 手机 | Mac |
|---|---|
| 移动 / 联通 / 电信蜂窝（IPv4、IPv6 都看） | 家宽 |
| 公司或酒店 Wi-Fi | 家宽 |
| 蜂窝 | 另一条蜂窝的热点 |

建议的停止规则：家宽↔蜂窝成功率低于 30% 就不做 P2P，只留中继。公开资料没有国内运营商的数据，只能实测。

**G3 闸门**：真实直连上持续 13 Mbps，往返 p95 优于 TCP 中继，手机耗电不明显变差。设置 › 日志里搜「直连：」「桌面码控」能看到路径和链路读数。

### 真机读数（2026-11-06）

中继在一台云服务器上（systemd，见 `relay/README.md`）。Mac：宽带，出口经代理的 TUN 网卡；手机：蜂窝，**无 IPv6**。Debug 包，`-remote.internetOnly YES -RemoteDebugPathMatrix 3` 自动跑、`devicectl --console` 收输出。

| 路 | 通过 | 建立 | 往返 p50 | 往返 p95 | 丢包 |
|---|---|---|---|---|---|
| 直连 IPv6 | 0/3 | – | – | – | 手机无公网 IPv6，立即判失败 |
| 直连 IPv4 | 0/6 | – | – | – | 两轮共 6 次全部 15 s 超时 |
| 中继 | 6/6 | 596–1199 ms | 96–113 ms | 143–410 ms | 0% |

- **G1 通过**（10:43–10:46，蜂窝，Mac 日志确认「直连没打通 → 中继回拨接通」）：打招呼到中继接通约 4.6 s（打洞等 3 s + 收集地址约 1.2 s，可优化）；终端开、用、关正常；桌面 2600×1462 HEVC 可控。桌面读数（Mac 码控日志，每 2 s 一行）：基线往返约 100–110 ms；平常画面帧往返 p50 140–210、p95 200–450 ms，约 40–55 fps；大面积变化时实发封顶约 4 Mbps，帧率掉到 10–20 fps、QP 上限顶到 51、p95 400–800 ms，最差一次 p95 1.7 s。用户体感「卡卡的」。这是跨境蜂窝上 TCP 中继的上限：Mathis 估算 + 实测一致，调码控救不了，要么中继加 UDP 转发（丢包策略才用得上），要么打通直连。
- 同一中继、手机在家里 Wi-Fi（同城）：基线 33 ms，帧往返 p50 44、p95 111 ms；实发到 5.2 Mbps 就开始丢帧、p95 456 ms——和蜂窝撞的是同一个上限。
- **约 4–5 Mbps 的上限来自 Mac 上代理软件的增强模式（TUN），不是中继也不是宽带**（2026-11-06 实测）：

  | 方向 / 路径 | 单连接 | 8 连接 |
  |---|---|---|
  | 中继服务器 → Mac（SFTP 下载） | 89 Mbps | 96 Mbps |
  | Mac → 中继服务器（SFTP 上传，经代理 TUN） | **2.9 Mbps** | 53.5 Mbps |
  | Mac → Cloudflare 上传，经代理 TUN | 9.4 / 5.1 Mbps | – |
  | Mac → Cloudflare 上传，绑 `en0` 绕过 TUN | 36.5 / 50.9 Mbps | – |

  Mac 的每条 TCP 都进代理软件的用户态网络栈，下载不受影响，**单连接上传**被压到几 Mbps。Mac → 中继正是一条上传为主的单连接，桌面就卡在这里。代理的假 IP（fake-ip DNS，`198.18.x`）也意味着按名字解析出来的地址只在 TUN 里有效。处理：在代理软件里把中继地址排除出 TUN，如 `tun-excluded-routes = <中继 IP>/32`（让中继的包根本不进 TUN；规则写 DIRECT 不够，DIRECT 仍走用户态栈），或 uTerm 的中继 / 打洞套接字自己绕开 TUN（会连带绕开用户的 VPN，要做成选项）。
- **G2 这一组合不过停止线**：蜂窝（无 IPv6）↔ 宽带（代理 TUN 后）IPv4 打洞 0%。只有一种组合，还不足以按停止规则砍掉 P2P；至少再测内地蜂窝（有 IPv6）与关掉 Mac 代理的情况。
- **G3 没法测**：没有一条真实直连。

测试方法上的两个坑：
- **手机插着线时，打洞会打通那根线**。USB 链路的 `fe80::` 与 `devicectl` 调试隧道的 ULA（`fdec:…`，经 USB 或 Wi-Fi）都会进 ICE 候选，配对出 1–2 ms 的「直连 host-v6→host-v6」。诊断里一律去掉链路本地与 `fc00::/7`（`RemoteICEDescriptionFilter`）；正式连接没去，插线时被选中也无害。
- **插着线时 Bonjour 也能经 USB 找到 Mac**，连接直接走局域网，测不到公网。「只走公网」开关（`remote.internetOnly`，网络诊断页上可切）专为此加。
- **「只走公网」光跳过 Bonjour 不够**：同一 Wi-Fi 下打洞会配上两端私有 IPv4（host-v4 ← host-v4，链路 13 ms）；开着 Clash / Surge 一类代理时 Mac 还有 `198.18.0.1`（代理 TUN 的假地址）当 host 候选。打开开关后打洞不用私有 / CGNAT / 回环 / 198.18/15 地址；网络诊断始终如此。
- **手机看延迟**：远程桌面左上角调试信息最前是「延迟 X ms（p95 Y）」，是 Mac 量的画面往返（新消息 `desktopLatency`，开流时要了才发）。

### 没做

G4（空闲切换直连、多中继选路、一键部署）、公网扫码配对、TURN、Mac 远程唤醒。中继路径上的 UDP 转发（打洞失败时也能用上丢包策略）也没做：要看真机测出的打洞成功率再决定。

## 16. Mac 控制 Mac（2026-11-07 起，分支 `feat/mac-remote-p0`）

目标：在 Mac 上控制另一台 Mac 的终端与桌面，和手机控制 Mac 是同一套协议与客户端代码。

### 定下来的规则（user 定）

- **所有设备都要配对**，不论主控端是 iPhone 还是 Mac，不论是不是同一 Apple ID。iCloud 名册整体删除：它不再放行任何连接，也不再用来列 Mac。
- **可以跨 Apple ID、跨网络配对**：邀请（二维码 / `uterm://pair` 链接）带上中继配置。
- **配对是单向的**：A 配对去控制 B，不代表 B 能控制 A。
- 一台远程 Mac 一个窗口，桌面和各个终端做成同一窗口里的标签页。

### 复用

主控端核心本来就在 `uTerm/Core/Remote/`，两端都编：`RemoteMacClient`、`RemoteTerminalBackend`（实现 `TerminalBackend`）、`RemoteDesktopSession` / `RemoteDesktopReceiver` / `RemoteVideoDecoder`、中继与打洞。Mac 新写的只有界面与 NSEvent → `RemoteDesktopInput` 的映射。要从 iOS 抽到共享的：`RemoteMacDirectory` 的发现 / 合并 / 客户端缓存，`MobileWorkspace.follow` 的整台接管增减计算，解锁密码库的存取。

### 信任表分方向

`RemoteIdentityStore(role:)`：`.controllers` = 允许来控制本机的设备（账号 `trustedPeers` / `blockedPeers`，被控端用），`.hosts` = 本机控制的主机（macOS 上 `trustedHosts` / `blockedHosts`；iOS 只当主控，沿用 `trustedPeers` 免迁移）。本机长期密钥与设备 ID 两个方向共用。必须分开的原因：共用一张表时，Mac A 记下的「我要控制的 B」会被 A 的被控端当成「允许 B 来控制我」。`RemoteHostServer` 与 `RemoteMacClient` 的 init 都对方向做 `precondition`。

### 分期

| 期 | 内容 |
|---|---|
| P0 信任模型 | 删名册；信任表分方向；主控端「附近的 Mac」+ 局域网审批（iOS 一起）；列表排除本机；握手加 `platform`，Mac 报商品名（设备树 `IODeviceTree:/product` 的 `product-name`） |
| P1 跨网邀请 | 邀请 v2 带中继配置；公网入口接受一次性凭据（仍不弹审批框）；邀请有效期内信令回应陌生设备 ID；Mac 注册 `uterm://` 与「粘贴邀请链接」 |
| P2 Mac 远程终端 | 「我的 Mac」入口、远程 Mac 窗口（`UPaneGroupArea`，终端标签复用 `TerminalSession` + `RemoteTerminalBackend`）、整台接管 |
| P3 Mac 远程桌面 | NSView + `AVSampleBufferDisplayLayer` 画布、输入映射（纯函数单测）、剪贴板、解锁 / 帘幕、全屏 |
| P4 | 系统快捷键拦截、光标形状、多显示器、窗口拉伸后重开流、Mac 网络诊断页、中继按成员发密钥 |

已知代价（P4 已解决，见下）：邀请带的中继成员密钥是所有成员共用的，交出去等于把中继分享给对方（他连不上没和他配对的主机，但能用中继流量）；收回只能换成员密钥。

### P0 落地

- 名册：`RemoteCloudRoster` / `RemoteRosterEntry` 删除；同步钥匙串存储改名 `RemoteSyncedStorage`（只剩中继配置在用）。两端启动时 `RemoteLegacyRoster.withdrawLocalDevice()` 撤下本机在旧名册里那一条，免得还没升级的设备继续凭它放行。
- 被控端：`recognizes` 只看本机信任；公网接入可勾选的就是配对过的设备（手机、Mac 都算）；`knownPeer` 不再查名册。升级前已经连过的设备不受影响（当时已写进本机信任）。
- 主控端：`knownMacs` 只列本机信任；新增 `nearbyMacs`（Bonjour 里在线、没配对、不是本机），iOS 主机页多一组「附近的 Mac」，点了进同一个 `RemoteMacSheet`，审批通过后 `onPaired` 让目录立刻把它挪进已配对。客户端再连已配对的 Mac 只更新名字 / 机型，保留别名与配对时间。
- 握手：`RemoteHello.platform`（字符串，`mac` / `mobile`）与被控端也报 `deviceModel`；`RemotePeer.platform` 落盘，设置页按它显示 Mac 图标。

### P1 落地：跨网邀请

- **邀请带中继**：被控端开着公网接入（已注册到中继）时，邀请多带 `rn` / `rh` / `rp` / `ri` / `rk` 五个参数，版本号仍是 1，老版本照样能在局域网里配对。中继参数缺或坏就当没带，邀请本身不作废。设置页二维码旁加「拷贝链接」，说明里讲清对方会一并拿到这台中继。
- **信令外层**（`RemoteInvitationSignal`）：平时的信令用两端长期公钥协商的密钥封，被控端按设备 ID 查到对方公钥才解得开；凭邀请来的设备它还不认识。主控端带着令牌时，在信令外再包一层（前缀 `p1:`，密钥由令牌经 HKDF 派生，AAD 绑定会话），里面放自己的长期公钥。中继看不到公钥，没有令牌的人做不出被控端肯打开的外层；回复照常用长期密钥封。被控端只在出示邀请期间认外层，且这时不看「允许经公网接入」。
- **公网入口**：`authorizeFromInternet` 认不出对方时，核销邀请凭据（绑定对方公钥，一次性），通过就信任并经 `grantInternetAccess` 替它勾上公网接入，仍然不弹审批框。
- **主控端的中继按主机记**：`RemoteRelayPlacement` —— 本机没有默认中继、或就是同一台（换了成员密钥）就存成默认，否则记在这台主机的 `RemotePeer.relay`（本机专属钥匙串），不顶掉自己的中继。连上后主机发来的中继配置走同一规则（以前一律覆盖默认）。iOS 目录按中继分别问谁在线，每台 Mac 只看自己那台中继。
- **iOS**：扫码之外，打开 `uterm://pair` 链接也能配对（`RemotePairingLinkHandler`，先确认）；配上的 Mac 一上线（局域网或中继）自动打开，用掉邀请。Mac 端接收邀请（URL scheme、粘贴链接）随 P2 的 Mac 主控界面一起做。

### P2 落地：Mac 远程终端

- **入口**：欢迎窗口侧栏「动作」里的「我的 Mac」，在欢迎窗口右侧换成 `RemoteMacsPane`（与快捷命令同级，⌘数字可直达）：已配对的 Mac（局域网 / 公网 / 不在线）、附近的 Mac、「粘贴邀请链接」。Mac 注册了 `uterm://`，`UTermLifecycleDelegate.application(_:open:)` 接住 `uterm://pair`（不让 SwiftUI 另开窗口），打开欢迎窗口并切到这个面板确认；冷启动时先存着（启动行为是「恢复」时也留着欢迎窗口）。
- **远程 Mac 窗口**：`WindowGroup(for: RemoteMacWindowID)`，一台 Mac 一个。第一次连时窗口里显示核对码；连上后整台接管（`RemoteMacWindowModel.takeOver`），之后按 `RemoteSessionFollower` 跟着那台 Mac 增减标签。标签区是 `UPaneGroupArea`（可拖放分屏，不显示分屏按钮：远程终端复制不出来），「＋」在那台 Mac 上新开本机终端。关标签 / 关窗口只断开接入。远程标签不登记进本机 `TerminalSessionRegistry`，免得控制这台 Mac 的手机看到别的 Mac 的终端。
- **共享**：`RemoteMacDirectory` 挪进 `uTerm/Features/Remote/`（两端共用，iOS 的后台任务在 `RemoteMacDirectoryLifecycle`）；对账抽成 `RemoteSessionFollower`，iOS 工作区也用它。有意差异是参数：`adoptsRelayAsDefault`（Mac 为 false，主机带来的中继一律按主机记，不换掉本机被控时用的那台）。调试用的链路矩阵只在 iOS 编（`RemoteNetworkLabel` 还在手机诊断页里）。
- **还没做**：Mac 端网络诊断页。`Info.plist` 的本地网络说明还只写了手机（与主工作树里未提交的改动在同一行，合并时一起改）。

### P3 落地：Mac 远程桌面

- **单独一扇窗口**（2026-11-07 改，原先是终端窗口里的一个标签）：`WindowGroup(for: RemoteDesktopWindowID)`，一台 Mac 最多一扇，整窗黑底、顶上一条细工具栏（名字与状态、适配 / 原始大小、帘幕、全屏），和手机上的远程桌面一样。入口：远程 Mac 窗口标签条上的显示器按钮、没有终端时的「查看屏幕」、「我的 Mac」里每台的「…」菜单。改的原因：放在标签区里控制页不干净；实测在标签里画面会整块黑一下（手机不会），单独窗口顺带绕开标签区的透明 / 裁剪托管。会话就是手机用的 `RemoteDesktopSession`，一行没改；画面尺寸按本机最大那块屏幕的像素要（至少 1080p）。
- **两扇窗口共用一条连接**：目录按 Mac 只缓存一个 `RemoteMacClient`，以前远程 Mac 窗口关闭时直接 `disconnect()`，会把屏幕窗口一起断掉。改成按窗口计数：`acquireClient(for:)` / `releaseClient(macID:)`，最后一扇关掉才断开。关屏幕窗口只停画面（那台 Mac 停采集、撤帘幕）。
- **画布**（`RemoteDesktopMacCanvas`，mac-only）：`AVSampleBufferDisplayLayer` 在解码队列上直接 enqueue，同手机。视图是图层宿主（自己建根图层再 `wantsLayer`，AppKit 不动这棵树）；视频图层的 frame 只在变了时才设（鼠标一动光标回报约 60 次/秒，以前每次都重设）；渲染器出错或要求 flush 时记日志（「远程桌面画布：渲染器出错…」）再接着送帧，画布建立 / 拆除也记一笔，再遇到黑一下可以从日志判断原因。指针是**绝对坐标**：本机指针在画面上就是那台 Mac 的指针（那边采集不画光标，本机光标就是它，零延迟）；本机指针不在画面上或只能查看时，按回报位置画箭头。黑边上的点贴到最近的屏幕边。
- **键盘**：画布是第一响应者时按原始虚拟键码发（两台 Mac 同一套），不进本机输入法，中文由那台 Mac 的输入法处理；`performKeyEquivalent` 截下 ⌘ 组合，不进本机菜单。例外：⌘W 关本机这扇屏幕窗口（窗口的监听先拿到）；纯 ⌘V 在本机剪贴板有图片 / 文字时改成「粘贴到那台 Mac」（那边写剪贴板再按 ⌘V），拷贝的是文件或剪贴板空就照常发 ⌘V。修饰键走 `flagsChanged` → 单独的按下 / 抬起，大写锁定每次完整按一下。失焦（`resignFirstResponder` / 窗口失去 key）把还按着的键和鼠标键全部抬起。系统级快捷键（⌘Tab、⌘空格）本机系统先拿走，发不过去——放 P4（event tap）。
- **滚动**：`scrollingDeltaX/Y` 原样传（方向已按本机「自然滚动」换算，注入那边不再反），滚轮的「行」×10 像素；阶段与惯性阶段一一对应，`mayBegin` 不发。
- **剪贴板**：那台 Mac 拷贝的文字（`desktopClipboard`）写进本机剪贴板并提示；本机 → 那台走 ⌘V 接管，图片 PNG / JPEG 原样，TIFF 转 PNG，超上限在后台转 JPEG 逐级降质量再缩边（ImageIO，`RemoteDesktopMacPasteSource`）。
- **显示**：只有「适配窗口」（2026-11-08 去掉了「原始大小」与推边跟随）。第一次拿到画面尺寸时把窗口调成那块屏幕的比例（保持顶边、不超出可见区域，换显示器后再调一次），不留黑边。全屏按钮走窗口的系统全屏。
- **顶栏**（2026-11-08 改）：居中是状态点 + 名字，只有不正常（连接中、只能查看、重连…）才带文字；右边依次是切换显示器（多于一块才有）、⌘ 开关、读数开关（读数改成画面左上角的小胶囊）、帘幕、全屏。
- **画面「偏胖」**：用户截图量过，没有拉伸（红绿灯正圆）。无显示器的 Mac mini 系统给的是 1920×1080 的 1 倍（非 Retina）虚拟屏，文字按 1 倍栅格化后再缩放进窗口就显得粗、发虚。治本是 HDMI 欺骗器设成带 HiDPI 的模式，或 uTerm 自己建 HiDPI 虚拟屏（私有 API，P4 评估）。
- **锁屏 / 帘幕**：锁屏时画面上盖密码框（不保存，Mac 端没有手机那样的面容 ID 钥匙串）；没锁时工具栏有帘幕开关。
- **测试**：`RemoteMacDesktopTests`——换算纯函数、剪贴板读写（独立命名的剪贴板）、屏幕窗口模型（没连先连、已在放不重开、关窗停画面不断连接）、共用连接的窗口计数（真实 `RemoteHostServer` + 合成采集），以及画布对着真服务端发出的点击 / ⌘C / 失焦补抬起（构造 NSEvent 直接喂视图，注入端是记录器）。截图用例多了「屏幕窗口-连接中」。
- **闪烁排查**：同一画布挂在普通窗口里、假 Mac 推帧时，4 秒内画布没有重建、视频图层一直是正常显示、没有报错，说明不是解码或渲染器失败；两台真 Mac 上（被控端是无显示器的 Mac mini）在标签里会黑一下。改成单独窗口 + 上面的图层改法后待真机复测。
- **没验**：真实两台 Mac 的手感（延迟、原始大小下推边、⌘ 组合在各 app 里的表现）、窗口拉伸后画面清晰度（流按开流时的尺寸，不随窗口重开）。

### P4 落地

- **系统快捷键**（`RemoteDesktopKeyboardCapture`，mac-only）：⌘Tab、⌘空格、调度中心、⌘W / ⌘Q 这类本机系统先拿走的组合，用键盘事件钩子（`CGEventTap`，`.cghidEventTap` 头部插入，要「辅助功能」授权）截下交给画布。只在屏幕窗口是前台、画布有焦点、有控制权、顶栏 ⌘ 开关开着（`DefaultsKey.remoteDesktopSendSystemShortcuts`，默认开）时挂着；切走窗口或 app 立刻摘掉。挂不上（没授权）时提示去哪里打开。鼠标不截。关掉开关就回到 P3 的行为（⌘W 关本机窗口）。
- **光标形状**：开流请求带 `cursorImages`；被控端每 0.1 秒取一次 `NSCursor.currentSystem` 的指纹（热点 + 最小位图），变了才把 2 倍图编成 PNG 发 `desktopCursorImage`（消息 39，`RemoteSystemCursor`）。主控端画布按它建 `NSCursor` 挂在画面区域的 cursor rect 上，本机指针就是那台 Mac 的光标形状。老版本不发，照旧箭头。
- **多显示器**：`info` 回带 `displays`（id / 名字 / 尺寸 / 是否主屏，主屏在前）；多于一块时顶栏有「切换显示器」菜单，`RemoteDesktopSession.switchDisplay(to:)` 停流再按新 `displayID` 开流，窗口按新比例再调一次。
- **窗口拉伸不重开流**：流本来就按本机最大那块屏幕的像素要，拉伸只是缩放，不需要。
- **网络诊断窗口**（`RemoteDiagnosticsWindow`，mac-only）：「我的 Mac」里每台的菜单、终端窗口和屏幕窗口连不上时都能打开，一台 Mac 一扇。四条路逐条测、结论、每条路的建立 / 往返 / 丢包、历史与「拷贝全部」。状态抽成两端共用的 `RemotePathDiagnosticsModel`，iOS 诊断页改成只画它；网络标签 `RemoteNetworkLabel` 挪进共享代码。
- **中继成员证书**（中继 1.2.0，协议见 `relay/PROTOCOL.md`）：被控端给每台配对设备另签一把只能连本机的成员密钥（`RemoteRelayConfig.certificate(for:)`，`cert` / `scope`），邀请（参数 `rs` / `rc`）和连上后推的配置都是它，同一台设备复用（记在被控端的 `RemotePeer.relayGrant`）。中继上持证书的只能 `client` / `dial` 那一台，`list` 只回那一台，不能注册主机。忘记设备、邀请没用掉就作废（被新邀请顶掉或过期）时吊销：`RemoteRelayRevocations` 先存进 `DefaultsKey.remoteRelayPendingRevocations`，注册着就立刻发 `revoke`，中继回 `revoked` 才划掉，不在线下次注册补发。发证书与否看 hello 报的中继版本：≥ 1.2.0 发证书，更老的照旧发共用成员密钥，还不知道版本（没注册上）时不发，注册上后补推给连着的设备。主控端：证书从不当默认（默认中继在 iCloud 钥匙串里，会同步到本人的 Mac，Mac 拿证书注册不了），只记在发证的那台 Mac 上；已有同一台中继的成员密钥时不用记；在线查询与中继客户端按 `memberIdentity`（中继 ID + 证书的主机）分开。
- **测试**：`RemoteMacDesktopTests`（快捷键截取条件、显示器切换、光标形状只在请求且变了时发）、`RemotePathDiagnosticsTests`、`RemoteRelayCertificateTests`（证书格式、各入口往返、放置规则、被控端发 / 复用 / 吊销）；中继侧 `relay/internal/relay/member_test.go`；经真实中继的 `make test-relay-e2e` 多了「证书只连得上发证的 Mac、不能注册主机」与「忘记设备 / 换邀请后证书作废」。
- **已部署**（2026-11-08）：中继 1.2.0 已发布到下载地址（`latest.json` = 1.2.0），测试中继 已从 1.1.1 更新，`relay check` TCP / 认证 / UDP 全通、报 1.2.0。之后邀请与推送的配置都是成员证书。
- **事故（2026-11-08）**：旧版 iPhone（main 构建）收到 Mac 推来的中继配置一律存成默认，且不认 `scope` / `cert`：把证书里设备自己的私钥当成中继成员密钥存进 iCloud 钥匙串，同步到本人所有 Mac，两台 Mac 注册中继全部被拒。修法：证书的 JSON / 二维码格式版本写 2（`RemoteRelayConfig.certificateVersion`），老版本只收 1，整份丢掉；恢复：在 Mac 上 `utermctl relay import -H <中继主机>` 重新导入。
- **证书有效期（中继 1.3.0）**：证书签名内容加到期时间（`uterm-relay-member-v2`，请求带 `exp`）。配对后的证书 1 年，邀请里带的 1 天，中继上限 400 天。签发超过 7 天就续：设备每次和中继打交道（目录查 Mac 在线状态后 `startCertificateRenewals`）经中继向签发的 Mac 发端到端加密的 `renewCertificate` 信令（`RemoteRelayCertificateRenewal`），Mac 只给认识、勾选过公网接入、公钥对得上 `relayGrant` 的设备续（`renewRelayGrant`），回 `renewedCertificate`；局域网 / 远控连上时 Mac 推配置也顺手续；iOS 另有 `BGAppRefreshTask`（`com.uozi.uTerm.relay.renewCertificates`，不保证执行）。续了是同一把钥匙、新的到期时间，旧证书在自己到期前照样能用，吊销按公钥一起作废；Mac 不回时同一台一小时才再试。一年没和中继打过交道的设备证书过期：本地先报「中继授权已过期」（`RemoteRelayError.certificateExpired`），同网连一次或重新扫码就续上。中继拒绝过期、没有到期时间（1.2.x 的证书）、到期超过 400 天的证书；吊销表记「公钥 → 证书到期时间」，到期自动清掉，满 4096 条才按最快到期淘汰（刚加的必留）。1.3.0 之前的中继（含 1.2.x）一律按老中继发共用成员密钥：1.2.x 的证书只在测试机上发过，没有发版，不留过渡期。
- **HiDPI 虚拟屏评估**（2026-11-08，只做了探针，没进 App）：
  - 私有类 `CGVirtualDisplay` / `CGVirtualDisplayDescriptor` / `CGVirtualDisplaySettings` / `CGVirtualDisplayMode` 在 macOS 27.2 还在，经 ObjC 运行时调用：描述符给最大 3840×2160，设置 `hiDPI = 2`、模式 1920×1080@60，得到 1920×1080 点、3840×2160 像素、缩放 2.0 的屏幕。
  - **沙盒里能用**：在测试宿主（沙盒内的 uTerm）里同样建得出来、模式一样。uTerm 走 Developer ID 分发，私有 API 不涉及审核；代价是系统升级可能改掉它。
  - **无显示器的 Mac mini**：建出虚拟屏后，系统自己的 1 倍占位屏消失，虚拟屏成为唯一、主显示器，窗口都在它上面——正好治「画面偏胖」。
  - **更正**：当时以为「建屏进程退出后虚拟屏不消失」，又以为 mini 的占位屏是厂商 'aapl'、型号 0x1234、带 2 倍模式。两件事其实都是**系统「屏幕共享」**：用户经屏幕共享（高性能模式）连 mini 时，`ScreensharingAgent` 自己建一块独占虚拟屏（'aapl' / 0x1234，2 倍模式齐全），WindowServer 日志是 `Disconnecting display … due to exclusive display`——别的显示器（包括我们的虚拟屏）全被断开，而这块屏 ScreenCaptureKit 采不到，uTerm 只能报「找不到要采集的显示器」。真正的无头占位屏是 'unkn' / 'virt'，只有 1 倍模式。
  - **最终做法（已实现，`RemoteHeadlessDisplay`）**：远程桌面开流前（`RemoteDesktopEnvironment.prepareDisplays`），主屏是唯一在线、非内建、'unkn'/'virt' 的 1 倍占位屏时：模式表里有同点数 2 倍模式就用公开 API 换过去；没有就建一块 1920×1080 点 / 3840×2160 像素的 `CGVirtualDisplay`（等它成为主屏再开流，uTerm 运行期间一直持有）。真显示器、不止一块屏、「屏幕共享」的独占屏一律不碰；后者在线时采集失败会明说「正被系统屏幕共享连着，断开后再试」。

### 附近的 Mac 只自动列同一个 iCloud 账户里的（2026-11-18）

user 定：局域网里不是自己 iCloud 账户里的 Mac 不要自动发现，要配对时走另一个不显眼的入口。

- **怎么认账户**：设备组名册（iCloud 钥匙串 `com.uozi.uTerm.remote.group`，加快通道的叠加层）里的 `device` 条目。每台有远控身份的设备开着 uTerm 都会登记自己，进没进设备组都一样（`RemoteDeviceGroup.register`）。目录按 Bonjour TXT 里的设备 ID 对号（`RemoteMacDirectory.liveAccountDevices` / `splitByAccount`）。
- **只决定列不列，不构成信任**：条目同一个钥匙串圈里谁都能写；配对照旧要在 Mac 上输核对码。
- **两份列表**：`nearbyMacs`（同账户，自动列进「附近的 Mac」）与 `otherNearbyMacs`（其余，不自动列）。后者只在「配对其他 Mac」里给看：Mac 是列表头「+」打开的 `RemotePairingOtherMacSheet`（粘贴邀请链接 + 附近的其他 Mac），iOS 是扫码页底部的「没有二维码？查看附近的其他 Mac」（`RemoteOtherNearbyMacsList`，同一页里切换，不推导航栈）。点了之后和原来一样走局域网审批。
- **条目晚到**：Bonjour 比 iCloud 钥匙串快（一跳约 20 秒），自家的 Mac 会先落在「其他」里。局域网里有对不上账户的 Mac、有界面在看、App 在前台时每 5 秒重读一次名册，对上了就挪进「附近的 Mac」；没有这样的 Mac 或没人看时不读。Bonjour 结果变了、开始浏览、回前台时各读一次。
- **没开 iCloud 钥匙串、模拟器**：名册里只有本机，什么都不自动列，全走「配对其他 Mac」。
- **没改的**：被控端照旧广播 `_uterm-remote._tcp`（TXT 带设备 ID），同一局域网里别人的 uTerm 仍能在它的「配对其他 Mac」里看到这台 Mac；配对仍要这台 Mac 的主人输码。要让别人完全看不到，得改广播（协议变更），这次没做。
- 测试：`RemoteMacDirectoryTests`（`testOnlyMacsInMyICloudAccountShowUpNearby` 等四条，`setDiscovered` 是给测试的入口）。

## 17. 远程桌面音频（方案，2026-11-07，分支 `feat/remote-audio`）

范围：看桌面时把 Mac 的系统声音传到手机，三条路径（局域网 TCP、公网直连数据报、中继 TCP）都要能用；帘幕模式下 Mac 本机静音。中继上的排队优化（§17.5）和帘幕静音（§17.6）都在第一期内（user 定）。

### 17.1 一页结论

- 声音挂在桌面流上，看桌面时才有，不单开会话。能力位 `desktop-audio`。
- 采集：ScreenCaptureKit 系统音频，单开一个只采音频的 `SCStream`（视频流会因分辨率、10-bit 切换重建，共用会断音）。授权就是现有的「录屏与系统录音」，不加 entitlement、不碰麦克风。
- 编码：Opus，48 kHz 立体声、20 ms 一包、默认 64 kbps，两端都用 AudioToolbox，不引第三方库。AAC-ELD 作退路，开流协商。
- 直连：新数据报种类 `audio`，发送节奏里排在控制之后、视频之前；不重传，按丢包率带冗余（上一包 / 前两包）。
- 局域网与中继（TCP）：链路层加优先级发送队列 + 大消息分片 + 手机回报收到的字节数，Mac 只把「端到端没到的字节」控制在带宽 × (最小往返 + 30 ms) 以内，其余留在应用层排队，音频、控制、终端插队（§17.5）。
- 手机：AudioConverter 解码 → 抖动缓冲（纯函数）→ `AVAudioSourceNode` 拉取播放；`.playback` 类别；只在前台播。画面不为声音等待。
- 静音检测：连续 200 ms 低于 −60 dBFS 停发，只留 1 s 一个心跳。
- 帘幕：开帘幕时把 Mac 默认输出设备静音，关帘幕 / 断开 / 下次启动时恢复（§17.6）。

### 17.2 探针（macOS 27.2；iOS 27.2 模拟器）

| 项 | 结果 |
|---|---|
| AudioToolbox 编码器 / 解码器（Mac） | Opus（480、960 采样一包）✅ / ✅；AAC-LC、AAC-ELD、AAC-LD、HE-AAC 都有 |
| Opus 64 kbps，440 Hz 正弦 1 s | 20 ms 一包时 50 包；10 ms 一包时每包约 65 B；编码 1 s 音频耗时 9 ms |
| Opus 往返（Mac 编 → Mac 解） | 信噪比 41.1 dB，固有延迟 516 采样（10.8 ms） |
| iOS 模拟器：本地编解码、解 Mac 编的包 | 都能用，结果与 Mac 逐样一致（41.1 dB、516 采样） |
| NWConnection `contentProcessed` 与 `NWProtocolTCP.Metadata.availableSendBuffer` | 回环上对端读得慢时，完成回调照样来、未确认字节只有几十到三百多 KB：积压在**对端已确认、还没读走**的缓冲里，发送端看不见。中继正是这种情况（它读得很积极，堆在发往手机的那段），所以排队控制必须用手机回报的端到端字节数，不能靠 Mac 本地 TCP 读数 |
| 同一块屏两个 `SCStream`（2026-11-07 晚补测，屏幕亮着） | 可以：只采声音的那条开着时，640×400 的视频流照常出帧（2 s 96 帧） |
| SCK 静音时是否仍回调 | 会：照常约 50 次 / 秒，每次 960 采样，全是 0，所以 Mac 端的静音停发是必要的。格式 48 kHz、非交错 Float32（flags 41） |
| 默认输出设备静音后 SCK 是否仍采得到 | 能：静音前后 `afplay` 提示音的峰值都是 0.198，帘幕静音不影响传到手机的声音 |
| 沙盒测试宿主里写静音属性 | 能：内建扬声器 静音 → 读回 true → 恢复成 false（`test_core_audio_can_mute_and_restore_from_the_sandbox`，`TEST_RUNNER_UTERM_REAL_AUDIO=1` 才跑） |

真机 iPhone 的解码还没跑过（模拟器的 AudioToolbox 是 iOS 版，预期一致）。

### 17.3 协议

- 能力位 `desktop-audio`（Mac 带）。老对端收到不认识的消息类型会断开整条连接，所以手机只在对端声明了才发。
- 手机 → Mac `desktopAudio = 39`（JSON，桌面通道）：`{enabled, codecs}`。开流时可带，看桌面途中随时开关，不重开视频。
- Mac → 手机 `desktopAudioFormat = 40`（JSON）：编码、采样率、声道、每包采样数、magic cookie；`desktopAudioFrame = 41`（二进制）：`[u8 标志][u32 序号][u64 首个采样的 Mac 采集时刻 ns][u16 长度][数据]`，丢包链路上后面附带前一两包（RED）。静音停发时发一个带「静音」标志的空帧。
- 数据报 `RemoteDatagramKind.audio = 7`，用媒体密钥。老版本解不出这个种类，直接丢掉（`RemoteDatagramKind(rawValue:)` 失败即丢弃）。

### 17.4 手机播放

- 抖动缓冲起步：直连 / 局域网 40 ms、中继 80 ms；跟随最近到达间隔 p95，上限 150 / 300 ms。
- 欠载：冗余能补先补，补不上就淡出补静音。积压超出目标 60 ms：先在静音段丢帧，再丢最旧的。两端时钟几十 ppm 的漂移也靠这条消掉。
- `AVAudioSession`：`.playback`，`preferredIOBufferDuration` 10 ms；声音开关默认关，打开是用户的选择，所以静音键下也出声。来电打断暂停，拔耳机停播。不加 `UIBackgroundModes audio`（后台连接本来就挂起）。
- 不强制音画同步，画面照旧收到就显示；调试信息显示「声音比画面晚 X ms」。
- 码率：视频预算扣掉音频那份（`mediaBudgetFactor`）；发送节奏低于 2 Mbps 时音频降到 32 kbps。

### 17.5 TCP 路径的排队优化（中继为主，局域网同样受益）

问题：现在每条消息封装成一整段直接交给 TCP；视频的在途上限按帧数和字节数算，到了中继上（§15 真机读数：画面往返 p95 400–800 ms）这些字节全堵在 TCP 和中继的缓冲里，后来的音频、按键、确认都得排在它们后面。旁路精修帧（约 330 KB）在 4 Mbps 下一次就要 0.66 s。

做法（能力位 `link-ack`，两端都声明才启用，否则保持现状）：

1. **端到端计量**：手机每收到 16 KB 或每 20 ms（取先到者）回一个 `linkAck`（累计收到的链路字节数）。Mac 由此得到「已发出但手机还没收到」的字节数（含中继里的积压）和送达速率；最小往返取 ping 与 linkAck 的最小值。
2. **应用层排队**：`RemoteLink` 的发送改成三级队列：控制 / 输入 / 确认 / 音频 > 终端 > 视频。只有端到端在途 ≤ 送达速率 × (最小往返 + 30 ms)（至少 64 KB）时才把数据交给 TCP；超出时视频留在应用层。音频、控制不受这个闸门限制（它们很小，而且最怕排队）。
3. **大消息分片**：超过 16 KB 的消息按 16 KB 切成链路记录，接收端拼回。一帧视频不再独占链路，音频能插在两片之间。
4. 视频自己的在途上限（帧数 + 字节）不变，只是计量点从「交给 TCP」挪到「手机收到」。

`linkAck` 本身每秒最多 50 个、每个十几字节，手机上行开销可以忽略。直连路径已有自己的分级节奏（`RemoteDatagramPacer`），不走这一套。

通过标准（`RemoteFaultProxy`，10 Mbps、往返 100 ms、丢包 1%，高细节滚动）：中继路径上音频到达延迟 p95 < 250 ms、关键帧 / 精修帧期间不断音；按键 → 回显 p95 不比现在差；视频实发码率不比现在低超过 10%。

### 17.6 帘幕静音

- 开帘幕：记下默认输出设备及其 `kAudioDevicePropertyMute`（不支持静音的设备记音量、把音量置 0），然后静音；监听 `kAudioHardwarePropertyDefaultOutputDevice`，帘幕期间插耳机 / 换输出设备时把新设备也静音并记下。
- 关帘幕、断开、`RemoteCurtain.disable`：只恢复我们改过的设备，且只恢复到原值（用户原本就静音的保持静音）。
- 崩溃不会像 gamma 那样被系统自动恢复，所以「改过哪些设备、原值是什么」写进 `DefaultsKey`（不同步的那类），下次启动时恢复并清掉。
- 前提要先验证（§17.2 没测的那项）：静音输出设备后 SCK 仍然采得到各 app 的声音；沙盒进程能写设备的静音属性。不成立的话改成只静音不采集（帘幕开时不传声音），并在手机上提示。

### 17.7 分期与验证

| 期 | 内容 | 通过标准 |
|---|---|---|
| A0 | 补 §17.2 没测的三项（要屏幕亮着）；真机 iPhone 解 Opus | 都有结论 |
| A1 | 采集、编码、协议、局域网 TCP、手机播放、开关与界面、帘幕静音 | XCTest：协议编解码、抖动缓冲、冗余选择、Opus 往返、静音状态恢复（含模拟崩溃后启动恢复）；端到端：假音频源从 Mac 到手机，序号连续，开关不重开视频，老 Mac 不受影响 |
| A2 | 直连数据报 + 冗余 | `RemoteMemoryDatagramPath` 丢包 1% / 5%：可听断裂率；视频占满上行时音频到达延迟 |
| B | §17.5 | 见 §17.5 |
| A3 | 真机 | 局域网 / 中继 / 蜂窝下采集到出声的延迟（Mac 放带时间码的音频，手机录音对照）、耗电 |

界面：手机远程桌面工具栏加扬声器按钮（默认关、按 Mac 记住）；Mac 设置 › 远程控制「允许远程桌面」下加「允许传输声音」（默认开），指示条显示「含声音」。

### 17.8 实施记录（2026-11-07，分支 `feat/remote-audio`）

| 层 | 文件 | 说明 |
|---|---|---|
| 共享 | `Core/Remote/RemoteAudioProtocol.swift` | 消息体（`RemoteDesktopAudioRequest` / `Format` / `Frame`）、`RemoteAudioPolicy`（码率、冗余、静音判定）、`RemoteDesktopAudioPreference`（手机按 Mac 记住开关） |
| | `RemoteAudioCodec.swift` | AudioToolbox 的 Opus / AAC-ELD 编解码；喂料回调用自己分配的内存（编码器在回调返回后才读，数组指针带出闭包是未定义行为） |
| | `RemoteAudioJitterBuffer.swift` | 纯值类型的抖动缓冲 |
| | `RemoteAudioReceiver.swift` | 手机端解码 + 冗余补洞 + 抖动缓冲；`RemoteAudioOutput` 协议与 `RemoteAudioEnginePlayer`（AVAudioEngine，iOS 上管 AVAudioSession、打断、拔耳机） |
| | `RemoteLinkFlow.swift` + `RemoteLink` | §17.5 的链路层排队（能力位 `link-flow`） |
| | `RemoteDatagram` / `RemoteP2PTransport` | 数据报种类 `audio = 7`、发送节奏的 `.audio` 一级（最多排 10 包，再旧的丢） |
| Mac | `Features/Remote/Desktop/ScreenCaptureAudioSource.swift` | 只采声音的 SCStream |
| | `RemoteAudioStreamer.swift` | 编码、静音停发、冗余、走数据报或链路 |
| | `RemoteCurtainMute.swift` | §17.6；CoreAudio 走协议，测试用假设备 |
| | `RemoteHostConnection` / `RemoteHostServer` / 设置 / 指示条 | 开关、起停、「允许传输声音」、「含声音」 |
| iOS | `uTermMobile/Screens/Remote/RemoteDesktopScreen.swift` | 工具栏扬声器按钮、自动恢复、原因提示、调试读数 |

**读数（Debug，回环）**

| 场景 | 结果 |
|---|---|
| TCP 经 `RemoteFaultProxy`，10 Mbps、往返 100 ms，视频端到端在途 1 MB，每 20 ms 一包声音 | 不开 `link-flow`：声音到达 p50 / p95 750 / 772 ms；开：149 / 157 ms。视频吞吐 9.84 → 9.84 Mbps。闸门稳定在预算约 240 KB、最小往返 115 ms（含对端攒 20 ms 再回报） |
| 直连模拟弱网（单程 50 ms、丢 1%、上行 10 Mbps、视频拉满）10 s | 放出 469 包，冗余补回 14，补静音 0，欠载 0，抖动缓冲目标深度 110 ms（瓶颈缓冲里排在视频后面的那部分排队） |
| 局域网回环端到端 | 开声音到收到第一批包 < 0.5 s；静音 1.2 s 内只发了 ≤ 2 包；关掉后 Mac 停采集 |
| 打开 `link-flow` 后的既有远程控制测试 | 30 个类、291 个用例全过 |

**偏离方案的决定**

1. 抖动缓冲追积压时，播放位置停在洞上要先跳过洞。最初的写法从洞后面最早的那包丢起：播放位置卡在洞上一格格补静音，后面的包被一个个丢光，一包都放不出来（直连用例里「放出 0」）。
2. 声音包在直连上不重传、发送节奏里最多排 10 包（200 ms）。重传或排得更久的包到了也赶不上播放。
3. 手机的声音开关按 Mac 记在本机（`remote.desktopAudioMacs`），不跟 iCloud 同步：不同手机外放习惯不同。
4. `RemoteCurtainMute` 先落盘再静音：静音后立刻崩溃，下次启动也恢复得回来。

**还没验证 / 需要真机**

- 真机 iPhone：Opus 解码（模拟器通过）、AVAudioSession 打断 / 拔耳机、蓝牙耳机延迟、静音键下出声。
- 蜂窝与公网中继上的声音延迟与断音。本机经真实 `uterm-relay` 已过：`make test-relay-e2e` 15 个用例全过（含新的 `test_desktop_audio_plays_through_the_relay_while_video_runs`：视频 30 fps 52 Mbps 同时，8 s 放出 363 包，补静音 0，欠载 0，确认启用 `link-flow`）。
- 采集到出声的端到端延迟（方案 A3：Mac 放带时间码的声音，手机录音对照）。

## 18. 被控 Mac 上的系统验证框（Touch ID / 密码）：探针结果（2026-11-20）

问题：远程控制时被控 Mac 弹出要 Touch ID 或密码的系统框，手机这边怎么过。指纹在 Mac 的传感器和安全隔区里本地比对，没有任何接口能把手机上的生物识别转过去；能走的只有框自带的「使用密码…」退路，再把登录密码打进去（密码可以复用手机上存的远程解锁密码，`RemoteUnlockVault`）。

探针：独立 App `com.uozi.uTerm.authprobe`（沙盒 + hardened runtime + Developer ID，授权辅助功能与录屏，和远控进程同一种注入：`hidSystemState` 事件源带 `userDataTag`、post 到 `.cghidEventTap`、鼠标带 `mouseEventNumber`，文字用 `keyboardSetUnicodeString`），macOS 27.2.1，本机有 Touch ID、`sudo_local` 开了 `pam_tid`。按钮位置靠 ScreenCaptureKit 截窗口 + Vision 认字。校验结果看 authd / coreauthd 日志，探针只打错误密码。

| 框 | 进程（`CGWindowList` 的 owner） | 外观 | 结果 |
|---|---|---|---|
| `do shell script … with administrator privileges`、第三方 App 调 `AuthorizationCopyRights`（例：`system.preferences.security`）、`sudo` | `SecurityAgent`（前台 bundle `com.apple.SecurityAgent`），layer 1000 | 用户名 + 密码框，**没有 Touch ID** | 模拟点击密码框 → SecurityAgent 变前台、安全输入打开 → Unicode 打字 + 回车 → authd `Evaluate denied`（确实校验了）。模拟点「不允许」/「取消」有效（osascript 收到 -128） |
| `LAContext.evaluatePolicy(.deviceOwnerAuthentication)` | `coreautha`（前台 bundle `com.apple.LocalAuthentication.UIAgent`），layer 1000 | 「使用触控 ID 或输入密码以继续」+「使用密码…」+「取消」 | 模拟点「使用密码…」→ coreauthd `Fallback authentication mechanism selected`，窗口变高、出现密码框且已聚焦（安全输入打开）→ 打字 + 回车 → coreauthd `PasscodeRejected`。框在前台时，回车 = 「使用密码…」（默认按钮）；Esc = 取消（`Canceled by user`） |
| 终端里的 `sudo`（`pam_tid`） | 同 SecurityAgent 那一行 | 本次弹的是 SecurityAgent 密码框 | 点「取消」后 sudo 退到终端里的 `Password:`，手机在终端里输就行 |

结论与实现要点：

- **可行**，不需要额外权限：远控进程已有的辅助功能 + 录屏就够。苹果没有拒收模拟输入（SecurityAgent 和 coreautha 都收）。
- **沙盒里 AX 读不到这两个进程**（`AXUIElementCopyAttributeValue` 回 -25204），按钮只能靠截图认字或按固定布局算。窗口宽 260pt，按钮文字稳定（「使用密码…」「取消」「允许」「解锁」「好」，英文系统另配）。
- **框出现时不一定在前台**：多次实测框弹出后前台还是原来的 App。直接发键盘事件会打进那个 App。有一次探针的错误密码和回车就打进了前台的别的窗口。所以**必须先点框（点密码框或「使用密码…」）把它变成前台，再核对**：前台 bundle 是 `com.apple.SecurityAgent` / `com.apple.LocalAuthentication.UIAgent` / `loginwindow`，并且 `IsSecureEventInputEnabled()` 为真，才打密码；每组按键前都复核一次（和锁屏解锁的规矩相同）。
- 带 Touch ID 的 **SecurityAgent** 框（苹果自家 App 发起的，如系统设置里的改动、安装器）这次没弹出来：第三方进程请求的授权只给密码框。预计也是「使用密码…」按钮，同一套流程，留到实现时在系统设置里手动触发核一次。
- 只认生物识别的框（`.deviceOwnerAuthenticationWithBiometrics`、Apple Pay）没有密码退路，远程过不了，界面上要明说。

复现：探针源码思路见本节；触发用 `osascript -e 'do shell script "true" with administrator privileges'`、一个调 `LAContext.evaluatePolicy` 的小命令行程序、`sudo -K; script -q /dev/null sudo -v`。日志：`/usr/bin/log show --last 1m --info --predicate 'process == "authd" OR process == "coreauthd"'`（zsh 里 `log` 是内建命令，要写全路径）。

### 落地（2026-11-20）

- 协议：能力 `desktop-auth-prompt`；`desktopScreenState` 多一个可选键 `authPrompt`（`RemoteDesktopAuthPrompt`：窗口号 + 种类，未知种类解成 `other`）；消息 60 `desktopAuthPrompt`（主控端 → Mac，`fill` 带密码 / `cancel`）、61 `desktopAuthPromptResult`（`accepted` / `rejected` / `cancelled` / `gone` / `notFocused` / `notAllowed` / `timedOut`）。老 Mac 不认 60，主控端只对声明了能力的发；Mac 只给声明了的主控端报框。
- 门禁与远程解锁相同：「允许远程解锁」开着、是正在看屏幕且能控制的那一路（`canUnlockRemotely`），和解锁请求互斥。锁屏时不报框。
- 被控端：`Features/Remote/Desktop/RemoteAuthPrompt.swift`（远控进程编、iOS 不编）。`RemoteAuthPromptDetector` 按进程名（`proc_name`，不按会被本地化的窗口属主名）认 `SecurityAgent` / `coreautha`、layer > 0、边长 ≥ 100；连接在开着桌面流时每 0.5 秒看一次，变了就推状态。`RemoteAuthPromptTypist` 不认按钮文字：点框标题区（顶边往下 30pt）把它叫到前台 → 安全输入没开时 LocalAuthentication 按回车（默认按钮「使用密码…」）、SecurityAgent 按 Tab → ⌘A + Delete → 逐字打（每字前核对：同一个框、它的进程在前台、安全输入开着）→ 回车 → 4 秒内框关了算通过，还在算密码不对。取消 = 叫到前台后按 Esc。
- 主控端：共用判定 `authPromptBanner` / `failureMessage`（`RemoteDesktopPresentation`）；Mac 窗口底部卡片（现输密码，不保存），iOS 底部卡片（有存过的解锁密码就用面容 ID / 触控 ID 取出，否则弹密码框，现输的顺手存进钥匙串）。都不盖住画面。
- 验证：`RemoteAuthPromptTests`（13 个：找框、步骤与守卫、回环端到端）；把 `RemoteAuthPrompt.swift` 原样编进探针 App 在真实的框上跑：管理员授权框（不在前台时）输错 → `rejected`（authd `Evaluate denied`）、取消 → `cancelled`（osascript -128）；LocalAuthentication 框（前台是 Finder）输错 → `rejected`（coreauthd `PasscodeRejected`）、取消 → `cancelled`。
- 没验的：输对密码的 `accepted`（要真密码）；帘幕开着时；经远控进程 + 真机的整条链路；苹果自家 App 发起的带 Touch ID 的 SecurityAgent 框。
