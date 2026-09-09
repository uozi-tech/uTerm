import Foundation

/// 一份可安装技能的静态定义。内容以字符串常量内嵌，安装时物化为 `SKILL.md`，
/// 避免新增 Xcode 资源构建阶段。
///
/// **单一真值源**：这些常量与仓库里的 `skills/<slug>/SKILL.md`、`scripts/utermctl`
/// 逐字一致，`uTermTests/SkillDefinitionTests` 会校验两边没有漂移 —— 改文档请改
/// 仓库文件，再把内容同步进来。
nonisolated struct SkillDefinition: Sendable {
    struct SupportFile: Sendable {
        let relativePath: String
        let content: String
        let isExecutable: Bool

        init(relativePath: String, content: String, isExecutable: Bool) {
            self.relativePath = relativePath
            self.content = content
            self.isExecutable = isExecutable
        }
    }

    let slug: String
    let displayName: String
    let markdownContent: String
    let supportFiles: [SupportFile]

    init(
        slug: String,
        displayName: String,
        markdownContent: String,
        supportFiles: [SupportFile] = []
    ) {
        self.slug = slug
        self.displayName = displayName
        self.markdownContent = markdownContent
        self.supportFiles = supportFiles
    }

    /// 命令执行 —— 唯一带客户端脚本的一份，另外三份靠它定位 `utermctl`。
    static let uTermRun = SkillDefinition(
        slug: "uterm-run",
        displayName: "uTerm 远程命令执行",
        markdownContent: Self.uTermRunMarkdown,
        supportFiles: [
            SupportFile(
                relativePath: "bin/utermctl",
                content: Self.controlClientScript,
                isExecutable: true
            )
        ]
    )

    static let uTermFiles = SkillDefinition(
        slug: "uterm-files",
        displayName: "uTerm 远程文件（SFTP）",
        markdownContent: Self.uTermFilesMarkdown
    )

    static let uTermForward = SkillDefinition(
        slug: "uterm-forward",
        displayName: "uTerm 端口转发",
        markdownContent: Self.uTermForwardMarkdown
    )

    static let uTermTerminal = SkillDefinition(
        slug: "uterm-terminal",
        displayName: "uTerm 终端会话",
        markdownContent: Self.uTermTerminalMarkdown
    )

    /// app 内置的全部 uTerm 技能；安装界面按工具整包装这些技能。
    ///
    /// 顺序即设置页与文档里的呈现顺序：`uterm-run` 打头（它带客户端，另外三份靠它
    /// 定位 `utermctl`），其余按 文件 / 转发 / 终端 排。
    static let catalog: [SkillDefinition] = [
        .uTermRun, .uTermFiles, .uTermForward, .uTermTerminal,
    ]

    // MARK: - 内嵌内容
    //
    // 下面五个常量与仓库里的 `skills/<slug>/SKILL.md`、`scripts/utermctl` **逐字一致**
    // （`SkillDefinitionTests` 逐字比对，比对前会 trim 掉文件末尾换行）。改文档请先改
    // 仓库文件，再把内容整段贴回来 —— 反过来改这里会让两边悄悄漂移。

    /// `skills/uterm-run/SKILL.md` 的逐字副本。
    static let uTermRunMarkdown = #"""
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
if command -v utermctl >/dev/null 2>&1; then
  UTERMCTL="$(command -v utermctl)"
else
  for p in "$HOME"/.{claude,codex,cursor}/skills/uterm-run/bin/utermctl; do
    if [ -x "$p" ]; then UTERMCTL="$p"; break; fi
  done
fi
test -n "$UTERMCTL" || { echo "utermctl not found"; exit 1; }
```

技能自带的那份（`~/.<tool>/skills/uterm-run/bin/utermctl`）随 uTerm 升级自动更新，
PATH 里那份是用户在设置里开了「同时链接到 ~/.local/bin」才有的符号链接，指向同一个
源文件，两者不会漂移。**找不到就直说找不到，不要自己写 socket 客户端、也不要改用
`ssh`。**

## 先探活

```sh
"$UTERMCTL" ping
```

`ok: true` 才能继续。三种常见失败：

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
"$UTERMCTL" run-many -H prod-web -H prod-db -- uptime --format table
```

`--format` 有 `json`（默认）/ `table` / `csv`，写在子命令前后都行。`table` 会逐主机
分段打印输出，给人看；要自己解析就用 `json`。

结果里的字段：`output` 是合并后的 stdout/stderr，`exitCode` 是远端真实退出码
（拿不到时为 `null`），`durationMs` 是耗时。**`exitCode` 非 0 不代表调用失败** ——
调用本身 `ok: true`，是被调的命令自己返回了非 0，照常读 `output` 去判断。

`run-many` 里**单台失败不会让整批失败**：那一条的 `errorCode` / `errorMessage` 单独
写着，其余主机照跑。

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
| `file_not_found` / `file_too_large` / `permission_denied` / `is_directory` | 文件面，见 `uterm-files` |
| `rule_not_found` / `rule_ambiguous` / `port_in_use` / `forward_failed` | 转发面，见 `uterm-forward` |
| `terminal_not_found` / `terminal_ambiguous` / `terminal_disconnected` | 终端面，见 `uterm-terminal` |
| `handler_timeout` | uTerm 侧 120 秒兜底超时 |
| `invalid_request` | 缺字段 / 字段冲突 |
| `not_implemented` | 这个动作在当前 uTerm 版本里还没实现 |

客户端的退出码：`0` 成功，`2` 连不上 uTerm 或客户端自己的前置检查没过，`3` 门禁，
`4` 找不到 / 有歧义，`5` 建连 / 认证 / 主机密钥 / 转发失败，`6` 超时，`1` 其它。
"""#

    /// `skills/uterm-files/SKILL.md` 的逐字副本。
    static let uTermFilesMarkdown = #"""
---
name: uterm-files
description: 通过 uTerm 的已保存 SSH 主机读写远程文件（列目录、看属性、读文本、下载、上传、建目录、删除、改名、改权限）。当需要查看或传输服务器上的文件，而手头没有主机地址或凭据时使用。
---

# 用 uTerm 读写远程文件

客户端怎么定位、探活怎么做、主机怎么指定、主机密钥怎么处理、错误码总表都在
`uterm-run`，这里不重复。本技能只讲 SFTP 这一面。

传输走 uTerm 已保存的主机档案，凭据你拿不到也不需要。**`sftpOnly` 的主机在这里完全
可用** —— 那条限制只挡执行命令与终端操作。

## 读

```sh
"$UTERMCTL" sftp ls   -H prod-web /var/log --format table
"$UTERMCTL" sftp stat -H prod-web /var/log/app.log
"$UTERMCTL" sftp cat  -H prod-web /etc/nginx/nginx.conf
```

- `ls` 的 `path` 不给时默认 `.`（登录目录）。表格里 `kind` 是 `file` / `dir` /
  `link`，`mode` 是八进制权限。
- `cat` 上限 **1 MiB**，超过会截断（`truncated: true`）。文件不是 UTF-8 文本时不会
  往终端里吐乱码，而是提示你改用 `sftp get`。
- 想「看日志最后 200 行」，用 `uterm-run` 的 `run -- tail -n 200 …` 更省事，
  别把整份日志 `cat` 下来再筛。

## 下载与上传

**本地文件是客户端读写的**，uTerm 自己在沙盒里，写不了任意本地路径。所以本地路径由
`utermctl` 处理，socket 上走 base64。

```sh
# 下载：第二个位置参数是本地落盘路径
"$UTERMCTL" sftp get -H prod-web /var/log/app.log ./app.log
"$UTERMCTL" sftp get -H prod-web /var/log/app.log ./app.log --force   # 覆盖已存在的

# 上传：先本地路径，后远端路径
"$UTERMCTL" sftp put -H prod-web ./deploy.sh /tmp/deploy.sh
```

- 单次上限 **8 MiB**，两个方向都是。上传超限客户端在发请求**之前**就拒，下载超限
  服务端回 `file_too_large`。要传大文件请用户在 uTerm 的文件窗口里拖，那里有断点与
  进度。
- `get` 默认**不覆盖**已存在的本地文件（客户端直接报错退出），要覆盖显式加 `--force`。
- 上传不会自动建父目录，先 `sftp mkdir`。

## 写与删

```sh
"$UTERMCTL" sftp mkdir -H prod-web /tmp/staging
"$UTERMCTL" sftp mv    -H prod-web /tmp/a.conf /tmp/b.conf
"$UTERMCTL" sftp chmod -H prod-web /tmp/deploy.sh 755
"$UTERMCTL" sftp rm    -H prod-web /tmp/b.conf
"$UTERMCTL" sftp rmdir -H prod-web /tmp/staging      # 只能删空目录
```

这五个加上 `put` 都归「允许执行命令与写入」开关管，关着时是 `mutations_disabled`。

## 硬约束

- **删除与覆盖先问用户**：`rm` / `rmdir`，以及 `put` 到一个已存在的远端路径、`mv`
  盖掉已有文件。远端没有回收站，这些操作没有撤销。问之前先 `stat` 或 `ls` 一下，把
  「要删的是这个、多大、什么时候改的」摆给用户看。
- **改配置文件先备份**：`sftp get` 一份到本地，或在远端 `cp x x.bak`（走
  `uterm-run`），再 `put`。
- `chmod` 别放宽到 `777`；脚本给 `755`、配置给 `644` 就够。
- **不要绕过 uTerm**：不要 `scp` / `rsync` / `sftp` 命令行直连，不要去翻 `~/.ssh`。
- 下载下来的文件可能含密钥、令牌、客户数据。**不要顺手往别处发**，用完按用户的
  要求处理。

## 错误码（本面新增的）

| code | 含义 |
|---|---|
| `file_not_found` | 远端路径不存在 |
| `file_too_large` | 超过 8 MiB（`cat` 是 1 MiB） |
| `permission_denied` | 远端权限不够 —— 换路径或让用户提权，别自己去试 `sudo` |
| `is_directory` | 对目录用了文件动作（或反过来） |

其余错误码见 `uterm-run`。客户端本地的前置拒绝（本地文件不存在、超过上限、目标已存在
且没给 `--force`）退出码是 `2`，消息在 stderr 上。
"""#

    /// `skills/uterm-forward/SKILL.md` 的逐字副本。
    static let uTermForwardMarkdown = #"""
---
name: uterm-forward
description: 通过 uTerm 启停用户已保存的 SSH 端口转发规则（本地 -L / 远程 -R / 动态 SOCKS），并查看它们的运行状态与流量。当需要打通到远程数据库、内网服务的隧道，或排查隧道没起来的原因时使用。
---

# 用 uTerm 启停端口转发

客户端怎么定位、探活怎么做、主机怎么指定、主机密钥怎么处理、错误码总表都在
`uterm-run`，这里不重复。

**规则只能由用户在 uTerm 界面里创建、修改、删除。** 命令行只能列出来、启动、停止 ——
监听哪个端口、通到哪台机器的哪个端口，是用户的定性，不是你的。需要一条不存在的规则
时，把「要什么」说清楚让用户去建，不要试图用 `run` 起一个 `ssh -L` 来代替。

## 列出来

```sh
"$UTERMCTL" forward list --format table
```

字段：

- `kind`：`local`（-L，本机监听 → 远端目标）、`remote`（-R，远端监听 → 本机目标）、
  `dynamic`（-D，本机 SOCKS5 代理，没有 `destHost`）。
- `status`：`inactive` / `starting` / `active` / `error`。`error` 时看 `issue`。
- `listenHost` / `listenPort`：本地这一头怎么连。`local` 与 `dynamic` 规则起来之后，
  就是往 `127.0.0.1:<listenPort>` 上连。
- `autostart: true` 表示用户已经让它随连接自动拉起，通常不需要你手动 start。
- `bytesIn` / `bytesOut` 是流量快照 —— 判断「隧道到底通没通」比看 `status` 更实。

## 启停

```sh
"$UTERMCTL" forward start -r pg-tunnel      # 规则名或 UUID
"$UTERMCTL" forward stop  -r pg-tunnel
```

两个都归「允许执行命令与写入」开关管（关着时 `mutations_disabled`）。

- 规则名同样按「精确 → 忽略大小写 → 唯一前缀」解析，多条命中是 `rule_ambiguous`，
  改用 `id`。
- `start` 是幂等的：已经 `active` 再 start 不会出问题。
- **start 之后不要立刻宣布成功**：回一次 `forward list` 看 `status` 变成 `active`，
  再去连本地端口。
- 用完主动 `stop` 掉你自己起的规则，尤其是 `remote`（-R）—— 它在服务器上占着端口。
  `autostart` 的规则不要动，那是用户要一直开着的。

## 端口冲突

`port_in_use` 表示本机（`local` / `dynamic`）或远端（`remote`）那个监听端口已经被占了。
常见原因是同一条规则已经在跑，或者用户手上另有一个 `ssh -L`。处理顺序：

1. 先 `forward list` 看这条规则是不是已经 `active` —— 是的话什么都不用做。
2. `local` / `dynamic` 规则占的是**本机**端口，而 `uterm-run` 的 `run` 跑的是**远端**
   命令，查不到本机的占用者。让用户自己 `lsof -i :<port>` 看，别拿 `run` 去打别的
   主机充数。`remote` 规则占的是服务器端口，那个可以 `run -H <该主机> -- ss -ltnp` 查。
3. 真要换端口，得用户去界面里改规则。

## 主机密钥

`forward start` 会真的建 SSH 连接，所以未知 / 变更的主机密钥同样会拦下它，返回
`host_key_unknown` / `host_key_changed`。处理流程与 `uterm-run` 的「主机密钥」一节
完全一样：拿 fingerprint 给用户确认，再 `trust`，然后重试。

## 硬约束

- 不要创建、修改、删除规则 —— 协议里没有这些动作。
- 不要为了「快一点」改用 `run -- ssh -L …`：那条隧道不受 uTerm 管理，用户在界面里
  看不到、也停不掉，而且会绕开他对这台主机做的定性。
- 隧道通了之后连上的数据库 / 服务里可能是生产数据。要动它们之前先问用户。

## 错误码（本面新增的）

| code | 含义 |
|---|---|
| `rule_not_found` | 没有这个名字/UUID 的规则 |
| `rule_ambiguous` | 名字匹配到多条，改用响应里的 `id` |
| `port_in_use` | 监听端口被占 |
| `forward_failed` | 隧道建立失败（消息里是原话，常见是远端拒绝 -R 或目标不可达） |

其余错误码见 `uterm-run`。
"""#

    /// `skills/uterm-terminal/SKILL.md` 的逐字副本。
    static let uTermTerminalMarkdown = #"""
---
name: uterm-terminal
description: 查看 uTerm 里正在开着的终端会话、读取某个会话的当前屏幕、往会话里注入文本、给一台主机开新终端窗口。当需要知道用户终端上正在发生什么、或要把命令送到用户眼前让他看着跑时使用。
---

# 用 uTerm 操作终端会话

客户端怎么定位、探活怎么做、主机怎么指定、错误码总表都在 `uterm-run`，这里不重复。

这一面碰的是**用户正在看的窗口**，与 `uterm-run` 那种「命令行自己另开一条连接」完全
不同。先想清楚要哪一种，见下面「什么时候别用 send」。

## 列会话

```sh
"$UTERMCTL" terminals --format table
```

列出所有窗口里的终端会话：`id`（`-t` 收它或它的唯一前缀）、`serverName`、
`windowKind`（`workspace` 工作区窗 / `terminal` 独立终端窗）、`title`（通常是当前
目录与提示符信息）、`isKeyWindowFocused`（用户此刻正看着哪个）、`connectedAt`。

会话 id 前缀重复时是 `terminal_ambiguous`，改用完整 id。会话在你操作期间被关掉是
`terminal_disconnected` —— 重新 `terminals` 一次，别对着旧 id 重试。

## 读屏

```sh
"$UTERMCTL" terminal read -t 7A2B --lines 60 --format table
```

**读屏是快照，不是流。** 它返回的是调用那一刻屏幕上的可见内容（默认 80 行，封顶
16000 字节，超了 `truncated: true`）。两次调用之间滚过去的输出**拿不回来**，被清屏
（`clear`、TUI 全屏程序）覆盖掉的也拿不回来。

所以：

- 想「盯着一个长任务的进度」，只能隔几秒读一次，并且要接受中间有缺口。别指望它当
  `tail -f` 用。
- 想拿一条命令的**完整**输出，用 `uterm-run` 的 `run` —— 那条路有明确的开始和结束、
  有退出码、输出不会被屏幕高度截掉。
- 屏幕上是 TUI（`top`、`htop`、`vim`、`less`）时，读到的是那一帧的画面，带着大量
  对齐空格，解析它没有意义 —— 直接把画面转述给用户就行。

## 注入文本

```sh
"$UTERMCTL" terminal send -t 7A2B "systemctl status nginx" --enter
```

把文本写进那个会话的 PTY，`--enter` 追加回车。归「允许执行命令与写入」开关管。

**这是四份技能里最容易造成意外的动作**，三条性质必须记住：

1. **没有输出边界。** 你拿不到这条命令的输出，也不知道它什么时候跑完。只能过一会儿
   `terminal read` 看屏幕，而那是快照。
2. **与用户的键入交错。** 用户可能正在那个会话里打字，你注入的文本会插在他打了一半
   的行里。`isKeyWindowFocused: true` 的会话尤其危险。
3. **可能落在意想不到的上下文里。** 那个会话可能正停在 `vim`、`less`、`sudo` 的
   密码提示、另一台机器的嵌套 ssh、或某个 REPL 里。你的「命令」会被当成那个上下文的
   输入。发之前先 `terminal read` 看一眼提示符。

所以 **`send` 之前一律先问用户**，即使开关已经开着。问的时候把三件事讲清楚：往哪个
会话（`serverName` + `title`）、发什么、`--enter` 会不会立刻执行。

## 什么时候别用 send

| 想干的事 | 该用 |
|---|---|
| 拿一条命令的输出、判断成败 | `uterm-run` 的 `run`（有退出码、有完整输出） |
| 在多台机器上跑同一条命令 | `uterm-run` 的 `run-many` |
| 传文件 | `uterm-files` |
| 让用户**看着**一条命令在他自己的终端里跑 | `terminal send` |
| 用户已经在会话里跑着交互程序，需要按个键 | `terminal send`（先读屏确认状态） |

一句话：**要结果就用 `run`，要让人看见才用 `send`。**

## 开新窗口

```sh
"$UTERMCTL" terminal open -H prod-web
```

给一台主机开一个新的终端窗口并连上，返回新会话。这会在用户屏幕上弹出窗口，**先问
用户**再开，也别一次开一堆。`sftpOnly` 的主机会被拒（`host_sftp_only`）。

## 硬约束

- `send` 与 `open` 都先问用户。
- 不要往会话里注入破坏性命令（`rm -rf`、`reboot`、`kill -9`），也不要在看不清上下文
  时盲发。
- 屏幕上可能有用户的私密内容（另一个项目的日志、密码提示、私人对话）。读到什么就
  只用来完成用户交代的事，**不要顺手往别处发**，也不要主动去读与任务无关的会话。
- 不要用注入去绕开 `host_sftp_only` 或两个开关 —— 门禁对这一面同样生效。

## 错误码（本面新增的）

| code | 含义 |
|---|---|
| `terminal_not_found` | 没有这个 id / 前缀的会话 |
| `terminal_ambiguous` | 前缀匹配到多个会话，改用完整 id |
| `terminal_disconnected` | 会话已经断开或被关掉了 |

其余错误码见 `uterm-run`。
"""#

    /// `scripts/utermctl` 的逐字副本（Python 3 标准库，零依赖）。
    static let controlClientScript = #"""
#!/usr/bin/env python3
"""uTerm 本机 IPC 客户端。

单一真值源：本文件的内容同时内嵌在 uTerm/Core/Skills/SkillDefinition.swift 里
（技能安装时物化到磁盘）。两边必须逐字一致，uTermTests/SkillDefinitionTests 会校验。

凭据永远不经过这里：密码 / 私钥 / 口令留在 uTerm 与钥匙串里，客户端只能按名字或
UUID 指一台**用户已保存**的主机。
"""
import argparse
import base64
import csv
import io
import json
import os
import shlex
import socket
import sys
import uuid

ENV_SOCKET = "UTERM_CONTROL_SOCKET"

# macOS 端 Debug 与 Release 都开沙盒，socket 只落在容器里。第二条候选是给
# 「万一有人跑不带沙盒的构建」留的，成本为零。
SOCKET_CANDIDATES = [
    "~/Library/Containers/com.uozi.uTerm/Data/Library/Application Support/uTerm/control.sock",
    "~/Library/Application Support/uTerm/control.sock",
]

# 与 ControlProtocol.maxFileBytes 一致：超过就别浪费一次往返，本地先拒。
MAX_FILE_BYTES = 8 * 1024 * 1024

FORMATS = ["json", "table", "csv"]

# 本地判定（服务端不会发出这两个码）
CODE_NOT_RUNNING = "uterm_not_running"
CODE_SOCKET_STALE = "uterm_socket_stale"

# code → 退出码。技能文档里的错误码总表与这张表一一对应。
EXIT_OK = 0
EXIT_OTHER = 1
EXIT_LOCAL = 2       # 连不上 uTerm，或客户端自己的前置检查没过
EXIT_GATED = 3       # 门禁：两个开关 / 仅 SFTP 主机
EXIT_NOT_FOUND = 4   # 主机 / 规则 / 会话 / 文件找不到或有歧义
EXIT_REMOTE = 5      # 建连、认证、主机密钥、转发失败
EXIT_TIMEOUT = 6     # 超时


def socket_paths():
    override = os.environ.get(ENV_SOCKET)
    if override:
        return [os.path.expanduser(override)]
    return [os.path.expanduser(p) for p in SOCKET_CANDIDATES]


def build_parser():
    # --format 在子命令前后都能写：父解析器用 SUPPRESS 做默认值，没写就不覆盖顶层的值。
    shared = argparse.ArgumentParser(add_help=False)
    shared.add_argument("--format", choices=FORMATS, default=argparse.SUPPRESS)

    parser = argparse.ArgumentParser(
        prog="utermctl",
        parents=[shared],
        description="通过正在运行的 uTerm 使用其已保存的主机执行命令、读写文件、启停转发",
    )
    # 别在这里 set_defaults(format=…)：argparse 会把默认值写回**共享的** action 对象，
    # 于是每个子解析器都拿到一个真实默认值，反手把顶层给的 --format 覆盖掉。
    sub = parser.add_subparsers(dest="action", required=True)

    def add(name, help_text, host=False, hosts=False):
        p = sub.add_parser(name, parents=[shared], help=help_text)
        if host:
            p.add_argument("--host", "-H", required=True, help="主机名或 UUID")
        if hosts:
            p.add_argument("--host", "-H", action="append", required=True,
                           help="主机名或 UUID，可重复")
        return p

    add("ping", "探活并报告版本与两个开关的状态")
    add("hosts", "列出已保存的主机")
    add("host-key", "查一台主机在信任库里的记录", host=True)

    p = add("trust", "按指纹钉住一台主机的密钥", host=True)
    p.add_argument("--fingerprint", required=True, help="必须与当前挑战一致的 SHA256:… 指纹")

    def with_command(p):
        p.add_argument("--command", "-c", help="整串 shell 命令（与 -- 之后的 argv 二选一）")
        p.add_argument("--timeout", type=int, help="秒；默认 60，封顶 300")
        p.add_argument("--max-lines", type=int, help="输出行数上限，默认 200")
        p.add_argument("--max-bytes", type=int, help="输出字节上限，默认 16000，封顶 1 MiB")
        p.add_argument("argv", nargs="*", help="-- 之后的命令与参数（原样拼成一条命令）")
        return p

    with_command(add("run", "在一台主机上跑一条命令", host=True))
    with_command(add("run-many", "在多台主机上并行跑同一条命令", hosts=True))

    add("quick-commands", "列出快捷命令")
    p = sub.add_parser("quick-run", parents=[shared], help="跑一条已保存的快捷命令")
    p.add_argument("name", help="快捷命令的名字或 UUID")
    p.add_argument("--host", "-H", action="append", help="覆盖目标主机，可重复")
    p.add_argument("--timeout", type=int)

    # --- sftp ---
    sftp = sub.add_parser("sftp", parents=[shared], help="远程文件操作")
    sftp_sub = sftp.add_subparsers(dest="sftp_action", required=True)

    def sftp_add(name, help_text):
        p = sftp_sub.add_parser(name, parents=[shared], help=help_text)
        p.add_argument("--host", "-H", required=True, help="主机名或 UUID")
        return p

    p = sftp_add("ls", "列目录")
    p.add_argument("path", nargs="?", default=".")

    p = sftp_add("stat", "看一个文件的大小与修改时间")
    p.add_argument("path")

    p = sftp_add("cat", "打印一个文本文件（上限 1 MiB）")
    p.add_argument("path")
    p.add_argument("--max-bytes", type=int)

    p = sftp_add("get", "下载一个文件到本地（上限 8 MiB）")
    p.add_argument("path")
    p.add_argument("local", help="本地落盘路径")
    p.add_argument("--force", action="store_true", help="覆盖已存在的本地文件")

    p = sftp_add("put", "上传一个本地文件（上限 8 MiB）")
    p.add_argument("local", help="本地文件路径")
    p.add_argument("path", help="远端目标路径")

    for name, help_text in (
        ("mkdir", "建目录"),
        ("rm", "删文件"),
        ("rmdir", "删空目录"),
    ):
        sftp_add(name, help_text).add_argument("path")

    p = sftp_add("mv", "改名 / 移动")
    p.add_argument("path")
    p.add_argument("new_path", metavar="new-path")

    p = sftp_add("chmod", "改权限")
    p.add_argument("path")
    p.add_argument("mode", help="八进制，如 644")

    # --- forward ---
    forward = sub.add_parser("forward", parents=[shared], help="端口转发规则的启停")
    forward_sub = forward.add_subparsers(dest="forward_action", required=True)
    forward_sub.add_parser("list", parents=[shared], help="列出规则与运行状态")
    for name, help_text in (("start", "启动一条规则"), ("stop", "停掉一条规则")):
        p = forward_sub.add_parser(name, parents=[shared], help=help_text)
        p.add_argument("--rule", "-r", required=True, help="规则名或 UUID")

    # --- terminal ---
    add("terminals", "列出所有窗口里的终端会话")
    terminal = sub.add_parser("terminal", parents=[shared], help="终端会话读屏 / 注入 / 开窗")
    terminal_sub = terminal.add_subparsers(dest="terminal_action", required=True)

    p = terminal_sub.add_parser("read", parents=[shared], help="读一个会话的当前屏幕（快照）")
    p.add_argument("--terminal", "-t", required=True, help="会话 id 或其唯一前缀")
    p.add_argument("--lines", type=int, help="行数，默认 80")

    p = terminal_sub.add_parser("send", parents=[shared], help="往一个会话注入文本")
    p.add_argument("--terminal", "-t", required=True, help="会话 id 或其唯一前缀")
    p.add_argument("text", help="要写入 PTY 的文本")
    p.add_argument("--enter", action="store_true", help="末尾追加回车")

    p = terminal_sub.add_parser("open", parents=[shared], help="给一台主机开一个新终端窗口")
    p.add_argument("--host", "-H", required=True, help="主机名或 UUID")

    p = add("disconnect", "松开命令行连接池对主机的持有")
    p.add_argument("--host", "-H", help="不给就释放全部")

    return parser


def resolved_action(args):
    """把 `sftp ls` / `forward list` / `terminal read` 拼成协议里的 kebab action。"""
    for group in ("sftp", "forward", "terminal"):
        leaf = getattr(args, group + "_action", None)
        if args.action == group and leaf:
            return "%s-%s" % (group, leaf)
    return args.action


def command_string(args):
    inline = getattr(args, "command", None)
    argv = [a for a in getattr(args, "argv", []) if a != "--"]
    if inline and argv:
        fail("-c 与 -- 之后的命令只能给一个")
    if inline:
        return inline
    if argv:
        return shlex.join(argv)
    fail("缺少命令：用 -c \"…\" 或在 -- 之后写命令")


def make_request(args):
    action = resolved_action(args)
    request = {"id": str(uuid.uuid4()), "action": action}

    host = getattr(args, "host", None)
    if isinstance(host, list):
        request["hosts"] = host
    elif host:
        request["host"] = host

    if action in ("run", "run-many"):
        request["command"] = command_string(args)
    if action == "quick-run":
        # 协议里 `name` 是按名字指定的显式入口，`command` 也接受「快捷命令的名字 / id」。
        # 两个都填，服务端读哪个都对。
        request["name"] = args.name
        request["command"] = args.name

    for field, key in (
        ("timeout", "timeoutSeconds"),
        ("max_lines", "maxLines"),
        ("max_bytes", "maxBytes"),
        ("lines", "lines"),
        ("path", "path"),
        ("new_path", "newPath"),
        ("mode", "mode"),
        ("rule", "rule"),
        ("terminal", "terminal"),
        ("text", "text"),
        ("fingerprint", "fingerprint"),
    ):
        value = getattr(args, field, None)
        if value is not None and value != "":
            request[key] = value

    if getattr(args, "enter", False):
        request["enter"] = True

    if action == "sftp-put":
        request["contentBase64"] = read_local_file(args.local)

    return request


def read_local_file(path):
    expanded = os.path.expanduser(path)
    if not os.path.isfile(expanded):
        fail("本地文件不存在：" + expanded)
    size = os.path.getsize(expanded)
    if size > MAX_FILE_BYTES:
        fail("本地文件 %d 字节，超过 uTerm 的 %d 字节上限；请分卷或改用别的通道"
             % (size, MAX_FILE_BYTES))
    with open(expanded, "rb") as handle:
        return base64.b64encode(handle.read()).decode("ascii")


def write_local_file(args, response):
    """`sftp get` 的落盘在客户端做 —— 沙盒里的 uTerm 写不了任意本地路径。"""
    payload = response.get("file") or {}
    target = os.path.expanduser(args.local)
    if os.path.exists(target) and not args.force:
        fail("本地已存在 " + target + "；要覆盖请加 --force")
    if payload.get("base64") is not None:
        data = base64.b64decode(payload["base64"])
    elif payload.get("text") is not None:
        data = payload["text"].encode("utf-8")
    else:
        fail("响应里既没有 base64 也没有 text，无法落盘")
    directory = os.path.dirname(os.path.abspath(target))
    if directory and not os.path.isdir(directory):
        fail("本地目录不存在：" + directory)
    with open(target, "wb") as handle:
        handle.write(data)
    return "已写入 %s（%d 字节）" % (target, len(data))


def fail(message):
    sys.stderr.write(message + "\n")
    sys.exit(EXIT_LOCAL)


def send_request(request):
    paths = socket_paths()
    stale = []
    for path in paths:
        if not os.path.exists(path):
            continue
        try:
            return exchange(path, request)
        except ConnectionRefusedError:
            # 文件在、没人监听 = 上一个实例被强杀（Xcode 重新 Run、崩溃）留下的残留，
            # 它自己没机会 unlink。和「uTerm 没装/没开」是两回事，别混成一个错。
            stale.append(path)
        except OSError as error:
            return {
                "id": request.get("id"),
                "ok": False,
                "code": "socket_error",
                "message": "%s: %s" % (path, error),
            }
    if stale:
        return {
            "id": request.get("id"),
            "ok": False,
            "code": CODE_SOCKET_STALE,
            "message": ("socket 文件还在但没有进程在监听（" + "、".join(stale) + "）。"
                        "uTerm 多半正在重启或刚被强制退出 —— 等它起来后重试一次；"
                        "若 uTerm 确实没在运行，这个文件会在下次启动时自动清掉。"),
        }
    return {
        "id": request.get("id"),
        "ok": False,
        "code": CODE_NOT_RUNNING,
        "message": ("uTerm 的 IPC socket 不存在（试过 " + "、".join(paths) + "）。"
                    "确认 uTerm 正在运行，且设置 ▸ 命令行与技能 里已打开「启用命令行接口」。"),
    }


def exchange(path, request):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    # run 的封顶超时是 300 秒，客户端要比它宽一点，否则自己先断。
    sock.settimeout(360)
    try:
        sock.connect(path)
        sock.sendall(json.dumps(request).encode("utf-8"))
        sock.shutdown(socket.SHUT_WR)
        chunks = []
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
    finally:
        sock.close()
    if not chunks:
        return {
            "id": request.get("id"),
            "ok": False,
            "code": "empty_response",
            "message": "uTerm IPC 返回了空响应",
        }
    return json.loads(b"".join(chunks).decode("utf-8"))


def exit_code_for(response):
    if response.get("ok"):
        return EXIT_OK
    code = response.get("code") or ""
    if code in (CODE_NOT_RUNNING, CODE_SOCKET_STALE, "socket_error", "empty_response"):
        return EXIT_LOCAL
    if code in ("control_disabled", "mutations_disabled", "host_sftp_only"):
        return EXIT_GATED
    if code.endswith("_not_found") or code.endswith("_ambiguous"):
        return EXIT_NOT_FOUND
    if (code in ("connect_failed", "auth_failed", "forward_failed")
            or code.startswith("host_key_") or code.endswith("_refused")):
        return EXIT_REMOTE
    if code in ("command_timeout", "handler_timeout"):
        return EXIT_TIMEOUT
    return EXIT_OTHER


def cell(value):
    if value is None:
        return "-"
    if isinstance(value, bool):
        return "是" if value else ""
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False, sort_keys=True)
    return str(value)


