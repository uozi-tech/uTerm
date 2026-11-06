# uterm-relay

让 uTerm 手机端连上不在同一网络的 Mac。部署在两端都能访问的服务器上，把配置导入 uTerm，再到 Mac 上打开公网接入。

中继只转发密文：远控握手和业务数据端到端加密，它看得到的只有设备 ID、来源 IP 和流量大小。线上协议见 [PROTOCOL.md](PROTOCOL.md)。

## 部署

需要 Docker Compose，并放行同一端口号的 **TCP 和 UDP**（默认 47310）。云服务器的安全组要手动放行。

```sh
RELAY_PUBLIC_HOST=relay.example.com docker compose up -d --build
docker compose exec relay /uterm-relay config > uterm-relay.json
```

不用 Docker（Go 1.25 或更新，只用标准库）：

```sh
go build -o uterm-relay ./cmd/uterm-relay
RELAY_DATA=/var/lib/uterm-relay RELAY_PUBLIC_HOST=relay.example.com ./uterm-relay
```

`uterm-relay.json` 含成员私钥，等同口令：不要提交到仓库，也不要发到公开渠道。导入后可以删掉服务器上的 `member.key`，之后 `config` 就打印不出来了，要新配置只能 `rotate`。

## 导入

- **Mac：** 设置 › 远程控制 › 中继服务器，选配置文件。
- **同一 Apple ID 的手机：** 经 iCloud 钥匙串自动同步。
- **其它手机：** 在 Mac 设置里显示二维码，手机在「我的 Mac」扫码；或运行 `uterm-relay config-url` 自己生成二维码。

然后在 Mac 上打开「允许经公网接入」，并勾选允许的设备。名册里的设备不会自动获得公网接入权限。

## 设置

| 环境变量 | 含义 | 默认 |
|---|---|---|
| `RELAY_PUBLIC_HOST` | 设备连接用的域名或 IP。生成配置时必须有 | 无 |
| `RELAY_PUBLIC_PORT` | 设备连接用的端口 | `47310` |
| `RELAY_NAME` | App 里显示的名字 | 同 `RELAY_PUBLIC_HOST` |
| `RELAY_LISTEN` | 监听地址 | `:47310` |
| `RELAY_DATA` | 数据目录 | `/data` |
| `RELAY_RATE_PER_IP` | 单 IP 每 10 秒可新建的连接数，`0` 关闭 | `60` |

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
