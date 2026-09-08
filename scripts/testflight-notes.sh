#!/usr/bin/env bash
# 把一份 Markdown 发布日志写进 TestFlight 的「测试信息 / What to Test」
# （App Store Connect 的 betaBuildLocalizations.whatsNew）。
#
# 配了 .env 里的 ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH 就走 App Store Connect API
# 自动写入：按 build 号找到构建 → 等它处理完（processingState=VALID）→ 建或改对应
# locale 的 betaBuildLocalization。没配 key 就退化成「把纯文本打印出来」，由人去
# App Store Connect 手动粘贴——这条分支照样是成功退出（0），发版流程不该被它卡住。
#
# JWT（ES256）用 python3 标准库 + openssl 签，不引任何第三方依赖：openssl 出的是
# DER 编码的 ECDSA 签名，JWS 要的是裸 r||s 各 32 字节，脚本里自己转。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CURL="${TESTFLIGHT_CURL:-curl}"
ASC_API="${ASC_API_BASE:-https://api.appstoreconnect.apple.com}"

version=""; build=""; notes_file=""
bundle_id="${TESTFLIGHT_BUNDLE_ID:-com.uozi.uTerm}"
locale="zh-Hans"
timeout=900           # 等 ASC 处理构建的上限，秒（默认 ~15 分钟）
poll=30               # 轮询间隔，秒
dry_run=0; emit_jwt=0
# What to Test 的长度上限（App Store Connect 侧的硬限制）。
max_chars=4000

usage="Usage: $0 --version X.Y.Z --build N --notes-file FILE
          [--bundle-id ID] [--locale zh-Hans] [--timeout SECONDS] [--poll SECONDS]
          [--dry-run] [--emit-jwt]"
while [ "$#" -gt 0 ]; do
	case "$1" in
		--version)    version="$2";    shift 2 ;;
		--build)      build="$2";      shift 2 ;;
		--notes-file) notes_file="$2"; shift 2 ;;
		--bundle-id)  bundle_id="$2";  shift 2 ;;
		--locale)     locale="$2";     shift 2 ;;
		--timeout)    timeout="$2";    shift 2 ;;
		--poll)       poll="$2";       shift 2 ;;
		--dry-run)    dry_run=1;       shift ;;
		# 自测用：只生成并打印 JWT 然后退出。对**真** key 用会把可用于 ASC API 的
		# 令牌打到终端上，只在 scripts/testflight-notes.test.sh 的假 key 上用。
		--emit-jwt)   emit_jwt=1;      shift ;;
		-h|--help) echo "$usage"; exit 0 ;;
		*) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
	esac
done

if [ -z "$version" ] || [ -z "$build" ]; then
	echo "ERROR: --version and --build are required." >&2; exit 1
fi
if [ "$emit_jwt" -eq 0 ]; then
	if [ -z "$notes_file" ]; then echo "ERROR: --notes-file is required." >&2; exit 1; fi
	[ -f "$notes_file" ] || { echo "ERROR: --notes-file not found: $notes_file" >&2; exit 1; }
	[ -s "$notes_file" ] || { echo "ERROR: --notes-file is empty: $notes_file" >&2; exit 1; }
	chars="$(python3 -c 'import sys; print(len(open(sys.argv[1], encoding="utf-8").read()))' "$notes_file")"
	if [ "$chars" -gt "$max_chars" ]; then
		echo "ERROR: What to Test is limited to $max_chars characters; $notes_file has $chars." >&2
		echo "  砍掉工程内务条目或合并性能条目，不要靠截断——截断会把「前 → 后」的数字切一半。" >&2
		exit 1
	fi
fi
case "$timeout$poll" in *[!0-9]*) echo "ERROR: --timeout/--poll must be integers." >&2; exit 1 ;; esac
[ "$poll" -gt 0 ] || { echo "ERROR: --poll must be > 0." >&2; exit 1; }

# .env 只在环境里没有时才读（CI 里可以直接 export）。
if [ -z "${ASC_KEY_ID:-}${ASC_ISSUER_ID:-}${ASC_KEY_PATH:-}" ] && [ -f "$REPO_ROOT/.env" ]; then
	set -a; . "$REPO_ROOT/.env"; set +a
fi
have_key=1
for v in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH; do
	eval "val=\${$v:-}"
	[ -n "$val" ] || have_key=0
done
[ "$have_key" -eq 1 ] && [ -f "${ASC_KEY_PATH:-/nonexistent}" ] || have_key=0

if [ "$have_key" -eq 0 ]; then
	if [ "$emit_jwt" -eq 1 ]; then
		echo "ERROR: --emit-jwt needs ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH." >&2; exit 1
	fi
	cat <<TXT
