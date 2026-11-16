#!/usr/bin/env bash
# 按 vendor/libghostty-spm/ENGINE.lock 把终端引擎的两个 xcframework 放进 vendor/libghostty-spm/BinaryTarget/。
#
# 二进制不进版本库（GhosttyKit 解开约 200 MB）。清单里记着每个 zip 的文件名和 sha256；这个脚本从本地目录取 zip、
# 校验、解开。已经是清单要的那一份就什么都不做（看 BinaryTarget/<目录>.stamp 里记的 sha256），所以可以挂在每次构建前面。
#
#   fetch-ghostty-engine.sh              取 / 校验 / 解开；已是最新时不动
#   fetch-ghostty-engine.sh --check      只核对，不改任何东西；不是最新就非零退出
#   fetch-ghostty-engine.sh --print KEY  打印清单里某一项的值（例如 engine_version）
#
# zip 从哪来：默认 <workspace>/uTerm-ghostty-artifacts/2026-11-15，环境变量 UTERM_GHOSTTY_ARTIFACTS 或 --from 可改。
# 清单里的 download_base 现在只是待办（还没上传），这里不联网。
# 本机现编的（scripts/build-ghostty-engine.sh，stamp 是 `local-build <engine_version>`）也算就位：和清单的 engine_version
# 一致就不动、不去找 zip。zip 找不到时退出码是 3（其余错误是 1），`make engine` 据此退到现编。
# 测试用：--lock PATH 换清单，--dest PATH 换输出目录。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCK="$REPO_ROOT/vendor/libghostty-spm/ENGINE.lock"
DEST="$REPO_ROOT/vendor/libghostty-spm/BinaryTarget"
FROM="${UTERM_GHOSTTY_ARTIFACTS:-<workspace>/uTerm-ghostty-artifacts/2026-11-15}"
MODE=fetch
PRINT_KEY=

usage() {
	cat >&2 <<'EOF'
Usage: fetch-ghostty-engine.sh [--check | --print KEY] [--from DIR] [--lock PATH] [--dest DIR]
  （无参数）     按 ENGINE.lock 取 zip、校验 sha256、解到 BinaryTarget/；已是最新时不动
  --check        只核对 BinaryTarget/ 是不是清单要的那一份，不改任何东西
  --print KEY    打印清单里 KEY 的值
  --from DIR     zip 所在的目录（默认读环境变量 UTERM_GHOSTTY_ARTIFACTS）
  --lock PATH    换一份清单（测试用）
  --dest DIR     换输出目录（测试用）
EOF
	exit 2
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--check) MODE=check; shift ;;
		--print) [ "$#" -ge 2 ] || usage; MODE=print; PRINT_KEY="$2"; shift 2 ;;
		--from)  [ "$#" -ge 2 ] || usage; FROM="$2"; shift 2 ;;
		--lock)  [ "$#" -ge 2 ] || usage; LOCK="$2"; shift 2 ;;
		--dest)  [ "$#" -ge 2 ] || usage; DEST="$2"; shift 2 ;;
		*) usage ;;
	esac
done

die() { echo "fetch-ghostty-engine: $*" >&2; exit 1; }

[ -f "$LOCK" ] || die "找不到清单 $LOCK"

# 读清单里的一项；没有这一项时输出空串。值里不带引号，等号后面原样取（去掉行尾空白）。
lock_value() {
	sed -n -E "s/^$1=(.*)$/\1/p" "$LOCK" | head -n1 | sed -E 's/[[:space:]]+$//'
}

if [ "$MODE" = print ]; then
	value="$(lock_value "$PRINT_KEY")"
	[ -n "$value" ] || die "清单 $LOCK 里没有 $PRINT_KEY"
	printf '%s\n' "$value"
	exit 0
fi

sha256_of() { /usr/bin/shasum -a 256 "$1" | awk '{print $1}'; }

