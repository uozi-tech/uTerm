#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFY="$SCRIPT_DIR/notify-wecom.sh"
fail=0
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Run the script from an isolated repo root so the real repo .env (which provides
# WECHAT_WEBHOOK_URL) cannot leak into tests and trigger real notifications.
mkdir -p "$tmp/scripts"
cp "$NOTIFY" "$tmp/scripts/notify-wecom.sh"
NOTIFY="$tmp/scripts/notify-wecom.sh"

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

# 2b) line breaks must be a proper JSON \n escape (single backslash + n),
# NOT a literal double-backslash \\n (regression: esc() over-escaping the separator).
# Decode the JSON content and require it to contain an actual newline character.
if python3 - "$tmp/body.json" <<'PY'
import json, sys
content = json.load(open(sys.argv[1]))["markdown"]["content"]
sys.exit(0 if "\n" in content else 1)
PY
then
	echo "ok: body content has a real line break (JSON \\n escape)"
else
	echo "FAIL: body content has no real line break (separator over-escaped to literal \\\\n)"; fail=1
fi
# Belt-and-suspenders on the raw payload bytes:
# - a double-backslash escape (\\n: backslash backslash n) is the bug -> must be absent.
# - a single-backslash escape (\n: backslash n) is correct -> must be present.
if printf '%s' "$body" | grep -qF '\\n'; then
	echo "FAIL: raw payload contains over-escaped \\\\n separator"; fail=1
elif printf '%s' "$body" | grep -qF '\n'; then
	echo "ok: raw payload uses single-backslash \\n separator"
else
	echo "FAIL: raw payload has no \\n separator at all"; fail=1
fi

# 3) JSON validity when notes contains a double quote (regression: esc() over-escaping)
OUT="$tmp/body2.json" WECOM_CURL="$tmp/fakecurl" WECHAT_WEBHOOK_URL="http://example/hook" \
	"$NOTIFY" --version 1.0.1 --build 504 --url "http://x/u.dmg" --notes 'say "hi" now' >/dev/null
if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$tmp/body2.json" 2>/dev/null; then
	echo "ok: body with quotes is valid JSON"
else
	echo "FAIL: body with quotes is invalid JSON"; fail=1
fi

# 4) --platform ios: TestFlight 文案，且不再强制要求 --url
OUT="$tmp/body3.json" WECOM_CURL="$tmp/fakecurl" WECHAT_WEBHOOK_URL="http://example/hook" \
	"$NOTIFY" --platform ios --version 1.11.0 --build 314 >/dev/null
body3="$(cat "$tmp/body3.json")"
for needle in "uTermMobile" "1.11.0" "314" "TestFlight"; do
	case "$body3" in *"$needle"*) echo "ok: ios body contains $needle" ;; *) echo "FAIL: ios body missing $needle"; fail=1 ;; esac
done
case "$body3" in *"已发布"*) echo "FAIL: ios body reused the macOS DMG wording"; fail=1 ;; *) echo "ok: ios body uses the TestFlight wording" ;; esac

# 5) 未知 --platform -> 非零退出
if WECOM_CURL="$tmp/fakecurl" WECHAT_WEBHOOK_URL="http://example/hook" \
	"$NOTIFY" --platform android --version 1.0.0 --build 1 2>/dev/null; then
	echo "FAIL: unknown platform accepted"; fail=1
else
	echo "ok: unknown platform rejected"
fi

# 6) --platform macos 仍强制要求 --url
if WECOM_CURL="$tmp/fakecurl" WECHAT_WEBHOOK_URL="http://example/hook" \
	"$NOTIFY" --version 1.0.0 --build 1 2>/dev/null; then
	echo "FAIL: macos without --url accepted"; fail=1
else
	echo "ok: macos without --url rejected"
fi

# 7) --notes-file：分组正文走 markdown_v2，标题/版本行/分组标题都在
cat > "$tmp/notes.md" <<'MD'
新功能
- 加了一个能看见的东西。

性能提升
- 某处 316ms → 21ms（−93%）。
MD
OUT="$tmp/body4.json" WECOM_CURL="$tmp/fakecurl" WECHAT_WEBHOOK_URL="http://example/hook" \
	"$NOTIFY" --platform ios --version 1.0.0 --build 323 --notes-file "$tmp/notes.md" >/dev/null
if python3 - "$tmp/body4.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["msgtype"] == "markdown_v2", d["msgtype"]
c = d["markdown_v2"]["content"]
for needle in ("# uTermMobile 1.0.0 已上传 TestFlight", "版本：1.0.0 (build 323)",
               "渠道：TestFlight", "新功能", "性能提升", "316ms → 21ms"):
    assert needle in c, needle
assert "\n" in c
PY
then
	echo "ok: --notes-file sends a grouped markdown_v2 body"
else
	echo "FAIL: --notes-file body is wrong"; fail=1
fi

# 7b) 不给 --notes-file 时仍是老的一句话 markdown（回退分支没被改坏）
if python3 - "$tmp/body3.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d["msgtype"] == "markdown" else 1)
PY
then
	echo "ok: without --notes-file the one-liner stays msgtype=markdown"
else
	echo "FAIL: one-liner fallback changed msgtype"; fail=1
fi

# 7c) macOS 也能用 --notes-file，正文带下载链接
OUT="$tmp/body5.json" WECOM_CURL="$tmp/fakecurl" WECHAT_WEBHOOK_URL="http://example/hook" \
	"$NOTIFY" --version 1.11.0 --build 313 --url "http://x/uTerm-1.11.0-313.dmg" \
	--notes-file "$tmp/notes.md" >/dev/null
if python3 - "$tmp/body5.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))["markdown_v2"]["content"]
for needle in ("# uTerm 1.11.0 已发布", "下载：http://x/uTerm-1.11.0-313.dmg", "新功能"):
    assert needle in c, needle
PY
then
	echo "ok: macos --notes-file body carries the DMG link"
else
	echo "FAIL: macos --notes-file body is wrong"; fail=1
fi

# 8) --notes-file 指向不存在的文件 -> 非零退出
if WECOM_CURL="$tmp/fakecurl" WECHAT_WEBHOOK_URL="http://example/hook" \
	"$NOTIFY" --platform ios --version 1.0.0 --build 323 --notes-file "$tmp/nope.md" 2>/dev/null; then
	echo "FAIL: missing notes file accepted"; fail=1
else
	echo "ok: missing notes file rejected"
fi

# 9) --notes-file 是空文件 -> 非零退出（空正文发出去等于没发）
: > "$tmp/empty.md"
if WECOM_CURL="$tmp/fakecurl" WECHAT_WEBHOOK_URL="http://example/hook" \
	"$NOTIFY" --platform ios --version 1.0.0 --build 323 --notes-file "$tmp/empty.md" 2>/dev/null; then
	echo "FAIL: empty notes file accepted"; fail=1
else
	echo "ok: empty notes file rejected"
fi

# 10) --notes 与 --notes-file 同时给 -> 非零退出
if WECOM_CURL="$tmp/fakecurl" WECHAT_WEBHOOK_URL="http://example/hook" \
	"$NOTIFY" --platform ios --version 1.0.0 --build 323 \
	--notes 'x' --notes-file "$tmp/notes.md" 2>/dev/null; then
	echo "FAIL: --notes + --notes-file accepted"; fail=1
else
	echo "ok: --notes + --notes-file rejected"
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "TESTS FAILED"; exit 1; }
