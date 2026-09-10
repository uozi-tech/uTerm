---
name: uterm-run
description: 通过正在运行的 uTerm 使用用户已保存的 SSH 主机执行命令（列主机、单机 run、多机并行 run-many、跑快捷命令、按指纹信任主机密钥）。当需要在远程服务器上执行 shell 命令、查看服务状态或排查线上问题，而手头没有主机地址、密码或私钥时使用。
---

# 用 uTerm 执行远程命令

uTerm 是 macOS 上的 SSH 终端。它在本机开了一个 Unix domain socket，外部工具可以让它
**用用户已经保存好的主机档案**代为执行命令 —— 地址、密码、私钥、口令、跳板机配置
全程留在 uTerm 和钥匙串里，你一个字节也拿不到，也不需要。

文件传输见 `uterm-files`，端口转发见 `uterm-forward`，终端会话见 `uterm-terminal`。
**那三份都靠这一份定位客户端**，下面「先定位客户端」「先探活」「主机怎么指定」
「主机密钥」「错误码」几节是四份技能共用的。

## 先定位客户端

```sh
UTERMCTL=""
if command -v utermctl >/dev/null 2>&1; then
  UTERMCTL="$(command -v utermctl)"
else
  for p in "$HOME"/.{claude,codex,cursor}/skills/uterm-run/bin/utermctl; do
    if [ -x "$p" ]; then UTERMCTL="$p"; break; fi
    if [ -r "$p" ] && [ -z "$UTERMCTL" ]; then UTERMCTL="$p"; fi
  done
fi
test -n "$UTERMCTL" || { echo "utermctl not found"; exit 1; }
```

这两条路径都是符号链接，最终指向 `uTerm.app` 包内的脚本（随 app 一起签名），可以直接
执行。技能自带的那份（`~/.<tool>/skills/uterm-run/bin/utermctl`）随 uTerm 升级自动更新，
PATH 里那份是用户在设置里开了「同时链接到 ~/.local/bin」才有的，两者不会漂移。
**找不到就直说找不到，不要自己写 socket 客户端、也不要改用 `ssh`。**

万一执行时报 `operation not permitted`（uTerm 1.12.x 装下的旧链接指向 app 自己写出的
文件，带着 `com.apple.quarantine`），跑一句
`xattr -d com.apple.quarantine "$UTERMCTL"`，或者干脆把所有 `"$UTERMCTL" …` 换成
`python3 "$UTERMCTL" …`（客户端是纯标准库的 Python 3 脚本，行为一模一样）。

## 先探活

```sh
"$UTERMCTL" ping
```

`ok: true` 才能继续。

三种常见失败：

- `uterm_not_running`：uTerm 没开，或用户没装。**不要**试图自己起 app，也不要绕过它
  直接 `ssh`，直接告诉用户打开 uTerm。
- `uterm_socket_stale`：socket 文件还在但没人监听 —— uTerm 刚被强制退出或正在重启。
  **等几秒重试一次**，别当成「没装」去绕路。
- `control_disabled`：uTerm 在跑但命令行接口是关的。让用户去 **uTerm 设置 ▸ 命令行与
  技能**，打开「启用命令行接口」。这个开关默认关闭，是用户的显式授权，不能绕。

`ping` 的响应里还有两条有用的信息：`app.mutationsEnabled` 说明第二个开关开没开
（没开的话 `run` 会被拒），`app.openHosts` 是命令行连接池当前持有的主机 —— 不在这个
列表里的主机，第一条命令要现建连接（可能还要走跳板机），慢几秒是正常的。

## 两个开关

| 开关 | 管什么 | 关着时的错误码 |
|---|---|---|
| 启用命令行接口 | 除 `ping` 外的一切 | `control_disabled` |
| 允许执行命令与写入 | `run` / `run-many` / `quick-run` / `trust` / SFTP 写 / 转发启停 / 终端注入 | `mutations_disabled` |

`run` **有意**归在第二个开关下：shell 命令无法可靠地分成读和写（`cat` 能读密钥、
`awk` 能写文件），假的「只读模式」比没有更糟。所以哪怕只是想看看磁盘水位，也需要
用户把第二个开关打开。碰到 `mutations_disabled` 就直说，不要试图用别的动作绕过去。

## 主机怎么指定

`-H/--host` 收主机档案的**名字**或 **UUID**。先列出来照抄，别猜：

```sh
"$UTERMCTL" hosts --format table
```

名字按「精确 → 忽略大小写 → 唯一前缀」解析。**用户的主机可能通过 iCloud 在多台设备
间同步，重名是常态** —— 匹配到多条会返回 `host_ambiguous` 并把候选（带 `id`）列出来，
这时改用 UUID 重发，不要凭感觉挑一个。

`hosts` 输出里几个字段值得先看一眼：

- `sftpOnly: true` 的主机被用户定性为「只传文件」，`run` / `run-many` / `quick-run` /
  终端注入对它一律返回 `host_sftp_only`。这是用户的定性，不要劝他改，也不要绕。
