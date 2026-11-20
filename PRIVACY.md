# uTerm 隐私政策 / Privacy Policy

生效日期：2026-11-20

uTerm 由柚子星云科技（深圳）有限公司（Uozi Tech，下称「我们」）开发，包括 macOS 版与 iOS / iPadOS 版。
这份说明讲清楚 uTerm 会处理哪些数据、存在哪里、发给谁。一句话：**uTerm 没有账号，不收集统计或行为数据，
你的主机、密钥、对话都存在你自己的设备和你自己的 iCloud 里，我们看不到。**

## 我们不收集的

- 不需要注册账号，不收集姓名、邮箱、手机号。
- 不内置任何统计、广告、行为追踪或第三方崩溃收集组件，不做跨 App 追踪。
- 没有运营任何接收你数据的服务器：远程控制用的中继由你自己部署，AI 请求直接发给你选的服务商。

## 存在你设备上的数据

- **主机、分组、快捷命令、端口转发规则、已知主机指纹、AI 对话记录**：存在本机的数据库里。
- **密码、私钥口令、AI 服务的 API Key、远程控制的配对身份**：存在系统钥匙串里。
- **偏好设置**：存在本机。

## 经 iCloud 同步的数据

开着 iCloud 时，上面的数据会经 **你自己的 iCloud** 在你的设备之间同步：数据库走 CloudKit 私有数据库，钥匙串里的条目走
iCloud 钥匙串，部分偏好走 iCloud 键值存储。这些都在你的 Apple 账户里，由 Apple 按其隐私政策保管，我们无法访问。
不想同步可以在系统设置里关掉 uTerm 的 iCloud。

## 会发生的网络连接

- **你的服务器**：SSH、SFTP、端口转发直接连你配置的主机。iOS 版为了让会话在断网、切后台后不中断，会把一个小程序
  `uterm-holder` 放到你主机上自己用户的 `~/.local/share/uterm/` 下，终端输出的缓冲与检查点也存在那里，都在你自己的主机上。
- **AI 服务**：你配置了 AI 服务（如 OpenAI、Anthropic、DeepSeek 等）并使用 AI 助手时，对话内容、你让它读的终端输出、
  它执行命令的结果会直接发给你选的服务商，适用该服务商的隐私政策。不配置就不会发。
- **设备之间**：局域网同步与远程控制在你的设备之间直接传输；跨网络时可能经过你自己部署的中继。远程控制的终端与屏幕
  内容端到端加密，中继只转发、看不到内容。
- **检查更新（仅 macOS 官方构建）**：会定期向我们的下载服务器请求更新信息并下载更新包。请求里只有常规的网络信息
  （IP 地址、App 版本），不附带系统信息或你的任何数据。可以在设置里关掉自动检查。
- **一键部署中继（仅官方构建）**：你在自己的服务器上一键安装或更新中继时，那台服务器会从我们的下载服务器取安装脚本与程序。

## 系统权限

只有用到相应功能时才会请求：

- **本地网络**：局域网同步、发现与远程控制附近的 Mac。
- **相机（iOS）**：扫描 Mac 上显示的配对二维码，不拍照、不保存。
- **面容 ID / 触控 ID**：解锁 App；远程解锁 Mac 或填写验证框时取用你保存的登录密码。
- **通知**：终端里的程序完成、出错或需要你处理时提醒你。
- **屏幕录制、辅助功能（macOS）**：只在你允许别的设备远程控制这台 Mac 时使用，用来传画面和接收鼠标键盘操作。
- **文件夹访问（macOS）**：在 uTerm 本机终端里运行的程序要读写桌面、文稿等文件夹时，系统会以 uTerm 的名义询问你。

## TestFlight 与 App Store

如果你通过 TestFlight 参加测试并主动提交反馈，Apple 会把你填写的反馈、附带的截图，以及你同意分享的崩溃报告转给我们，
只用于修问题。App Store 版本的崩溃统计同样只在你在系统设置里同意与开发者共享时才会经 Apple 提供给我们。