No App Store Connect API key (ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH), so the
TestFlight "What to Test" was NOT written automatically.

手动粘贴：App Store Connect → App「uTerm」→ TestFlight → iOS 构建 $version ($build)
→ 测试信息 / What to Test（语言 $locale），内容如下（也在 $notes_file）：

--- 8< --- What to Test ($chars/$max_chars chars) --- 8< ---
TXT
	cat "$notes_file"
	echo "--- 8< --- end --- 8< ---"
	exit 0
fi

# ---------- JWT（ES256，python3 stdlib + openssl） ----------
mint_jwt() {
	ASC_KEY_ID="$ASC_KEY_ID" ASC_ISSUER_ID="$ASC_ISSUER_ID" ASC_KEY_PATH="$ASC_KEY_PATH" \
	python3 - <<'PY'
import base64, json, os, subprocess, sys, time

def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=")

kid, iss, key = os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"], os.environ["ASC_KEY_PATH"]
now = int(time.time())
header = {"alg": "ES256", "kid": kid, "typ": "JWT"}
# ASC 要求 exp 不超过签发后 20 分钟。
payload = {"iss": iss, "iat": now, "exp": now + 19 * 60, "aud": "appstoreconnect-v1"}
signing_input = b".".join(
    b64u(json.dumps(x, separators=(",", ":")).encode()) for x in (header, payload)
)
der = subprocess.run(
    ["openssl", "dgst", "-sha256", "-sign", key, "-binary"],
    input=signing_input, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
)
if der.returncode != 0:
    sys.stderr.write("ERROR: openssl could not sign with ASC_KEY_PATH.\n")
    sys.stderr.write(der.stderr.decode(errors="replace"))
    sys.exit(1)

def der_to_raw(sig, size=32):
    # SEQUENCE { INTEGER r, INTEGER s } -> r||s，各定长 size 字节（JWS ES256 要求）。
    if sig[0] != 0x30:
        raise ValueError("not a DER SEQUENCE")
    i = 2 if sig[1] < 0x80 else 2 + (sig[1] & 0x7F)
    out = b""
    for _ in range(2):
        if sig[i] != 0x02:
            raise ValueError("not a DER INTEGER")
        ln = sig[i + 1]
        v = sig[i + 2 : i + 2 + ln].lstrip(b"\x00")
        out += v.rjust(size, b"\x00")
        i += 2 + ln
    return out

sys.stdout.write((signing_input + b"." + b64u(der_to_raw(der.stdout))).decode())
PY
}

if [ "$emit_jwt" -eq 1 ]; then
	echo "WARNING: printing an App Store Connect API token; only do this with a throwaway key." >&2
	mint_jwt; echo
	exit 0
fi

# 令牌只经过 600 权限的 curl 配置文件，不进 argv（`ps` 看不到）。
cfg="$(mktemp)"; body="$(mktemp)"
trap 'rm -f "$cfg" "$body"' EXIT
chmod 600 "$cfg"

# asc <METHOD> <PATH-or-URL> [JSON_BODY_FILE]；成功时 body 落在 $body，返回 HTTP 码。
asc() {
	local method="$1" path="$2" data="${3:-}" url code
	case "$path" in http*) url="$path" ;; *) url="$ASC_API$path" ;; esac
	printf 'header = "Authorization: Bearer %s"\n' "$(mint_jwt)" > "$cfg"
	if [ -n "$data" ]; then
		code="$("$CURL" -sS --config "$cfg" -X "$method" \
			-H 'Content-Type: application/json' --data-binary "@$data" \
			-o "$body" -w '%{http_code}' "$url")"
	else
		code="$("$CURL" -sS --config "$cfg" -X "$method" -o "$body" -w '%{http_code}' "$url")"
	fi
	printf '%s' "$code"
}

jq_get() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); exec(sys.argv[2])' "$body" "$1"; }

die_http() {
	local code="$1" what="$2"
	echo "ERROR: $what failed (HTTP $code)." >&2
	python3 - "$body" <<'PY' >&2 || true
import json, sys
try:
    for e in json.load(open(sys.argv[1])).get("errors", []):
        print("  -", e.get("status"), e.get("code"), e.get("title"), "|", e.get("detail"))
except Exception:
    print("  (response was not JSON)")
PY
	case "$code" in
		401|403) echo "  401/403 通常是 key 过期、被吊销，或这把 key 的角色不够（要能改 TestFlight 的角色，App Manager 及以上）。" >&2 ;;
	esac
	exit 1
}

