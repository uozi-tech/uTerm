# 远程控制的授权与设备管理：信息架构重组方案（2026-11-16）

起因：user 说「设备授权、设备权限控制等各种都塞在一个页面里面，每一行的描述都很多」。本文只是方案，没有改产品代码。

> 「我的设备」（26–28 行、`RemoteSibling*`）后来整个换成了设备组，见 `docs/remote-device-group-design.md` §13；本文里那几行的文件与行号是当时的。

两个方向贯穿全文，先定名：

- **被控**：谁能控制**这台 Mac**。包括总开关、允许的操作和系统授权、公网接入、已配对的设备、担保开关。只有 Mac 有。
- **主控**：**这台设备**去控制别的设备。包括「我的设备」（同一 Apple ID 的设备互相确认）、「我的 Mac」、共享给被控 Mac 的文件夹。两端都有。

---

## 1. 现状清单

### 1.1 Mac「设置 › 远程控制」（一整页，`RemoteControlSettingsView.swift:11-35`）

页头：「远程控制」/「让 iPhone、iPad 接入这台 Mac」（`:13`）。字数是 `String.count`，含标点。

| # | 组 / 项 | 方向 | 类型 · 默认 | 出现条件 | 说明文字（字数） | 位置 |
|---|---|---|---|---|---|---|
| 1 | 组「远程控制」footer | 被控 | — | 总在 | 配对规则 + 尺寸（128） | `RemoteControlSettingsView.swift:16` |
| 2 | 允许手机远程控制 | 被控 | 开关 · 关 | 总在 | — | `:17`；默认 `RemoteControlSettings.swift:117` |
| 3 | 状态 | 被控 | 状态 | 总开关开 | hint「已连接：X、Y」 | `:21-26`；`RemoteControlPresentation.swift:22` |
| 4 | 组「能力」footer | 被控 | — | 总开关开 | 辅助程序原理 + 屏幕提示（108） | `RemoteCapabilitiesGroup.swift:16` |
| 5 | 允许打开本机终端 | 被控 | 开关 · 关 | 同上 | 35 | `:17-20`；默认 `RemoteControlSettings.swift:121` |
| 6 | ↳ 辅助程序 | 被控 | 状态（正常 / 无法连接 + 重试） | 本机终端开 | 15（失败时是失败原因） | `:23-31`、`:110-113` |
| 7 | 允许远程桌面 | 被控 | 开关 · 关 | 总开关开 | 32 | `:34-37`；默认 `:118` |
| 8 | ↳ 屏幕录制 | 被控 · 系统授权 | 状态 + 授权 + ⋯（打开系统设置 / 授权引导） | 远程桌面开 | 22 | `:40-45`、`:133-150` |
| 9 | ↳ 辅助功能 | 被控 · 系统授权 | 同上 | 同上 | 21，远控进程在服务时 42 | `:46-51`、`:104-108` |
| 10 | ↳ 授权后需重启 uTerm | 被控 | 按钮 | 两项授权有一项没给 | 30 | `:52-60` |
| 11 | ↳ 允许传输声音 | 被控 | 开关 · **开** | 远程桌面开 | 53 | `:62-67`；默认 `:120` |
| 12 | ↳ 允许远程解锁 | 被控 | 开关 · 关 | 同上 | 44 | `:68-73`；默认 `:119` |
| 13 | ↳ 当前观看者 + 断开 | 被控 · 会话 | 列表行 | 有人在看屏幕 | 副标题 10–30 | `:74-83`、`:115-119` |
| 14 | 组「公网接入」footer | 被控（中继两向共用） | — | 总开关开 | 140 | `RemoteInternetGroup.swift:27` |
| 15 | 中继注册（开发构建 / 测试宿主） | — | 状态 | 被拦时 | 约 40 | `:28-33`；`RemoteControlPresentation.swift:133-140` |
| 16 | 中继（未配置） | 两向共用 | 「让 AI 部署…」+「导入配置」 | 没配中继 | 71 | `:156-166`；`RemoteControlPresentation.swift:57` |
| 16a | ↳ 让 AI 部署（展开块） | — | 前提检查 + 选主机 + 提示词 + 拷贝 | 点了展开 | 每条前提 20–35，底注 45 | `RemoteRelayAgentPromptBlock.swift:29-75` |
| 17 | 中继（已配置） | 两向共用 | 列表行 + ⋯（**8 项**：测试连接 / 二维码 / 分享 / 导出 / 指定所在主机 / 更换 / 移除） | 已配中继 | 副标题：名字 · 地址 · 版本 | `:125-155` |
| 17a | ↳ 中继二维码 | — | 二维码块 | ⋯ 里点开 | 23 | `:39-44` |
| 17b | ↳ 所在主机 / 有新版本 / 更新进度 / 测试结果 | — | 选择器 / 按钮 / 行内提示 | 各自条件 | 更新说明 30–45 | `:171-212`；`RemoteControlPresentation.swift:67-104` |
| 18 | 允许经公网接入 | 被控 | 开关 · 关 | 已配中继 | 14 | `:48-52`；默认 `:122` |
| 19 | 中继状态 | 被控 | 状态 + 重新连接 | 公网开 | 失败原因 / 被顶替 46 | `:53-64` |
| 20 | 保持唤醒 | 被控 | 开关 · 关 | 公网开 | 16 + 单独一行提示 23 | `:65-70`；默认 `:124` |
| 21 | 组「允许经公网连接的设备」 | 被控 | **每台设备一个开关**（重复列一遍已配对的设备） | 公网开 | footer 26 | `:74-98` |
| 22 | 组「已配对的设备」footer | 被控 | — | 总在 | 83 | `RemotePairedDevicesGroup.swift:15` |
| 23 | 扫码配对 | 被控 | 显示二维码 → 拷贝链接 / 收起 | 总开关开 | 20 / 58 | `:17-31`；`RemoteControlPresentation.swift:160-164` |
| 23a | ↳ 二维码 + 说明 | 被控 | **行内展开的大块** | 点了显示 | 104 / 111 | `:32-37`；`RemoteControlPresentation.swift:153-158` |
| 24 | 允许已配对的设备开通主人的其它设备 | 被控（担保） | 开关 · **开** | 总在，**夹在二维码与设备列表之间** | 标题 17 + hint 77 | `:39-42`；默认 `RemoteControlSettings.swift:125` |
| 25 | 已配对设备列表 | 被控 | 行 + ⋯（重命名… / 撤销配对… / 撤销同一组的 N 台…） | 总在 | 副标题：机型 · 配对于 · 由谁添加 · 已连接 | `:43-55`、`:69-102` |
| 26 | 组「我的设备」footer | **主控** | — | 总在 | **174**（全页最长） | `RemoteMyDevicesGroup.swift:13`；`RemoteSiblingDevices.swift:576` |
| 26a | ↳ 收到的确认：核对码 + 一致 / 不一致 | 主控（本机是新设备） | **行内块，在页面最底部** | 别的设备在确认本机 | 标题 + 说明 30–40 | `RemoteMyDevicesGroup.swift:63-77` |
| 26b | ↳ 发起的确认：等待 / 比对 / 失败 | 主控（本机是已有设备） | 行内块 | 点了「确认…」 | 等待说明 56 | `:78-81`、`:125-156` |
| 26c | ↳ 本机被报告丢失 / 钥匙串写入错误 | 主控 | 红色行 | 各自条件 | 60 | `:82-87` |
| 26d | ↳ 同 Apple ID 设备列表 | 主控 | 行 + 确认… + ⋯（取消确认 / 从名单移除 / 这台设备丢了…） | 总在 | 副标题：状态 · 开通进度 | `:88-123`；`RemoteSiblingDevices.swift:517-531` |
| 27 | 组「报告丢失的设备」 | 主控 | 列表 + ⋯（取消报告） | 有墓碑 | footer 110 | `RemoteMyDevicesGroup.swift:37-50`；`RemoteSiblingDevices.swift:567` |
| 28 | 组「替这台设备开通的 Mac」 | 主控 | 只读列表 | 收到过开通 | footer 48 | `RemoteMyDevicesGroup.swift:51-58`；`RemoteSiblingDevices.swift:579` |

