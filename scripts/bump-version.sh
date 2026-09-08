#!/usr/bin/env bash
# Single source of truth version manager for uTerm.
# Reads / writes MARKETING_VERSION (semver X.Y.Z) in an xcconfig.
# 两个平台各有一份，靠「目标文件」参数选，而不是复制一份脚本：
#   macOS (uTerm)       -> Config/Version.xcconfig        （默认）
#   iOS   (uTermMobile) -> Config/VersionMobile.xcconfig  （--mobile）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
XCCONFIG="${VERSION_XCCONFIG:-$REPO_ROOT/Config/Version.xcconfig}"

usage() {
	cat >&2 <<'EOF'
Usage: bump-version.sh [--mobile | --file PATH] <command>
  print            Print current MARKETING_VERSION
  patch            X.Y.Z -> X.Y.(Z+1)
  minor            X.Y.Z -> X.(Y+1).0
  major            X.Y.Z -> (X+1).0.0
  set X.Y.Z        Set explicit version

Target file (默认 Config/Version.xcconfig，即 macOS 的 uTerm):
  --mobile         改用 Config/VersionMobile.xcconfig（iOS 的 uTermMobile）
  --file PATH      改用任意 xcconfig（测试用；等价的环境变量是 VERSION_XCCONFIG）
EOF
	exit 2
}

# 目标文件选项必须在命令之前。VERSION_XCCONFIG 环境变量仍然有效（自测在用），
# 显式选项优先级高于环境变量。
while [ "$#" -gt 0 ]; do
	case "${1:-}" in
		--mobile) XCCONFIG="$REPO_ROOT/Config/VersionMobile.xcconfig"; shift ;;
		--file)   [ "$#" -ge 2 ] || usage; XCCONFIG="$2"; shift 2 ;;
		*) break ;;
	esac
done

read_version() {
	if [ ! -f "$XCCONFIG" ]; then
		echo "ERROR: $XCCONFIG not found" >&2
		exit 1
	fi
	local v
	v="$(grep -E '^[[:space:]]*MARKETING_VERSION[[:space:]]*=' "$XCCONFIG" | head -n1 | sed -E 's/.*=[[:space:]]*//; s/[[:space:]]*$//')"
	if ! printf '%s' "$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
		echo "ERROR: MARKETING_VERSION in $XCCONFIG is not semver X.Y.Z: '$v'" >&2
		exit 1
	fi
	printf '%s' "$v"
}

write_version() {
	local new="$1"
	if ! printf '%s' "$new" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
		echo "ERROR: version must be X.Y.Z: '$new'" >&2
		exit 1
	fi
	local tmp
	tmp="$(mktemp "$(dirname "$XCCONFIG")/.$(basename "$XCCONFIG").XXXXXX")"
	sed -E "s/^([[:space:]]*MARKETING_VERSION[[:space:]]*=[[:space:]]*).*/\1$new/" "$XCCONFIG" > "$tmp"
	mv "$tmp" "$XCCONFIG"
	printf '%s\n' "$new"
}

cmd="${1:-}"
case "$cmd" in
	print)
		read_version; echo
		;;
	patch|minor|major)
		cur="$(read_version)"
		IFS=. read -r vmajor vminor vpatch <<EOF
$cur
EOF
		case "$cmd" in
			patch) vpatch=$((vpatch + 1)) ;;
			minor) vminor=$((vminor + 1)); vpatch=0 ;;
			major) vmajor=$((vmajor + 1)); vminor=0; vpatch=0 ;;
		esac
		write_version "$vmajor.$vminor.$vpatch"
		;;
	set)
		[ "$#" -eq 2 ] || usage
		write_version "$2"
		;;
	*)
		usage
		;;
esac
