# 另一台 Mac：读写文件、搜代码、跑命令（`macs` / `mac …`）

客户端怎么定位、探活怎么做、两个开关、错误码总表都在 `SKILL.md`，这里不重复。本文只讲
「另一台 Mac」这一面。

对象不是 SSH 主机，是经 uTerm 的远控链路连着的另一台 Mac（同一局域网直接连，不在一起就走
打洞或用户自建的中继）。那台 Mac **不用开 SSH、不用公网地址**，你也拿不到任何凭据。
文件操作由那台 Mac 上的 uTerm 以登录用户的身份执行。有两个方向，命令一样，能做的事不一样：

| | 这台 Mac **控制**的 Mac（`role: host`） | **正在控制这台 Mac** 的设备（`role: controller`） |
|---|---|---|
| 典型场景 | 你在用户手边的 Mac 上，去操作他配对过的另一台 | 你跑在一台被远程控制着的 Mac 的终端里，要回头读用户手边那台 Mac 上的项目 |
| 能访问哪里 | 整台 Mac（那边打开了「允许打开本机终端」） | **只有用户在那台 Mac 上共享出来的文件夹**，默认一个都没有 |
| `mac run` / `mac patch` | 可以 | 不行，永远拒绝 |
| 怎么指定 | `-M 名字或 UUID` | 不写 `-M`（见下面「正在控制这台 Mac 的设备」），或 `-M 名字` / `-M controller:<UUID>` |

## 正在控制这台 Mac 的设备

你在一台 Mac 的 uTerm 终端里，这个终端正被用户的另一台 Mac 远程接管着 —— 用户说「看一下
我电脑上的那个项目」，指的多半是他手边那台。先看它共享了什么：

```sh
"$UTERMCTL" mac shares --format table      # 不写 -M：此刻接管着这个终端的那台设备
"$UTERMCTL" macs --format table            # current 那一列标着「是」的就是它
```

然后照常用 `mac ls` / `cat` / `read` / `grep` / `find` / `tree` / `get` / `put` / `write` /
`edit` …，路径写**那台 Mac 上的绝对路径**，必须落在 `shares` 列出的文件夹里。

- **不写 `-M` 时用哪台**：uTerm 开终端时把终端的编号写进了环境变量 `UTERM_SESSION_ID`，
  `utermctl` 带着它去问「此刻是谁在用这个终端」。同一时刻一个终端只归一台设备；换了设备接管，
  同一条命令就落在新的那台上，不用你管。`-M @controller` 是同一个意思的显式写法。
- **几台设备同时连着**：在被接管的终端里照上面的规则，不会串。认不出终端（`tmux` / `ssh` 嵌套
  之后环境变量丢了、命令不是在 uTerm 的终端里发的）或这个终端此刻没人接管时：只连着一台肯提供
  文件的设备就用它，否则回 `host_ambiguous` 并列出候选 —— **照 `id` 重发，不要挑一个试**。
- **接管这个终端的是手机**：手机没有文件可共享，命令会直说，不会悄悄换成别的设备。
- `permission_denied` +「不在共享的文件夹里」：`message` 里列着共享了哪些。要别的目录，
  **请用户在他那台 Mac 的 uTerm「动作 › 我的 Mac」里选中这台 Mac、添加共享文件夹**，
  这件事只能他在界面里做。不要试 `..`、符号链接这些路子绕，都会被拒。
- `permission_denied` +「是只读共享」：文件夹共享的是只读。要改，请用户把它改成「读写」。
- 没有共享任何文件夹：`mac shares` 回空列表，别的命令回 `permission_denied`，处理同上。
- 写操作除了那边得是读写共享，**这台 Mac** 的「允许执行命令与写入」也得开着。

下面各节的命令两个方向通用；`mac run`、`mac patch` 只对你控制的 Mac 有效。

## 先看有哪些 Mac

```sh
"$UTERMCTL" macs --format table
```

`-M/--mac` 收这里列出的**名字**或 **`id`**，解析规则同主机：精确 → 忽略大小写 → 唯一前缀；
重名回 `host_ambiguous`，改用 `id`。同一台 Mac 可能出现两行（既配对过、此刻又在控制这台 Mac），
两行的 `id` 不一样，走的路和能访问的范围也不一样，用 `id` 点名。