整页的说明文字（footer + hint + 二维码说明）在截图那一版上约 **1100 字**，其中 5 段 footer 占 633 字。

### 1.2 Mac 上的其它入口

| 入口 | 方向 | 内容 | 位置 |
|---|---|---|---|
| 配对审批面板（`RemotePairingPrompt`，浮动 `NSPanel`） | 被控 | 「X」请求远程控制终端 + 6 位码 + 允许 / 拒绝（说明 31 + 39 字） | `RemotePairingPanel.swift:10-75`、`:93-118`；创建于 `uTermApp.swift:135`、`:196` |
| 担保通知（系统通知） | 被控 | 「X」为「Y」开通了远程控制；正文引用路径「设置 › 远程控制 › 已配对的设备」 | `RemoteVouchNotifier.swift:7-9` |
| 欢迎窗口「我的 Mac」 | 主控 | 已配对 / 附近的 Mac、粘贴邀请链接、详情（路径 · 往返 · 中继 · 配对时间、打开终端 / 屏幕 / 文件 / 网络诊断）、右键「忘记」 | `RemoteMacsPane.swift:10-62`、`:251-380`；挂在 `WelcomeView.swift:213` |
| ↳ 空态说明 | 主控 | 59 + 67 字 | `RemoteMacsPane.swift:398`、`:405` |
| ↳ 附近 Mac 的说明 | 主控 | 49 字 | `RemoteMacsPane.swift:273` |
| ↳ 共享文件夹（每台 Mac 的详情里） | 主控（反方向读写） | 添加文件夹、只读 / 读写 | `RemoteSharedFoldersSection.swift:17-79`；挂在 `RemoteMacsPane.swift:282` |

### 1.3 iOS

| 入口 | 方向 | 内容 | 位置 |
|---|---|---|---|
| 设置 › 远程控制 | 主控 | 我的设备 › / 网络诊断 › / 只走公网（开关，开发者选项）；footer 83 字只讲「只走公网」 | `SettingsRemoteSection.swift:12-26` |
| 设置 › 远程控制 › 我的设备 | 主控 | 与 Mac 1.1 的 26–28 同一套模型和文案（`RemoteSiblingCopy`）；收到的确认、发起的确认都是页面里的一组 | `RemoteMyDevicesScreen.swift:50-104`、`:122-144` |
| 主机页「我的 Mac」 | 主控 | 已配对的 Mac + 扫码；「附近的 Mac」footer 55 字 | `RemoteMacSection.swift:22-39` |
| ↳ RemoteMacSheet | 主控 | 配对中核对码（说明 44 字）、这台 Mac / 屏幕 / 文件 / 终端四组，接管说明 **112 字**、忘记这台 Mac | `RemoteMacSection.swift:233-237`、`:251-314` |

### 1.4 设置清单（`SettingsCatalog`）与实际不符

