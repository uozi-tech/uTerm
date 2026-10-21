---
name: uterm-run
description: 通过 uTerm（没开时客户端会按需在后台启动它）使用用户已保存的 SSH 主机执行命令（列主机、单机 run、多机并行 run-many、跑快捷命令、按指纹信任主机密钥），也能一问一答地驱动交互式命令（sudo 要密码、[Y/n] 确认、安装向导、REPL —— 密码由用户在 uTerm 弹出的安全输入框里自己输）。当需要在远程服务器上执行 shell 命令、查看服务状态或排查线上问题，而手头没有主机地址、密码或私钥时使用。
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
  for p in "$HOME"/.{claude,codex,cursor,codebuddy}/skills/uterm-run/bin/utermctl; do
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

**uTerm 没在运行不是停手的理由：客户端会自己把它起起来。** 找不到 socket（或 socket
残留）时，`utermctl` 先静默启动一个无窗口的后台实例、等接口就绪，再发你的请求 —— 你
什么都不用做，直接发命令即可，不必先让用户去打开 uTerm。前提是用户在 **uTerm 设置 ▸
命令行与技能** 里打开了「允许 CLI 按需启动」（默认关闭）。后台实例里 `run`、SFTP、端口
转发照常可用，只有 `terminal-read/send` 需要已经开着的终端窗口。

三种常见失败：

- `uterm_not_running`：客户端试过按需启动、没起来，**原因写在 `message` 里**，照着说：
  - 「没有允许 CLI 按需启动」/「拒绝了按需启动」：告诉用户两条路任选 —— 手动打开
    uTerm；或者去 **设置 ▸ 命令行与技能** 打开「允许 CLI 按需启动」，以后 uTerm 没开
    也能直接用。这个开关是用户的显式授权：**不要**自己 `open -a uTerm`、改 `defaults`
    去绕，也不要绕过 uTerm 直接 `ssh`。
  - 「无法唤起」：多半没装，或 app 不在 `/Applications`。
- `uterm_socket_stale`：socket 文件还在但没人监听 —— uTerm 刚被强制退出或正在重启。
  `message` 末尾带「按需启动没成功：…」就按上一条处理；没带就**等几秒重试一次**，别
  当成「没装」去绕路。
- `control_disabled`：uTerm 在跑但命令行接口是关的。让用户去 **uTerm 设置 ▸ 命令行与
  技能**，打开「启用命令行接口」。这个开关默认关闭，是用户的显式授权，不能绕。

`ping` 的响应里还有两条有用的信息：`app.mutationsEnabled` 说明第二个开关开没开
（没开的话 `run` 会被拒），`app.openHosts` 是命令行连接池当前持有的主机 —— 不在这个
列表里的主机，第一条命令要现建连接（可能还要走跳板机），慢几秒是正常的。

## 两个开关

| 开关 | 管什么 | 关着时的错误码 |
|---|---|---|
| 启用命令行接口 | 除 `ping` 外的一切 | `control_disabled` |
| 允许执行命令与写入 | `run` / `run-many` / `quick-run` / `trust` / SFTP 写 / 转发启停 / 终端注入 / 交互会话的 `session start` 与 `session send` | `mutations_disabled` |

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
- 输出默认最多 200 行 / 16000 字节，`--max-lines` / `--max-bytes` 可放宽，
  字节数封顶 1 MiB。被削过时 `truncated: true`。要看大量输出，正确做法是在远端就
  过滤（`grep` / `tail -n` / `awk`），而不是把上限调到最大再本地筛。
- **`run` 没有 stdin**：要输入的命令（`sudo` 要密码、`apt` 问 `[Y/n]`、`read`、安装向导、
  `mysql` / `python` 这类 REPL）在 `run` 里只会干等到静默超时。这类命令改用下面的
  **交互会话**（`session`）。
- **不要用 `run` 跑长驻命令**：`tail -f`、`watch` 永远不结束，只会把请求耗到总时长上限。
  要盯一段时间的输出，用交互会话开着它、隔一会儿 `session read` 一次，看够了 `session close`。

## 交互命令：sudo 密码、确认提示、安装向导

`run` 一次性跑完、没有 stdin，碰上要输入的命令只能卡到超时。**交互会话**在主机上开一条
后台 PTY（真终端），你写一点、读一点，像 expect 一样往下推：

| 动作 | 干什么 |
|---|---|
| `session start -H <主机> [-- 命令]` | 开会话。给命令就在 PTY 里跑它（结束即会话结束，带退出码）；不给就是登录 shell |
| `session send -s <id> …` | 写文本 / 按键；`--secret` 让**用户**输密码 |
| `session read -s <id>` | 读自上次以来的新输出 |
| `session close -s <id>` | 关掉（远端进程随 PTY 挂断收到 SIGHUP） |
| `sessions` | 列出开着的会话 |

