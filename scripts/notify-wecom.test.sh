#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFY="$SCRIPT_DIR/notify-wecom.sh"
fail=0
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# 1) 缺 WECHAT_WEBHOOK_URL -> 非零退出
if WECHAT_WEBHOOK_URL="" "$NOTIFY" --version 1.0.1 --build 504 --url http://x/u.dmg 2>/dev/null; then
	echo "FAIL: missing webhook accepted"; fail=1
else
	echo "ok: missing webhook rejected"
fi

# 2) 正常：用假 curl 捕获 body
cat > "$tmp/fakecurl" <<'SH'
#!/usr/bin/env bash
prev=""
for a in "$@"; do
  if [ "$prev" = "--data" ] || [ "$prev" = "-d" ]; then printf '%s' "$a" > "$OUT"; fi
  prev="$a"
done
SH
chmod +x "$tmp/fakecurl"
OUT="$tmp/body.json" WECOM_CURL="$tmp/fakecurl" WECHAT_WEBHOOK_URL="http://example/hook" \
	"$NOTIFY" --version 1.0.1 --build 504 --url "http://x/uTerm-1.0.1-504.dmg" >/dev/null
body="$(cat "$tmp/body.json")"
for needle in "1.0.1" "504" "uTerm-1.0.1-504.dmg"; do
	case "$body" in *"$needle"*) echo "ok: body contains $needle" ;; *) echo "FAIL: body missing $needle"; fail=1 ;; esac
done

# 3) JSON validity when notes contains a double quote (regression: esc() over-escaping)
OUT="$tmp/body2.json" WECOM_CURL="$tmp/fakecurl" WECHAT_WEBHOOK_URL="http://example/hook" \
	"$NOTIFY" --version 1.0.1 --build 504 --url "http://x/u.dmg" --notes 'say "hi" now' >/dev/null
if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$tmp/body2.json" 2>/dev/null; then
	echo "ok: body with quotes is valid JSON"
else
	echo "FAIL: body with quotes is invalid JSON"; fail=1
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "TESTS FAILED"; exit 1; }