`SettingsCatalog.swift:127-149` 里的 group 是「远程控制 / 本机终端 / 远程桌面 / 公网接入 / 已配对的设备」，界面上却是「能力」一组；声音、解锁、担保三个开关（`remote.deviceVouching` 在 `DefaultsKey.swift:89`）没有条目。

---

## 2. 问题

### 2.1 两个方向混在同一页

| 问题 | 依据 |
|---|---|
| 页头说「让 iPhone、iPad 接入这台 Mac」（被控），页底却是「我的设备」（主控：本机去确认 / 开通别的设备）。用户分不清哪组管谁。 | `RemoteControlSettingsView.swift:13` vs `:34` |
| 「替这台设备开通的 Mac」是**主控**结果（这台能控制哪些 Mac），却放在被控设置页；同一批 Mac 在「我的 Mac」里本来就列着。 | `RemoteMyDevicesGroup.swift:51-58` |
| 中继放在「公网接入」（被控）里，但它也是本机控制别的 Mac 时的默认中继，还经 iCloud 钥匙串发给自己的设备。 | `RemoteInternetGroup.swift:27`；`RemoteMacsPane.swift:358` |
| 称呼不准：总开关叫「允许手机远程控制」，声音 / 解锁 / 辅助功能的说明都写「手机」，但另一台 Mac 也能控制（§16「所有设备都要配对」）。 | `RemoteControlSettingsView.swift:17`；`RemoteCapabilitiesGroup.swift:63`、`:69`、`:106`；`SettingsCatalog.swift:127` |

### 2.2 重复

| 重复的内容 | 出现处 |
|---|---|
| 两张设备列表：「已配对的设备」与「允许经公网连接的设备」列的是同一批设备，后者只多一个开关 | `RemotePairedDevicesGroup.swift:43-55`、`RemoteInternetGroup.swift:74-98` |
| 「每台都要配对、同一 Apple ID 不算数、可由已配对的设备开通」讲了 3 遍 | footer 1（`RemoteControlSettingsView.swift:16`）、footer 22（`RemotePairedDevicesGroup.swift:15`）、担保开关 hint（`:40`） |
| 「怎么扫码」讲了 2 遍 | `RemoteControlPresentation.swift:163`（无邀请时）与 `:155/157`（二维码下） |
| 「经公网也能连」讲了 3 遍 | footer 14、开关 hint（`RemoteInternetGroup.swift:49`）、邀请说明 |
| 「含成员密钥，只给自己的设备」讲了 3 遍 | `RemoteControlPresentation.swift:55`、`RemoteInternetGroup.swift:40`、`:248` |
| 「状态」行的 hint 和设备列表的「已连接」是同一件事 | `RemoteControlSettingsView.swift:21`、`RemotePairedDevicesGroup.swift:100` |

### 2.3 说明过长（> 40 字的 footer / hint）

| 原文出处 | 字数 | 毛病 |
|---|---|---|
| 我的设备 footer `RemoteSiblingDevices.swift:576` | 174 | 把一整套操作步骤写在 footer 里 |
| 公网接入 footer `RemoteInternetGroup.swift:27` | 140 | 原理（直连 / 中继 / 加密）、睡眠、钥匙串分发混在一段 |
| 远程控制 footer `RemoteControlSettingsView.swift:16` | 128 | 尺寸规则 + 配对规则 |
| 二维码说明 `RemoteControlPresentation.swift:155/157` | 104 / 111 | 步骤 + 局域网限制 + 中继代价 |
| 丢失 footer `RemoteSiblingDevices.swift:567` | 110 | 撤销机制细节 |
| 能力 footer `RemoteCapabilitiesGroup.swift:16` | 108 | 沙盒原理，用户做不了任何事 |
| iOS 接管 footer `RemoteMacSection.swift:289` | 112 | — |
| iOS 只走公网 footer `SettingsRemoteSection.swift:13` | 83 | 开发者选项占了整组的 footer |
| 已配对 footer `RemotePairedDevicesGroup.swift:15` | 83 | 与 footer 1 重复 |
| 担保 hint `RemotePairedDevicesGroup.swift:40` | 77 | 举例 + 规则 + 通知 |
| 中继未配 hint `RemoteControlPresentation.swift:57` | 71 | — |
| 声音 hint `RemoteCapabilitiesGroup.swift:63` | 53 | 「沿用屏幕录制授权」不需要用户知道 |
| 解锁 hint `:69` | 44 | — |
| 辅助功能 hint（远控进程在服务时） `:107` | 42 | — |

### 2.4 找不到 / 看不懂

