# 终端会话（`terminals` / `terminal …`）

客户端怎么定位、探活怎么做、主机怎么指定、错误码总表都在 `SKILL.md`，这里不重复。

这一面碰的是**用户正在看的窗口**，与 `run` 那种「命令行自己另开一条连接」完全
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
- 想拿一条命令的**完整**输出，用 `run` —— 那条路有明确的开始和结束、
  有退出码、输出不会被屏幕高度截掉。
- 屏幕上是 TUI（`top`、`htop`、`vim`、`less`）时，读到的是那一帧的画面，带着大量
  对齐空格，解析它没有意义 —— 直接把画面转述给用户就行。

## 注入文本

```sh
"$UTERMCTL" terminal send -t 7A2B "systemctl status nginx" --enter
```

把文本写进那个会话的 PTY，`--enter` 追加回车。归「允许执行命令与写入」开关管。

文本以 `-` 开头时会被客户端当成选项，在它前面加 `--`（`terminal send -t 7A2B -- "-h"`）。
要按控制键就发对应的控制字符，比如 Ctrl-C 是 `$'\x03'`、`q` 退出 `less` 就发 `q`。

**这是 uTerm 命令行里最容易造成意外的动作**，三条性质必须记住：

1. **没有输出边界。** 你拿不到这条命令的输出，也不知道它什么时候跑完。只能过一会儿
   `terminal read` 看屏幕，而那是快照。
2. **与用户的键入交错。** 用户可能正在那个会话里打字，你注入的文本会插在他打了一半
   的行里。`isKeyWindowFocused: true` 的会话尤其危险。
3. **可能落在意想不到的上下文里。** 那个会话可能正停在 `vim`、`less`、`sudo` 的
   密码提示、另一台机器的嵌套 ssh、或某个 REPL 里。你的「命令」会被当成那个上下文的
   输入。发之前先 `terminal read` 看一眼提示符。

所以 **`send` 之前一律先问用户**，即使开关已经开着。问的时候把三件事讲清楚：往哪个
会话（`serverName` + `title`）、发什么、`--enter` 会不会立刻执行。

## 跑要人交互的命令：sudo 密码、确认提示、安装向导

`run` 没有 stdin，碰上要输入的命令只能卡到超时。这类命令开个窗口跑，让用户
在窗口里自己操作，你只等结果：

```sh
# 1. 开窗口并在里面跑（-- 之后原样拼成一条命令；或用 -c "整串"）
"$UTERMCTL" terminal open -H mac-01 -- sudo /bin/zsh -f ./bootstrap.zsh --only-root-entry
#    → terminals[0].id 是这个窗口的会话；run.state = "pending"

# 2. 在对话里告诉用户：mac-01 的窗口已经开了，请在里面输 sudo 密码

# 3. 等它跑完：拿退出码与输出
"$UTERMCTL" terminal wait -t 7A2B --format table
```

- 命令在连上后**照原样打进用户的登录 shell**，用户在窗口里看得到自己在跑什么，密码、`[Y/n]`
  都由他在窗口里输。**不要**让用户把密码发到对话里，也不要把密码写进命令（`echo pw | sudo -S`）。
- 打进去的那一行前后各带一个 `printf`（发不可见的标记，uTerm 靠它认出命令的起止和退出码），
  用户在窗口里会看到这两段 —— 正常，提前跟用户说一声即可。
- 命令包在子 shell `( … )` 里跑：命令里的 `exit N` 只结束这条命令（退出码照样拿到），窗口还在；
  反过来，命令里的 `cd` / `export` 也不会留在窗口里。
- `terminal wait` 默认最多等 90 秒（`--wait` 可调，封顶 1800），没跑完就回 `run.state: "running"`
  和到目前为止的输出，再调一次接着等。用户可能正在输密码，别催，也别中途 `send` 东西进去。
- `run` 里的字段：`state` 是 `pending`（还没连上 / 还没开始，可能卡在首连或主机密钥确认）、
  `running`、`finished`、`disconnected`（没跑完窗口就关了或连接断了，拿不到退出码）；
  `exitCode` 只在 `finished` 时有；`output` 是命令开始以来窗口里的输出（超过 64 KB 只给最后
  一段，`truncated: true`）。
- 只支持单行命令、最长 4096 字节（超了回 `invalid_request`）：多条用 `&&` / `;` 连起来，
  长脚本先用 `sftp put` 传到主机上再跑。
  退出码靠 `$?`，登录 shell 要是 bash / zsh / sh 一类；fish、tcsh 拿不到（`terminal read` 看屏幕判断）。
- 几台机器就开几个窗口，各自 `terminal wait`。一个会话只跟踪最近一条这样跑的命令；
  对没用 `terminal open -- 命令` 跑过命令的会话 `terminal wait` 回 `invalid_request`。
- 开窗成功但命令 6 秒内没在会话里登记上（首连慢、卡在主机密钥确认）时回
  `operation_failed`：**窗口已经开了，命令没跑**。先 `terminals` 找到那个会话、读屏
  看卡在哪，别再 `open` 一遍。
- `terminal wait` 占一个长请求槽位（与传输共用 8 个），别同时挂太多。
- 开窗口会在用户屏幕上弹窗，和普通 `terminal open` 一样**先问用户**；命令有破坏性的照样先确认。

## 什么时候别用 send

| 想干的事 | 该用 |
|---|---|
| 拿一条命令的输出、判断成败 | `run`（有退出码、有完整输出） |
| 在多台机器上跑同一条命令 | `run-many` |
| 传文件 | `sftp get` / `sftp put` |
| 跑要输入的命令（`sudo` 要密码、`[Y/n]`、安装向导）并拿到结果 | `terminal open -H <主机> -- <命令>` + `terminal wait` |
| 让用户**看着**一条命令在他自己的终端里跑 | `terminal send` |
| 用户已经在会话里跑着交互程序，需要按个键 | `terminal send`（先读屏确认状态） |

一句话：**要结果就用 `run`，要人交互就 `terminal open -- 命令` 再 `terminal wait`，要让人看见才用 `send`。**

## 开新窗口

```sh
"$UTERMCTL" terminal open -H prod-web
```

给一台主机开一个新的终端窗口并连上，返回的 `terminals` 里是那条新会话。这会在用户
屏幕上弹出窗口（后台实例也会把界面带到前台），**先问用户**再开，也别一次开一堆。
归「允许执行命令与写入」开关管；`sftpOnly` 的主机会被拒（`host_sftp_only`）。

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

其余错误码见 `SKILL.md`。