# 一个二进制是不是已经就位：目录是真目录（不是软链）、里面有 Info.plist、旁边的 stamp 记的是清单里的 sha256，
# 或者是本机按清单的 engine_version 现编的（`local-build <engine_version>`）。
is_current() {
	local dir="$1" sha="$2" stamp
	[ -d "$DEST/$dir" ] && [ ! -L "$DEST/$dir" ] && [ -f "$DEST/$dir/Info.plist" ] && [ -f "$DEST/$dir.stamp" ] || return 1
	stamp="$(cat "$DEST/$dir.stamp")"
	[ "$stamp" = "$sha" ] || [ "$stamp" = "local-build $(lock_value engine_version)" ]
}

fetch_one() {
	local id="$1" zip sha dir
	zip="$(lock_value "${id}_zip")"
	sha="$(lock_value "${id}_sha256")"
	dir="$(lock_value "${id}_dir")"
	[ -n "$zip" ] && [ -n "$sha" ] && [ -n "$dir" ] || die "清单 $LOCK 里 ${id}_zip / ${id}_sha256 / ${id}_dir 不全"
	case "$sha" in *[!0-9a-f]*) die "清单里 ${id}_sha256 不是小写十六进制：$sha" ;; esac
	[ "${#sha}" -eq 64 ] || die "清单里 ${id}_sha256 不是 64 位：$sha"
	case "$dir" in */*|.*) die "清单里 ${id}_dir 不能带路径：$dir" ;; esac
	case "$dir" in *.xcframework) ;; *) die "清单里 ${id}_dir 要以 .xcframework 结尾：$dir" ;; esac

	if is_current "$dir" "$sha"; then
		case "$(cat "$DEST/$dir.stamp")" in
			local-build*) echo "$dir 是本机现编的 $(lock_value engine_version)" ;;
			*) echo "$dir 已是清单要的那一份（${sha:0:12}…）" ;;
		esac
		return 0
	fi
	if [ "$MODE" = check ]; then
		echo "fetch-ghostty-engine: $DEST/$dir 不是清单要的那一份，跑 make engine" >&2
		stale=1
		return 0
	fi

	local src="$FROM/$zip"
	if [ ! -f "$src" ]; then
		echo "fetch-ghostty-engine: 找不到 $src
  清单要 ${zip}（sha256 ${sha}）。
  把它放进 ${FROM}，或者用 UTERM_GHOSTTY_ARTIFACTS=<目录> 指到放 zip 的地方再跑一次；
  或者从上游源码现编：make engine-build（scripts/build-ghostty-engine.sh）。" >&2
		exit 3
	fi
	local actual
	actual="$(sha256_of "$src")"
	[ "$actual" = "$sha" ] || die "$src 的 sha256 对不上
  清单：$sha
  实际：$actual
  不解包。zip 换过的话，连同 ENGINE.lock 的 engine_version 和 TerminalEngineVersion.current 一起改。"

	mkdir -p "$DEST"
	local work
	work="$(mktemp -d "$DEST/.fetch.XXXXXX")"
	# shellcheck disable=SC2064
	trap "rm -rf '$work'" EXIT
	/usr/bin/ditto -x -k "$src" "$work"
	# zip 里只有一个顶层的 .xcframework 目录；名字不一定和 dir 相同，落地时统一改名。
	local found
	found="$(find "$work" -mindepth 1 -maxdepth 1 -type d -name '*.xcframework' | head -n2)"
	[ -n "$found" ] && [ "$(printf '%s\n' "$found" | wc -l | tr -d ' ')" = 1 ] \
		|| die "$src 里不是正好一个顶层的 .xcframework 目录"
	[ -f "$found/Info.plist" ] || die "$src 解出来的 $(basename "$found") 里没有 Info.plist"

	rm -f "$DEST/$dir.stamp"
	rm -rf "${DEST:?}/$dir"          # 旧的一份；评估期留下的软链也在这里拿掉（rm 不跟软链）
	mv "$found" "$DEST/$dir"
	printf '%s\n' "$sha" > "$DEST/$dir.stamp"
	rm -rf "$work"
	trap - EXIT
	echo "$dir ← ${src}（${sha:0:12}…）"
}

# 不写成 `fetch_one … || …`：那样函数体里 set -e 失效，解包或改名中途失败会接着往下走、写出一个假的 stamp。
stale=0
for id in ghosttykit ghosttyvt; do
	fetch_one "$id"
done
exit "$stale"