| 字段 | 含义 |
|---|---|
| `role` | `host`：配对过、由这台 Mac 控制的；`controller`：此刻正控制着这台 Mac 的设备 |
| `current` | `controller` 才有意义：它此刻接管着发命令的这个终端（不写 `-M` 用的就是它） |
| `onLocalNetwork` | 此刻在同一局域网里找得到 |
| `onRelay` | 此刻在中继上（没问过中继时是 `-`，不代表不在） |
| `connected` | 命令行已经握着到它的连接，下一条命令不用再建连 |
| `path` | 连着时走的哪条路：局域网 / 直连 / 中继 |
| `supportsFiles` | 那台 Mac 上的 uTerm 支不支持这组命令 |

连不上时照 `message` 说，常见的几种：

- 列表是空的 / `host_not_found`：还没配对。让用户在 uTerm「动作 › 我的 Mac」里配对，
  这件事只能在界面里做。
- `connect_failed`：那台 Mac 没开机、没开 uTerm、没打开「远程控制」，或者两边不在同一
  局域网又没有配中继。局域网只有在用户**打开过「我的 Mac」之后**才会去找（免得命令行
  触发系统的「本地网络」授权框），没打开过就只走中继。
- `permission_denied` +「没有打开『允许打开本机终端』」：那台 Mac 的 uTerm「设置 ›
  远程控制」里这个开关关着。它管的是「配对过的设备能不能在这台 Mac 上开终端、读写文件、
  跑命令」，只能那台 Mac 的主人去开，**不要想办法绕**。
- 「版本太旧」：那台 Mac 上的 uTerm 要更新。

第一条命令要建连（局域网约 1 秒，中继更久），之后复用；空闲 10 分钟自动放掉。

## 路径

- `~` 会展开成那台 Mac 的主目录；相对路径相对主目录；不给路径的命令默认主目录。
- 桌面、文稿、下载这几个目录受 macOS 隐私保护：第一次访问时**那台 Mac 的屏幕上**会弹
  授权框，没人点就回 `permission_denied`。代码放在 `~/Workspace`、`~/Developer`
  这类普通目录下不受影响。

## 读

```sh
"$UTERMCTL" mac ls   -M studio ~/Workspace/app --format table
"$UTERMCTL" mac stat -M studio ~/Workspace/app/Package.swift
"$UTERMCTL" mac cat  -M studio ~/Workspace/app/README.md --format table
"$UTERMCTL" mac read -M studio ~/Workspace/app/Sources/main.swift --lines 120:180 --format table
"$UTERMCTL" mac read -M studio /var/log/system.log --tail 50 --format table
```

- `ls` / `stat` / `cat` 的输出形状与 `sftp ls|stat|cat` 完全一样（`entries` / `stat` /
  `file`）。`cat` 上限 1 MiB，超过回 `file_too_large`。
- `read` 读一段，适合大文件：`--lines A:B`（从 1 起，两端都含）、`--head N`、`--tail N`
  三选一，都不给就从头读；内容默认最多 256 KiB（`--max-bytes` 可调），超过会在**行尾**
  截断并标 `truncated`，接着用 `--lines` 读下一段。JSON 里文本在 `mac.text`，另有
  `mac.totalLines`（总行数）和 `mac.sha256`（**整个文件**的哈希，给 `write --if-match`
  / `edit --if-match` 用）。
- `read --offset N --length M` 按字节读（封顶 1 MiB），二进制文件用它；结果在 `file` 里。
- `--format table` 直接打印文本，末尾一行 `-- …` 是说明。

## 搜

```sh
"$UTERMCTL" mac grep -M studio 'func \w+Handler' ~/Workspace/app --include '*.swift' -C 2 --format table
"$UTERMCTL" mac grep -M studio -F 'TODO(' ~/Workspace/app --format table
"$UTERMCTL" mac find -M studio ~/Workspace/app --name '*.xcconfig' --format table
"$UTERMCTL" mac find -M studio ~/Workspace/app --type f --newer 3600      # 最近一小时改过的
"$UTERMCTL" mac tree -M studio ~/Workspace/app --depth 2 --format table
```

- `grep` 的模式是正则（ICU 语法）；`-F` 按字面量，`-i` 忽略大小写，`-C N` 带上下文，
  `--include` / `--exclude` 按文件名通配，可重复。`--format table` 输出 `路径:行号: 内容`。
  默认最多 200 处（`--limit`，封顶 2000）。坏的正则回 `invalid_request`。