| 问题 | 依据 |
|---|---|
| **核对码藏在页底**：新设备收到确认时，6 位码只出现在「我的设备」组里，在一整页最下面，走查时 user 以为卡住了。违反 `confirmations-as-popups`。 | `RemoteMyDevicesGroup.swift:63-77`；iOS `RemoteMyDevicesScreen.swift:51-60` |
| **页面关着就收不到确认**：名册只在这一页开着时轮询，新设备不开这一页就不回答（发起方一直「正在确认…」直到 5 分钟超时）。要弹窗，先得把轮询提到 App 层。 | `RemoteSiblingDevices.swift:7-16`、`:177-187`；页面里的 `.task` 在 `RemoteMyDevicesGroup.swift:21-25`、`RemoteMyDevicesScreen.swift:31-34` |
| 发起方的等待说明让用户去「设置 › 远程控制 › 我的设备」，要两台都翻到这一页。 | `RemoteSiblingDevices.swift:587` |
| 二维码在设备列表上方行内展开（约 300pt 高），把列表顶出首屏。 | `RemotePairedDevicesGroup.swift:32-37` |
| 担保开关夹在二维码和设备列表之间，看起来像列表的一项。 | `:39-42` |
| 中继的 8 个动作 + 版本 / 更新 / 测试结果 / AI 提示词都在设置页里行内展开，一个组最多能长到 10 行。 | `RemoteInternetGroup.swift:124-212` |
| 「辅助程序 · 正常」常驻一行，正常时没有信息量。 | `RemoteCapabilitiesGroup.swift:23-31` |
| 「授权后需重启 uTerm」做成独立一行、带一个常驻按钮，读起来像第三项授权。 | `:52-60` |
| 「撤销配对…」带省略号但不弹确认，点下去直接撤（违反「… 只给会再弹输入的操作」，也缺确认）。 | `RemotePairedDevicesGroup.swift:75-77` |
| 口语：「没法写入」「没能保存」（copy-terminology：没能 → 无法）。 | `RemoteSiblingDevices.swift:205`、`:312`、`:344`、`:509` |

截图那一版的 footer 1 与当前代码（`:16`）略有不同，代码更新，本文按代码。

---

## 3. 重组方案

### 3.1 规则

| 规则 | 说明 |
|---|---|
| R1 一页一个方向 | 被控的东西放「设置 › 远程控制」；主控（我的设备）单独一页；「我的 Mac」留在欢迎窗口和主机页。 |
| R2 标题一句话 | 行标题 ≤ 12 字，说的是开关打开后的结果。 |
| R3 说明按需出现 | hint ≤ 20 字，只在标题看不出后果时才写；footer 每组最多一句、≤ 40 字，能不写就不写。 |
| R4 步骤写进动作里 | 怎么扫码、怎么核对，写进弹窗 / sheet，不写进设置页说明。 |
| R5 原理进「了解更多」 | 沙盒、端到端、iCloud 同步延迟、撤销机制这类内容放组标题右侧的 ⓘ popover（新原语 `SettingsLearnMore`），或干脆删掉。 |
| R6 要人点头的就弹窗 | 别的设备发起、要这台确认的流程，一律在 App 层弹出（Mac 用 `NSPanel`，iOS 用盖在当前界面上的 sheet）。 |
| R7 一个对象一张列表 | 同一批设备只列一次；按设备的权限（公网）放进这台设备的菜单 / 详情。 |
| R8 状态写进行尾 | 状态放在已有那一行的末尾，不另起一行；没有可做的事就不显示（例如「辅助程序 · 正常」）。 |
| R9 主语用「设备」 | 不写「手机」，Mac 也能控制 Mac。 |

### 3.2 Mac 的新结构

```
设置（侧栏）
├─ 远程控制                                     ← 只放被控
│   页头：远程控制 / 让你配对过的设备控制这台 Mac
│   ├─ [无标题组]
│   │   ├─ 允许远程控制                    [开关]   行尾状态：正在等待连接 / 已连接 2 台 / 无法启动
│   │   └─ 「X」正在查看屏幕 · 含声音       [断开]   （有人看屏幕时才出现，从「能力」挪上来）
│   ├─ 设备                         （组标题右侧：添加设备… 按钮）
│   │   ├─ 我的 iPhone   iPhone 16 · 可经公网连接 · 已连接      [⋯]
│   │   │     ⋯：重命名… / ✓ 允许经公网连接 / 撤销配对… / 撤销同一组的 N 台…
│   │   └─ 工作室 iPad Pro   配对于 2026年8月12日 · 由「我的 iPhone」添加  [⋯]
│   │   footer（可选）：撤销后要重新配对才能连接。
│   ├─ 允许的操作
│   │   ├─ 打开本机终端                     [开关]   新开一个终端（你的登录 shell）
│   │   │   └─ ↳ 辅助程序无法连接  原因   [重试]     （只在失败时出现）
│   │   └─ 远程桌面                         [开关]   查看屏幕，授权后可操作鼠标和键盘
│   │       ├─ ↳ 屏幕录制         已授权 / 未授权 [授权] [⋯]
│   │       ├─ ↳ 辅助功能         已授权 / 未授权 [授权] [⋯]
│   │       │     （本次运行请求过授权时，下面多一行行内提示「授权后重新启动 uTerm 才生效」[重新启动]）
│   │       ├─ ↳ 传输声音           [开关]
│   │       └─ ↳ 远程解锁           [开关]   锁屏时用登录密码解锁，并黑屏
│   ├─ 公网接入
│   │   ├─ 中继      relay-sz · 已连接 · v1.3.0             [管理…]   （未配置时：未设置 [设置…]）
│   │   ├─ 允许经公网接入                   [开关]
│   │   └─ 保持唤醒                         [开关]   合盖仍会睡眠
│   │   footer：内容端到端加密。Mac 睡眠时无法连接。
│   └─ 新设备
│       └─ 允许已配对的设备代为添加         [开关]   新设备权限不超过它，每次都会通知你
│
├─ 我的设备（新侧栏项，主控）                    ← 见拍板 Q1
│   页头：我的设备 / 同一 Apple ID 下的 iPhone、iPad 和 Mac
│   ├─ [这台设备被报告丢失 / 钥匙串错误]（红行，有才出现）
│   ├─ 设备列表：名字 · 已确认 / 未确认 · 已替它开通 N 台 Mac    [确认…] [⋯]
│   │     ⋯：取消确认 / 从名单移除 / 这台设备丢了…
│   │   footer：确认过的设备可以替彼此开通配对过的 Mac。需要打开 iCloud 钥匙串。
│   └─ 报告丢失的设备（有才出现）
│       footer：只能撤销由你的设备开通的 Mac，其余要到那台 Mac 上撤销。
│
弹窗与 sheet（不在页面里）
├─ 添加设备（sheet，设置窗口上）：二维码 + 拷贝链接 + 一句说明          ← 原「扫码配对」行内块
├─ 中继（sheet）：状态、测试连接、二维码 / 分享 / 导出、所在主机与更新、更换、移除、让 AI 部署
├─ 配对审批（已有 NSPanel）：文案改短
└─ 确认我的设备（新 NSPanel，App 层）：
     ├─ 被确认方：「X」正在确认这台 Mac · 6 位码 · 不一致 / 一致
     └─ 发起方：等待（「X」上会弹出同一个 6 位数）→ 比对 → 完成 / 失败

欢迎窗口「我的 Mac」（主控，不动结构）
└─ 收到的开通（原「替这台设备开通的 Mac」组）并进列表：行副标题加「由『X』开通」；冲突 / 被拒的留在「我的设备」页显示
```

