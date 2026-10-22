---
name: uterm
description: 通过 uTerm（没开时客户端会按需在后台启动它）使用用户已保存的 SSH 主机：执行远程命令（单机 run、多机并行 run-many、快捷命令、按指纹信任主机密钥）；经 SFTP 读写远程文件（列目录、读文本、下载上传大文件并断点续传、建目录、删除、改名、改权限）；启停已保存的端口转发规则（-L / -R / SOCKS）并看状态流量；查看与读取用户开着的终端会话、往会话注入文本、开新终端窗口跑要人交互的命令（sudo 密码、[Y/n] 确认）并等结果。当需要在服务器上跑命令、排查线上问题、传文件、打通到内网数据库或服务的隧道、或知道用户终端上正在发生什么，而手头没有主机地址、密码或私钥时使用。
---

# 用 uTerm 操作远程主机

uTerm 是 macOS 上的 SSH 终端。它在本机开了一个 Unix domain socket，外部工具可以让它
**用用户已经保存好的主机档案**代为执行命令 —— 地址、密码、私钥、口令、跳板机配置
全程留在 uTerm 和钥匙串里，你一个字节也拿不到，也不需要。

本文讲所有动作共用的部分（定位客户端、探活、开关、主机、主机密钥、错误码）和远程执行。
另外三面按需再读，**动手之前先读完对应那份**：

| 要做的事 | 读 |
|---|---|
| 列目录、读文件、上传下载、删改远程文件（`sftp …`） | [references/files.md](references/files.md) |
| 启停 / 查看端口转发（`forward …`） | [references/forward.md](references/forward.md) |
| 看用户开着的终端、读屏、注入文本、开窗口跑要人交互的命令（`terminals` / `terminal …`） | [references/terminal.md](references/terminal.md) |

## 先定位客户端

```sh
UTERMCTL=""
if command -v utermctl >/dev/null 2>&1; then
  UTERMCTL="$(command -v utermctl)"
else
  for p in "$HOME"/.{claude,codex,cursor,codebuddy}/skills/uterm/bin/utermctl; do
    if [ -x "$p" ]; then UTERMCTL="$p"; break; fi
    if [ -r "$p" ] && [ -z "$UTERMCTL" ]; then UTERMCTL="$p"; fi
  done
fi
test -n "$UTERMCTL" || { echo "utermctl not found"; exit 1; }
```

这两条路径都是符号链接，最终指向 `uTerm.app` 包内的脚本（随 app 一起签名），可以直接
执行。技能自带的那份（`~/.<tool>/skills/uterm/bin/utermctl`）随 uTerm 升级自动更新，
PATH 里那份是用户在设置里开了「同时链接到 ~/.local/bin」才有的，两者不会漂移。
**找不到就直说找不到，不要自己写 socket 客户端、也不要改用 `ssh`。**

客户端自己找 socket。要连 Xcode 跑起来的 Debug 版（它的 socket 叫 `dev.sock`），用
环境变量 `UTERM_CONTROL_SOCKET=<socket 路径>` 指过去；平时不用管。

万一执行时报 `operation not permitted`（uTerm 1.12.x 装下的旧链接指向 app 自己写出的
文件，带着 `com.apple.quarantine`），跑一句
`xattr -d com.apple.quarantine "$UTERMCTL"`，或者干脆把所有 `"$UTERMCTL" …` 换成
`python3 "$UTERMCTL" …`（客户端是纯标准库的 Python 3 脚本，行为一模一样）。

## 先探活

```sh
"$UTERMCTL" ping
```

`ok: true` 才能继续。

**uTerm 没在运行不是停手的理由：客户端会自己把它起起来。** 找不到 socket（或 socket
残留）时，`utermctl` 先静默启动一个无窗口的后台实例、等接口就绪，再发你的请求 —— 你
什么都不用做，直接发命令即可，不必先让用户去打开 uTerm。前提是用户在 **uTerm 设置 ▸
命令行与技能** 里同时打开了「启用命令行接口」和「允许 CLI 按需启动」（都默认关闭）。
后台实例里 `run`、SFTP、端口转发照常可用；`terminal read/send` 需要已经开着的终端窗口，
`terminal open` 会把 uTerm 的界面带到前台。