- **默认跳过**：隐藏文件、二进制文件、超过 4 MiB 的文件；目录在 git 仓库里时按
  `.gitignore` 过滤，不在仓库里时跳过 `node_modules`、`build`、`DerivedData`、`.git`
  这类目录。`--hidden` 连隐藏文件一起，`--no-ignore` 不过滤。
- 搜索最多跑 20 秒。`truncated: true` 表示没搜完（撞了条数上限或时限），**不要当成
  「没有更多」**：缩小目录或加 `--include` 再搜。
- `find --name` 是文件名通配符（不是正则），`--type f|d`，`--depth N`，`--newer 秒数`，
  `--hash` 给每个文件带 sha256。默认最多 500 项（封顶 5000）。
- `tree` 默认 3 层、400 项。
- 另有 `mac hash`（一个文件的 sha256）、`mac du`（目录占用）、`mac df`（磁盘可用空间）。

## 下载、上传、同步

单个文件的 `get` / `put` 与 `sftp get|put` 是同一套：本地文件由客户端打开、把文件描述符
交给 uTerm，并行传、大小不限，`--force` / `--resume` / `--no-verify` / `--parallel` /
`--quiet` 含义相同，断点续传与失败后的状态也相同（见 `files.md` 的「传断了」一节，
**先读它**）。

```sh
"$UTERMCTL" mac get -M studio ~/Workspace/app/build.log ./build.log
"$UTERMCTL" mac put -M studio ./patch.diff ~/Workspace/app/patch.diff

# 整个目录
"$UTERMCTL" mac get -r -M studio ~/Workspace/app/Sources ./Sources
"$UTERMCTL" mac put -r -M studio ./dist ~/Workspace/app/dist --force

# 同步：只传大小或修改时间不一样的文件
"$UTERMCTL" mac sync up   -M studio ./site ~/Sites/site --dry-run
"$UTERMCTL" mac sync down -M studio ./notes ~/Notes --exclude '.DS_Store'
```

- `get -r` / `put -r`：目录结构原样重建，文件逐个传（4 个一起）。已存在的文件默认
  **不覆盖**、记进 `tree.failed`；确认要盖加 `--force`。符号链接一律跳过，列在
  `tree.skippedLinks` 里。部分失败时 `ok: false`，逐个看 `tree.failed`，重跑一遍
  （加 `--force`）即可，目录传输没有 `--resume`。
- `sync up|down <本地目录> <那台 Mac 上的目录>`：大小不同就传；大小相同、修改时间不同
  也传（`--checksum` 会先比 sha256，内容一样就只把时间对齐）。传完把目标的修改时间设成
  和源一样，下次同步靠它判断「没变」。`--delete` 删掉目标里多出来的文件：`up` 时是
  移进那台 Mac 的废纸篓，`down` 时是**直接删本地文件** —— 先 `--dry-run` 看清单再跑。
  `--exclude` 按名字通配，可重复。
- 文件多、大多很小的目录（比如 `node_modules`）逐个传很慢：在那台 Mac 上先
  `mac run … tar czf`，传一个包过来再解。

## 写

```sh
"$UTERMCTL" mac write -M studio ~/Workspace/app/notes.md --text '# 记录'
"$UTERMCTL" mac write -M studio ~/Workspace/app/config.json --file ./config.json --force
"$UTERMCTL" mac edit  -M studio ~/Workspace/app/Sources/main.swift --old 'let retries = 3' --new 'let retries = 5'
git diff | "$UTERMCTL" mac patch -M studio ~/Workspace/app --dry-run
```

- `write`：内容来自 `--text`、`--file <本地文件>` 或标准输入，必须是 UTF-8 文本，上限
  512 KiB（更大的或二进制用 `put`）。**默认只肯新建**，已存在回 `file_exists`；
  `--force` 覆盖；`--if-match <sha256>` 只在文件当前内容的哈希等于它时才写，否则回
  `operation_failed`（说明别人改过，重新读了再决定）。写入是原子的：先写临时文件再改名，
  不会留下写了一半的文件，原文件的权限保留。
- `edit`：把 `--old` 换成 `--new`。`--old` 必须在文件里**恰好出现一次**（没有或多于
  一次都失败、不改文件），多带几行上下文让它唯一；确实要全换加 `--all`。同样支持
  `--if-match`。响应里的 `mac.sha256` 是改完之后的哈希，连着改几处时拿它接着用。
