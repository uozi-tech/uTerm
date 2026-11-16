#!/usr/bin/env bash
# build-ghostty-engine.sh 的自测。全离线、不编：只核清单解析（--dry-run）、gitconfig 过滤、补丁接入的冲突检查、
# Zig 版本校验。真的从源码编一遍要联网、约 15 分钟，用 `make engine-build ENGINE_BUILD_ARGS='--dest <临时目录>'` 手动跑。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD="$SCRIPT_DIR/build-ghostty-engine.sh"
fail=0

ok()  { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
contains() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3（输出里没有 '$2'：$1）" ;; esac; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
lock="$tmp/ENGINE.lock"
write_lock() { # [ghostty_commit]
	cat > "$lock" <<EOF
engine_version=test-engine/1
libghostty_spm_tag=9.9.9
libghostty_spm_commit=abcdef12
ghostty_commit=${1:-0123456789abcdef0123456789abcdef01234567}
zig_version=0.17.0
zig_aarch64_macos_sha256=$(printf '0%.0s' $(seq 64))
ghosttykit_zip=kit.zip
ghosttykit_sha256=$(printf '1%.0s' $(seq 64))
ghosttykit_dir=GhosttyKit.xcframework
ghosttyvt_zip=vt.zip
ghosttyvt_sha256=$(printf '2%.0s' $(seq 64))
ghosttyvt_dir=ghostty-vt.xcframework
EOF
}
mkdir -p "$tmp/ours"; printf 'diff\n' > "$tmp/ours/0023-ours.patch"
run() { UTERM_GHOSTTY_BUILD_DIR="$tmp/work" "$BUILD" --lock "$lock" --dest "$tmp/dest" --patches "$tmp/ours" "$@"; }

# 1. --dry-run 读出清单里钉住的东西，不建工作目录。
write_lock
out="$(run --dry-run 2>&1)" && ok "--dry-run 成功" || bad "--dry-run 失败：$out"
contains "$out" "engine_version=test-engine/1" "--dry-run 打印 engine_version"
contains "$out" "libghostty-spm=9.9.9 (abcdef12)" "--dry-run 打印 tag 与提交"
contains "$out" "platforms=macos,ios" "默认只编 macOS + iOS"
contains "$out" "0023-ours.patch" "--dry-run 列出我们的补丁"
contains "$out" "install=$tmp/dest" "默认装进 --dest"
[ ! -e "$tmp/work" ] && ok "--dry-run 不建工作目录" || bad "--dry-run 建了工作目录"
out="$(run --dry-run --platforms macos,ios,visionos --no-install --pack "$tmp/pack" 2>&1)"
contains "$out" "platforms=macos,ios,visionos" "--platforms 透传"
contains "$out" "install=no" "--no-install 生效"
contains "$out" "pack=$tmp/pack" "--pack 生效"

# 2. 清单不全 / ghostty_commit 不是全长：拒绝。
write_lock 0123456
if run --dry-run >/dev/null 2>&1; then bad "短的 ghostty_commit 应当失败"; else ok "短的 ghostty_commit 失败"; fi
write_lock; sed -i '' '/^zig_aarch64_macos_sha256=/d' "$lock"
out="$(run --dry-run 2>&1)" && bad "缺 zig sha256 应当失败" || contains "$out" "zig_aarch64_macos_sha256" "缺 zig sha256 时报出键名"
write_lock

# 3. UTERM_ZIG 指到版本不对的东西：拒绝。
printf '#!/bin/sh\necho 0.16.0\n' > "$tmp/fakezig"; chmod +x "$tmp/fakezig"
out="$(UTERM_ZIG="$tmp/fakezig" run --dry-run 2>&1)" && bad "版本不对的 UTERM_ZIG 应当失败" || contains "$out" "不是 Zig 0.17.0" "UTERM_ZIG 版本不对时失败"
printf '#!/bin/sh\necho 0.17.0\n' > "$tmp/fakezig"
out="$(UTERM_ZIG="$tmp/fakezig" run --dry-run 2>&1)"
contains "$out" "zig=$tmp/fakezig" "UTERM_ZIG 版本对时就用它"

# 4. gitconfig 过滤：去掉所有 url.* 小节（insteadOf / pushInsteadOf），别的原样留着；没有全局配置时给空文件。
cat > "$tmp/gitconfig.in" <<'EOF'
[user]
	name = Someone
[url "git@github.com:"]
	insteadOf = https://github.com/
[http]
	proxy = http://127.0.0.1:1
[url "ssh://git@github.com/"]
	pushInsteadOf = https://github.com/
EOF
"$BUILD" --self-test-filter-gitconfig "$tmp/gitconfig.in" "$tmp/gitconfig.out"
[ -z "$(git config --file "$tmp/gitconfig.out" --get-regexp '^url\.' || true)" ] && ok "url.* 改写全去掉了" || bad "还留着 url.* 改写"
[ "$(git config --file "$tmp/gitconfig.out" http.proxy)" = "http://127.0.0.1:1" ] && ok "代理等其余配置留着" || bad "其余配置丢了"
[ "$(git config --file "$tmp/gitconfig.out" user.name)" = "Someone" ] && ok "user 小节留着" || bad "user 小节丢了"
"$BUILD" --self-test-filter-gitconfig "$tmp/no-such-file" "$tmp/gitconfig.empty"
[ -f "$tmp/gitconfig.empty" ] && [ ! -s "$tmp/gitconfig.empty" ] && ok "没有全局配置时给空文件" || bad "没有全局配置时没给空文件"

# 5. 补丁接入：接在上游后面；同名、编号撞上、没有补丁都拒绝。
stage() { "$BUILD" --patches "$1" --self-test-stage-patches "$2"; }
mkdir -p "$tmp/up1"; touch "$tmp/up1/0001-a.sh" "$tmp/up1/0022-b.sh"
stage "$tmp/ours" "$tmp/up1" >/dev/null && [ -f "$tmp/up1/0023-ours.patch" ] && ok "我们的补丁接进上游目录" || bad "补丁没接进去"
mkdir -p "$tmp/up2"; touch "$tmp/up2/0023-upstream-new.sh"
out="$(stage "$tmp/ours" "$tmp/up2" 2>&1)" && bad "编号撞上应当失败" || contains "$out" "编号相同" "编号和上游撞上时失败并说明"
[ ! -e "$tmp/up2/0023-ours.patch" ] && ok "撞号时不往上游目录里放东西" || bad "撞号时还是放进去了"
mkdir -p "$tmp/up3"; touch "$tmp/up3/0023-ours.patch"
if stage "$tmp/ours" "$tmp/up3" >/dev/null 2>&1; then bad "同名补丁应当失败"; else ok "同名补丁失败"; fi
mkdir -p "$tmp/empty" "$tmp/up4"
out="$(stage "$tmp/empty" "$tmp/up4" 2>&1)" && bad "没有补丁应当失败" || contains "$out" "没有补丁" "我们的补丁目录空着时失败"

# 6. 仓库里那份清单（只读）：现编要的几项都在，--dry-run 能走通。
real="$REPO_ROOT/vendor/libghostty-spm/ENGINE.lock"
out="$("$BUILD" --lock "$real" --dry-run 2>&1)" && ok "仓库清单 --dry-run 走通" || bad "仓库清单 --dry-run 失败：$out"
contains "$out" "engine_version=$(sed -n 's/^engine_version=//p' "$real")" "仓库清单的 engine_version 读得出"

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "TESTS FAILED"; exit 1; }