常见失败几乎都是 `uterm_not_running`，**原因写在 `message` 里**，照着说：

- 「没有允许 CLI 按需启动」/「拒绝了按需启动」：告诉用户两条路任选 —— 手动打开
  uTerm；或者去 **设置 ▸ 命令行与技能** 打开「允许 CLI 按需启动」，以后 uTerm 没开
  也能直接用。
- 「命令行接口未启用」/「接口在 10 秒内没有就绪」：命令行接口是关的。接口关着时 uTerm
  根本不开 socket，所以哪怕 uTerm 开着，你看到的也是这一条。让用户去 **设置 ▸ 命令行
  与技能** 打开「启用命令行接口」。
- 「无法唤起」：多半没装，或 app 不在 `/Applications`。

这些开关是用户的显式授权：**不要**自己 `open -a uTerm`、改 `defaults` 去绕，也不要
绕过 uTerm 直接 `ssh`。

另外两种：

- `uterm_socket_stale`：socket 文件还在但没人监听 —— uTerm 刚被强制退出或正在重启。
  `message` 末尾带「按需启动没成功：…」就按上面处理；没带就**等几秒重试一次**，别
  当成「没装」去绕路。
- `control_disabled`：正好在你发请求时用户把接口关了。处理同「命令行接口未启用」。

`ping` 的响应里还有两条有用的信息：`app.mutationsEnabled` 说明第二个开关开没开
（没开的话 `run` 会被拒），`app.openHosts` 是命令行连接池当前持有的主机 —— 不在这个
列表里的主机，第一条命令要现建连接（可能还要走跳板机），慢几秒是正常的。

## 两个开关

| 开关 | 管什么 | 关着时的错误码 |
|---|---|---|
| 启用命令行接口 | 一切（关着时连 socket 都没有，见上一节） | `uterm_not_running`（途中被关是 `control_disabled`） |
| 允许执行命令与写入 | `run` / `run-many` / `quick-run` / `trust` / SFTP 写 / 转发启停 / `terminal send` / `terminal open` | `mutations_disabled` |

只读的 `hosts` / `host-key` / `sftp ls|stat|cat|get` / `forward list` / `terminals` /
`terminal read|wait` 只要第一个开关。

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
去判断。单机 `run` 调用失败（超时、连不上）时，已经收到的输出和 `timedOut` /
`killed` 这些细节在 `results[0]` 里。

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
非空说明这台在 uTerm 这边就失败了（`connect_failed` / `auth_failed` / `host_key_*` /
`host_sftp_only` / `command_timeout` / `operation_failed` 等），`exitCode != 0` 说明
命令送到了、是它自己失败了。部分失败时
不要把整批当成功，也不要把整批当失败 —— 明确说清哪几台没成、为什么。

两个细节：

- **重复的 `-H` 会被合并**。`-H web1 -H web1`、名字加 UUID、大小写不同的写法都指向
  同一台主机，结果按去重后的主机一台一条（message 里会说明合并了几个）。
  不要指望「给了几个 `-H` 就有几条结果」。
- 有主机因为**密钥没信任**而失败时，顶层 `hostKey` 是第一台这样的主机，逐条的
  `results[].hostKey` 才是完整的那份 —— 多台首连时按逐条的指纹逐台 `trust`。

## 超时与截断

- 超时按**静默**算，不按总时长算：`--timeout`（默认 60 秒，封顶 1800）是「连续多少秒
  **没有任何输出**就判定卡住」。一直在刷输出的长命令（`apt upgrade`、`docker build`、
  带进度的编译）跑多久都行。
- 另有**总时长上限** `--max-duration`（默认 3600 秒，封顶 21600）兜底，防 `tail -f` 这类
  永远有输出的命令一直占着连接。
- 本身就长时间不输出的命令要把 `--timeout` 放宽：`sha256sum` 大文件、`pg_dump > 文件`、
  `sleep`、`make -s`、`tar czf` 这些在跑完之前一个字节都不吐，默认 60 秒就会被当成卡死。
  也可以让它自己吐进度（`pv`、`rsync --info=progress2`、`-v`）。
