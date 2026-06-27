# uTerm 对 vendored swift-nio-ssh 的本地补丁

上游：`https://github.com/Wellz26/swift-nio-ssh`（Citadel 依赖的 fork），基线
revision `a05e6bbe6b141ee68da3030e00275504c0595d4d`（tag `0.3.6`）。

为什么 vendor：Citadel `0.12.1` 的 `Package.swift` 把 `swift-nio-ssh` 硬钉到
`Wellz26/swift-nio-ssh`（`0.3.4 ..< 0.4.0`，带 cert-auth / Catalyst 补丁，不能直接
换成 apple 上游）。这个 fork 是 swift-nio-ssh **修复前**的快照，缺了 Apple 后来
加的 `!self.state.sentClose` 守卫，会在连接拆除时崩溃（见下）。

引用方式（2026-06-27 改）：现由 vendored Citadel 的 `Package.swift` 用
`.package(path: "../swift-nio-ssh")` 直接拉入本包，根工程**不再**有
`XCLocalSwiftPackageReference "vendor/swift-nio-ssh"`。改前靠「根工程声明同名本地包覆盖
Citadel 远程 nio-ssh」的 identity-override，虽有效但会触发 SwiftPM 6（Xcode 26）的
「Conflicting identity for swift-nio-ssh」警告（同 identity、一个远程 URL 一个本地 path）。
vendor Citadel 后依赖图里不再有任何 nio-ssh 远程 URL，警告消除。来龙去脉见
`vendor/Citadel/UTERM-PATCHES.md`。`Package.resolved` 里 `swift-nio-ssh` 解析为本地 path
即表示生效。

更新方式：拉取上游 fork 新 revision，用其 `Sources/NIOSSH` 覆盖本目录的
`Sources/NIOSSH`（保留本文件与裁剪版 `Package.swift`），然后逐条重放下列补丁。
**不要**直接整目录覆盖。

裁剪：`Package.swift` 只保留 `NIOSSH` library target；上游的 `NIOSSHClient` /
`NIOSSHServer` / `NIOSSHPerformanceTester` 可执行 target、测试 target，以及
`swift-docc-plugin` 依赖都已删除。

## 1. 修复 channel 拆除期的 window-adjust 崩溃

崩溃签名（线上 1.6.0 build 134 实测）：

```
Swift runtime failure: precondition failure
ChildChannelStateMachine.sendChannelWindowAdjust(_:)  ChildChannelStateMachine.swift:432
  "Sent channel window adjust on channel in invalid state"
SSHChildChannel.handleOutboundChannelWindowAdjust(_:_:)  SSHChildChannel.swift
SSHChildChannel.deliverSingleRead(_:)                     SSHChildChannel.swift
SSHChildChannel.deliverPendingReads()
SSHChildChannel.tryToRead()
SSHChannelMultiplexer.parentChannelReadComplete()
NIOSSHHandler.channelReadComplete(context:)
```

根因：远端关闭 channel（或本地发起拆除）后，state machine 进入
`.closedLocally`/`.closed`，但 `didClose` 标志还没置位、且仍有缓冲的入站数据要
投递。父 socket 的 `channelReadComplete` 触发 `tryToRead()` →
`tryToRead` 的守卫 `state.isActiveOnChannel` 对 `.closedLocally`/`.closedRemotely`
**返回 true** → `deliverPendingReads()` → `deliverSingleRead()`：排空读数据腾出了
window，于是构造 `CHANNEL_WINDOW_ADJUST` 并 `processOutboundMessage` →
`sendChannelWindowAdjust()` 对这些已关闭状态 `preconditionFailure`，直接 abort
整个进程（SIGTRAP，发生在 NIO event-loop 线程上）。

`isActiveOnChannel`（投递读，避免丢数据）和 `sendChannelWindowAdjust`（拒绝已关闭
状态）对“已关闭”的判定不一致，是这个 bug 的本质。

涉及文件：

