# 部署与更新 uTerm 中继

中继（`uterm-relay`）让用户的手机在不同网络下也能连上他的 Mac：手机和 Mac 先经它交换地址
尝试打洞直连，打不通再由它转发。它只转发端到端加密的数据，看不到终端内容。这台服务器由
用户自建，你的任务是：在用户**已保存在 uTerm 里**的一台 Linux 主机上装好它，把配置交给
uTerm，再测通。

整件事只用三样东西：`utermctl run`（在主机上跑安装脚本）、`utermctl relay import`
（让 uTerm 自己取配置）、`utermctl relay check`（让 uTerm 测连通）。前两个要「允许执行
命令与写入」开关（见 SKILL.md）。

## 先记住：成员密钥不经过你

中继的设备配置里有一把**成员密钥**，等同口令。它只应该从服务器上的文件直接进到 uTerm
的钥匙串，**不能出现在你的输出、对话或任何命令的回显里**。所以：

- **不要**运行 `uterm-relay config` / `uterm-relay config-url`（它们会把密钥打印出来）。
- **不要** `cat` / `sftp cat` / `sftp get` / `grep` 以下文件：`~/.config/uterm-relay/client.json`、
  数据目录里的 `member.key`（`/var/lib/uterm-relay/`、`/var/lib/private/uterm-relay/`）。
- 配置只用 `relay import` 导入；它的响应里只有名字、地址和 relayID。
- **不要** `uterm-relay rotate`，除非用户明确说要换钥（换完所有设备都要重新导入）。
- 安装脚本的所有输出都不含密钥，可以照常读。
- **不要**在对话或文档里四处写中继的地址和端口，也不要用 `nc` / 浏览器去「探」它：中继对认证
  之前的连接一律不回话（只吐 32 字节随机数或直接断开），这本来就是为了不被扫到。要测就用
  `relay check`。

## 部署

### 1. 选主机、看环境

```sh
"$UTERMCTL" hosts --format table
```

让用户指定装在哪台（或用他在提示里给的那台）。要求：Linux、systemd、amd64 或 arm64、
能访问外网下载（`downloads.example.com`）。手机和 Mac 都要能访问到它，
所以通常是一台有公网 IP 的云服务器。

```sh
"$UTERMCTL" run -H <主机> -c 'uname -m; id -u; command -v systemctl; sudo -n true 2>&1 && echo sudo-ok; command -v curl || command -v wget'
```

- `id -u` 是 `0`（root）就直接跑安装脚本。
- 不是 root 但打印了 `sudo-ok`：命令前加 `sudo`。
- 不是 root 且 `sudo -n` 要密码：安装那一步改用 `terminal open`（见第 3 步）。

### 2. 问用户三件事（不要自己定）

1. **监听端口**：**每台中继用一个随机的高位端口，不要用 47310**（固定的默认端口最先被扫）。
   默认就是不给 `--port`，安装脚本自己在 20000–32767 里挑一个没被占用的，装完从输出的
   `port=` 读出来告诉用户。用户坚持要指定端口时才加 `--port`，先查有没有被占：
   ```sh
   "$UTERMCTL" run -H <主机> -c 'ss -lntu | grep -E ":<端口>\b" || echo free'
   ```
   TCP 和 UDP 用**同一个**端口号。
2. **对外地址**：手机和 Mac 连接用的域名或公网 IP。可以先给出候选——主机档案里的地址，
   或 `run -c 'curl -s4 https://ifconfig.me'` 查到的出口 IP——让用户确认。内网地址
   （`10.*`、`172.16–31.*`、`192.168.*`）在外面连不上。
3. **名字**（可选）：在 App 里显示的名字，默认就是对外地址。

另外问一句要不要让脚本放行**服务器自己的防火墙**（`ufw` / `firewalld`，加
`--open-firewall`）。不确定就不加，脚本会在输出里报告防火墙状态。

### 3. 安装

```sh
"$UTERMCTL" run -H <主机> --timeout 180 -c \
  'curl -fsSL https://downloads.example.com/uTerm/relay/install.sh | sh -s -- install --public-host <地址> --name "<名字>"'
```

（用户指定了端口才加 `--port <端口>`。）

非 root 时在 `sh` 前加 `sudo`：`… | sudo sh -s -- install …`。需要 sudo 密码时：

```sh
"$UTERMCTL" terminal open -H <主机> -- sh -c 'curl -fsSL https://downloads.example.com/uTerm/relay/install.sh | sudo sh -s -- install --public-host <地址>'
"$UTERMCTL" terminal wait -t <返回的会话 id>
```

告诉用户去那个窗口里输密码。

成功的输出是一行行 `key=value`：

