# uTerm

macOS 与 iOS / iPadOS 上的服务器工作台：SSH 终端、SFTP 文件浏览与编辑、端口转发、密钥管理、快捷命令与多机并行执行、
AI 助手；手机或另一台 Mac 还能经局域网或自建中继远程控制这台 Mac 的终端与屏幕。终端引擎是 [Ghostty](https://ghostty.org)。

A native server workspace for macOS and iOS / iPadOS: SSH terminals (Ghostty engine), SFTP, port forwarding, keys,
quick commands across many hosts, an AI assistant, and remote control of a Mac from a phone or another Mac over the LAN or
a self-hosted relay.

## 平台

- macOS 26 及以上（Apple 芯片）
- iOS / iPadOS 18 及以上

## 从源码构建

需要 Xcode 27（或更新）、Go（编主机上的会话保持进程 `holder/`）和网络。

```sh
git clone https://github.com/uozi-tech/uTerm.git && cd uTerm
cp Config/Local.xcconfig.example Config/Local.xcconfig   # 填自己的 Apple Developer Team ID
make engine     # 终端引擎：第一次从上游源码编（约 15 分钟，会下载 Zig 与 Ghostty 源码）
make build      # 或者 open uTerm.xcodeproj
```

- **签名**：远控进程、本机终端的辅助进程与 holder 之间按「同一团队签名」互认，团队号从签名里读，所以用你自己的团队签就行，
  不用改源码。
- **引擎**：`vendor/libghostty-spm` 是带补丁的 libghostty-spm（补丁见它的 `UTERM-PATCHES.md`），两个 xcframework 不进版本库，
  `make engine` 按 `ENGINE.lock` 取或现编。
- **应用内更新与中继一键部署**：源码构建默认没有（入口自动隐藏）。要的话在 `Config/Local.xcconfig` 里配自己的更新源与中继
  发布地址，见 `Config/Local.xcconfig.example`。
- **iCloud 同步**：用的是 `iCloud.com.uozi.uTerm` 容器，你自己的团队用不了它；换 bundle id 与容器才能同步。

## 测试

```sh
make test-fast           # macOS：并行全量，失败的再串行复核
make test-mobile-fast    # iOS 模拟器
make test-holder         # 主机会话保持进程（Go）
cd relay && GOWORK=off go test -race ./...   # 自建中继
```

## 目录

| 路径 | 内容 |
|---|---|
| `uTerm/` | 两端共享的代码与 macOS App（iOS 不编的文件在 pbxproj 的 membership exceptions 里） |
| `uTermMobile/` | iOS / iPadOS 的视图与平台桥接 |
| `uTermRemoteHost/`、`uTermShellAgent/`、`uTermHolder/`、`uTermSSH/` | macOS 的辅助进程：远控、本机终端、会话保持、SSH 桥 |
| `holder/` | 主机上的会话保持进程（Go，断线重连接回 shell） |
| `relay/` | 自建中继（Go，TCP 中继 + STUN），协议见 `relay/PROTOCOL.md`、部署见 `relay/README.md` |
| `skills/`、`scripts/utermctl` | 给 AI 工具用的命令行与技能 |
| `vendor/` | 带补丁的第三方源码，各自的 `UTERM-PATCHES.md` 记着改了什么 |
| `docs/` | 设计文档与调研记录 |

工程约定（共享代码怎么放、终端引擎、远控进程、holder、CloudKit schema、版本号……）写在 [`CLAUDE.md`](CLAUDE.md)，
既是给人看的，也是给 AI 编码工具读的。共享的 Swift 包在 [uAppKit](https://github.com/uozi-tech/uAppKit)。

## 参与贡献

见 [`CONTRIBUTING.md`](CONTRIBUTING.md)。合并 PR 之前每位贡献者要签一次 [CLA](CLA.md)（PR 里自动检查）。
安全问题请按 [`SECURITY.md`](SECURITY.md) 私下报告。

## 许可证

[AGPL-3.0](LICENSE)。第三方组件各自的许可证见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