if [ "$dry_run" -eq 1 ]; then
	echo "dry-run: 会用 key $ASC_KEY_ID 在 $ASC_API 上"
	echo "  1) 按 bundle id $bundle_id 找 App"
	echo "  2) 找 build $build（版本字串 $version），等 processingState=VALID（上限 ${timeout}s）"
	echo "  3) 写 locale $locale 的 whatsNew（$chars/$max_chars chars，来自 $notes_file）"
	exit 0
fi

echo "App Store Connect: 查 App $bundle_id …"
code="$(asc GET "/v1/apps?filter%5BbundleId%5D=$bundle_id&limit=1&fields%5Bapps%5D=bundleId,name")"
[ "$code" = "200" ] || die_http "$code" "apps lookup"
app_id="$(jq_get 'print(d["data"][0]["id"] if d.get("data") else "")')"
if [ -z "$app_id" ]; then
	echo "ERROR: App Store Connect 里没有 bundle id $bundle_id 的 App 记录。" >&2
	exit 1
fi
echo "  App id: $app_id"

echo "等构建 $version ($build) 处理完成（上限 ${timeout}s，每 ${poll}s 查一次）…"
deadline=$(( $(date +%s) + timeout ))
build_id=""; state=""
while :; do
	code="$(asc GET "/v1/builds?filter%5Bapp%5D=$app_id&filter%5Bversion%5D=$build&limit=1&fields%5Bbuilds%5D=version,processingState")"
	[ "$code" = "200" ] || die_http "$code" "builds lookup"
	build_id="$(jq_get 'print(d["data"][0]["id"] if d.get("data") else "")')"
	state="$(jq_get 'print(d["data"][0]["attributes"].get("processingState","") if d.get("data") else "")')"
	case "$state" in
		VALID) echo "  build $build_id 已就绪（VALID）"; break ;;
		FAILED|INVALID)
			echo "ERROR: 构建 $build 的处理状态是 $state，不能写测试信息。去 App Store Connect 看具体原因。" >&2
			exit 1 ;;
	esac
	if [ "$(date +%s)" -ge "$deadline" ]; then
		if [ -z "$build_id" ]; then
			echo "ERROR: 等了 ${timeout}s 仍找不到 build $build。" >&2
			echo "  常见原因：上传后 ASC 还没收完（再等等重跑）；或 build 号对不上——" >&2
			echo "  ASC 上 App Store 版本字串是「1.0」而我们的 MOBILE_VERSION 是「$version」，" >&2
			echo "  TestFlight 只认 build 号，所以真正要核的是 CFBundleVersion == $build。" >&2
		else
			echo "ERROR: 等了 ${timeout}s，构建 $build 仍是 $state。稍后用同样的命令重跑即可。" >&2
		fi
		exit 1
	fi
	echo "  processingState=${state:-未出现}，${poll}s 后重试…"
	sleep "$poll"
done

echo "写 What to Test（locale $locale）…"
code="$(asc GET "/v1/builds/$build_id/betaBuildLocalizations?limit=50&fields%5BbetaBuildLocalizations%5D=locale,whatsNew")"
[ "$code" = "200" ] || die_http "$code" "betaBuildLocalizations lookup"
loc_id="$(jq_get "print(next((x['id'] for x in d.get('data',[]) if x['attributes'].get('locale')=='$locale'), ''))")"

req="$(mktemp)"; trap 'rm -f "$cfg" "$body" "$req"' EXIT
python3 - "$notes_file" "$locale" "$build_id" "$loc_id" > "$req" <<'PY'
import json, sys
notes, locale, build_id, loc_id = sys.argv[1:5]
whats_new = open(notes, encoding="utf-8").read().strip()
if loc_id:
    body = {"data": {"type": "betaBuildLocalizations", "id": loc_id,
                     "attributes": {"whatsNew": whats_new}}}
else:
    body = {"data": {"type": "betaBuildLocalizations",
                     "attributes": {"whatsNew": whats_new, "locale": locale},
                     "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}}
json.dump(body, sys.stdout, ensure_ascii=False)
PY

if [ -n "$loc_id" ]; then
	code="$(asc PATCH "/v1/betaBuildLocalizations/$loc_id" "$req")"
	[ "$code" = "200" ] || die_http "$code" "betaBuildLocalizations update"
	echo "已更新 $locale 的 What to Test（betaBuildLocalization $loc_id）。"
else
	code="$(asc POST "/v1/betaBuildLocalizations" "$req")"
	[ "$code" = "201" ] || die_http "$code" "betaBuildLocalizations create"
	echo "已写入 $locale 的 What to Test（新建 betaBuildLocalization）。"
fi