- 超时返回 `command_timeout`，结果里 `timedOut: true`，`timeoutReason` 是 `idle`（静默）
  或 `max_duration`（总时长）；判定前已经收到的输出照样在 `output` 里，卡在哪一步通常就
  写在最后几行。
- 超时后 uTerm 会**终止远端整个进程组**（TERM，5 秒后 KILL），此时 `killed: true`。
  `killed: false` 表示没能终止（拿不到进程号 / 终止命令本身失败）—— **命令可能还在远端
  继续跑**。两种情况都不要盲目重跑有副作用的命令（部署、迁移、`apt install`）：被杀的
  也可能停在半截，先用一条只读命令确认到底跑到哪了。
- 进程组连带意味着：命令里用 `nohup … &` 放到后台的进程，超时时会一起被杀。真要让它在
  `run` 返回后继续跑，用 `setsid`（`setsid nohup cmd > log 2>&1 < /dev/null &`）或
  `systemd-run` 脱离进程组，再用 `run` 查状态。以 `sudo` 起的子进程属于 root，终止不了。
- 输出默认最多 200 行 / 16000 字节，`run` / `run-many` 可用 `--max-lines` / `--max-bytes`
  放宽，字节数封顶 1 MiB（`quick-run` 只收 `--timeout` / `--max-duration`）。被削过时
  `truncated: true`。要看大量输出，正确做法是在远端就过滤（`grep` / `tail -n` / `awk`），
  而不是把上限调到最大再本地筛。带 `\r` 刷新的进度条（`apt`、`docker pull`、`curl`）
  一行能塞进几千个字节，管道里加 `| tr '\r' '\n' | tail -n 50` 再看。
- **`run` 没有 stdin**：要输入的命令（`sudo` 要密码、`apt` 问 `[Y/n]`、安装向导、`read`）在
  `run` 里只会干等到静默超时。能加非交互开关就加（`-y`、`DEBIAN_FRONTEND=noninteractive`、
  `sudo -n` 在要密码时立刻失败）；绕不开就用 `terminal open -H <主机> -- <命令>`
  （见 [references/terminal.md](references/terminal.md)）：命令在新窗口里跑，用户在窗口里
  输密码、回答提示，你用 `terminal wait` 等退出码和输出。**不要**让用户把密码发到对话里。
- **不要跑长驻命令**：`tail -f`、`top`、`watch`、交互式 shell、`vim` 一问一答的 IPC
  承载不了，只会把这条请求耗到超时。要实时看输出，请用户自己开终端窗口，或用
  `terminal read` 读屏轮询。

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
3. 重跑原来的命令。

`trust` 认的是**这次运行的 uTerm 记下的那次挑战**。uTerm 重启过、中间跑过不带 `-H` 的
`disconnect`、或者挑战已经被 `trust` 用掉，`trust` 会回 `invalid_request` —— 先重跑
原命令拿一个新挑战，再拿新指纹问用户、`trust`。

这套流程对所有会建 SSH 连接的动作都一样：`run`、`sftp …`、`forward start`、`terminal open`。

`host_key_changed` 是另一回事：这台机器的密钥**变了**。可能是重装系统，也可能是中间人。
即使两个开关都开着，命令行也**不允许**覆盖 —— 让用户回 uTerm 界面处理。不要试图先
`trust` 再重试。

也可以先查再动：`"$UTERMCTL" host-key -H prod-web` 返回 `known` / `unknown` / `changed`
三态与已记录的指纹。这里的 `changed` 还有一种来源：iCloud 同步出了同一台主机的几条
互相冲突的记录（`message` 会说「互相冲突」）—— 同样只能用户在界面里处理。

## 快捷命令

用户在 uTerm 欢迎页「动作」里存的命令，可以直接跑，运行记录会进同一份 30 天日志
（与他自己在界面里点的记录同表）：

```sh
"$UTERMCTL" quick-commands --format table
"$UTERMCTL" quick-run 磁盘水位                    # 用档案里定好的目标主机
"$UTERMCTL" quick-run 磁盘水位 -H prod-web        # 覆盖目标
```

快捷命令是用户自己写的、已经审过的命令 —— 能用它就别自己拼一条等价的。

