#!/usr/bin/env python3
"""录制终端快照测试（TerminalSnapshotTests）用的真实程序输出语料。

在 100×30 的伪终端里驱动真实程序，把它们写给终端的原始字节存成 terminal-corpus-*.bin。
依赖：/bin/zsh、/usr/bin/vim、/usr/bin/less、Homebrew 的 htop（/opt/homebrew/bin/htop）。
可重复运行；字节不会逐字相同（时间、负载、git 历史都在变），测试只依赖它们覆盖到的特性。

刻意保持中性、不带本机环境信息：固定提示符、git 只输出哈希与标题（无作者 / 邮箱）、
htop 只监视自己起的 sleep 进程且隐藏 USER 列、vim/htop 都不读用户配置。

用法：python3 -I uTermTests/Support/Fixtures/TerminalCorpus/record.py
"""
import os, pty, sys, time, select, fcntl, termios, struct, signal, subprocess, tempfile

COLS, ROWS = 100, 30
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
SHELL_ENV = {"PROMPT": "%F{green}demo%f:%F{blue}uTerm%f %# ", "HISTFILE": "/dev/null",
             "GIT_PAGER": "cat", "PAGER": "cat"}


def run(name, argv, keys, env_extra=None, timeout=25):
    env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "TERM": "xterm-256color",
           "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "HOME": tempfile.gettempdir(),
           "COLUMNS": str(COLS), "LINES": str(ROWS)}
    env.update(env_extra or {})
    pid, fd = pty.fork()
    if pid == 0:
        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
        os.chdir(REPO)
        os.execvpe(argv[0], argv, env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    out = bytearray()
    start = time.time()
    plan = list(keys)
    next_at = start + (plan[0][0] if plan else 0)
    while time.time() - start < timeout:
        r, _, _ = select.select([fd], [], [], 0.02)
        if r:
            try:
                data = os.read(fd, 65536)
            except OSError:
                break
            if not data:
                break
            out += data
        if plan and time.time() >= next_at:
            _, k = plan.pop(0)
            os.write(fd, k)
            if plan:
                next_at = time.time() + plan[0][0]
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    os.waitpid(pid, 0)
    with open(os.path.join(HERE, f"terminal-corpus-{name}.bin"), "wb") as f:
        f.write(out)
    print(f"{name}: {len(out)} bytes")


def typed(cmds, first_delay=0.6, gap=0.35):
    return [(first_delay, b"")] + [(gap, (c + "\r").encode()) for c in cmds]


GIT_LOG = "git log --color=always --graph --decorate --format='%C(yellow)%h%Creset %s' -n 120"

# shell：彩色 ls / git log、CJK 与 emoji、组合字符、长行折行、\r 进度条、制表符、256 色与真彩、隐藏光标
run("shell", ["/bin/zsh", "-f", "-i"], typed([
    "CLICOLOR_FORCE=1 ls -laG /usr/bin | head -60",
    GIT_LOG,
    "printf '\\033[1;31m红色粗体\\033[0m 普通 \\033[4;32m下划线绿\\033[0m 😀👨‍👩‍👧 é e\\u0301 中文宽字符测试\\n'",
    "python3 -c \"print('x'*250)\"",
    "for i in $(seq 0 10 100); do printf '\\r进度 [%-20s] %3d%%' $(printf '#%.0s' $(seq 1 $((i/5+1)))) $i; sleep 0.02; done; echo",
    "printf 'a\\tb\\tc\\n\\tindent\\tmore\\n'",
    "printf '\\033[38;5;208m256色\\033[48;2;30;60;90m真彩背景\\033[0m\\033[7m反显\\033[0m\\033[9m删除线\\033[0m\\033[3m斜体\\033[0m\\n'",
    "seq 1 80",
    "printf '\\033[?25l光标已隐藏 '; sleep 0.1",
]), SHELL_ENV, timeout=12)

# vim：滚动区域、备用屏、应用光标键、分屏、插入 / 删除行、插入中文
vim_keys = [(0.8, b"")] + [(0.25, k) for k in [
    b"40j", b"\x04", b"\x04", b"\x04", b"\x15", b"/feed\r", b"n", b"n", b":vsplit\r", b"\x17w",
    b"30j", b"\x19\x19\x19", "o你好世界 emoji 😀\x1b".encode(), b"G", b"gg", b":set nonumber\r",
    b"20\x05", b":q!\r", b":q!\r"]]
run("vim", ["/usr/bin/vim", "-u", "NONE", "-N", "-c", "syntax on", "-c", "set number hlsearch",
            "uTerm/Features/Terminal/TerminalSession.swift"], vim_keys, timeout=12)

# htop：全屏高频重绘、SGR 鼠标。只看自己起的 sleep，隐藏 USER 列（字段：PID STATE CPU% MEM% TIME COMM）
sleeper = subprocess.Popen(["/bin/sleep", "60"])
htoprc_dir = tempfile.mkdtemp()
with open(os.path.join(htoprc_dir, "htoprc"), "w") as f:
    f.write("fields=0 2 46 47 49 1\nshow_program_path=0\nhighlight_base_name=1\n")
run("htop", ["/opt/homebrew/bin/htop", "-d", "5", "-p", str(sleeper.pid)],
    [(3.0, b"\x1b[B\x1b[B\x1b[B"), (1.0, b"q")],
    {"HTOPRC": os.path.join(htoprc_dir, "htoprc")}, timeout=7)
sleeper.kill()

# less：向前 / 向后翻页（反向滚动）、搜索
gitlog = os.path.join(tempfile.mkdtemp(), "gitlog.txt")
subprocess.run(f"git log --color=always --stat --format='%C(yellow)%h%Creset %C(green)%s%Creset' -n 60 > {gitlog}",
               shell=True, cwd=REPO, check=True)
run("less", ["/usr/bin/less", "-R", gitlog], [(0.6, b"")] + [(0.25, k) for k in [
    b" ", b" ", b" ", b"b", b"b", b"\x1b[B" * 5, b"\x1b[A" * 3, b"/Terminal\r", b"n", b"G", b"g", b"q"]],
    timeout=8)

# mixed：shell 输出 → DEC 画线字符集 → vim 开鼠标 → 退出回 shell 继续输出（主屏在备用屏之下）
run("mixed", ["/bin/zsh", "-f", "-i"], typed([
    "CLICOLOR_FORCE=1 ls -laG /usr/bin | head -45",
    "printf '\\033(0lqqqqqqqqk\\nx 画线框 x\\nmqqqqqqqqj'; sleep 0.3; printf '\\033(B\\n'",
    "seq 1 40",
], gap=0.4) + [
    (0.4, b"vim -u NONE -N -c 'syntax on' -c 'set mouse=a number' uTerm/Features/Terminal/TerminalSession.swift\r"),
    (0.8, b"30j"), (0.3, b"\x1b[<0;20;10M\x1b[<0;20;10m"), (0.3, b"\x04"), (0.3, b":vsplit\r"), (0.3, b"20j"),
    (0.3, b":q!\r"), (0.3, b":q!\r"), (0.5, "printf '\\033[1;35m回到 shell\\033[0m\\n'; seq 41 70\r".encode()),
    (0.5, b"")], SHELL_ENV, timeout=10)
