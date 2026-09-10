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

# 断了接着传：只补没传完的那几片（靠下面说的分片状态文件）
"$UTERMCTL" sftp put -H prod-web ./release.tar.gz /srv/release.tar.gz --resume
```

| 选项 | 作用 |
|---|---|
| `--parallel N` | 并行分片数，1–6，默认 4。服务端一共 8 个连接槽位，上限 6 是给校验用的 `run` 和别人的调用留余量；超过槽位的连接会被服务端**直接关掉**（客户端看到 `empty_response`）或回 `server_busy`，客户端退避重试，但排队不会让它更快 |
| `--chunk-mib N` | 分片大小（MiB，可带小数），默认 8，上限 8 |
| `--resume` | 断点续传，能做什么见下面两节。与 `--force` **互斥**（一起给是退出码 `2`） |
| `--no-verify` | 传完不比对 sha256 |
| `--quiet` | 不刷进度行（结束仍打一行汇总到 stderr） |
| `--force` | 覆盖已存在的目标。与 `--resume` 互斥 |

### 传断了，目标是什么状态

**并行分片失败留下的不是「前缀」，是带空洞的文件** —— 第 3 片成了、第 2 片没成很正常。
所以「按已有的大小接着传」在并行下是错的，会跳过空洞、拼出一个悄悄错掉的文件。客户端
因此显式记账：

- 每趟分片传输都在**本地**写一份分片状态文件 `<本地路径>.utermctl-transfer.json`
  （`put` 与 `get` 都写在本地），记着方向、远端路径、总大小、分片大小、文件身份
  （大小 + 修改时间）和**已完成的分片 offset**；每片成功就原子更新，整趟成功后删掉。
  单请求传输（小文件）不写它 —— 没有半截可续。
- `put` 断了：**远端是一个不完整的文件**（有空洞）。别拿它当结果，也别去 `mv` 它。
- `get` 断了：目标文件名**根本不会生成**，半成品在 `<本地路径>.part`；校验通过之后才
  rename 成目标名。所以「目标名存在」== 「这份文件是完整且校验过的」。
- 失败响应的 `transfer` 里有 `incomplete` / `resumable` / `statePath` / `partPath`，
  stderr 上是同一句话。别自己去猜目标现在有多少字节。

### `--resume` 到底能做什么

- **有分片状态文件、身份对得上** → 只重传 / 重取没完成的那几片，分片大小以状态文件里
  记的为准（不用再给 `--chunk-mib`）。`put` 的首片要是没成：文件多半已经被别的片建出
  来了，客户端会先 `stat` 一下，远端有就用 `write` 重发，没有才 `create`。
- **身份对不上**（本地源文件改了 / 远端文件换了）→ **拒绝**，退出码 `2`。接着传只会
  拼出一个错的文件；删掉状态文件整份重传。
- **没有分片状态文件** → 只有 `--parallel 1` 才允许「按远端 / 本地已有的大小接着传」，
  而且**只有上一趟也是 `--parallel 1`** 时这么做才对。默认（并行）下直接拒绝，退出码
  `2`，两条出路都写在消息里：整份重传，或者 `--parallel 1`。
- sha256 对不上（`checksum_mismatch`）**不是 `--resume` 能修的**：片都传完了，错的是
  内容。状态文件会被删掉，只能整份重传（去掉 `--resume`，目标已存在时加 `--force`）。
- 一个本地路径同一时间只跟踪一趟传输。同一个本地文件传去两个远端路径时，`--resume`
  会认出「状态文件记的不是这条」并拒绝。

### 其它

- **校验默认开，但只对分片传输做**：单请求传输是一次收发，会出错的是分片拼装；而且
  校验要在远端跑 `sha256sum`（`shasum -a 256` 兜底），那归「允许执行命令与写入」开关
  管，不该把小文件的只读下载也拖下水。远端两个工具都没有时 `verified: false` +
  stderr 一句说明，**不算失败**。
- sha256 对不上时退出码是 `1`、`code: checksum_mismatch`，**别当成传成功了** ——
  按上一节整份重传。
- 单片失败自动重试 2 次（0.5 / 1 秒退避）；服务端槽位满（`server_busy` 或它直接关连接
  时看到的 `empty_response`）更耐心：重试 5 次，退避 0.5 / 1 / 2 / 4 / 4 秒。仍失败
  整条传输就失败，退出码按响应里的错误码映射。
- `get` 分片时**每一片必须收满它要的字节数**：空载荷不是 EOF（区间是按 `stat` 的大小
  切的），那片会重试，仍然空就报 `remote_short_read`。远端文件正在被写就会撞上它 ——
  等它稳定了再传，或者先 `cp` 一份快照。
- 进度打在 stderr（stdout 留给 JSON）。成功时 `transfer` 里有这一趟的账：
  `bytes` / `totalBytes` / `chunks` / `parallel` / `seconds` / `mbps`（MiB/s）/
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
| `server_busy` | 服务端的连接槽位满了（一共 8 个）。客户端已经退避重试过 5 次；还撞上就等一会儿，或把 `--parallel` 调小（退出码 `2`） |

这几个是**客户端**判的（都在分片传输里）：

| code | 含义 |
|---|---|
| `checksum_mismatch` | 片都传完了，本地与远端 sha256 对不上（退出码 `1`）。整份重传，别 `--resume` |
| `remote_short_read` | `get` 的某一片收不满它要的字节数（远端文件正在被写 / 被截短），退出码 `1` |
| `local_read_failed` | 读本地源文件失败（权限、传输期间被改）（退出码 `2`） |
| `local_write_failed` | 写本地半成品 / 改名成目标失败（磁盘满、路径被目录占着）（退出码 `2`） |

其余错误码见 `uterm-run`。客户端本地的前置拒绝（本地文件不存在、本地目标已存在且没给
`--force`、`--resume` 无从续起 / 身份对不上 / 没有分片状态文件又是并行、
`--parallel` / `--chunk-mib` 超范围、`--force` 与 `--resume` 一起给）退出码是 `2`，
消息在 stderr 上。