### 3.3 iOS 的新结构

```
设置
├─ 远程控制
│   ├─ 我的设备 ›            （有待确认的设备时行尾显示数字角标）
│   └─ 网络诊断 ›
│       └─ 网络诊断页底部：只走公网 [开关]（从设置根组挪进来，说明也跟过去）
│   （删掉原 83 字 footer）
│
├─ 我的设备页（结构同 Mac 的「我的设备」，同一份共享文案）
│
主机页「我的 Mac」（不动结构，只改短说明）
│
弹窗（App 根视图层，盖在当前界面上）
└─ 确认我的设备：同 Mac，用 sheet（`.presentationDetents([.medium])`），不用 confirmationDialog
```

### 3.4 挪动、合并、删除一览

| 现在 | 之后 | 理由 |
|---|---|---|
| 状态行（`RemoteControlSettingsView.swift:21-26`） | 并进总开关的行尾 | R8 |
| 当前观看者（`RemoteCapabilitiesGroup.swift:74-83`） | 挪到第一组 | 它是当前会话，不是一项能力 |
| 扫码配对 + 行内二维码（`RemotePairedDevicesGroup.swift:17-37`） | 「设备」组标题右侧的「添加设备…」→ sheet | 列表不被顶下去 |
| 担保开关（`:39-42`） | 单独一组「新设备」 | 不再夹在列表里 |
| 「允许经公网连接的设备」整组（`RemoteInternetGroup.swift:74-98`） | 删组；每台设备的 ⋯ 里加勾选项「允许经公网连接」，副标题显示「可经公网连接」；公网没开时这一项置灰 | R7 |
| 中继行的 8 个动作 + 管理行 + AI 提示词（`:124-212`、`RemoteRelayAgentPromptBlock`） | 「中继」sheet | 设置页只留一行状态 |
| 中继状态行（`:53-64`） | 并进中继行副标题；「重新连接」放进 sheet | R8 |
| 「合盖仍会睡眠」单独一行（`:69-70`） | 并进保持唤醒的 hint | R3 |
| 辅助程序常驻行（`RemoteCapabilitiesGroup.swift:23-31`） | 只在失败时出现 | R8；memory 也这么定过 |
| 「授权后需重启」独立一行（`:52-60`） | 授权行下的行内提示 + 按钮，只在本次运行请求过授权、仍未生效时出现 | 不像第三项授权 |
| 「我的设备」三组（`RemoteMyDevicesGroup.swift`） | 侧栏单独一页（Q1） | R1 |
| 核对码行内块（`:63-81`；iOS `RemoteMyDevicesScreen.swift:51-63`） | App 层弹窗 | R6 |
| 「替这台设备开通的 Mac」组（`:51-58`） | 并进「我的 Mac」列表副标题；异常留在「我的设备」 | 主控结果放主控入口 |
| iOS「只走公网」（`SettingsRemoteSection.swift:23-25`） | 网络诊断页 | 开发者选项不占设置根 |
| 能力 footer、已配对 footer | 删 | 重复或没有可做的事 |

### 3.5 文案（前 → 后）

#### 被控页（Mac，`RemoteControlPresentation` + 各 Group，mac-only）