- `jumpHost` 非空说明要经跳板机，首连更慢。
- `cliConnected: true` 说明命令行这边已经握着连接，下一条命令会快。
- `group` 是用户自己的分组名（如「生产」「测试」），在挑主机时比名字更能说明风险。

## 跑命令

```sh
# 命令写在 -- 之后，原样传，不用自己处理引号
"$UTERMCTL" run -H prod-web -- systemctl status nginx

# 也接受整串
"$UTERMCTL" run -H prod-web -c "df -h | sort -k5 -r | head"

# 多台并行（有界并发 6），逐主机一条结果
"$UTERMCTL" run-many -H prod-web -H prod-db --format table -- uptime
```

`--format` 有 `json`（默认）/ `table` / `csv`。**它必须写在 `--` 之前** —— `--`
之后的一切都被原样当成远程命令的一部分，写在后面就成了 `uptime --format table`，
在远端跑，不是给客户端看的。`table` 会逐主机分段打印输出，给人看；要自己解析就用
`json`。

`--` 之后的 argv 会被 `shlex.join` 拼成**一条命令**，其中每一段都是独立的一个词。
所以 `-- 'uname -a; id'` 是错的：整串被当成**一个程序名**引起来，远端报
`sh: uname -a; id: not found`。要跑带 `;`、管道、重定向的整串，用
`-c '…'`，或者显式 `-- sh -c '…'`。

结果里的字段：`output` 是合并后的 stdout/stderr，`exitCode` 是远端真实退出码
（拿不到时为 `null`），`durationMs` 是耗时。**单机 `run` 的 `exitCode` 非 0 不代表
调用失败** —— 调用本身 `ok: true`，是被调的命令自己返回了非 0，照常读 `output`
去判断。

同理，**`utermctl` 自己的退出码只说明「这次调用有没有送达并执行完」**，不是远端
命令的退出码。`ok: true` + `exitCode: 127` 是完全正常的一次调用（命令送到了，
远端说找不到这个程序）。要判断命令成没成，读 `result.exitCode`；要判断调用成没成，
看顶层 `ok` / `code`。

## run-many / quick-run 怎么读结果

多主机动作**不看顶层 `ok` 就下结论是错的**，要先看顶层 `code`：

| 顶层 | 含义 | 退出码 |
|---|---|---|
| `ok: true` | 每一台都跑完了且 `exitCode == 0` | 0 |
| `run_partial_failure` | 有成有败 | 7 |
| `run_failed` | **一台都没成** | 5 |

不论哪种，`results` 数组都在，**按请求顺序**一台一条。逐条看两件事：`errorCode`
非空说明这台连都没连上（或超时），`exitCode != 0` 说明命令自己失败了。部分失败时
不要把整批当成功，也不要把整批当失败 —— 明确说清哪几台没成、为什么。

两个细节：

- **重复的 `-H` 会被合并**。`-H web1 -H web1`、名字加 UUID、大小写不同的写法都指向
  同一台主机，结果按去重后的主机一台一条（message 里会说明合并了几个）。
  不要指望「给了几个 `-H` 就有几条结果」。
- 有主机因为**密钥没信任**而失败时，顶层 `hostKey` 是第一台这样的主机，逐条的
  `results[].hostKey` 才是完整的那份 —— 多台首连时按逐条的指纹逐台 `trust`。

## 超时与截断

- 默认超时 60 秒，`--timeout` 可调，**封顶 300 秒**。
- 超时返回 `command_timeout`（或结果里 `timedOut: true`）。**语句本身很可能还在远端
  继续跑** —— 底层 SSH 执行不可取消。所以超时后不要盲目重跑有副作用的命令
  （部署、迁移、`apt install`），先用一条只读命令确认上一次到底跑到哪了。
- 输出默认最多 200 行 / 16000 字节，`--max-lines` / `--max-bytes` 可放宽，
  字节数封顶 1 MiB。被削过时 `truncated: true`。要看大量输出，正确做法是在远端就
  过滤（`grep` / `tail -n` / `awk`），而不是把上限调到最大再本地筛。
- **不要跑长驻命令**：`tail -f`、`top`、`watch`、交互式 shell、`vim` 一问一答的 IPC
  承载不了，只会把这条请求耗到超时。要实时看输出，请用户自己开终端窗口，或用
  `uterm-terminal` 的读屏轮询。

## 主机密钥

uTerm **绝不自动 TOFU**。第一次连一台没信任过的主机，`run` 会直接失败：

```json
{"ok": false, "code": "host_key_unknown",
 "message": "主机密钥尚未信任",
 "hostKey": {"host": "prod-web", "algorithm": "ssh-ed25519",
             "fingerprint": "SHA256:…", "status": "unknown"}}
```

正确流程是三步，**中间那步不能省**：

