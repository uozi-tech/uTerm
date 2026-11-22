# 终端里的程序请 uTerm 预览文件（OSC 6975）

目标：Claude Code 在 uTerm 的 SSH 终端里写完文档、生成完图片，旁边直接显示出来，不用切出去、不用 Kitty 图片
（整屏回放、检查点、远控镜像都会把 Kitty 图片丢掉）。

## 协议

程序往终端写一条不显示的私有 OSC：

```
ESC ] 6975 ; open ; <绝对路径> BEL
```

- 路径是这个终端所连主机上的路径，UTF-8，不带控制字符，最长 4096 字节；相对路径不认（程序那边拼好）。
- 编号紧跟 6973（`terminal open` 的命令跟踪）与 6974（pty 认领）。解析在共享的 `TerminalFilePreview`
  （`uTerm/Features/Terminal/TerminalFilePreview.swift`），经影子终端的未知 OSC 出口进来
  （`ShadowTerminal.reportUnknownOSC(withPrefixes:)`，两端各自登记）。
- 不认的情况静默丢掉：历史字节里的（接回时补上的那段，影子喂历史时不报）、远控镜像（路径在被控的 Mac 上）、
  不合规矩的路径。同一个路径 0.5 秒内只认一次（`TerminalFilePreviewThrottle`：Claude 连改几处，每次 Edit 都触发）。
- 只读、只在 uTerm 里显示，不交给别的 App、不执行。SSH 上的程序能做到的，也就是让用户看到一个本来就能 `cat` 的文件。

## 两端怎么显示

| | Mac | iOS |
|---|---|---|
| 入口 | `TerminalSession.onFilePreviewRequest`（`TerminalSession+TrackedRun` 的 `handleUnknownOSC` 分出来，`TerminalSession+FilePreview`） | `MobileTerminalController.onFilePreviewRequest` |
| 接的人 | `WorkspaceModel.terminalRequestedPreview`：工作区窗口里、侧栏 SFTP 连着的那台主机上的终端进预览区；其余（纯终端窗口、工作区里别的主机的终端）在终端区开文件标签 | `MobileWorkspace.onFilePreviewRequest` → `WorkspaceScreen.showPreview` |
| 显示 | 预览区的预览（临时）标签（`FilePreviewModel.reveal(path:)`）：没开过就开、顶替上一个预览标签；开着就切过去并重读，脏的不重读。终端区：临时文件标签放在发请求那个终端旁边一格（只有一格就拆到右边），同一主机同一路径已开着就切过去并重读 | 只读预览标签（`FilePreviewTab`）：一台主机一个，换内容；放在终端旁边那一格（没分屏就拆出第二格） |
| 焦点 | 不抢编辑器焦点 | 键盘留在终端那一格 |
| 内容 | 预览区原有的一套（编辑器 / Markdown 含图片 / 图片） | 图片（可缩放）、Markdown（`MStreamingMarkdown`，图片只显示替代文字）、等宽纯文本；上限 16 MiB |

终端区的文件标签（`WorkspaceModel.openInTerminalArea`）：文件经这台主机单独的 SFTP 连接读（`makeFileProvider`，按主机缓存，
窗口关时一起关；两种窗口都用 `WorkspaceModel.liveFileProvider`），文档不进侧栏的那份列表（`FilePreviewModel.openDetached`，
标签全关了就 `releaseDetached`），也不进「最近打开」。先 stat：目录、不存在的不理。

保存：两处的文件标签都能改，改了默认自动保存（设置 › 通用 › 文件 › 自动保存，`DefaultsKey.editorAutoSave`）：
停顿 1 秒写回这个文档所在的主机（`FilePreviewModel.scheduleAutosave`）。远端在打开之后被别处改过（比如 Claude 又写了一遍）
不自动覆盖，编辑器上方出一条提示，按 ⌘S 或提示里的按钮选「覆盖 / 放弃本地改动」，选完才恢复自动保存；写失败也是一条提示，
内容留在编辑器里，下次改动或 ⌘S 再试。关最后一个引用它的标签时先存（自动保存关着就问「保存 / 不保存」），终端区的文件标签
同样，之前那里关掉会直接丢掉没存的改动。⌘S 在纯终端窗口里也认（`saveInteractively`）。

没做：Mac 本机终端（预览区只走 SFTP；沙盒也读不到用户文件）、远控镜像；关窗口 / 退出时还没到点的那一秒改动不会补存。

## ⌘ 点终端里的链接