| 键 | 含义 |
|---|---|
| `version` | 装上的版本 |
| `port` / `endpoint` | 监听端口（没给 `--port` 时是随机挑的）、设备连接用的地址 |
| `relay_id` | 这台中继的 ID |
| `client_config` | 设备配置写在哪（**不要读它**） |
| `firewall` | `none` / `ufw-opened` / `firewalld-opened` / `ufw-active-not-opened` / `firewalld-active-not-opened` |

`firewall` 是 `*-active-not-opened` 时，主机防火墙开着却没放行：问用户要不要加
`--open-firewall` 重跑一次 `install`（重跑是安全的，不会换密钥）。

失败时脚本在 stderr 说原因（端口被占、架构不支持、下载或校验失败、服务没起来），照着说。
服务没起来就 `run -c 'journalctl -u uterm-relay -n 50 --no-pager'` 看日志。

### 4. 提醒安全组

**云厂商控制台的安全组你碰不到**。明确告诉用户：去服务器所在云厂商的控制台，把安装输出里
`port=` 那个端口的 **TCP 和 UDP** 都放行（入方向，来源 `0.0.0.0/0`，有 IPv6 的话也放 `::/0`）。
这是最常见的「装好了却连不上」的原因。

### 5. 导入到 uTerm

```sh
"$UTERMCTL" relay import -H <主机>
```

uTerm 经 SFTP 读 `~/.config/uterm-relay/client.json`（安装脚本以 SSH 登录用户写的），
直接存进钥匙串，并记下这台中继装在这台主机上（以后 uTerm 自己能更新它）。

- `relay_exists`：uTerm 里已经有另一台中继。把 `message` 里的旧中继名字告诉用户，
  他确认要换才加 `--replace` 重跑。
- `file_not_found`：安装没成功，或装的时候用的不是同一个 SSH 用户。用
  `… | sh -s -- client-config`（非 root 加 sudo）以当前用户重新生成，再导入。
- `relay_config_invalid`：同上，重新生成。

### 6. 测试

```sh
"$UTERMCTL" relay check --format table
```

uTerm 从这台 Mac 连一遍中继，逐项报告：

| 项 | 不通时多半是 |
|---|---|
| `tcp` | 服务没跑起来、安全组或防火墙没放行 TCP、对外地址写错 |
| `auth` | 地址指到了别的服务器，或中继数据目录被重建过——重新 `client-config` + `relay import` |
| `udp` | 安全组或防火墙没放行 UDP。**中继仍可用**，只是手机和 Mac 没法打洞直连 |

`tcp` 和 `auth` 都通时调用成功（`ok: true`）；否则回 `relay_unreachable`（退出码 5），
原因在 `message` 和 `relay.check.problems` 里。按原因修好（多半是让用户去放行安全组），
**再测一次**，直到 `tcp` 和 `auth` 都通。`udp` 不通要告诉用户影响，但不必卡住。

注意这是**从这台 Mac** 测的。Mac 上开着代理 / VPN 的增强模式时，结果可能和手机走蜂窝
不一样。

### 7. 收尾

告诉用户在 uTerm **设置 › 远程控制 › 公网接入** 打开「允许经公网接入」，并在下方逐台
勾选允许的手机。同一 Apple ID 的手机会经 iCloud 钥匙串自动拿到中继配置；其他手机在
设置里点「分享到我的设备…」或扫二维码。

## 更新

中继有新版本时 uTerm 会提醒用户，设置页里也能一键更新。用户让你更新时：

```sh
"$UTERMCTL" run -H <主机> --timeout 180 -c \
  'curl -fsSL https://downloads.example.com/uTerm/relay/install.sh | sh -s -- update'
```

（非 root 同样加 `sudo`，要密码就走 `terminal open`。）输出 `previous=` / `version=` /
`updated=yes|no`。新版本起不来时脚本会**自动换回旧版本**并报错。更新会重启中继，
正在经中继的连接会断几秒。完了跑一次 `relay check`，确认 `serverVersion` 是新版本。

不知道装在哪台主机：`relay check` 的 `relay.managedHost` 就是导入时记下的那台。

只读看状态：`… | sh -s -- status`（输出安装版本、最新版本、服务状态、端口）。

## 错误码

| code | 含义 |
|---|---|
| `relay_exists` | `relay import`：已经导入了另一台中继，用户确认后加 `--replace` |
| `relay_config_invalid` | `relay import`：读到的文件不是中继的设备配置 |
| `relay_not_configured` | `relay check`：还没导入中继 |
| `relay_unreachable` | `relay check`：TCP 或认证没通，逐项结果在 `relay.check` |