def octal(value):
    if value is None:
        return "-"
    try:
        return format(int(value) & 0o7777, "04o")
    except (TypeError, ValueError):
        return str(value)


TABLES = [
    ("hosts", ["name", "host", "port", "username", "authMethod", "group", "jumpHost",
               "sftpOnly", "cliConnected", "activeForwards", "id"]),
    ("rules", ["name", "serverName", "kind", "listenHost", "listenPort", "destHost",
               "destPort", "status", "autostart", "bytesIn", "bytesOut", "id"]),
    ("terminals", ["title", "serverName", "windowKind", "isKeyWindowFocused",
                   "connectedAt", "id"]),
    ("quickCommands", ["name", "command", "serverNames", "lastRunAt", "id"]),
    ("results", ["host", "exitCode", "timedOut", "truncated", "durationMs",
                 "errorCode", "errorMessage"]),
]


def rows_of(response):
    """把响应里可表格化的部分取成 (表头, 行) —— 没有就返回 None。"""
    entries = response.get("entries")
    if isinstance(entries, list):
        header = ["name", "kind", "size", "mode", "owner", "group", "modifiedAt"]
        rows = []
        for item in entries:
            kind = "dir" if item.get("isDirectory") else ("link" if item.get("isSymlink") else "file")
            rows.append([
                cell(item.get("name")), kind, cell(item.get("size")),
                octal(item.get("permissions")), cell(item.get("ownerName")),
                cell(item.get("groupName")), cell(item.get("modifiedAt")),
            ])
        return header, rows
    for key, columns in TABLES:
        items = response.get(key)
        if isinstance(items, list):
            return columns, [[cell(item.get(c)) for c in columns] for item in items]
    result = response.get("result")
    if isinstance(result, dict):
        columns = dict(TABLES)["results"]
        return columns, [[cell(result.get(c)) for c in columns]]
    stat = response.get("stat")
    if isinstance(stat, dict):
        return ["path", "size", "modifiedAt"], [[cell(stat.get(c)) for c in
                                                 ("path", "size", "modifiedAt")]]
    return None


