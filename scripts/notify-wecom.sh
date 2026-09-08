#!/usr/bin/env bash
# Send a uTerm release notification to a WeCom (企业微信) group webhook.
# Reads WECHAT_WEBHOOK_URL from the environment (or repo-root .env).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CURL="${WECOM_CURL:-curl}"

# --platform macos (default) 是 DMG 发布，必须给 --url；
# --platform ios 是 TestFlight 上传，没有可下载链接，--url 可省。
version=""; build=""; url=""; notes=""; platform="macos"
while [ "$#" -gt 0 ]; do
	case "$1" in
		--version)  version="$2";  shift 2 ;;
		--build)    build="$2";    shift 2 ;;
		--url)      url="$2";      shift 2 ;;
		--notes)    notes="$2";    shift 2 ;;
		--platform) platform="$2"; shift 2 ;;
		-h|--help) echo "Usage: $0 --version X.Y.Z --build N [--platform macos|ios] [--url DMG_URL] [--notes TEXT]"; exit 0 ;;
		*) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
	esac
done
case "$platform" in
	macos|ios) ;;
	*) echo "ERROR: --platform must be macos or ios (got: $platform)." >&2; exit 1 ;;
esac

# Allow .env to provide the webhook when not already exported.
if [ -z "${WECHAT_WEBHOOK_URL:-}" ] && [ -f "$REPO_ROOT/.env" ]; then
	set -a; . "$REPO_ROOT/.env"; set +a
fi
if [ -z "${WECHAT_WEBHOOK_URL:-}" ]; then
	echo "ERROR: WECHAT_WEBHOOK_URL is not set (export it or add to .env)." >&2
	exit 1
fi
if [ -z "$version" ] || [ -z "$build" ]; then
	echo "ERROR: --version and --build are required." >&2
	exit 1
fi
if [ "$platform" = "macos" ] && [ -z "$url" ]; then
	echo "ERROR: --url is required for --platform macos." >&2
	exit 1
fi

if [ "$platform" = "ios" ]; then
	content="uTermMobile $version (build $build) 已上传 TestFlight"
	if [ -n "$url" ]; then content="$content
链接：$url"; fi
else
	content="uTerm $version (build $build) 已发布
下载：$url"
fi
if [ -n "$notes" ]; then content="$content
更新：$notes"; fi

# Build markdown payload. Escape backslashes/quotes for JSON safety, then turn
# real newlines into the JSON \n escape (single backslash + n) as the LAST step
# so WeCom renders line breaks instead of literal backslash-n.
# 注意换行合并用 `$!{N;ba}` 而不是裸 `N` —— macOS 是 BSD sed，在**最后一行**执行 `N`
# 会不打印 pattern space 直接退出（GNU sed 会打印）。单行 content（iOS 的 TestFlight
# 文案就是单行）走裸 `N` 会被整条吞掉，payload 变成空字符串。
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | sed -e ':a' -e '$!{N;ba' -e '}' -e 's/\n/\\n/g'; }
payload="{\"msgtype\":\"markdown\",\"markdown\":{\"content\":\"$(esc "$content")\"}}"

"$CURL" --fail --silent --show-error \
	--request POST \
	--header "Content-Type: application/json" \
	--data "$payload" \
	"$WECHAT_WEBHOOK_URL"
echo
echo "WeCom notification sent."
