# uTerm 对 vendored swift-nio-ssh 的本地补丁

上游：`https://github.com/Wellz26/swift-nio-ssh`（Citadel 依赖的 fork），基线
revision `a05e6bbe6b141ee68da3030e00275504c0595d4d`（tag `0.3.6`）。

为什么 vendor：Citadel `0.12.1` 的 `Package.swift` 把 `swift-nio-ssh` 硬钉到
`Wellz26/swift-nio-ssh`（`0.3.4 ..< 0.4.0`，带 cert-auth / Catalyst 补丁，不能直接
换成 apple 上游）。这个 fork 是 swift-nio-ssh **修复前**的快照，缺了 Apple 后来
加的 `!self.state.sentClose` 守卫，会在连接拆除时崩溃（见下）。

引用方式：pbxproj 以 `XCLocalSwiftPackageReference "vendor/swift-nio-ssh"` 引用。
本地 path 包的 identity = 目录名 `swift-nio-ssh`，与 Citadel 远程依赖的 identity
相同，因此**覆盖**掉那条 transitive 远程依赖（SwiftPM 的 local override 机制，无视
版本区间）。`Package.resolved` 里不再出现 `swift-nio-ssh` 即表示覆盖生效。

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
