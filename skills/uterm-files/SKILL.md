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
| `file_too_large` | 超过 8 MiB（`cat` 是 1 MiB；超限不截断，直接报这个码） |
| `permission_denied` | 远端权限不够 —— 换路径或让用户提权，别自己去试 `sudo` |
| `is_directory` | 对目录用了文件动作（或反过来） |

其余错误码见 `uterm-run`。客户端本地的前置拒绝（本地文件不存在、超过上限、目标已存在
且没给 `--force`）退出码是 `2`，消息在 stderr 上。
