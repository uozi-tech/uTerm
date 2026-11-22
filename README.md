# uTerm

**简体中文** | [English](README.en.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md)

macOS 与 iOS / iPadOS 上的服务器工作台：SSH 终端、SFTP 文件浏览与编辑、端口转发、密钥管理、快捷命令与多机并行执行、
AI 助手；手机或另一台 Mac 还能经局域网或自建中继远程控制这台 Mac 的终端与屏幕。终端引擎是 [Ghostty](https://ghostty.org)，
经 [libghostty-spm](https://github.com/Lakr233/libghostty-spm) 以 Swift 包接入（带补丁的 fork 在 `vendor/libghostty-spm`）。

## 平台

- macOS 26 及以上（Apple 芯片）
- iOS / iPadOS 18 及以上
- 界面语言：简体中文、English、繁體中文、日本語、한국어（跟随系统；Mac 上可在「设置 › 外观 › 语言」单独指定）

## 从源码构建

需要 Xcode 27（或更新）、Go（编主机上的会话保持进程 `holder/`）和网络。

```sh
git clone https://github.com/uozi-tech/uTerm.git && cd uTerm
cp Config/Local.xcconfig.example Config/Local.xcconfig   # 填自己的 Team ID 与 bundle id 前缀
make engine     # 终端引擎：第一次从上游源码编（约 15 分钟，会下载 Zig 与 Ghostty 源码）
make build      # 或者 open uTerm.xcodeproj
```

- **签名**：用你自己的团队签名时，在 `Config/Local.xcconfig` 里填 Team ID，并把 `UTERM_BUNDLE_ID` 换成你自己的前缀
  （App ID 全苹果唯一，`com.uozi.uTerm` 只有我们的团队能用）。各 target 的 bundle id、iCloud 容器、钥匙串访问组、
  远控进程的 launchd 任务名都由这个前缀派生；远控进程、本机终端的辅助进程与 holder 之间按「同一团队签名」互认，
  团队号与身份都在运行时读，不用改源码。第一次构建用 Xcode 打开工程、在 Signing & Capabilities 里让它注册 App ID
  与 iCloud 容器，或者命令行加 `-allowProvisioningUpdates`。
- **引擎**：`vendor/libghostty-spm` 是带补丁的 libghostty-spm（补丁见它的 `UTERM-PATCHES.md`），两个 xcframework 不进版本库，
  `make engine` 按 `ENGINE.lock` 取或现编。
- **应用内更新与中继一键部署**：源码构建默认没有（入口自动隐藏）。要的话在 `Config/Local.xcconfig` 里配自己的更新源与中继
  发布地址，见 `Config/Local.xcconfig.example`。
- **分发改过的版本**：换掉应用名称（`INFOPLIST_KEY_CFBundleDisplayName`）与图标（`AppIcon`），不能以 uTerm 的名义发布，
  见 [`TRADEMARK.md`](TRADEMARK.md)。自己编、自己用不用改。
- **iCloud 同步**：容器是 `iCloud.<bundle id 前缀>`，和正式版不通。`Local.xcconfig.example` 里把环境设成 Development：
  新容器的 Production 里还没有 schema，同步会静默失败。

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
隐私政策见 [`PRIVACY.md`](PRIVACY.md)：没有账号、不收集统计数据，数据在你自己的设备与 iCloud 里。

## 许可证

[AGPL-3.0](LICENSE)。第三方组件各自的许可证见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

许可证只覆盖代码，不包括「uTerm」名称与图标：分发改过的版本要换名称和图标，见 [`TRADEMARK.md`](TRADEMARK.md)。
