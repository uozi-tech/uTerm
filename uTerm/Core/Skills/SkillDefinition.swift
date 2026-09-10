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
        /// app 包内 `Contents/Resources/` 下的同名资源。
        ///
        /// **可执行文件必须走这条路**：uTerm 开着 App Sandbox，它写出的每一个文件都被
        /// 打上 `com.apple.quarantine`，直接 exec 必然 `operation not permitted`，而沙盒
        /// 进程无权解除自己的隔离（见 `SkillInstaller` 的说明）。所以脚本由构建期
        /// 「Copy utermctl CLI」阶段拷进 app 包、随 app 一起签名/公证，物化时只在源目录
        /// 里建一条**指向包内文件的符号链接** —— 与 VS Code 的 `code` 命令同一套路。
        ///
        /// 为 nil（或包内资源缺失，比如测试宿主）时退回把 `content` 写成真实文件。
        let bundleResourceName: String?

        init(
            relativePath: String,
            content: String,
            isExecutable: Bool,
            bundleResourceName: String? = nil
        ) {
            self.relativePath = relativePath
            self.content = content
            self.isExecutable = isExecutable
            self.bundleResourceName = bundleResourceName
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
                isExecutable: true,
                bundleResourceName: "utermctl"
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
- `stat` 回 `size` / `modifiedAt` / `permissions` / `kind`。`permissions` 是**原始
  POSIX mode（含类型位）**，与 `ls` 的那一列同义；`--format table` 里已经按
  `& 0o7777` 显示成八进制。`kind` 是 `file` / `directory` / `symlink` / `other`，
  服务端没回权限位时 `permissions` 与 `kind` 都是 `null`。
- `cat` 上限 **1 MiB**，超过**不截断**而是直接回 `file_too_large`（远端没有部分读
  的原语）—— 改用 `sftp get`（上限 8 MiB）落盘后本地处理，或者用下面那条 `tail`。
  文件不是 UTF-8 文本时也不会往终端里吐乱码，同样提示你改用 `sftp get`。
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

- **两个方向都默认不覆盖**：`get` 碰到已存在的本地文件、`put` 碰到已存在的远端路径
  都直接失败（前者是客户端本地拒绝、退出码 `2`，后者是服务端回 `file_exists`、
  退出码 `1`）。确认要盖就显式加 `--force`。
- 上传不会自动建父目录，先 `sftp mkdir`。
- 单次请求上限 **8 MiB**，但**这不是文件大小的上限** —— 超过一片的文件由客户端自动
  切片并行传，见下一节。

## 大文件

`get` / `put` 超过分片大小（默认 8 MiB，= 单次请求上限）时，客户端自动切成
`[offset, offset+length)` 的分片，各开一条连接并行传，传完比对 sha256。**不需要你做
任何事**，也不用再把大文件劝回 GUI：

```sh
"$UTERMCTL" sftp put -H prod-web ./release.tar.gz /srv/release.tar.gz
"$UTERMCTL" sftp get -H prod-web /var/log/big.log ./big.log

# 断了接着传（put 以远端已有大小为起点，get 以本地已有大小为起点）
"$UTERMCTL" sftp put -H prod-web ./release.tar.gz /srv/release.tar.gz --resume
```

| 选项 | 作用 |
|---|---|
| `--parallel N` | 并行分片数，1–8，默认 4。上限 8 是服务端的并发客户端上限，再大只会排队 |
| `--chunk-mib N` | 分片大小（MiB，可带小数），默认 8，上限 8 |
| `--resume` | 断点续传；只在「已有的那部分比源文件小」时可用，否则退出码 `2` |
| `--no-verify` | 传完不比对 sha256 |
| `--quiet` | 不刷进度行（结束仍打一行汇总到 stderr） |
| `--force` | 覆盖已存在的目标 |

- **校验默认开，但只对分片传输做**：单请求传输是一次收发，会出错的是分片拼装；而且
  校验要在远端跑 `sha256sum`（`shasum -a 256` 兜底），那归「允许执行命令与写入」开关
  管，不该把小文件的只读下载也拖下水。远端两个工具都没有时 `verified: false` +
  stderr 一句说明，**不算失败**。
- sha256 对不上时退出码是 `1`、`code: checksum_mismatch` —— 加 `--resume` 续传，或者
  去掉 `--resume` 整份重传，**别当成传成功了**。
- 单片失败自动重试 2 次（0.5 / 1 秒退避）；仍失败整条传输就失败，退出码按响应里的
  错误码映射。此时远端是**半截文件**，用 `--resume` 接着传。
- 进度打在 stderr（stdout 留给 JSON）。成功时 `transfer` 里有这一趟的账：
  `bytes` / `totalBytes` / `chunks` / `parallel` / `seconds` / `mbps`（MiB/s）/
  `sha256` / `verified` / `verifyNote` / `resumedFrom`。

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

- **删除与覆盖先问用户**：`rm` / `rmdir`，以及 `put --force` 到一个已存在的远端路径、
  `mv` 盖掉已有文件。（不加 `--force` 的 `put` 会被服务端的 `file_exists` 挡住 ——
  撞上它就是在提醒你先问。）远端没有回收站，这些操作没有撤销。问之前先 `stat` 或 `ls` 一下，把
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
| `file_exists` | `put` 的远端路径已存在，且没给 `--force`（退出码 `1`） |
| `file_too_large` | 超过 8 MiB（`cat` 是 1 MiB；超限不截断，直接报这个码）。`get` / `put` 不会撞它 —— 大文件走分片 |
| `permission_denied` | 远端权限不够 —— 换路径或让用户提权，别自己去试 `sudo` |
| `is_directory` | 对目录用了文件动作（或反过来） |

另外 `checksum_mismatch` 是**客户端**判的：分片传完后本地与远端的 sha256 对不上，
退出码 `1`。

其余错误码见 `uterm-run`。客户端本地的前置拒绝（本地文件不存在、本地目标已存在且没给
`--force`、`--resume` 无从续起、`--parallel` / `--chunk-mib` 超范围）退出码是 `2`，
消息在 stderr 上。
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
`windowKind`（`workspace` 工作区窗 / `terminal` 独立终端窗）、`title`（那条**标签**的
名字：用户给标签起的自定义名，没起过就是主机名 —— 它**不是**当前目录，也不是提示符）、
`isKeyWindowFocused`（用户此刻正看着哪个）、`connectedAt`。

同一台主机开了两条会话时，`serverName` 与 `title` 可能一模一样，**只有 `id` 能区分**。

**这张表只列还连着的会话。** 标签 / 窗口被关掉，或那条 SSH 断了（远端退出、网络掉了），
会话立刻从表里消失。所以拿旧 id 去操作，通常得到的是 `terminal_not_found` 而不是
`terminal_disconnected` —— 重新 `terminals` 一次，别对着旧 id 重试。会话 id 前缀
匹配到多条时是 `terminal_ambiguous`，改用完整 id。

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

给一台主机开一个新的终端窗口并连上，返回的 `terminals` 里是那条新会话。这会在用户
屏幕上弹出窗口，**先问用户**再开，也别一次开一堆。`sftpOnly` 的主机会被拒
（`host_sftp_only`）。

窗口是异步搭起来的：开窗成功但 6 秒内会话还没连上（首连慢、卡在主机密钥确认）时，
响应仍是 `ok`，但 `terminals` 是**空数组**，`message` 会说明情况 —— 此时窗口确实已经
开了，隔几秒用 `terminals` 再列一次拿会话 id，不要重复 `open`。

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
| `terminal_not_found` | 没有这个 id / 前缀的会话 —— 包括已经关掉 / 断开、因而不再出现在 `terminals` 里的 |
| `terminal_ambiguous` | 前缀匹配到多个会话，改用完整 id |
| `terminal_disconnected` | 你列表之后、操作之前，这条会话正好断了 / 被关了，字节没写进去 |

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
import concurrent.futures
import csv
import hashlib
import io
import json
import os
import re
import shlex
import socket
import sys
import threading
import time
import uuid

ENV_SOCKET = "UTERM_CONTROL_SOCKET"

# macOS 端 Debug 与 Release 都开沙盒，socket 只落在容器里。第二条候选是给
# 「万一有人跑不带沙盒的构建」留的，成本为零。
SOCKET_CANDIDATES = [
    "~/Library/Containers/com.uozi.uTerm/Data/Library/Application Support/uTerm/control.sock",
    "~/Library/Application Support/uTerm/control.sock",
]

# 与 ControlProtocol.maxFileBytes 一致：**单次请求**的上限。超过这个数的文件不再本地
# 拒绝，而是由客户端切片后多请求并行传（见「大文件传输」一节）。
MAX_FILE_BYTES = 8 * 1024 * 1024

# 分片传输的默认值。并发上限 8 = ControlServer.maxActiveClients：再多也只是排队，
# 还会把别的客户端挤掉。分片上限就是单请求上限。
DEFAULT_CHUNK_BYTES = MAX_FILE_BYTES
DEFAULT_PARALLEL = 4
MAX_PARALLEL = 8

# 分片失败重试 2 次，指数退避；仍失败整条传输就失败（不留半截还报成功）。
CHUNK_RETRY_DELAYS = (0.5, 1.0)

# 远端算 sha256：两个工具挑一个，都没有就跳过校验（不算失败）。
REMOTE_SHA256_TIMEOUT = 300
SHA256_RE = re.compile(r"\b([0-9a-fA-F]{64})\b")

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
EXIT_REMOTE = 5      # 建连、认证、主机密钥、转发失败（run-many 全失败也算这一档）
EXIT_TIMEOUT = 6     # 超时
EXIT_PARTIAL = 7     # run-many / quick-run：有的主机成了、有的没成


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

    p = sftp_add("stat", "看一个文件的类型、大小、权限与修改时间")
    p.add_argument("path")

    p = sftp_add("cat", "打印一个文本文件（上限 1 MiB，超限回 file_too_large，改用 get）")
    p.add_argument("path")
    p.add_argument("--max-bytes", type=int)

    p = sftp_add("get", "下载一个文件到本地（超过分片大小自动切片并行）")
    p.add_argument("path")
    p.add_argument("local", help="本地落盘路径")
    p.add_argument("--force", action="store_true", help="覆盖已存在的本地文件")
    transfer_options(p)

    p = sftp_add("put", "上传一个本地文件（超过分片大小自动切片并行）")
    p.add_argument("local", help="本地文件路径")
    p.add_argument("path", help="远端目标路径")
    p.add_argument("--force", action="store_true", help="覆盖已存在的远端文件")
    transfer_options(p)

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


def transfer_options(p):
    """`sftp get` / `sftp put` 共用的分片传输选项。"""
    p.add_argument("--resume", action="store_true",
                   help="断点续传：从已有的那部分之后接着传")
    p.add_argument("--parallel", type=int, default=DEFAULT_PARALLEL,
                   help="并行分片数，1–%d，默认 %d" % (MAX_PARALLEL, DEFAULT_PARALLEL))
    p.add_argument("--no-verify", dest="verify", action="store_false", default=True,
                   help="传完不比对 sha256（默认只对分片传输校验）")
    p.add_argument("--chunk-mib", type=float,
                   help="分片大小（MiB，可带小数），默认 8，上限 8")
    # 自测用：直接给字节数，好用 1–2 MiB 的小分片跑出多片而不真的搬 8 MiB。
    p.add_argument("--chunk-bytes", type=int, help=argparse.SUPPRESS)
    p.add_argument("--quiet", action="store_true",
                   help="不刷进度行（结束仍打一行汇总到 stderr）")
    return p


def resolved_action(args):
    """把 `sftp ls` / `forward list` / `terminal read` 拼成协议里的 kebab action。"""
    for group in ("sftp", "forward", "terminal"):
        leaf = getattr(args, group + "_action", None)
        if args.action == group and leaf:
            return "%s-%s" % (group, leaf)
    return args.action


def command_string(args):
    inline = getattr(args, "command", None)
    argv = list(getattr(args, "argv", []))
    # `--` 是命令的一部分，**不能过滤**：`run -H h -- grep -- --include f` 里那个
    # `--` 是 grep 的参数分隔符，滤掉就变成了另一条命令。
    # 实测 argparse（本机 3.9.6 / 3.10.21 / 3.13.15 / 3.14.7，含子解析器）只吃掉
    # 分隔用的**第一个** `--`，不会留在 argv 里；下面这行只是防御：万一某个版本把它
    # 留下，也只去掉开头那一个。
    if argv[:1] == ["--"]:
        argv = argv[1:]
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

    return request


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


def read_response(sock):
    """读到 EOF 并解析成 JSON。空响应或解析不了都返回 None。"""
    chunks = []
    try:
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
    except OSError:
        # 对端已经把连接拆了；已经收到的那部分仍然可能是完整的一条响应。
        pass
    if not chunks:
        return None
    try:
        return json.loads(b"".join(chunks).decode("utf-8"))
    except ValueError:
        return None


def exchange(path, request):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    # run 的封顶超时是 300 秒，客户端要比它宽一点，否则自己先断。
    sock.settimeout(360)
    try:
        sock.connect(path)
        try:
            sock.sendall(json.dumps(request).encode("utf-8"))
            sock.shutdown(socket.SHUT_WR)
        except (BrokenPipeError, ConnectionResetError):
            # 服务端可能**在我们写完之前**就回了一条响应并关掉连接 —— 典型是请求体
            # 超过 maxRequestBytes（大文件 sftp put）时的 `request_too_large`。
            # AF_UNIX 上已经写回的数据不会因对端 close 而丢，所以先把它读出来：
            # 读到 JSON 就按正常响应处理，读不到才把 EPIPE 报成 socket_error。
            response = read_response(sock)
            if response is not None:
                return response
            raise
        response = read_response(sock)
    finally:
        sock.close()
    if response is None:
        return {
            "id": request.get("id"),
            "ok": False,
            "code": "empty_response",
            "message": "uTerm IPC 返回了空响应或读不懂的内容",
        }
    return response


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
    # run-many / quick-run：全失败按「远端失败」报，有成有败单独给一档，
    # 好让脚本能区分「一台都没成」和「大部分成了」。
    if code == "run_failed":
        return EXIT_REMOTE
    if code == "run_partial_failure":
        return EXIT_PARTIAL
    return EXIT_OTHER


# ---------------------------------------------------------------------------
# 大文件传输：客户端切片 + 并行
#
# 单次 IPC 请求上限 8 MiB（ControlProtocol.maxFileBytes），而 SFTP 的往返延迟才是
# 真正的瓶颈。所以超过一片的文件由客户端切成 [offset, offset+length) 的片，各自开
# 一条 socket 连接并行发（服务端 maxActiveClients = 8，所以并发上限也是 8）。
#
# `sftp-put` 的首片决定覆盖语义（create / overwrite），其余片一律 `write`（不截断、
# 写到 offset）—— 所以首片必须先单独发完再并行，否则一条迟到的 overwrite 会把已经
# 写进去的尾巴截掉。
# ---------------------------------------------------------------------------

# 这些码重试没有意义：门禁、找不到、参数不对、远端已存在、密钥没信任。
PERMANENT_CODES = frozenset([
    "control_disabled", "mutations_disabled", "host_sftp_only",
    "invalid_request", "not_implemented", "file_exists", "file_too_large",
    "permission_denied", "is_directory", "auth_failed", "request_too_large",
    CODE_NOT_RUNNING, CODE_SOCKET_STALE,
])


def new_request(action, **fields):
    """带 id 的请求体；值为 None 的字段不出现在 JSON 里。"""
    body = {"id": str(uuid.uuid4()), "action": action}
    for key, value in fields.items():
        if value is not None:
            body[key] = value
    return body


def is_retryable(code):
    if code in PERMANENT_CODES:
        return False
    if code.endswith("_not_found") or code.endswith("_ambiguous"):
        return False
    return not code.startswith("host_key_")


def send_chunk(body):
    """发一片：失败重试 2 次（0.5 / 1 秒退避），仍失败就把最后那条响应原样返回。

    每次重试换一个 id —— 服务端的日志里能看出这是第几次。`send_request` 自己不共享
    任何状态（每次新建 socket），所以线程池里直接调就行。
    """
    response = send_request(body)
    for delay in CHUNK_RETRY_DELAYS:
        if response.get("ok") or not is_retryable(response.get("code") or ""):
            return response
        time.sleep(delay)
        response = send_request(dict(body, id=str(uuid.uuid4())))
    return response


def chunk_size_for(args):
    if getattr(args, "chunk_bytes", None) is not None:
        value = args.chunk_bytes
    elif getattr(args, "chunk_mib", None) is not None:
        value = int(args.chunk_mib * 1024 * 1024)
    else:
        return DEFAULT_CHUNK_BYTES
    if value < 1 or value > MAX_FILE_BYTES:
        fail("分片大小要在 1 字节 – %d 字节（8 MiB，= 单次请求上限）之间，实得 %d"
             % (MAX_FILE_BYTES, value))
    return value


def parallel_for(args):
    value = getattr(args, "parallel", DEFAULT_PARALLEL)
    if value < 1 or value > MAX_PARALLEL:
        fail("--parallel 要在 1–%d 之间（服务端并发客户端上限），实得 %d"
             % (MAX_PARALLEL, value))
    return value


def human(count):
    value = float(count)
    for unit in ("B", "KiB", "MiB"):
        if value < 1024:
            return "%d %s" % (count, unit) if unit == "B" else "%.1f %s" % (value, unit)
        value /= 1024.0
    return "%.2f GiB" % value


def clock(seconds):
    seconds = int(max(seconds, 0))
    return "%d:%02d" % (seconds // 60, seconds % 60)


class Progress(object):
    """stderr 上的一行进度。tty 上原地刷新；非 tty 或 `--quiet` 时不刷，只在结束
    打一行汇总（stdout 留给 JSON，进度绝不能污染它）。"""

    def __init__(self, label, total, live):
        self.label = label
        self.total = total
        self.live = live
        self.done = 0
        self.started = time.time()
        self.lock = threading.Lock()
        self.drawn = False
        self.last = 0.0

    def advance(self, count):
        with self.lock:
            self.done += count
            now = time.time()
            if not self.live or now - self.last < 0.2:
                return
            self.last = now
            self.drawn = True
            sys.stderr.write("\r\033[K" + self._line(now))
            sys.stderr.flush()

    def _line(self, now):
        seconds = max(now - self.started, 0.001)
        speed = self.done / 1048576.0 / seconds
        remaining = (self.total - self.done) / 1048576.0 / speed if speed > 0 else 0
        return "%s %s / %s  %.1f MiB/s  ETA %s" % (
            self.label, human(self.done), human(self.total), speed, clock(remaining))

    def finish(self, note):
        with self.lock:
            if self.drawn:
                sys.stderr.write("\r\033[K")
                self.drawn = False
            if note:
                sys.stderr.write(note + "\n")
            sys.stderr.flush()


def local_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def remote_sha256(host, path):
    """回 (十六进制, None) 或 (None, 说明)。远端两个工具都没有不算失败。"""
    quoted = shlex.quote(path)
    command = ("sha256sum -- %s 2>/dev/null || shasum -a 256 -- %s"
               % (quoted, quoted))
    response = send_request(new_request(
        "run", host=host, command=command,
        timeoutSeconds=REMOTE_SHA256_TIMEOUT, maxLines=5))
    if not response.get("ok"):
        return None, ("远端算 sha256 没跑成（%s：%s），跳过校验"
                      % (response.get("code"), response.get("message") or ""))
    match = SHA256_RE.search((response.get("result") or {}).get("output") or "")
    if match is None:
        return None, "远端既没有 sha256sum 也没有 shasum，跳过校验"
    return match.group(1).lower(), None


def verify_pair(args, local_path, chunked):
    """校验缺省开，但**只对分片传输**做：单请求传输是一次收发，会出错的是分片拼装；
    而且 `run` 归「允许执行命令与写入」开关管，小文件的只读下载不该被它拖下水。"""
    verdict = {"sha256": None, "verified": False, "note": None, "remote": None}
    if not getattr(args, "verify", True):
        verdict["note"] = "已用 --no-verify 关掉校验"
        return verdict
    if not chunked:
        verdict["note"] = "单请求传输，默认不做 sha256 校验"
        return verdict
    verdict["sha256"] = local_sha256(local_path)
    remote, note = remote_sha256(args.host, args.path)
    verdict["remote"] = remote
    if remote is None:
        verdict["note"] = note
        return verdict
    verdict["verified"] = remote == verdict["sha256"]
    if not verdict["verified"]:
        verdict["note"] = "sha256 不一致：本地 %s，远端 %s" % (verdict["sha256"], remote)
    return verdict


def remote_stat(host, path):
    """回 (字节数, None) 或 (None, 失败响应)。"""
    response = send_request(new_request("sftp-stat", host=host, path=path))
    if not response.get("ok"):
        return None, response
    return int((response.get("stat") or {}).get("size") or 0), None


def decode_payload(payload):
    if payload.get("base64") is not None:
        return base64.b64decode(payload["base64"])
    if payload.get("text") is not None:
        return payload["text"].encode("utf-8")
    return None


def transfer_stats(kind, args, **fields):
    seconds = round(max(time.time() - fields["started"], 0.0), 3)
    moved = fields["bytes"]
    speed = round(moved / 1048576.0 / seconds, 2) if seconds > 0 and moved else 0.0
    return {
        "action": kind,
        "localPath": os.path.abspath(os.path.expanduser(args.local)),
        "remotePath": args.path,
        "bytes": moved,
        "totalBytes": fields["total"],
        "chunks": fields["chunks"],
        "parallel": fields["parallel"],
        "seconds": seconds,
        "mbps": speed,                       # MiB/s
        "resumedFrom": fields["resumed"],
        "sha256": fields.get("sha256"),
        "verified": fields.get("verified", False),
        "verifyNote": fields.get("verifyNote"),
    }


def transfer_failure(response, stats):
    """分片失败：保留服务端的 code / message（退出码沿用既有映射），附上已传的账。"""
    return {
        "id": response.get("id"),
        "ok": False,
        "code": response.get("code") or "operation_failed",
        "message": response.get("message") or "分片传输失败",
        "hostKey": response.get("hostKey"),
        "transfer": stats,
    }


def put_mode(offset, resumed, force):
    """首片决定覆盖语义，其余片不截断。

    与规划里「首片恒 overwrite」不同：没有 `--force` 时首片用 `create`，让服务端回
    `file_exists` —— 否则大文件会绕过 `put` 默认不覆盖的保护，与小文件不一致。
    """
    if offset > 0 or resumed > 0:
        return "write"
    return "overwrite" if force else "create"


def do_put(args):
    local = os.path.expanduser(args.local)
    if not os.path.isfile(local):
        fail("本地文件不存在：" + local)
    total = os.path.getsize(local)
    chunk = chunk_size_for(args)
    workers = parallel_for(args)
    started = time.time()

    resumed = 0
    if args.resume:
        size, error = remote_stat(args.host, args.path)
        if error is not None and error.get("code") != "file_not_found":
            return transfer_failure(error, transfer_stats(
                "put", args, started=started, bytes=0, total=total,
                chunks=0, parallel=workers, resumed=0))
        if size is not None:
            if size >= total:
                fail("远端已有 %d 字节，不小于本地的 %d 字节 —— --resume 无从续起；"
                     "确认要整份重传就去掉 --resume 并加 --force" % (size, total))
            resumed = size

    plan = [(off, min(chunk, total - off)) for off in range(resumed, total, chunk)]
    if not plan:
        plan = [(0, 0)]           # 空文件也要在远端建出来
    chunked = len(plan) > 1 or resumed > 0
    progress = Progress("↑ " + os.path.basename(local), total - resumed,
                        sys.stderr.isatty() and not args.quiet)

    fd = os.open(local, os.O_RDONLY)

    def send_slice(offset, length):
        try:
            data = os.pread(fd, length, offset) if length else b""
        except OSError as error:
            return {"ok": False, "code": "local_read_failed", "message": str(error)}
        return send_chunk(new_request(
            "sftp-put", host=args.host, path=args.path, offset=offset,
            mode=put_mode(offset, resumed, args.force),
            contentBase64=base64.b64encode(data).decode("ascii")))

    try:
        sent = 0
        error = None
        # 首片单独发完：它带的是 create / overwrite，晚到会截掉别人写好的尾巴。
        response = send_slice(*plan[0])
        if response.get("ok"):
            sent += plan[0][1]
            progress.advance(plan[0][1])
        else:
            error = response
        if error is None and len(plan) > 1:
            with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
                futures = {pool.submit(send_slice, off, length): length
                           for off, length in plan[1:]}
                for future in concurrent.futures.as_completed(futures):
                    # 已经取消掉的片没有结果可取（`result()` 会抛 CancelledError）。
                    if future.cancelled():
                        continue
                    outcome = future.result()
                    if outcome.get("ok"):
                        sent += futures[future]
                        progress.advance(futures[future])
                    elif error is None:
                        error = outcome
                        for pending in futures:
                            pending.cancel()
    finally:
        os.close(fd)

    if error is not None:
        stats = transfer_stats("put", args, started=started, bytes=sent, total=total,
                               chunks=len(plan), parallel=workers, resumed=resumed)
        progress.finish("上传失败（%s）：已传 %s / %s"
                        % (error.get("code"), human(sent), human(total)))
        return transfer_failure(error, stats)

    verdict = verify_pair(args, local, chunked)
    stats = transfer_stats("put", args, started=started, bytes=sent, total=total,
                           chunks=len(plan), parallel=workers, resumed=resumed,
                           sha256=verdict["sha256"], verified=verdict["verified"],
                           verifyNote=verdict["note"])
    return finish_transfer("上传", args.path, progress, stats, verdict)


def do_get(args):
    local = os.path.expanduser(args.local)
    directory = os.path.dirname(os.path.abspath(local))
    if directory and not os.path.isdir(directory):
        fail("本地目录不存在：" + directory)
    exists = os.path.exists(local)
    if exists and not (args.force or args.resume):
        fail("本地已存在 " + local + "；要覆盖请加 --force，要接着传请加 --resume")
    chunk = chunk_size_for(args)
    workers = parallel_for(args)
    started = time.time()

    size, error = remote_stat(args.host, args.path)
    if error is not None:
        return transfer_failure(error, transfer_stats(
            "get", args, started=started, bytes=0, total=0,
            chunks=0, parallel=workers, resumed=0))

    resumed = 0
    if args.resume and exists:
        resumed = os.path.getsize(local)
        if resumed >= size:
            fail("本地已有 %d 字节，不小于远端的 %d 字节 —— 无从续起；"
                 "确认要整份重下就去掉 --resume 并加 --force" % (resumed, size))

    plan = [(off, min(chunk, size - off)) for off in range(resumed, size, chunk)]
    chunked = len(plan) > 1 or resumed > 0
    progress = Progress("↓ " + os.path.basename(local), size - resumed,
                        sys.stderr.isatty() and not args.quiet)
    note = None

    if not chunked:
        # 单请求：整文件（≤ 8 MiB），请求形状与旧版一模一样（不带 offset / length）。
        response = send_chunk(new_request("sftp-get", host=args.host, path=args.path))
        if not response.get("ok"):
            progress.finish("下载失败（%s）" % response.get("code"))
            return transfer_failure(response, transfer_stats(
                "get", args, started=started, bytes=0, total=size,
                chunks=1, parallel=workers, resumed=0))
        data = decode_payload(response.get("file") or {})
        if data is None:
            fail("响应里既没有 base64 也没有 text，无法落盘")
        with open(local, "wb") as handle:
            handle.write(data)
        received = len(data)
        plan = plan or [(0, 0)]
    else:
        fd = os.open(local, os.O_RDWR | os.O_CREAT, 0o644)
        received = 0
        ends = [resumed]
        error = None

        def fetch(offset, length):
            got = 0
            while got < length:
                response = send_chunk(new_request(
                    "sftp-get", host=args.host, path=args.path,
                    offset=offset + got, length=length - got))
                if not response.get("ok"):
                    return response, got
                data = decode_payload(response.get("file") or {})
                if not data:
                    break         # 短读到 0 = 远端文件比 stat 时短了
                os.pwrite(fd, data, offset + got)
                got += len(data)
                progress.advance(len(data))
            return None, got

        try:
            os.ftruncate(fd, size)        # 预分配，好让各片按 offset 直接 pwrite
            with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
                futures = {pool.submit(fetch, off, length): (off, length)
                           for off, length in plan}
                for future in concurrent.futures.as_completed(futures):
                    if future.cancelled():
                        continue
                    outcome, got = future.result()
                    received += got
                    ends.append(futures[future][0] + got)
                    if outcome is not None and error is None:
                        error = outcome
                        for pending in futures:
                            pending.cancel()
            end = max(ends)
            if error is None and end < size:
                os.ftruncate(fd, end)     # 远端文件在传输期间变短了
                note = "远端文件在传输期间从 %d 缩到了 %d 字节" % (size, end)
        finally:
            os.close(fd)

        if error is not None:
            progress.finish("下载失败（%s）：已收 %s / %s"
                            % (error.get("code"), human(received), human(size)))
            return transfer_failure(error, transfer_stats(
                "get", args, started=started, bytes=received, total=size,
                chunks=len(plan), parallel=workers, resumed=resumed))

    verdict = verify_pair(args, local, chunked)
    if note and verdict["note"] is None:
        verdict["note"] = note
    stats = transfer_stats("get", args, started=started, bytes=received, total=size,
                           chunks=len(plan), parallel=workers, resumed=resumed,
                           sha256=verdict["sha256"], verified=verdict["verified"],
                           verifyNote=verdict["note"])
    return finish_transfer("下载", local, progress, stats, verdict)


def finish_transfer(verb, target, progress, stats, verdict):
    summary = "%s完成：%s → %s，%s，%d 片 × %d 并发，%.1fs，%.2f MiB/s" % (
        verb, human(stats["bytes"]), target, human(stats["totalBytes"]),
        stats["chunks"], stats["parallel"], stats["seconds"], stats["mbps"])
    if stats["resumedFrom"]:
        summary += "（从 %s 续传）" % human(stats["resumedFrom"])
    if verdict["remote"] is not None and not verdict["verified"]:
        progress.finish(summary + "\n" + (verdict["note"] or ""))
        return {
            "id": str(uuid.uuid4()), "ok": False, "code": "checksum_mismatch",
            "message": (verdict["note"] or "sha256 不一致")
                       + " —— 加 --resume 续传，或去掉 --resume 整份重传",
            "transfer": stats,
        }
    if stats["verified"]:
        summary += "，sha256 已校验"
    elif verdict["note"]:
        summary += "，未校验：" + verdict["note"]
    progress.finish(summary)
    return {"id": str(uuid.uuid4()), "ok": True, "code": "ok",
            "message": summary, "transfer": stats}


TRANSFER_COLUMNS = ["action", "localPath", "remotePath", "bytes", "totalBytes",
                    "chunks", "parallel", "seconds", "mbps", "resumedFrom",
                    "sha256", "verified", "verifyNote"]


def render_transfer(response, fmt):
    # 失败响应一律原样打 JSON —— 与别的动作一致，模型要读 code / hostKey。
    if fmt == "json" or not response.get("ok"):
        return as_json(response)
    transfer = response.get("transfer") or {}
    header = ["字段", "值"]
    rows = [[key, cell(transfer.get(key))] for key in TRANSFER_COLUMNS]
    return render_table(header, rows) if fmt == "table" else render_csv(header, rows)


def cell(value):
    if value is None:
        return "-"
    if isinstance(value, bool):
        # false 必须画成「否」而不是空白：空白与「字段缺失」（"-"）分不开，
        # hosts 的 sftpOnly / cliConnected、terminals 的 isKeyWindowFocused、
        # forward list 的 autostart 在表格里本来整列都是空的。
        return "是" if value else "否"
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
        # mode 与 ls 一样按 & 0o7777 的八进制显示（原始值含类型位，类型另立 kind 列）。
        header = ["path", "kind", "size", "mode", "modifiedAt"]
        row = [cell(stat.get("path")), cell(stat.get("kind")), cell(stat.get("size")),
               octal(stat.get("permissions")), cell(stat.get("modifiedAt"))]
        return header, [row]
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


# 这两个码的响应带着完整的 results，人类可读格式照常逐主机渲染。
RUN_BATCH_CODES = ("run_failed", "run_partial_failure")


def render(response, fmt, args):
    if not response.get("ok"):
        # run-many / quick-run 失败时 results 才是有用的东西（逐台的 errorCode），
        # 一股脑打 JSON 等于把表格吞了。json 格式仍然原样输出。
        if (fmt != "json" and response.get("code") in RUN_BATCH_CODES
                and isinstance(response.get("results"), list)):
            return run_output(response) + "\n-- " + (response.get("message") or "")
        return as_json(response)
    action = resolved_action(args)

    if fmt == "json":
        return as_json(response)

    if action == "sftp-cat":
        payload = response.get("file") or {}
        if payload.get("text") is not None:
            body = payload["text"]
            if payload.get("truncated"):
                body += "\n-- 内容不完整：读取期间远端文件变大了"
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
    # 空表就打服务端的说明。`terminal open` 会在窗口开了、但 6 秒内会话还没注册上来
    # 时回 `terminals: []` + 一句解释，只印表头等于把这句话吞了。
    if not rows:
        return response.get("message") or as_json(response)
    return render_table(header, rows) if fmt == "table" else render_csv(header, rows)


def main():
    args = build_parser().parse_args()
    fmt = getattr(args, "format", "json")
    action = resolved_action(args)
    # 传输是多请求的（stat / 分片 / 校验），自己走一条路；其余动作一请求一响应。
    if action in ("sftp-put", "sftp-get"):
        response = do_put(args) if action == "sftp-put" else do_get(args)
        print(render_transfer(response, fmt))
        return exit_code_for(response)
    response = send_request(make_request(args))
    print(render(response, fmt, args))
    return exit_code_for(response)


if __name__ == "__main__":
    sys.exit(main())
"""#
}
