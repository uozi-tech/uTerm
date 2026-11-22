#!/bin/bash
# scripts/uterm-open 的自测：写出的私有 OSC、Claude Code hook 的过滤与 JSON 解析（jq / python3 / sed 三条路）。
set -u
here=$(cd "$(dirname "$0")" && pwd)
tool="$here/uterm-open"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

check() { # 名字 期望 实际
    if [ "$2" == "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; printf '  want %q\n  got  %q\n' "$2" "$3"; fail=1; fi
}

out="$work/tty"
mkdir -p "$work/docs"
: >"$work/docs/plan.md"
: >"$work/docs/shot.PNG"
: >"$work/docs/main.go"

run() { : >"$out"; UTERM_OPEN_TTY="$out" TMUX= "$@"; cat "$out"; }
esc=$'\033'; bel=$'\007'

check "绝对路径" "${esc}]6975;open;/tmp/a b.md${bel}" "$(run "$tool" "/tmp/a b.md")"
check "相对路径按当前目录" "${esc}]6975;open;$work/docs/plan.md${bel}" "$(cd "$work" && run "$tool" docs/plan.md)"
check "多个文件" "${esc}]6975;open;/a${bel}${esc}]6975;open;/b${bel}" "$(run "$tool" /a /b)"
check "没有参数什么也不写" "" "$(run "$tool")"
: >"$out"; UTERM_OPEN_TTY="$out" TMUX=/tmp/tmux-1/default,1,0 "$tool" /a
check "tmux 里包 passthrough" "${esc}Ptmux;${esc}${esc}]6975;open;/a${bel}${esc}\\" "$(cat "$out")"

hook() { printf '%s' "$1" | run "$tool" --claude-hook; }
json() { printf '{"hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"%s","content":"x"},"tool_response":{"filePath":"%s"}}' "$1" "$1"; }

check "hook：Markdown" "${esc}]6975;open;$work/docs/plan.md${bel}" "$(hook "$(json "$work/docs/plan.md")")"
check "hook：扩展名不分大小写" "${esc}]6975;open;$work/docs/shot.PNG${bel}" "$(hook "$(json "$work/docs/shot.PNG")")"
check "hook：代码文件不打开" "" "$(hook "$(json "$work/docs/main.go")")"
check "hook：文件不存在不打开" "" "$(hook "$(json "$work/docs/gone.md")")"
check "hook：没有 file_path" "" "$(hook '{"tool_name":"Bash","tool_input":{"command":"ls"}}')"
check "hook：坏 JSON" "" "$(hook 'not json')"
: >"$out"
printf '%s' "$(json "$work/docs/main.go")" | UTERM_OPEN_TTY="$out" UTERM_OPEN_EXTENSIONS="go" "$tool" --claude-hook
check "hook：UTERM_OPEN_EXTENSIONS" "${esc}]6975;open;$work/docs/main.go${bel}" "$(cat "$out")"

# 没有 jq / python3 时退回 sed：PATH 里只留基础命令。
bin="$work/bin"; mkdir -p "$bin"
for c in sh cat tr sed ps printf; do p=$(command -v "$c") && ln -sf "$p" "$bin/$c"; done
: >"$out"
json "$work/docs/plan.md" | PATH="$bin" UTERM_OPEN_TTY="$out" /bin/sh "$tool" --claude-hook
check "hook：只有 sed" "${esc}]6975;open;$work/docs/plan.md${bel}" "$(cat "$out")"

check "总是以 0 退出" "0" "$(printf 'x' | UTERM_OPEN_TTY=/nonexistent/dir/tty "$tool" --claude-hook >/dev/null 2>&1; echo $?)"

exit $fail
