# uterm-relay

让 uTerm 手机端连上不在同一网络的 Mac。部署在两端都能访问的服务器上，把配置导入 uTerm，再到 Mac 上打开公网接入。

中继只转发密文：远控握手和业务数据端到端加密，它看得到的只有设备 ID、来源 IP 和流量大小。线上协议见 [PROTOCOL.md](PROTOCOL.md)。

## 部署

### 让 AI 装（推荐）

在 uTerm 设置 › 远程控制 › 公网接入 点「让 AI 部署…」，复制提示词贴给装了 uterm 技能的 AI 工具（Claude Code、Codex 等）。它会在你 uTerm 里保存的一台主机上跑下面的安装脚本、经 `utermctl relay import` 把配置交给 uTerm、再用 `utermctl relay check` 测通。成员密钥只从服务器文件直接进 uTerm 的钥匙串，不经过 AI。流程见 `skills/uterm/references/relay.md`。

### 安装脚本

Linux + systemd，amd64 或 arm64。放行同一端口号的 **TCP 和 UDP**（默认 47310），云服务器的安全组要手动放行。

```sh
curl -fsSL https://downloads.example.com/uTerm/relay/install.sh \
  | sudo sh -s -- install --port 47310 --public-host relay.example.com [--name 家里] [--open-firewall]
```

脚本从 OSS 下载对应架构的二进制、按 `SHA256SUMS` 校验，装到 `/usr/local/bin/uterm-relay`，写 `/etc/uterm-relay/relay.env` 和 `uterm-relay.service`（DynamicUser，数据在 `/var/lib/uterm-relay`）。设备配置写到运行 sudo 的那个用户的 `~/.config/uterm-relay/client.json`（0600），然后在 uTerm 里导入：

```sh
utermctl relay import -H <这台主机>   # 或 设置 › 远程控制 › 导入配置，选这个文件
utermctl relay check
```

脚本只输出 `key=value` 摘要，不打印密钥。其它子命令：

| 子命令 | 作用 |
|---|---|
| `update [--version V]` | 换成最新版（或 V）并重启；起不来自动换回旧版 |
| `status` | 安装版本、最新版本、服务状态、在线主机 |
| `client-config` | 重新生成设备配置（`rotate` 之后，或换了 SSH 用户） |

uTerm 会提醒新版本；中继是经 `relay import` 导入的话，设置页里能一键更新。

### Docker / 手动编译

需要源码。Docker Compose：

```sh
RELAY_PUBLIC_HOST=relay.example.com docker compose up -d --build
docker compose exec relay /uterm-relay config > uterm-relay.json
```

或者（Go 1.25 或更新，只用标准库）：

```sh
go build -o uterm-relay ./cmd/uterm-relay
RELAY_DATA=/var/lib/uterm-relay RELAY_PUBLIC_HOST=relay.example.com ./uterm-relay
```

`uterm-relay.json` 含成员私钥，等同口令：不要提交到仓库，也不要发到公开渠道。

### 发布（维护者）

`make relay-publish`：交叉编译两个架构、生成 `SHA256SUMS` 与 `latest.json`，连同 `install.sh` 传到 OSS 的 `uTerm/relay/`。版本取 `cmd/uterm-relay/main.go` 的 `version`；hello 里会带上它，uTerm 据此提醒更新。

## 导入

- **Mac：** 设置 › 远程控制 › 中继服务器，选配置文件；或 `utermctl relay import`。
- **同一 Apple ID 的手机：** 经 iCloud 钥匙串自动同步。
- **其它手机：** Mac 设置里「分享到我的设备…」（AirDrop / 信息，手机上点开链接确认导入），或「显示二维码」后在手机「我的 Mac」扫码。

然后在 Mac 上打开「允许经公网接入」，并勾选允许的设备。名册里的设备不会自动获得公网接入权限。

## 设置

| 环境变量 | 含义 | 默认 |
|---|---|---|
| `RELAY_PUBLIC_HOST` | 设备连接用的域名或 IP。生成配置时必须有 | 无 |
| `RELAY_PUBLIC_PORT` | 设备连接用的端口 | `47310` |
| `RELAY_NAME` | App 里显示的名字 | 同 `RELAY_PUBLIC_HOST` |
| `RELAY_LISTEN` | 监听地址 | `:47310` |
| `RELAY_DATA` | 数据目录 | `/data` |
| `RELAY_RATE_PER_IP` | 单 IP（IPv6 按 /64）每 10 秒可新建的连接数。`0` 关闭，同时关闭单来源最多 16 条未认证连接的上限；中继前面有代理、所有连接看起来来自同一地址时要设 `0` | `60` |

## 命令

```sh
docker compose exec relay /uterm-relay status
```

| 命令 | 作用 |
|---|---|
| `config` / `config-url` | 打印配置（JSON / 二维码链接） |
| `status` | 在线主机和连接数 |
| `rotate` | 换成员密钥并断开所有连接，所有设备要重新导入。配置泄露时用 |
| `forget <主机 ID>` | 解除主机 ID 与其密钥的绑定，Mac 重装后用；绑定满了（1024 个）新 Mac 注册不上时也用它腾位置 |

## 限制

- Mac 睡眠时会掉线，中继无法把它唤醒。
- Mac 锁屏时终端可用，桌面采不到画面。
- 手机和 Mac 会先经这台服务器交换地址尝试打洞，打通后数据不再经过它。打不通才走中继。
- 中继走 TCP：丢包时整条流会短暂卡住，桌面的码率也上不去。