def render_table(header, rows, limit=60):
    widths = [len(h) for h in header]
    clipped = []
    for row in rows:
        cells = []
        for index, value in enumerate(row):
            text = value.replace("\n", " ")
            if len(text) > limit:
                text = text[: limit - 1] + "…"
            cells.append(text)
            widths[index] = max(widths[index], len(text))
        clipped.append(cells)
    lines = ["  ".join(h.ljust(widths[i]) for i, h in enumerate(header)).rstrip()]
    lines.append("  ".join("-" * widths[i] for i in range(len(header))))
    for row in clipped:
        lines.append("  ".join(row[i].ljust(widths[i]) for i in range(len(header))).rstrip())
    return "\n".join(lines)


def render_csv(header, rows):
    buffer = io.StringIO()
    writer = csv.writer(buffer)
    writer.writerow(header)
    writer.writerows(rows)
    return buffer.getvalue().rstrip("\n")


def as_json(response):
    return json.dumps(response, ensure_ascii=False, indent=2, sort_keys=True)


def run_output(response):
    """run / run-many 的人类可读输出：逐主机一段，带退出码与超时提醒。"""
    results = response.get("results")
    if not isinstance(results, list):
        single = response.get("result")
        results = [single] if isinstance(single, dict) else []
    blocks = []
    for item in results:
        head = "── %s" % item.get("host", "?")
        if item.get("exitCode") is not None:
            head += "  exit=%s" % item["exitCode"]
        head += "  %sms" % item.get("durationMs", 0)
        if item.get("errorCode"):
            head += "  [%s] %s" % (item["errorCode"], item.get("errorMessage") or "")
        blocks.append(head)
        body = item.get("output") or ""
        if body:
            blocks.append(body.rstrip("\n"))
        if item.get("truncated"):
            blocks.append("-- 输出已截断（--max-lines / --max-bytes 可放宽）")
        if item.get("timedOut"):
            blocks.append("-- 已超时；**命令可能还在远端继续跑**")
    return "\n".join(blocks)