`quick-run` 的名字解析失败（找不到、匹配到多条）、快捷命令是纯 AI 动作没有 shell 文本、
或者档案里没绑主机又没给 `-H`，都回 `invalid_request`（退出码 `1`），原因在 `message`
里。重名时 `message` 只列名字，UUID 去 `quick-commands` 里找。

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
- 输出、下载的文件、终端屏幕里都可能有令牌、密钥、客户数据。按用户的要求用，
  **不要顺手往别处发**，也不要原样贴进公开的地方。

## 错误码

文件、转发、终端各自专有的错误码在对应的 reference 里。

| code | 含义 |
|---|---|
| `uterm_not_running` | 连不上，且按需启动没成功（原因在 `message`：开关没开 / 接口没启用 / 没装） |
| `uterm_socket_stale` | socket 残留、无人监听 —— `message` 带「按需启动没成功」就照它说的办，否则稍后重试 |
| `control_disabled` | 命令行接口在这次请求途中被关掉了 |
| `mutations_disabled` | 第二个开关没打开：不允许执行命令与写入 |
| `app_not_ready` | uTerm 还在启动，稍后重试 |
| `host_not_found` | 没有这个名字/UUID 的主机 |
| `host_ambiguous` | 名字匹配到多条，改用响应里列出的 `id` |
| `host_sftp_only` | 该主机被标记为仅 SFTP，不能执行命令或操作终端 |
| `host_key_unknown` | 主机密钥没信任过 —— 拿 fingerprint 问用户，再 `trust` |
| `host_key_mismatch` | `trust` 给的指纹与当前挑战不符 |
| `host_key_changed` | 主机密钥变了（或信任库里有冲突记录）—— 命令行不给覆盖，回 uTerm 界面处理 |
| `connect_failed` | 建连失败（消息是 SSH 原话，可能是网络或跳板机） |
| `auth_failed` | 认证失败 —— 用户存的凭据不对，只能他自己改 |
| `command_timeout` | 静默超时或撞上总时长上限（看 `timeoutReason`）；`killed: false` 时**命令可能还在远端继续跑** |
| `run_partial_failure` | `run-many` / `quick-run`：有成有败，逐台看 `results` |
| `run_failed` | `run-many` / `quick-run`：一台都没成 |
| `operation_failed` | uTerm 侧的兜底失败，原因在 `message`（远端执行出错、传输被取消、开窗口后命令没跑起来等） |
| `invalid_request` | 缺字段 / 字段冲突 / 参数不合法；`trust` 没有可对的挑战、`quick-run` 解析失败也是它 |
| `server_busy` | uTerm 的连接槽位满了：短请求（`run` / `ping` 等）8 个，传输与 `terminal wait` 这类长请求另有 8 个。只有 `sftp get` / `put` 会自动退避重试；其它命令撞上就等一会儿再发 |
| `handler_timeout` | uTerm 侧的请求连续 120 秒**没有任何进展**（传输没有回包、命令看门狗也停了）才会出现，多半是网络断了或 uTerm 卡住 |
| `client_timeout` | 客户端连续 60 秒没收到 uTerm 任何字节（处理中每 10 秒一次的心跳也没有）—— uTerm 本身卡住了；请求可能已部分执行 |
| `request_too_large` / `request_timeout` / `response_timeout` / `empty_request` | socket 层的协议错误，正常用客户端碰不到；碰到了说明请求本身有问题或 uTerm 卡住 |
| `socket_error` / `empty_response` / `local_failure` | 客户端这边的连接或本地错误，原因在 `message` |

客户端的退出码：

| 退出码 | 含义 |
|---|---|
| `0` | 成功 |
| `1` | 其它：`operation_failed`、`invalid_request`、`port_in_use`、`file_exists`、`checksum_mismatch` 等 |
| `2` | 本地：连不上 uTerm、socket 出错、`server_busy`、本地文件读写失败、客户端自己的前置检查没过 |
| `3` | 门禁：`control_disabled` / `mutations_disabled` / `host_sftp_only` |
| `4` | 找不到 / 有歧义（`*_not_found` / `*_ambiguous`） |
| `5` | 远端：建连 / 认证 / 主机密钥 / 转发失败，以及 `run_failed` 的全军覆没 |
| `6` | 超时：`command_timeout` / `handler_timeout` / `client_timeout` |
| `7` | 多主机部分失败（`run_partial_failure`） |