1. 把 `hostKey.fingerprint` 原样给用户看，问他这是不是那台机器的指纹。
2. 用户确认后再钉：
   ```sh
   "$UTERMCTL" trust -H prod-web --fingerprint "SHA256:…"
   ```
   `trust` 只接受与当前挑战**一致**的指纹，你自己编一个不会通过（`host_key_mismatch`）。
3. 重跑 `run`。

`host_key_changed` 是另一回事：这台机器的密钥**变了**。可能是重装系统，也可能是中间人。
即使两个开关都开着，命令行也**不允许**覆盖 —— 让用户回 uTerm 界面处理。不要试图先
`trust` 再重试。

也可以先查再动：`"$UTERMCTL" host-key -H prod-web` 返回 `known` / `unknown` / `changed`
三态与已记录的指纹。

## 快捷命令

用户在 uTerm 欢迎页「动作」里存的命令，可以直接跑，运行记录会进同一份 30 天日志
（与他自己在界面里点的记录同表）：

```sh
"$UTERMCTL" quick-commands --format table
"$UTERMCTL" quick-run 磁盘水位                    # 用档案里定好的目标主机
"$UTERMCTL" quick-run 磁盘水位 -H prod-web        # 覆盖目标
```

快捷命令是用户自己写的、已经审过的命令 —— 能用它就别自己拼一条等价的。

## 释放连接

```sh
"$UTERMCTL" disconnect -H prod-web   # 不给 -H 就全部释放
```

平时不用管：连接池空闲 10 分钟自动关。只有在明确要求「断开」或某台连接卡住需要重建
时才用。

## 硬约束

- **破坏性命令一律先问用户**：`rm -rf`、`reboot` / `shutdown`、`kill -9`、
  `systemctl stop`、`iptables` / 防火墙规则、`dd`、包管理器的安装与卸载、
  改数据库或改配置文件。开关是「允许你执行」，不是「允许你不问」。
- **不要绕过 uTerm**：不要直接 `ssh`、不要去翻 `~/.ssh`、不要读 uTerm 的钥匙串或
  SwiftData 存储、不要试图从任何响应里找密码。协议里根本没有导出凭据的字段，找不到
  是设计如此。
- **不要改用户的主机档案 / 密钥 / 转发规则**。命令行只消费这些定性，增删改要用户在
  界面里做。
- 生产主机上先只读（`systemctl status`、`journalctl -n`、`df -h`、`ps`），确认清楚
  再动。改之前留一手（备份文件、记下原值）。
- 输出里可能有令牌、密钥、客户数据。按用户的要求用，**不要顺手往别处发**，也不要
  原样贴进公开的地方。

## 错误码

| code | 含义 |
|---|---|
| `uterm_not_running` | 找不到 socket —— uTerm 没开 |
| `uterm_socket_stale` | socket 残留、无人监听 —— uTerm 正在重启，稍后重试 |
| `control_disabled` | 主开关没打开（设置 ▸ 命令行与技能） |
| `mutations_disabled` | 第二个开关没打开：不允许执行命令与写入 |
| `host_not_found` | 没有这个名字/UUID 的主机 |
| `host_ambiguous` | 名字匹配到多条，改用响应里列出的 `id` |
| `host_sftp_only` | 该主机被标记为仅 SFTP，不能执行命令或操作终端 |
| `host_key_unknown` | 主机密钥没信任过 —— 拿 fingerprint 问用户，再 `trust` |
| `host_key_mismatch` | `trust` 给的指纹与当前挑战不符 |
| `host_key_changed` | 主机密钥变了 —— 命令行不给覆盖，回 uTerm 界面处理 |
| `connect_failed` | 建连失败（消息是 SSH 原话，可能是网络或跳板机） |
| `auth_failed` | 认证失败 —— 用户存的凭据不对，只能他自己改 |
| `command_timeout` | 超时；**命令可能还在远端继续跑** |
| `run_partial_failure` | `run-many` / `quick-run`：有成有败，逐台看 `results` |
| `run_failed` | `run-many` / `quick-run`：一台都没成 |
| `file_not_found` / `file_exists` / `file_too_large` / `permission_denied` / `is_directory` | 文件面，见 `uterm-files` |
| `rule_not_found` / `rule_ambiguous` / `port_in_use` / `forward_failed` | 转发面，见 `uterm-forward` |
| `terminal_not_found` / `terminal_ambiguous` / `terminal_disconnected` | 终端面，见 `uterm-terminal` |
| `handler_timeout` | uTerm 侧 120 秒兜底超时 |
| `invalid_request` | 缺字段 / 字段冲突 |
| `not_implemented` | 这个动作在当前 uTerm 版本里还没实现 |

客户端的退出码：`0` 成功，`2` 连不上 uTerm 或客户端自己的前置检查没过，`3` 门禁，
`4` 找不到 / 有歧义，`5` 建连 / 认证 / 主机密钥 / 转发失败（含 `run_failed` 的全军覆没），
`6` 超时，`7` 多主机部分失败（`run_partial_failure`），`1` 其它。
