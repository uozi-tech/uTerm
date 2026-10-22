# 读写远程文件（`sftp …`）

客户端怎么定位、探活怎么做、主机怎么指定、主机密钥怎么处理、错误码总表都在
`SKILL.md`，这里不重复。本文只讲 SFTP 这一面。

传输走 uTerm 已保存的主机档案，凭据你拿不到也不需要。**`sftpOnly` 的主机在这里完全
可用** —— 那条限制只挡执行命令与终端操作。

远端路径原样传给 SFTP：用绝对路径，或相对登录目录的路径。**`~/x` 不会展开**，会被当成
登录目录下一个叫 `~` 的目录。

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
- `cat` 上限 **1 MiB**（`--max-bytes N` 只能调小），超过**不截断**而是直接回
  `file_too_large`（远端没有部分读的原语）—— 改用 `sftp get`（大小不限）落盘后本地处理，
  或者用下面那条 `tail`。
- `cat` 默认输出也是 JSON：文本在 `file.text`，不是 UTF-8 的文件给成 `file.base64`。
  要直接拿纯文本就加 `--format table`（非 UTF-8 时这里会提示你改用 `sftp get`，不吐乱码）。
- 想「看日志最后 200 行」，用 `run -H <主机> -- tail -n 200 …` 更省事，
  别把整份日志 `cat` 下来再筛。

## 下载与上传

**本地文件是客户端打开的**：uTerm 自己在沙盒里，打不开任意本地路径。`utermctl` 建好 /
打开本地文件后，把文件描述符随请求交给 uTerm（`SCM_RIGHTS`），uTerm 用多条 SFTP 连接
**并行**直接读写它 —— 文件内容不走 socket、不做 base64，**大小没有上限**，几 GB 的
文件照传不误，不需要把大文件劝回 GUI。

```sh
# 下载：第二个位置参数是本地落盘路径
"$UTERMCTL" sftp get -H prod-web /var/log/app.log ./app.log
"$UTERMCTL" sftp get -H prod-web /var/log/app.log ./app.log --force   # 覆盖已存在的

# 上传：先本地路径，后远端路径
"$UTERMCTL" sftp put -H prod-web ./release.tar.gz /srv/release.tar.gz

# 断了接着传：只补没传完的区间（靠下面说的续传状态文件）
"$UTERMCTL" sftp put -H prod-web ./release.tar.gz /srv/release.tar.gz --resume
```

- **两个方向都默认不覆盖**：`get` 碰到已存在的本地文件、`put` 碰到已存在的远端路径
  都直接失败（前者是客户端本地拒绝、退出码 `2`，后者是服务端回 `file_exists`、
  退出码 `1`）。确认要盖就显式加 `--force`。
- 上传不会自动建父目录，先 `sftp mkdir`。

| 选项 | 作用 |
|---|---|
| `--parallel N` | uTerm 用几条 SFTP 连接并行传，1–16，默认 8。实测（50 ms 延迟）8 路已经吃满，再往上多半更慢，一般不用调；目标服务器 sshd 很吃紧时可以调小 |
| `--resume` | 断点续传，能做什么见下面两节。与 `--force` **互斥**（一起给是退出码 `2`） |
| `--no-verify` | 传完不比对 sha256 |
| `--quiet` | 不刷进度行（结束仍打一行汇总到 stderr） |
| `--force` | 覆盖已存在的目标。与 `--resume` 互斥 |

### 传断了，目标是什么状态

**并行传输失败留下的不是「前缀」，是带空洞的文件** —— 后面的段传完了、前面的段没完
很正常。所以「按已有的大小接着传」是错的，会跳过空洞、拼出一个悄悄错掉的文件。客户端
因此显式记账：

- 传输期间 uTerm 每 0.5 秒报一次「新完成的段」，客户端把它们记进**本地**的续传状态
  文件 `<本地路径>.utermctl-transfer.json`（`put` 与 `get` 都写在本地），连同方向、
  远端路径、总大小、文件身份（大小 + 修改时间）；整趟成功后删掉。
- 中途撞上可重试的错误（连接断了、服务端忙），客户端**自动续传**两次，只补缺的区间，
  不从头来。
- `put` 最终还是失败：**远端是一个不完整的文件**（有空洞）。别拿它当结果，也别去 `mv` 它。
- `get` 最终还是失败：目标文件名**根本不会生成**，半成品在 `<本地路径>.part`；校验通过
  之后才 rename 成目标名。所以「目标名存在」== 「这份文件是完整且校验过的」。
- 失败响应的 `transfer` 里有 `incomplete` / `resumable` / `statePath` / `partPath`，
  stderr 上是同一句话。别自己去猜目标现在有多少字节。

### `--resume` 到底能做什么

- **有续传状态文件、身份对得上** → 只传没完成的区间；`put` 续传时不再动远端已有内容。
- **身份对不上**（本地源文件改了 / 远端文件换了）→ **拒绝**，退出码 `2`。接着传只会
  拼出一个错的文件；删掉状态文件整份重传。
- **没有续传状态文件** → 拒绝，退出码 `2`：去掉 `--resume` 整份重传。
- sha256 对不上（`checksum_mismatch`）**不是 `--resume` 能修的**：区间都传完了，错的
  是内容。状态文件会被删掉，只能整份重传（去掉 `--resume`，目标已存在时加 `--force`）。
