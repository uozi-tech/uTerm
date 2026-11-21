# 终端里的真实录制

`claude-code-<列>x<行>.raw` 是真的 Claude Code 在那个终端尺寸下输出的字节（`script -q` 录的），画廊把它原样喂给
Ghostty 终端，画出来就是真的 Claude Code 界面，不是仿写的。Claude Code 是全屏界面、按录制时的行列数用绝对坐标排版，
所以每个尺寸各录一份，喂给同样大小的终端（尺寸在画廊日志的 `term-size` 行里）。

录法（在一个只有假日志的演示目录里，干净环境，不带当前会话的 `CLAUDE_*` 变量）：

```sh
mkdir -p ~/api && cp -R <假日志与 compose 文件> ~/api/
env -i HOME="$HOME" USER="$USER" PATH=/opt/homebrew/bin:/usr/bin:/bin TERM=xterm-256color COLORTERM=truecolor \
    LANG=zh_CN.UTF-8 TZ=Asia/Shanghai \
  script -q claude-code-120x41.raw /bin/bash -c 'stty cols 120 rows 41; cd ~/api && exec claude \
    --allowedTools Read Grep Glob "Bash(tail:*)" "Bash(grep:*)" "Bash(cat:*)" "Bash(ls:*)" \
    -- "nginx 偶尔回 502，帮我看看是怎么回事。日志在 var/log 下面，服务配置在 srv/api。"'
```

对话跑完后直接结束进程（不要 /exit，退出会切回主屏，画面就没了）。录完删掉 `~/api` 和 `~/.claude.json` 里它的信任记录。