Ghostty（`5ebe501a`）的链接正则本来就认路径：`/abs`、`./x`、`../x`、`~/x`、`$HOME/x`、带点的 `src/a.md`，可带 `:行号:列号`；
OSC 8 超链接同样。⌘ 点之后以 `open_url` 交给宿主（文字里认出来的是 `.unknown`，OSC 8 是 `.osc8`）。

- 分类在共享的 `TerminalLink`：`http` / `https` / `mailto` 交给系统；`file://主机/路径` 和不像网址的文字当路径；
  别的 scheme（`ssh:`、`tel:`、自定义）丢掉——终端里的文字谁都能写。Ghostty 自己写的临时文件（`.text` / `.html`）照旧交给它。
- 路径解析（`TerminalLinkPath` / `TerminalLinkResolver`）：绝对路径直接用；相对路径先用 shell 的 OSC 7，没报过（很多远端 shell
  不报）再问后端 `foregroundDirectories()`；`~/` 要家目录，也问后端。后端在同一条 SSH 连接上开 exec：进程表认出这个终端的前台
  进程（`RemoteProcessTable.foregroundPID`，前台是 claude 就是 claude 的目录，不是 shell 的），再读它的 cwd（Linux
  `/proc/<pid>/cwd`，macOS / BSD 退到 `lsof`）和 `$HOME`。实现了的后端：`SSHConnection`、`HeldSSHBackend`（Mac 重启不断）、
  `PersistentSSHConnection`（iOS）；其他返回 nil。限时 3 秒。
- Mac：`GhosttyTerminalBridge` 接 `TerminalSurfaceOpenURLHandlingDelegate` → `TerminalSession.openTerminalLink`。之前 Mac 没接，
  Ghostty 自己的处理会拒掉 `.unknown` 与 `.osc8`，所以 ⌘ 点网址也没反应；现在网址交给系统打开。
  `WorkspaceModel.terminalRequestedPreview` 先 stat：目录在侧栏打开，文件进预览区，不存在的不理（正文里像路径的词也会被认成链接）。
- iOS 的快捷触发：手机上没有 ⌘ 点，双击路径（Ghostty 的触摸选词只在空白、引号、括号处断开，整条路径一次选中）或长按拖选，
  编辑菜单最前面多一项「在 uTerm 中打开「文件名」」（网址是「打开「主机名」」）。选中的文字交给共享的 `TerminalLinkDetector`：
  整段像链接、或单行里恰好一个像链接的词才出这一项，两头的中英文引号、括号、句末标点去掉。之后和 ⌘ 点同一条路
  （`MGhosttyTerminalView.onOpenLink` → `openTerminalLink`）。远控镜像不出这一项（路径在被控的 Mac 上）。
- iOS：`SurfaceDelegate` 交给 `MobileTerminalController.openTerminalLink`（接了键盘和指针才 ⌘ 点得到）。之前任何 scheme 都交给
  `UIApplication.open`，现在只放行上面三种。目录 / 不存在的文件会在预览标签里显示失败，还没像 Mac 那样先 stat。
- 真 sshd 用例：`ForegroundActivityIntegrationTests.testForegroundDirectoriesFollowTheForegroundProcess`
  （`TEST_RUNNER_UTERM_TEST_FOREGROUND_SSH_PORT`，用户名密码默认 tester / tester）。

## 发请求的一方：`scripts/uterm-open`

POSIX sh，放进主机的 PATH：

```sh
uterm-open docs/plan.md out/chart.png   # 相对路径按当前目录
uterm-open --claude-hook                # Claude Code 的 PostToolUse hook：stdin 读 JSON，文档 / 图片才打开
```

- 写到 `/dev/tty`；打不开（hook 被拉起时可能没有控制终端）就顺着父进程找第一个有终端的（`ps -o tty=`）。
- tmux 里包一层 passthrough（tmux 要开 `allow-passthrough on`，否则 tmux 会吞掉）。
- hook 只认 `UTERM_OPEN_EXTENSIONS`（默认 md / markdown / mdx 与常见图片）且文件存在；JSON 用 jq → python3 → sed 解析。
- 什么都不输出、总是以 0 退出：hook 失败不该打断 Claude。自测：`bash scripts/uterm-open.test.sh`。

Claude Code 的配置（项目的 `.claude/settings.json` 或 `~/.claude/settings.json`）：

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit|MultiEdit",
        "hooks": [{ "type": "command", "command": "uterm-open --claude-hook" }]
      }
    ]
  }
}
```

未验证：hook 子进程写 pty 会不会和 Claude 自己的画面输出交错（按理一次 `write` 落在两帧之间，OSC 本身不显示）。