- 一个本地路径同一时间只跟踪一趟传输。同一个本地文件传去两个远端路径时，`--resume`
  会认出「状态文件记的不是这条」并拒绝。

### 其它

- **校验默认开，但只对 8 MiB 以上的文件做**：校验要在远端跑 `sha256sum`
  （`shasum -a 256` 兜底），那归「允许执行命令与写入」开关管，不该把小文件的只读下载
  也拖下水。远端两个工具都没有时 `verified: false` + stderr 一句说明，**不算失败**。
- sha256 对不上时退出码是 `1`、`code: checksum_mismatch`，**别当成传成功了** ——
  按上一节整份重传。
- uTerm 同时最多跑 8 个传输（与 `run` / `ping` 等调用的槽位分开，传输再多也挤不掉
  它们）；同一台主机的 SFTP 通道全忙时也一样。满了回 `server_busy`，`get` / `put` 的
  客户端会退避 0.5 / 1 / 2 秒后每 4 秒一次重试，约 1 分钟。
- 下载的文件会去掉系统打的 `com.apple.quarantine`（uTerm 在沙盒里写过的文件会被打上），
  下载下来的脚本 / 可执行文件不会被 Gatekeeper 拦。
- 远端文件在传输期间被截短会报 `operation_failed`（「远端在 N 处提前结束」）：等它
  稳定了再传，或者先在远端 `cp` 一份快照。
- `Ctrl-C` 掉 `utermctl`，uTerm 一秒内就停下这趟传输；已完成的区间记在续传状态里，
  `--resume` 接着传。
- 进度打在 stderr（stdout 留给 JSON）。成功时 `transfer` 里有这一趟的账：
  `bytes` / `totalBytes` / `parallel` / `seconds` / `mbps`（MiB/s）/
  `sha256` / `verified` / `verifyNote` / `resumedFrom`；失败时还多
  `incomplete` / `resumable` / `statePath` / `partPath`。

## 写与删

```sh
"$UTERMCTL" sftp mkdir -H prod-web /tmp/staging
"$UTERMCTL" sftp mv    -H prod-web /tmp/a.conf /tmp/b.conf
"$UTERMCTL" sftp chmod -H prod-web /tmp/deploy.sh 755
"$UTERMCTL" sftp rm    -H prod-web /tmp/b.conf
"$UTERMCTL" sftp rmdir -H prod-web /tmp/staging      # 只能删空目录
```

这五个加上 `put` 都归「允许执行命令与写入」开关管，关着时是 `mutations_disabled`。

`chmod` 只收八进制数字（`755`、`0644`，封顶 `7777`）；`u+x` 这类符号写法回
`invalid_request`。

## 硬约束

- **删除与覆盖先问用户**：`rm` / `rmdir`，以及 `put --force` 到一个已存在的远端路径、
  `mv` 盖掉已有文件。（不加 `--force` 的 `put` 会被服务端的 `file_exists` 挡住 ——
  撞上它就是在提醒你先问。）远端没有回收站，这些操作没有撤销。问之前先 `stat` 或 `ls` 一下，把
  「要删的是这个、多大、什么时候改的」摆给用户看。
- **改配置文件先备份**：`sftp get` 一份到本地，或在远端 `cp x x.bak`（走 `run`），
  再 `put`。
- `chmod` 别放宽到 `777`；脚本给 `755`、配置给 `644` 就够。
- **不要绕过 uTerm**：不要 `scp` / `rsync` / `sftp` 命令行直连，不要去翻 `~/.ssh`。
- 下载下来的文件可能含密钥、令牌、客户数据。**不要顺手往别处发**，用完按用户的
  要求处理。

## 错误码（本面新增的）

| code | 含义 |
|---|---|
| `file_not_found` | 远端路径不存在 |
| `file_exists` | `put` 的远端路径已存在，且没给 `--force`（退出码 `1`） |
| `file_too_large` | `cat` 超过 1 MiB（超限不截断，直接报这个码）。`get` / `put` 没有大小上限 |
| `permission_denied` | 远端权限不够 —— 换路径或让用户提权，别自己去试 `sudo` |
| `is_directory` | 对目录用了文件动作（或反过来） |
| `server_busy` | 传输槽位或该主机的 SFTP 通道满了。`get` / `put` 已经退避重试了约 1 分钟；还撞上就等别的传输跑完（退出码 `2`） |
| `local_read_failed` | 读本地源文件失败（权限、传输期间被改短）（退出码 `2`） |
| `local_write_failed` | 写本地半成品 / 改名成目标失败（磁盘满、路径被目录占着）（退出码 `2`） |

这个是**客户端**判的：

| code | 含义 |
|---|---|
| `checksum_mismatch` | 区间都传完了，本地与远端 sha256 对不上（退出码 `1`）。整份重传，别 `--resume` |

其余错误码见 `SKILL.md`。客户端本地的前置拒绝（本地文件不存在、本地目标已存在且没给
`--force`、`--resume` 无从续起 / 身份对不上 / 没有续传状态文件、
`--parallel` 超范围、`--force` 与 `--resume` 一起给）退出码是 `2`，
消息在 stderr 上。