**先想能不能不交互**：`apt-get -y`、`DEBIAN_FRONTEND=noninteractive`、`yes |`、`--yes` /
`--force` 之类的开关能用就用，`run` 有退出码、有完整输出，比会话省事。`sudo -n …` 在需要
密码时立刻失败而不是卡住，可以先用它探一下要不要密码。真绕不开才开会话。

### 典型流程

```sh
# 1. 开会话跑命令。默认最多等 10 秒，输出静下来就返回
"$UTERMCTL" session start -H mac-01 -- sudo /usr/local/libexec/telemetry-vphone/root-entry version
#    → session.id = "1A2B3C4D-…"，session.output = "[sudo] password for alice: "
#      session.passwordPrompt = true

# 2. 远端在要密码：让用户自己输（uTerm 弹安全输入框，内容直接写进 PTY 并回车）
"$UTERMCTL" session send -s 1A2B3C4D --secret --prompt "mac-01 的 sudo 密码：更新 telemetry-vphone 到 1.3.0"

# 3. 等结果：--wait 放宽，--wait-for 等某段文字出现（正则）
"$UTERMCTL" session read -s 1A2B3C4D --wait 120 --wait-for '^1\.3\.0$'
#    → session.running = false，session.exitCode = 0

# 4. 跑完的会话会自己结束；登录 shell 或中途放弃的，用完关掉
"$UTERMCTL" session close -s 1A2B3C4D
```

`-s` 收完整 id 或唯一前缀（`1A2B3C4D` 就够）。几台机器各开一个会话，可以交替推进。

### 读响应

响应里的 `session` 对象：

- `output`：**自上次以来的新输出**，已去掉颜色和光标控制、按 `\r` 覆盖收成纯文本（进度条只留
  最后一帧）。是流不是快照 —— 读过就不会再给第二次，自己记住要的东西。一次超过 64 KB 只给
  最后一段（`truncated: true`）；两次读取之间输出超过 1 MiB，最早的被挤掉（`droppedBytes`）。
- `running` / `exitCode` / `endReason`：`endReason` 是 `exited`（进程自己结束）、`closed`、
  `failed`（连接断了）、`idle_timeout`、`max_duration`。会话结束后照样能读到最后的输出，
  10 分钟后从列表里删掉。
- `promptLine`：光标所在那一行，通常就是提示符（`[sudo] password for alice:`、`[Y/n]`、`$`）。
- `awaitingInput: true`：输出静下来了、光标停在一行中间 —— 多半在等输入，看 `promptLine`。
- `passwordPrompt: true`：`promptLine` 像密码提示。**此时只能用 `--secret`。**
- `matched`：给了 `--wait-for` 时等没等到。
- `screen`（加 `--screen` 才有）：虚拟终端此刻的画面。`top`、`htop`、带对话框的安装向导
  这类全屏程序靠重绘屏幕说话，`output` 里是碎片，看 `screen`。

`message` 会写下一步该怎么做（要密码时会直接告诉你用 `--secret`）。

### 发输入

```sh
"$UTERMCTL" session send -s 1A2B y --enter          # 文本原样写入，--enter 才回车
"$UTERMCTL" session send -s 1A2B -k down -k enter   # 按键，可重复，按顺序
"$UTERMCTL" session send -s 1A2B -k ctrl-c          # 中断当前这一步
"$UTERMCTL" session send -s 1A2B --enter -- -y      # 以 - 开头的文本放在 -- 后面（选项写在 -- 前）
```

按键名：`enter` `tab` `esc` `backspace` `space` `delete` `up` `down` `left` `right` `home` `end`
`pageup` `pagedown`、`ctrl-a` … `ctrl-z`（`ctrl-d` 结束输入）。

`send` 之后同样会等：默认最多 10 秒，等**这次输入引出的**输出静下来（0.8 秒没新输出）就返回；
`--wait 0` 发完立刻返回，`--wait-for` 等某段文字，封顶 600 秒。命令跑得久就多 `read` 几次，
每次 `--wait` 给到几十秒，别空转。

### 密码：只能用户自己输

`--secret` 不带文本：uTerm 在用户屏幕上弹一个安全输入框，写明是哪台主机、远端此刻的提示行
（取自真实输出，不是你写的）和你给的 `--prompt` 说明。用户输完，内容直接写进 PTY 并回车，
**响应里没有，之后的输出 / 画面里万一出现也会被打码**。

硬约束：

- 看到 `passwordPrompt: true`（或提示行明显在要密码 / 口令 / PIN）一律 `--secret`。**绝不**让
  用户把密码发到对话里，**绝不**把密码写进 `send` 的文本或命令行（`echo pw | sudo -S`），
  也不要自己猜。
- `--prompt` 写清楚为什么要输、输的是什么（「mac-01 的 sudo 密码：更新 telemetry-vphone」）。
  用户看不懂就会点取消。
- 用户点了取消或 5 分钟没输：`secret_cancelled`（退出码 3）。这是用户的决定，**不要**马上
  再弹一次；问用户要不要继续，或者 `-k ctrl-c` 中断这一步、`session close` 收尾。