| 项 | 前（字数） | 后（字数） |
|---|---|---|
| 页头副标题 | 让 iPhone、iPad 接入这台 Mac（17） | 让你配对过的设备控制这台 Mac（14） |
| 总开关 | 允许手机远程控制 | 允许远程控制 |
| 组 1 footer | 打开后，同一局域网里配对过的设备可以接入…替它开通。（128） | 配对过的设备可以接入这台 Mac 上打开的终端。（22）；尺寸规则进 ⓘ |
| 状态 hint | 已连接：X、Y | 行尾「已连接 2 台」，悬停显示名字（设备列表里本来就标了「已连接」） |
| 组名「能力」 | 能力 | 允许的操作 |
| 能力 footer | 本机终端由 uTerm 内置的辅助程序启动…可随时断开。（108） | 删；「有人查看屏幕时顶部会显示提示」进 ⓘ |
| 本机终端 | 允许打开本机终端 / 配对过的设备可以在这台 Mac 上新开一个终端（你的登录 shell）（35） | 打开本机终端 / 新开一个终端（你的登录 shell）（15） |
| 辅助程序 | 辅助程序 / 用到时自动运行，不需要额外授权（15） | 正常时不显示；失败：辅助程序无法连接 / 〈原因〉 |
| 远程桌面 | 允许远程桌面 / 查看这台 Mac 的屏幕；有「辅助功能」授权时还能操作鼠标和键盘（32） | 远程桌面 / 查看屏幕，授权后可操作鼠标和键盘（16） |
| 屏幕录制 | 查看屏幕必需；macOS 会定期要求重新确认（22） | 删 hint（「定期重新确认」进授权引导） |
| 辅助功能 | 控制鼠标和键盘；没有这项时手机只能查看（21）/ +「系统设置里要打开的是『uTerm 远程控制』」（42） | 删 hint；远控进程在服务时：在系统设置里打开「uTerm 远程控制」（17） |
| 重启 | 授权后需重启 uTerm / 在「系统设置」里打开开关后，要等 uTerm 重新启动才生效（30） | 行内提示：授权后重新启动 uTerm 才生效（15）[重新启动] |
| 声音 | 允许传输声音 / 查看屏幕时把这台 Mac 的声音传到手机…不需要其他权限（53） | 传输声音（无 hint） |
| 解锁 | 允许远程解锁 / Mac 锁屏时，配对过的手机能用登录密码解锁并进入帘幕（屏幕变黑、暂停本机键鼠和扬声器）（44） | 远程解锁 / 锁屏时用登录密码解锁，并黑屏（17） |
| 观看者副标题 | 正在查看 · 只能查看（没有「辅助功能」授权） | 正在查看 · 只能查看 |
| 公网 footer | 打开后，这台 Mac 会注册到中继…或用「分享到我的设备」。（140） | 内容端到端加密。Mac 睡眠时无法连接。（18）；直连优先、钥匙串分发进 ⓘ |
| 中继（未配） | 跨网络控制需要在你自己的主机上运行中继…生成的配置文件。（71） | 未设置 [设置…]；sheet 里再分「导入配置」「让 AI 部署」 |
| 允许经公网接入 hint | 不在同一局域网的设备也能连接（14） | 保留 |
| 保持唤醒 | 公网接入期间不让 Mac 闲置睡眠（16）+ 合盖仍会睡眠。要合盖使用，请接上电源和外接显示器。（23） | 合盖仍会睡眠（6）；接电源和外接显示器那句进 ⓘ |
| 公网设备组 | 允许经公网连接的设备 / 配对过的设备不会自动获得公网权限，要在这里逐台打开。（26） | 删组 → ⋯ 菜单项「允许经公网连接」 |
| 设备组名 | 已配对的设备 | 设备 |
| 设备组 footer | 配对过的设备才能连接这台 Mac…撤销后这台设备要重新配对。（83） | 撤销后要重新配对才能连接。（12），或干脆不写 |
| 扫码配对行 | 扫码配对 / 二维码和链接 10 分钟内有效，只能用一次。 | 组标题右侧按钮「添加设备…」 |
| 添加设备 sheet 说明（无中继） | 在 iPhone / iPad 的 uTerm 主机页打开…不在同一网络也能配对。（104） | 在 iPhone、iPad 上打开「主机 › 我的 Mac › 扫码配对」，或拷贝链接发给对方。仅限同一局域网，10 分钟内有效。（约 55） |
| 同上（带中继） | …邀请里带着中继「X」…也能使用这台中继。（111） | 同上前半句 + 「对方也会拿到中继『X』。10 分钟内有效，只能用一次。」（约 60） |
| 担保开关 | 允许已配对的设备开通主人的其它设备（17）/ 比如配对过的 iPhone…每次开通都会通知你。（77） | 允许已配对的设备代为添加（12）/ 新设备权限不超过它，每次都会通知你（17） |
| 撤销菜单 | 撤销配对…（不确认，直接撤） | 撤销配对…（加确认：「撤销『X』？撤销后它要重新配对才能连接。」） |
| 审批面板标题 | 「X」请求远程控制终端 | 「X」请求控制这台 Mac |
| 审批面板说明 | 允许后，它可以接入这台 Mac 上已打开的终端，之后再连无需确认。（31） | 允许后，它以后再连接不用确认。（14） |
| 审批面板核对说明 | 确认手机上显示的是同一组数字再允许。如果不一致，连接可能已被截获，应当拒绝。（39） | 和对方设备上的数字一致再允许，不一致就拒绝。（21） |
| 担保通知正文 | …到「设置 › 远程控制 › 已配对的设备」里撤销它。 | …到「设置 › 远程控制」里撤销它。 |

#### 我的设备（两端共享，`RemoteSiblingCopy`，`uTerm/Features/Remote/RemoteSiblingDevices.swift:565-603`）