- `patch`：unified diff 来自 `--file` 或标准输入，在给的目录下打（默认 `-p1`，`--strip`
  可改）。`--dry-run` 只检查能不能打上。打不上回 `operation_failed`，`message` 里是
  `patch` 的原话，文件不动、不留 `.rej` / `.orig`。
- 其它：`mkdir [-p]`、`rm [-r]`、`rmdir`、`trash`（移进废纸篓，能放回）、`mv` /
  `cp [--force]`、`chmod [-R]`、`ln <指向> <链接路径>`、`readlink`、`touch`、
  `xattr <路径> [list|get|set|remove] [名字] [值]`。
- **删除优先用 `trash`**。`rm -r` 是立刻、不可恢复的；破坏性操作照 `SKILL.md` 的硬约束
  先问用户。

## 等变化

```sh
"$UTERMCTL" mac wait-change -M studio ~/Workspace/app/build --wait 120
```

等一个文件或目录（连同它下面的一切）有变化，默认最多 30 秒，封顶 600。有变化时
`mac.names` 是变了的路径；到时限没变化是 `ok: true` + `mac.timedOut: true`。适合
「等构建产物出来」「等日志有新内容」，别用 `sleep` 轮询。

## 跑命令

```sh
"$UTERMCTL" mac run -M studio --cwd ~/Workspace/app -- swift build
"$UTERMCTL" mac run -M studio -c 'cd ~/Workspace/app && git status --short'
```

- 在那台 Mac 上用**登录 shell**跑（读用户的 `~/.zprofile` 等，`PATH` 和他开终端时一样），
  `--cwd` 不给就是主目录。
- 响应形状、`--timeout`（静默超时，默认 60 秒）、`--max-duration`、`--max-lines`、
  `--max-bytes`、超时后杀整个进程组、`exitCode` 非 0 不算调用失败 —— 全部与 `run`
  相同，见 `SKILL.md` 的「跑命令」「超时与截断」。`--` 之后的 argv 同样被拼成**一条**
  命令，带管道、`&&` 的整串用 `-c`。
- **没有 stdin**：要输密码、要确认的命令会干等到超时。`sudo` 用不了。
- 这是一台有人在用的 Mac，不是服务器：别动用户的桌面环境（`killall Finder`、改系统
  设置、`open` 一堆窗口），长时间吃满 CPU 的任务先说一声。

## 哪些要第二个开关

只读的 `macs` / `mac shares|ls|stat|cat|read|grep|find|tree|hash|du|df|get|readlink|
wait-change` 和 `xattr list|get` 只要「启用命令行接口」。

`mac run|put|sync up|write|edit|patch|mkdir|rm|rmdir|trash|mv|cp|chmod|ln|touch` 和
`xattr set|remove` 要「允许执行命令与写入」，没开回 `mutations_disabled`。

这两个开关是**这台** Mac 上的；那台 Mac 上还有它自己的一道：你控制的 Mac 是「允许打开本机终端」，
正在控制这台 Mac 的设备是它共享了哪些文件夹、只读还是读写，见上文。

## 错误码

| code | 含义 |
|---|---|
| `host_not_found` / `host_ambiguous` | 没有这个名字的 Mac / 匹配到多台，或没写 `-M` 而几台设备同时连着分不出来：改用 `message` 里列的 `id` |
| `connect_failed` | 连不上那台 Mac，或请求途中链路断了（原因在 `message`）。读类操作可以直接重试；写和跑命令先确认做到哪了 |
| `permission_denied` | 那台 Mac 没开「允许打开本机终端」，或系统不让读这个路径（隐私保护的目录、别的用户的文件）；对正在控制这台 Mac 的设备：路径不在它共享的文件夹里、文件夹是只读共享、用了 `mac run` / `mac patch` |
| `file_not_found` / `file_exists` / `is_directory` / `file_too_large` | 同 SFTP |
| `invalid_request` | 参数不对：缺路径、坏的正则、文件不是文本 |
| `command_timeout` | `mac run` 静默超时或撞上总时长上限，细节在 `results[0]` |
| `operation_failed` | 其它失败，原因在 `message`：`--if-match` 对不上、`edit` 的原文没找到或不唯一、补丁打不上、目录非空、目录传输有文件没成 |
