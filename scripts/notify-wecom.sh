#!/usr/bin/env bash
# Send a uTerm release notification to a WeCom (企业微信) group webhook.
# Reads WECHAT_WEBHOOK_URL from the environment (or repo-root .env).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CURL="${WECOM_CURL:-curl}"

version=""; build=""; url=""; notes=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--version) version="$2"; shift 2 ;;
		--build)   build="$2";   shift 2 ;;
		--url)     url="$2";     shift 2 ;;
		--notes)   notes="$2";   shift 2 ;;
		-h|--help) echo "Usage: $0 --version X.Y.Z --build N --url DMG_URL [--notes TEXT]"; exit 0 ;;
		*) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
	esac
done

# Allow .env to provide the webhook when not already exported.
if [ -z "${WECHAT_WEBHOOK_URL:-}" ] && [ -f "$REPO_ROOT/.env" ]; then
	set -a; . "$REPO_ROOT/.env"; set +a
fi
if [ -z "${WECHAT_WEBHOOK_URL:-}" ]; then
	echo "ERROR: WECHAT_WEBHOOK_URL is not set (export it or add to .env)." >&2
	exit 1
fi
if [ -z "$version" ] || [ -z "$build" ] || [ -z "$url" ]; then
	echo "ERROR: --version, --build and --url are required." >&2
	exit 1
fi

content="uTerm $version (build $build) 已发布\n下载：$url"
if [ -n "$notes" ]; then content="$content\n更新：$notes"; fi

# Build markdown payload. Escape backslashes/quotes for JSON safety.
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
payload="{\"msgtype\":\"markdown\",\"markdown\":{\"content\":\"$(esc "$content")\"}}"

"$CURL" --fail --silent --show-error \
	--request POST \
	--header "Content-Type: application/json" \
	--data "$payload" \
	"$WECHAT_WEBHOOK_URL"
echo
echo "WeCom notification sent."