| 项 | 前（字数） | 后（字数） |
|---|---|---|
| 页 footer | 同一 Apple ID 下打开过 uTerm 的 iPhone、iPad 和 Mac 会出现在这里…连不上任何 Mac。（174） | 确认过的设备可以替彼此开通配对过的 Mac。需要打开 iCloud 钥匙串。（33） |
| 空态 | 还没有别的设备。在你的 iPhone、iPad 或其它 Mac 上打开 uTerm 后会出现在这里 | 还没有别的设备。在你的其它设备上打开 uTerm 后会出现在这里 |
| 丢失 footer | 你的设备会逐台请配对过的 Mac 撤销它…已经撤掉的 Mac 要重新开通。（110） | 只能撤销由你的设备开通的 Mac，其余要到那台 Mac 上撤销。（27） |
| 本机被报告丢失 | 这台设备被你的另一台设备报告丢失，已不再参与「我的设备」。找回来的话，在那台设备上取消报告。（48） | 这台设备已被报告丢失。找回后在报告它的设备上取消报告。（26） |
| 弹窗 · 等待（发起方） | 正在确认「X」/ 在「X」上打开设置 › 远程控制 › 我的设备，两台设备会显示同一个 6 位数。iCloud 同步可能要几十秒。（56） | 正在确认「X」/「X」上会弹出同一个 6 位数，可能要几十秒。（约 24） |
| 弹窗 · 比对（发起方） | 「X」上显示的也是这个数吗？/ 一致才点「一致」。不一致说明名单里可能有别的设备冒充它，点「不一致」。（37） | 标题不变 / 不一致说明可能有设备冒充它。（15） |
| 弹窗 · 被确认方 | 「X」正在确认这台设备 / 和「X」上的数一样就在两台上都点「一致」。不是你发起的、或数不一样，点「不一致」。（约 40） | 「X」正在确认这台设备 / 和「X」上的数字一致才点「一致」。（约 17） |
| 已点一致 | 已记下。等对方也点了「一致」，它会替这台设备开通它配对过的 Mac。（32） | 已确认。对方也点「一致」后，会替这台设备开通它配对过的 Mac。（约 28） |
| 收到的开通 footer | 别的设备替这台设备开通的 Mac…可以随时撤销。（48） | 删（并进「我的 Mac」） |
| 错误 | 没法写入 iCloud 钥匙串：… / 没能保存确认结果：… | 无法写入 iCloud 钥匙串：… / 无法保存确认结果：… |

#### iOS 其它

| 项 | 前 | 后 |
|---|---|---|
| 设置 › 远程控制 footer（`SettingsRemoteSection.swift:13`，83） | 「只走公网」打开后… | 删；网络诊断页里「只走公网」的说明：即使在同一局域网也经中继或打洞连接，切换后立即重连。（约 25） |
| 附近的 Mac footer（`RemoteMacSection.swift:39`，55） | 同一局域网里打开了远程控制、还没和这台手机配对的 Mac… | 点一下，在 Mac 上核对数字并点「允许」。（18） |
| 配对中说明（`:237`，44） | Mac 上会弹出同样的 6 位数字… | Mac 上会弹出同一个 6 位数，一致再点「允许」。（20） |
| 接管 footer（`:289`，112） | 点任意一个都会接管这台 Mac 上的全部终端… | 会接管这台 Mac 上的全部终端并跟着增减，直到点「断开全部终端」。（约 31） |

#### Mac「我的 Mac」

| 项 | 前 | 后 |
|---|---|---|
| 空态两段（`RemoteMacsPane.swift:398`、`:405`，59 + 67） | … | 控制另一台 Mac 的终端和屏幕。（13）+ 同一局域网的 Mac 会自动出现；其它的，粘贴它「设置 › 远程控制 › 添加设备」里的链接。（约 38） |
| 附近 Mac 说明（`:273`，49） | … | 点「配对」，在那台 Mac 上核对数字并点「允许」。（21） |

### 3.6 代码落点（按「iOS / macOS 共享代码」）

| 内容 | 放哪 | 端 |
|---|---|---|
| 「我的设备」状态机、文案 | 已在 `uTerm/Features/Remote/RemoteSiblingDevices.swift`（共享），只改文案 | 两端 |
| App 层的名册运行者 + 「待确认」队列（弹窗读它） | 新 `uTerm/Features/Remote/RemoteSiblingCoordinator.swift`：持有唯一一个 `RemoteSiblingDevices`，按节奏跑 `refresh()`，暴露 `pendingPrompt`；页面不再自己 `.live()` | 两端 |
| 确认弹窗的纯逻辑（选哪一条、什么时候关） | 同上文件或 `RemoteSiblingPromptState.swift` | 两端 |
| Mac 弹窗 | `uTerm/Features/Remote/RemoteSiblingPrompt.swift`（照 `RemotePairingPrompt` 写 `NSPanel`） | mac-only，加进 iOS 的 `membershipExceptions` |
| iOS 弹窗 | `uTermMobile/Screens/Remote/RemoteSiblingPromptSheet.swift`，挂根视图 | iOS |
| 被控页各组、添加设备 sheet、中继 sheet | `uTerm/Features/Settings/Views/`（mac-only，同现状） | mac |
| ⓘ「了解更多」原语 | `SettingsPrimitives.swift` 加 `SettingsLearnMore`（popover） | mac（iOS 的 `MInsetGroup` 另加或不加） |
| 新侧栏页 | `SettingsSection` 加 `case devices`（Q1 选 A 时），`SettingsCatalog` 加条目 | 两端 |

---

## 4. 分步落地

收益按「user 的抱怨 + 走查卡住的点」排序。

