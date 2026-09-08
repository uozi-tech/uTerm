#!/usr/bin/env bash
# testflight-notes.sh 的自测：只覆盖参数校验、无 key 的打印分支与 JWT 格式，
# **不打真网**（没有 key 时脚本压根不发请求；带假 key 的用例都走 --dry-run/--emit-jwt）。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/testflight-notes.sh"
fail=0
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# 从隔离的“仓库根”跑，免得真 .env 里的 ASC_* 漏进来（现在是空的，将来配了也不会污染）。
mkdir -p "$tmp/scripts"
cp "$SRC" "$tmp/scripts/testflight-notes.sh"
TF="$tmp/scripts/testflight-notes.sh"
# curl 换成 false：任何一次真发请求都会让用例失败，等于“没打网”的看门狗。
export TESTFLIGHT_CURL=false
export ASC_KEY_ID="" ASC_ISSUER_ID="" ASC_KEY_PATH=""

notes="$tmp/notes.md"
cat > "$notes" <<'MD'
新功能
- 加了一个能看见的东西。

修复
- 修了一个看得见的毛病。
MD

# 1) 缺 --version / --build -> 非零
if "$TF" --notes-file "$notes" >/dev/null 2>&1; then
	echo "FAIL: missing --version/--build accepted"; fail=1
else
	echo "ok: missing --version/--build rejected"
fi

# 2) 缺 --notes-file -> 非零
if "$TF" --version 1.0.0 --build 323 >/dev/null 2>&1; then
	echo "FAIL: missing --notes-file accepted"; fail=1
else
	echo "ok: missing --notes-file rejected"
fi

# 3) --notes-file 不存在 -> 非零
if "$TF" --version 1.0.0 --build 323 --notes-file "$tmp/nope.md" >/dev/null 2>&1; then
	echo "FAIL: missing notes file accepted"; fail=1
else
	echo "ok: missing notes file rejected"
fi

# 4) --notes-file 是空文件 -> 非零
: > "$tmp/empty.md"
if "$TF" --version 1.0.0 --build 323 --notes-file "$tmp/empty.md" >/dev/null 2>&1; then
	echo "FAIL: empty notes file accepted"; fail=1
else
	echo "ok: empty notes file rejected"
fi

# 5) 超过 What to Test 的 4000 字上限 -> 非零，且提示里带上限
python3 -c 'open("'"$tmp"'/long.md","w").write("字"*4001)'
if out="$("$TF" --version 1.0.0 --build 323 --notes-file "$tmp/long.md" 2>&1)"; then
	echo "FAIL: over-long notes accepted"; fail=1
else
	case "$out" in *4000*4001*) echo "ok: over-long notes rejected with the limit spelled out" ;;
		*) echo "FAIL: over-long rejection message lacks the counts: $out"; fail=1 ;; esac
fi
# 边界：正好 4000 字要过（无 key 分支，退出 0）
python3 -c 'open("'"$tmp"'/exact.md","w").write("字"*4000)'
if "$TF" --version 1.0.0 --build 323 --notes-file "$tmp/exact.md" >/dev/null 2>&1; then
	echo "ok: exactly 4000 chars is accepted"
else
	echo "FAIL: exactly 4000 chars rejected"; fail=1
fi

# 6) 没有 ASC key：退出 0，把纯文本打出来并提示手动粘贴（且没发过任何请求）
if out="$("$TF" --version 1.0.0 --build 323 --notes-file "$notes" 2>&1)"; then
	ok=1
	for needle in "was NOT written automatically" "手动粘贴" "TestFlight" "加了一个能看见的东西" "修了一个看得见的毛病"; do
		case "$out" in *"$needle"*) ;; *) echo "FAIL: no-key output missing: $needle"; ok=0 ;; esac
	done
	[ "$ok" -eq 1 ] && echo "ok: without an ASC key it prints the notes and exits 0" || fail=1
else
	echo "FAIL: no-key branch exited non-zero"; fail=1
fi

# 7) JWT 格式：用**一次性**的 P-256 key（不是任何真 key），只核结构
if ! command -v openssl >/dev/null 2>&1; then
	echo "skip: openssl not available, JWT format case skipped"
else
	openssl ecparam -genkey -name prime256v1 -noout 2>/dev/null \
		| openssl pkcs8 -topk8 -nocrypt -out "$tmp/fake.p8" 2>/dev/null
	jwt="$(ASC_KEY_ID=FAKEKEYID1 ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
		ASC_KEY_PATH="$tmp/fake.p8" "$TF" --version 1.0.0 --build 323 --emit-jwt 2>/dev/null)"
	if JWT="$jwt" python3 - <<'PY'
import base64, json, os, sys

def b64u(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))

parts = os.environ["JWT"].split(".")
assert len(parts) == 3, f"expected 3 JWT parts, got {len(parts)}"
head = json.loads(b64u(parts[0]))
assert head == {"alg": "ES256", "kid": "FAKEKEYID1", "typ": "JWT"}, head
body = json.loads(b64u(parts[1]))
assert body["aud"] == "appstoreconnect-v1", body
assert body["iss"] == "00000000-0000-0000-0000-000000000000", body
assert 0 < body["exp"] - body["iat"] <= 20 * 60, body
sig = b64u(parts[2])
assert len(sig) == 64, f"ES256 signature must be raw r||s = 64 bytes, got {len(sig)}"
PY
	then
		echo "ok: ES256 JWT has the right header/claims and a 64-byte raw signature"
	else
		echo "FAIL: JWT format is wrong"; fail=1
	fi

	# 8) --dry-run 带（假）key：只打印计划，一个请求都不发（TESTFLIGHT_CURL=false 会炸）
	if out="$(ASC_KEY_ID=FAKEKEYID1 ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
		ASC_KEY_PATH="$tmp/fake.p8" "$TF" --version 1.0.0 --build 323 \
		--notes-file "$notes" --dry-run 2>&1)"; then
		case "$out" in *"dry-run"*com.uozi.uTerm*) echo "ok: --dry-run prints the plan without calling the API" ;;
			*) echo "FAIL: --dry-run output looks wrong: $out"; fail=1 ;; esac
	else
		echo "FAIL: --dry-run exited non-zero"; fail=1
	fi

	# 9) ASC_KEY_PATH 指向不存在的 .p8 -> 当作没配 key（退出 0 并打印），不要中途炸
	if ASC_KEY_ID=FAKEKEYID1 ASC_ISSUER_ID=x ASC_KEY_PATH="$tmp/gone.p8" \
		"$TF" --version 1.0.0 --build 323 --notes-file "$notes" >/dev/null 2>&1; then
		echo "ok: a missing .p8 degrades to the print-only branch"
	else
		echo "FAIL: a missing .p8 did not degrade to the print-only branch"; fail=1
	fi
fi

# 10) 未知参数 -> 非零
if "$TF" --version 1.0.0 --build 323 --notes-file "$notes" --wat >/dev/null 2>&1; then
	echo "FAIL: unknown argument accepted"; fail=1
else
	echo "ok: unknown argument rejected"
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "TESTS FAILED"; exit 1; }