- `Sources/NIOSSH/Child Channels/SSHChildChannel.swift`，`deliverSingleRead(_:)`
  的 `.data` 分支：window-adjust 的发送条件从 `if !self.didClose, …` 改为
  `if !self.didClose, !self.state.sentClose, …`。`sentClose` 对 `.closedLocally` /
  `.closed` 返回 true，正好覆盖会触发 precondition 的状态——已发过 CLOSE 的
  channel 不再尝试回 window-adjust（对端已走，回 ACK 本就无意义）。

这与 apple/swift-nio-ssh 上游 `deliverSingleRead` 的现行实现一致（上游正是用
`!self.didClose, !self.state.sentClose` 守卫修掉同一个 precondition 崩溃）。fork
合上游或升级 Citadel 到改用已修 nio-ssh 的版本后，此补丁可去除。

## 2. 补全 window-adjust 崩溃：覆盖 `.closedRemotely`（对端先关）

补丁 #1 的 `!self.state.sentClose` 守卫**只覆盖我方先关**方向：`sentClose` 仅对
`.closedLocally`/`.closed` 返回 true。但 `.closedRemotely`（“远端已发 CHANNEL_CLOSE、
我方还没回”——**正是网络波动 / 远端先掉线的场景**）`sentClose` 返回 **false**，而
`isActiveOnChannel` 对它返回 **true**、`sendChannelWindowAdjust` 对它仍 `preconditionFailure`
（`ChildChannelStateMachine.swift` 三者分别在 line 607 / 595 / 431）。于是补丁 #1 之后，
**同一条 line:432 崩溃经“对端先关”这扇门照样触发**：

```
对端 DATA+CLOSE 同段到达
  → receiveChannelClose: .active → .closedRemotely
  → 父 channelReadComplete → tryToRead（guard isActiveOnChannel 对 .closedRemotely == true，放行）
  → deliverPendingReads → deliverSingleRead(.data)
  → 补丁 #1 守卫 `!didClose && !sentClose` 在 .closedRemotely 下双双为 false → 放行
  → unbufferBytes 出增量 → processOutboundMessage(.channelWindowAdjust)
  → sendChannelWindowAdjust 命中 .closedRemotely → preconditionFailure → 进程 abort
```

（TCP 掉线那条路径**不是**第二入口：`errorEncountered` 先把 `didClose = true` 再排空读，
被 `!didClose` 半边挡住。真正漏的只有 inbound-CHANNEL_CLOSE 即 `.closedRemotely` 这条。）

根因是结构性的：window-adjust 的合法状态集
（`.active`/`.halfClosedLocal`/`.halfClosedRemote`/`.quiescent`）**严格窄于** `isActiveOnChannel`
（后者还含 `.closedLocally`/`.closedRemotely`）。补丁 #1 只中和了 `.closedLocally` 一臂。

涉及文件：

- `Sources/NIOSSH/Child Channels/ChildChannelStateMachine.swift`：在 `sentClose` 之后新增计算
  属性 `canSendWindowAdjust`，只对 `sendChannelWindowAdjust` 接受的 4 个状态返回 true（与
  该方法的接受集逐一对齐，把“合法性”收敛到一处）。
- `Sources/NIOSSH/Child Channels/SSHChildChannel.swift`：`deliverSingleRead` 的 `.data` 分支
  守卫从 `if !self.didClose, !self.state.sentClose, …` 改为
  `if !self.didClose, self.state.canSendWindowAdjust, …`。`.closedRemotely` 下短路、不再尝试
  发 window-adjust（对端已走，回 ACK 本就无意义；与补丁 #1 对 `.closedLocally` 的短路行为一致，
  顺带也不会在该状态调用 `unbufferBytes` 的无符号减法）。

升级上游 / Citadel 换用已修 nio-ssh 后，补丁 #1、#2 一并可去除（届时核对上游
`deliverSingleRead` 是否已对两个关闭方向都不发 window-adjust）。

> ⚠️ 验证：vendored 包改完后需在 Xcode reset package caches 重解析再编译；线上崩溃只在
> `-L`/`-D`/长连在**远端先断**时复现，**发版前务必真机 flap smoke 验证**（编译过 ≠ 修好）。
> SourceKit 在 fresh checkout 对本 target 报「Cannot find type SSHChannelIdentifier / 不符合
> Equatable」是已知假阳性，信 xcodebuild。