| 步 | 内容 | 收益 | 改动量（粗估） | 坑 |
|---|---|---|---|---|
| **1** | **确认弹窗**：`RemoteSiblingCoordinator` 在 App 层跑名册；Mac `NSPanel`、iOS 根视图 sheet；页面改用 coordinator 的同一个实例 | 解决「以为卡住了」；不用两台都翻到某一页 | 中：共享 ~150 行 + Mac 面板 ~120 + iOS sheet ~120 + 测试 | ① 全 App 只能有一个 `RemoteSiblingDevices` 实例在答题，页面再 `.live()` 一个会重复写名册；② 轮询节奏（Q4），后台停；③ 测试宿主不跑（和正式版共用钥匙串 / 偏好，同 `MobileTerminalTabArchive` 的做法）；④ 远控进程 `uTermRemoteHost` 不跑（没有钥匙串访问组）；⑤ 起点放 `AppBootstrap.finishCore` 之后，**不改 startCore / finishCore 的顺序**；⑥ iOS 宽屏别用 `confirmationDialog`（会变 popover，见 memory mobile-dialog-popover-anchor）；⑦ 面板与 `uTermApp.swift:135/196` 的 `showsRemotePanels` 判断对齐 |
| **2** | **文案一轮**：按 3.5 改字、删 footer、修「撤销配对…」加确认、修口语 | 一页字数从约 1100 降到约 250 | 小：纯字符串 + 一个 alert | ① `RemoteControlPresentationTests.testHints`（`:74-78`）断言含「uterm 技能」「10 分钟」「扫码配对」，要跟着改；② `make sync-strings`（两端都编）后 `make check-strings`；③ 担保通知正文、`waitingDetail` 里的设置路径要和新结构一致 |
| **3** | **拆方向**：「我的设备」挪出被控页（Q1）；「替这台设备开通的 Mac」并进「我的 Mac」 | 被控页只剩被控 | 小到中：新 `SettingsSection` case + 视图搬家 | `SettingsCatalogTests` 钉了分区 rawValue 列表（`:83-88`）、图标互不相同（`:90`）、侧栏覆盖（`:102`）、mac-only 分区（`:118`）；`rawValue` 一旦加了不能改；`SettingsView.sections` 与截图用例的循环都会多一页 |
| **4** | **设备合并**：删「允许经公网连接的设备」组，公网权限进每台设备的 ⋯；担保开关单独成组；二维码改「添加设备」sheet | 只剩一张设备列表；列表不被二维码顶下去 | 中 | ① 公网候选（`server.internetAccessCandidates`）与已配对列表是否完全同集，先核一下；② 截图用例的 `Options(pairingInvitation:)`（`SettingsPageSnapshotTests.swift:245`）会把二维码拍进 `remote-tall`，挪进 sheet 后要单拍一张「remote-add-device」；③ `SettingsCatalog` 里 `remote.internetDevices`、`remote.pairing` 的 group / kind 要改 |
| **5** | **中继 sheet**：中继行只留一行状态，其余进 sheet | 公网组从最多 10 行缩到 3 行 | 中：从 `RemoteInternetGroup` 搬 ~200 行 | sheet 在设置窗最小尺寸 880×600 下要放得下 AI 提示词块；`fileImporter` / `NSSavePanel` 从 sheet 里弹要验一次；截图用例补「relay-sheet」 |
| **6** | **能力组收紧**：辅助程序只在失败时出现；重启提示改行内；观看者挪到第一组 | 少 2–3 行常驻 | 小 | `RemoteDesktopPermissionState.requestedThisRun` 决定提示何时出现，别把「从没授权过」的用户也挡在提示后面 |
| **7** | **iOS**：只走公网挪进网络诊断；「我的设备」行角标；改短主机页说明 | iOS 设置根更干净 | 小 | `SettingsCatalog` 里 `remote.internetOnly` 的 group 要改；`uTermMobileTests` 若有设置页快照要重拍 |

通用的坑：

- **截图验收**：`SettingsPageSnapshotTests`（`TEST_RUNNER_UTERM_SETTINGS_SHOTS=<dir>`）出 PNG 看图，别只看编译过（memory settings-visual-taste）。新增的 sheet / 面板都要加拍。
- **视觉口味**：单色图标、同底色 + 描边卡片、缩进带导轨；弹窗沿用 `RemotePairingPanelView` 的样式（`RemotePairingPanel.swift:86-124`）。
- **新文件**：mac-only 视图加进 pbxproj `10C0DE0000000000000000C0` 的 `membershipExceptions`；共享文件放 `uTerm/` 下即可。
- **偏好键**：不新增键就不碰 `DefaultsKey`；要加（例如记住 sheet 状态）就先加表，已有值不改。
- **主工作树里有别的会话未提交的改动**（`project.pbxproj`、`RemoteControlBanner.swift` 等），动手时在 worktree 里做，合 pbxproj 时注意冲突。

---

## 5. 要 user 拍板的问题

| # | 问题 | 选项 | 推荐 |
|---|---|---|---|
| Q1 | Mac 上「我的设备」放哪？ | A 设置侧栏单独一页「我的设备」；B 留在「远程控制」页底部、默认折叠；C 挪进欢迎窗口「我的 Mac」 | **A**。它管主控、两端都有，和 iOS「设置 › 远程控制 › 我的设备」对得上；确认改成弹窗后，这一页只剩列表和丢失管理，不用常开 |
| Q2 | 公网放行怎么放？ | A 删掉单独的列表，每台设备的 ⋯ 里勾「允许经公网连接」，副标题标出来；B 保留单独一组 | **A**。同一批设备只列一次；新配对的设备默认只在局域网，规则不变 |
| Q3 | 中继的管理挪进 sheet 吗？ | A 设置页只留一行「中继 · 状态 · [管理…]」，其余进 sheet；B 保持行内展开 | **A**。8 个动作、更新、测试结果、AI 提示词都是低频操作 |
| Q4 | 为了弹窗，App 要在后台一直读名册吗？ | A App 在运行就读：平时每 10 秒，有确认在进行时每 2 秒，iOS 进后台停；B 只在打开「我的设备」页时读（现状，弹窗只在那一页有效） | **A**。只读本机钥匙串、不联网，代价小；B 解决不了「新设备不开那一页就收不到」 |