## 儿童

uTerm 是面向开发者与运维人员的工具，不针对儿童。

## 变更

这份政策有变化时会更新本页并修改生效日期，历次修改记录在本仓库的提交历史里。

## 联系我们

对隐私有疑问，请在 [GitHub](https://github.com/uozi-tech/uTerm/issues) 开 issue；涉及安全问题请按 [`SECURITY.md`](SECURITY.md) 私下报告。

---

## English

Effective date: 2026-11-20

uTerm for macOS and iOS / iPadOS is developed by Uozi Tech (柚子星云科技（深圳）有限公司, "we"). In short: **uTerm has no
accounts and collects no analytics or usage data. Your hosts, keys and conversations stay on your devices and in your
own iCloud, where we cannot see them.**

**What we don't collect.** No sign-up, no name, email or phone number. No analytics, advertising, tracking or
third-party crash-reporting SDKs, and no cross-app tracking. We run no server that receives your data: the remote-control
relay is one you deploy yourself, and AI requests go directly to the provider you choose.

**Stored on your device.** Hosts, groups, quick commands, port-forwarding rules, known host fingerprints and AI
conversations are kept in a local database. Passwords, key passphrases, AI API keys and remote-control pairing identities
are kept in the system keychain. Preferences stay on the device.

**iCloud sync.** With iCloud on, the data above syncs between your devices through **your own iCloud**: the database via
a CloudKit private database, keychain items via iCloud Keychain, some preferences via iCloud key-value storage. It lives
in your Apple account under Apple's privacy policy; we cannot access it. Turn off iCloud for uTerm in Settings to stop
syncing.

**Network connections.**
- *Your servers*: SSH, SFTP and port forwarding connect directly to the hosts you configure. To keep sessions alive across
  network changes and backgrounding, the iOS app places a small helper, `uterm-holder`, under `~/.local/share/uterm/` of
  your own user on your host; terminal output buffers and checkpoints are stored there too, on your host.
- *AI providers*: if you configure one (OpenAI, Anthropic, DeepSeek, etc.) and use the assistant, the conversation, any
  terminal output you share with it and the results of commands it runs are sent directly to that provider, under its
  privacy policy. Nothing is sent if you don't configure one.
- *Between your devices*: LAN sync and remote control go directly between your devices, possibly through a relay you
  deploy yourself when crossing networks. Remote-control terminal and screen content is end-to-end encrypted; the relay
  only forwards it and cannot read it.
- *Update checks (official macOS builds only)*: the app periodically asks our download server for update information and
  downloads updates. The request carries only ordinary network information (IP address, app version), no system profile
  and none of your data. Automatic checks can be turned off in Settings.
- *One-click relay deployment (official builds only)*: when you install or update the relay on your own server, that
  server downloads the install script and binary from our download server.

**Permissions**, requested only when a feature needs them: local network (LAN sync, finding and controlling nearby Macs);
camera on iOS (scanning the pairing QR code shown on a Mac; nothing is saved); Face ID / Touch ID (unlocking the app, and
retrieving your saved login password to unlock a Mac or fill an authentication prompt remotely); notifications (programs
in a terminal finished, failed or need you); screen recording and accessibility on macOS (only when you allow another
device to control this Mac); folder access on macOS (prompted on behalf of programs you run in uTerm's local terminal).

**TestFlight and App Store.** If you join a TestFlight test and send feedback, Apple forwards your feedback, attached
screenshots and any crash reports you agree to share; we use them only to fix problems. App Store crash statistics reach us
through Apple only if you have chosen to share them with developers.

**Children.** uTerm is a tool for developers and operators and is not directed at children.

**Changes.** We update this page and its effective date when the policy changes; every revision is in this repository's
history.

**Contact.** Open an issue on [GitHub](https://github.com/uozi-tech/uTerm/issues); report security issues privately as
described in [`SECURITY.md`](SECURITY.md).