def render(response, fmt, args):
    if not response.get("ok"):
        return as_json(response)
    action = resolved_action(args)

    if action == "sftp-get":
        note = write_local_file(args, response)
        return as_json(response) if fmt == "json" else note

    if fmt == "json":
        return as_json(response)

    if action == "sftp-cat":
        payload = response.get("file") or {}
        if payload.get("text") is not None:
            body = payload["text"]
            if payload.get("truncated"):
                body += "\n-- 已按 --max-bytes 截断"
            return body
        return ("-- %s 不是 UTF-8 文本（%s 字节）：用 `sftp get` 下载后本地处理"
                % (payload.get("path", "?"), payload.get("bytes", "?")))

    screen = response.get("screen")
    if isinstance(screen, dict):
        body = "\n".join(screen.get("lines") or [])
        if screen.get("truncated"):
            body += "\n-- 读屏已截断"
        return body

    if action in ("run", "run-many", "quick-run"):
        return run_output(response)

    table = rows_of(response)
    if table is None:
        return as_json(response)
    header, rows = table
    return render_table(header, rows) if fmt == "table" else render_csv(header, rows)


def main():
    args = build_parser().parse_args()
    response = send_request(make_request(args))
    print(render(response, getattr(args, "format", "json"), args))
    return exit_code_for(response)


if __name__ == "__main__":
    sys.exit(main())
"""#
}