- 密码输错时远端会再问一次（`Sorry, try again.`），照样 `--secret`；连续失败就停下来问用户。
- 弹窗会出现在用户屏幕上，所以 `--secret` 之前先在对话里说一句「要在 mac-01 上输 sudo 密码，
  uTerm 会弹窗」。

### 登录 shell 会话

`session start -H host` 不给命令就是登录 shell（带 motd 和提示符），适合多步操作：`su` 之后
连着跑几条、进 `mysql` / `psql` / `python` REPL、`ssh` 到内网另一台再操作。每条命令用
`send … --enter` 发，`--wait-for` 等提示符回来。用完必须 `session close`。

### 约束与回收

- 会话**不在任何窗口里，用户看不见**。要让用户看着跑，用 `uterm-terminal` 开窗口。
- 上限：总共 16 个、每台主机 4 个（`session_limit`）。用完就关，别攒着。
- 30 分钟没有任何 `session` 调用碰过的自动关闭（`idle_timeout`），单个会话最长 6 小时。
- `session close` / 自动回收都会让远端进程收到 SIGHUP；`sudo` 起的 root 进程同样收得到。
  不想被一起带走的长任务，在会话里用 `setsid nohup … &` 或 `systemd-run` 丢出去。
- `sftpOnly` 的主机开不了会话；`disconnect -H` 会关掉那台的全部会话。
- 破坏性命令照样**先问用户**，会话不改变这条规矩。

### 给人用的 `run -t`

用户自己在终端里想交互地跑一条命令（看着进度、自己输密码、开 `top` / `vim`），可以给他这一条：

```sh
utermctl run -t -H mac-01 -- sudo ./bootstrap.zsh --only-root-entry
utermctl run -t -H mac-01        # 不给命令 = 登录 shell，像 ssh 一样
```

它把本终端直通到远端 PTY（Ctrl-C、窗口缩放都照常），退出码就是远端的退出码。**你自己不能
用它**：没有终端时客户端直接拒绝（退出码 2），提示改用 `session`。

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
| `uterm_not_running` | 找不到 socket，且按需启动没成功（原因在 `message`：开关没开 / 没装） |
| `uterm_socket_stale` | socket 残留、无人监听 —— `message` 带「按需启动没成功」就照它说的办，否则稍后重试 |
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
| `command_timeout` | 静默超时或撞上总时长上限（看 `timeoutReason`）；`killed: false` 时**命令可能还在远端继续跑** |
| `run_partial_failure` | `run-many` / `quick-run`：有成有败，逐台看 `results` |
| `run_failed` | `run-many` / `quick-run`：一台都没成 |
| `file_not_found` / `file_exists` / `file_too_large` / `permission_denied` / `is_directory` | 文件面，见 `uterm-files` |
| `server_busy` | uTerm 的连接槽位满了。短请求（`run` / `ping` 等）有 8 个专用槽位、传输另有 8 个，互不挤占；撞上多半是同时跑了太多 utermctl —— 客户端已退避重试过，仍不行就等一会儿 |
| `local_read_failed` / `local_write_failed` | 客户端自己的本地文件 I/O 失败（只出现在 `sftp get` / `put`），见 `uterm-files` |
| `rule_not_found` / `rule_ambiguous` / `port_in_use` / `forward_failed` | 转发面，见 `uterm-forward` |
| `terminal_not_found` / `terminal_ambiguous` / `terminal_disconnected` | 终端面，见 `uterm-terminal` |
| `session_not_found` / `session_ambiguous` | 交互会话没有这个 id / 前缀有歧义（结束 10 分钟后会被清掉）—— `sessions` 重新看 |
| `session_limit` | 交互会话开满了（总共 16、每台 4），先 `session close` 不用的 |
| `session_ended` | 会话已经结束，写不进去了；响应里带最后的输出与 `endReason` |
| `secret_cancelled` | 用户在安全输入框里点了取消 / 没输 —— 不要马上重弹，问用户 |
| `handler_timeout` | uTerm 侧的请求连续 120 秒**没有任何进展**（传输没有回包、命令看门狗也停了）才会出现，多半是网络断了或 uTerm 卡住 |
| `client_timeout` | 客户端连续 60 秒没收到 uTerm 任何字节（处理中每 10 秒一次的心跳也没有）—— uTerm 本身卡住了；请求可能已部分执行 |
| `invalid_request` | 缺字段 / 字段冲突 |
| `not_implemented` | 这个动作在当前 uTerm 版本里还没实现 |

客户端的退出码：`0` 成功，`2` 连不上 uTerm（含服务端槽位满的 `server_busy`）、客户端
自己的前置检查没过或本地文件 I/O 失败，`3` 门禁（含用户取消输入的 `secret_cancelled`），
`4` 找不到 / 有歧义，`5` 建连 / 认证 / 主机密钥 / 转发失败（含 `run_failed` 的全军覆没），
`6` 超时，`7` 多主机部分失败（`run_partial_failure`），`1` 其它。
