#!/usr/bin/env bash
# fetch-ghostty-engine.sh 的自测。全离线：在临时目录里造两个假的 xcframework zip 和一份清单，不碰仓库里的 BinaryTarget/，
# 也不需要真的引擎二进制。最后只读地核一遍仓库里那份 ENGINE.lock 的形状。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FETCH="$SCRIPT_DIR/fetch-ghostty-engine.sh"
fail=0

ok()   { echo "ok: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3（要 '$2'，实际 '$1'）"; fi; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
src="$tmp/artifacts"; dest="$tmp/BinaryTarget"; lock="$tmp/ENGINE.lock"
mkdir -p "$src"

# 造一个假的 xcframework zip：顶层目录名可以和落地的目录名不同（真的 GhosttyKit-0023 那份 zip 就是这样的关系）。
make_zip() { # <zip 文件名> <zip 里的顶层目录名> <内容标记>
	local stage="$tmp/stage.$RANDOM"
	mkdir -p "$stage/$2/macos-arm64"
	printf '<plist/>\n' > "$stage/$2/Info.plist"
	printf '%s\n' "$3" > "$stage/$2/macos-arm64/marker"
	(cd "$stage" && /usr/bin/ditto -c -k --keepParent "$2" "$src/$1")
	rm -rf "$stage"
}
sha() { /usr/bin/shasum -a 256 "$1" | awk '{print $1}'; }
write_lock() { # <kit zip> <kit sha> <vt zip> <vt sha>
	cat > "$lock" <<EOF
# 测试用清单
engine_version=test-engine/1
ghosttykit_zip=$1
ghosttykit_sha256=$2
ghosttykit_dir=GhosttyKit.xcframework
ghosttyvt_zip=$3
ghosttyvt_sha256=$4
ghosttyvt_dir=ghostty-vt.xcframework
# download_base=https://example.invalid/never-fetched
EOF
}
run() { "$FETCH" --lock "$lock" --dest "$dest" --from "$src" "$@"; }

make_zip kit-a.zip GhosttyKit-0099.xcframework kit-a
make_zip vt-a.zip  ghostty-vt.xcframework      vt-a
write_lock kit-a.zip "$(sha "$src/kit-a.zip")" vt-a.zip "$(sha "$src/vt-a.zip")"

# 1. 还没取过：--check 报不是最新，且不创建任何东西。
if run --check >/dev/null 2>&1; then bad "--check 在空目录上应当失败"; else ok "--check 在空目录上失败"; fi
[ ! -e "$dest" ] && ok "--check 不创建输出目录" || bad "--check 创建了输出目录"

# 2. 取：两个目录就位，顶层目录按清单改名，stamp 记着 sha256。
run >/dev/null
assert_eq "$(cat "$dest/GhosttyKit.xcframework/macos-arm64/marker")" "kit-a" "GhosttyKit 解到位（zip 里的顶层目录名不同也改成清单里的名字）"
assert_eq "$(cat "$dest/ghostty-vt.xcframework/macos-arm64/marker")" "vt-a"  "ghostty-vt 解到位"
assert_eq "$(cat "$dest/GhosttyKit.xcframework.stamp")" "$(sha "$src/kit-a.zip")" "stamp 记的是 zip 的 sha256"
[ -z "$(find "$dest" -name '.fetch.*')" ] && ok "没有留下临时目录" || bad "留下了临时目录"
run --check >/dev/null && ok "取完之后 --check 通过" || bad "取完之后 --check 仍然失败"

# 3. 再跑一次：什么都不动（放一个记号文件，重解的话它会没了），zip 不在也不报错。
touch "$dest/GhosttyKit.xcframework/untouched"
mv "$src" "$src.away"
run >/dev/null && ok "已是最新时不需要 zip 在场" || bad "已是最新时还去找 zip"
[ -f "$dest/GhosttyKit.xcframework/untouched" ] && ok "已是最新时不重解" || bad "已是最新时重解了"
mv "$src.away" "$src"

# 4. 清单换了一份 zip：只换变了的那个。
make_zip kit-b.zip GhosttyKit.xcframework kit-b
write_lock kit-b.zip "$(sha "$src/kit-b.zip")" vt-a.zip "$(sha "$src/vt-a.zip")"
touch "$dest/ghostty-vt.xcframework/untouched"
if run --check >/dev/null 2>&1; then bad "清单变了 --check 应当失败"; else ok "清单变了 --check 失败"; fi
run >/dev/null
assert_eq "$(cat "$dest/GhosttyKit.xcframework/macos-arm64/marker")" "kit-b" "清单变了就换成新的那份"
[ ! -e "$dest/GhosttyKit.xcframework/untouched" ] && ok "旧的那份整个换掉" || bad "旧的那份里的文件还在"
[ -f "$dest/ghostty-vt.xcframework/untouched" ] && ok "没变的那个不动" || bad "没变的那个也被重解了"

# 5. sha256 对不上：非零退出、说清楚、原来的那份留着。（清单里写一个和现有 stamp、和 zip 都不同的 sha256。）
write_lock kit-a.zip "$(printf 'not-the-zip' | /usr/bin/shasum -a 256 | awk '{print $1}')" vt-a.zip "$(sha "$src/vt-a.zip")"
out="$(run 2>&1)" && bad "sha256 对不上应当失败" || ok "sha256 对不上时失败"
case "$out" in *"sha256 对不上"*) ok "报错里写了 sha256 对不上" ;; *) bad "报错没说 sha256：$out" ;; esac
assert_eq "$(cat "$dest/GhosttyKit.xcframework/macos-arm64/marker")" "kit-b" "校验不过时不动原来的那份"

# 6. zip 找不到：退出码 3（make engine 据此退到现编），报错里有要找的路径和 make engine-build。
write_lock kit-missing.zip "$(sha "$src/kit-a.zip")" vt-a.zip "$(sha "$src/vt-a.zip")"
rc=0; out="$(run 2>&1)" || rc=$?
assert_eq "$rc" "3" "zip 找不到时退出码是 3"
case "$out" in *"$src/kit-missing.zip"*) ok "报错里写了要找的路径" ;; *) bad "报错没写路径：$out" ;; esac
case "$out" in *"make engine-build"*) ok "报错里提示了 make engine-build" ;; *) bad "报错没提示现编：$out" ;; esac
rc=0; write_lock kit-a.zip "$(printf 'x' | /usr/bin/shasum -a 256 | awk '{print $1}')" vt-a.zip "$(sha "$src/vt-a.zip")"
run >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "1" "sha256 对不上的退出码是 1，不是 3（不该退到现编）"

# 6b. 本机现编的（stamp = local-build <engine_version>）：版本对得上就算就位，不找 zip；版本变了就不算。
rm -rf "$dest"; mkdir -p "$dest/GhosttyKit.xcframework" "$dest/ghostty-vt.xcframework"
for d in GhosttyKit.xcframework ghostty-vt.xcframework; do
	printf '<plist/>\n' > "$dest/$d/Info.plist"; touch "$dest/$d/untouched"
	printf 'local-build test-engine/1\n' > "$dest/$d.stamp"
done
write_lock kit-missing.zip "$(sha "$src/kit-a.zip")" vt-missing.zip "$(sha "$src/vt-a.zip")"
run --check >/dev/null && ok "本机现编、版本对得上时 --check 通过" || bad "本机现编的不被认"
out="$(run 2>&1)" && ok "本机现编时不找 zip" || bad "本机现编时还去找 zip：$out"
case "$out" in *"本机现编"*) ok "输出里说明是本机现编" ;; *) bad "输出没说本机现编：$out" ;; esac
[ -f "$dest/GhosttyKit.xcframework/untouched" ] && ok "本机现编的不被覆盖" || bad "本机现编的被覆盖了"
sed -i '' 's#^engine_version=.*#engine_version=test-engine/2#' "$lock"
if run --check >/dev/null 2>&1; then bad "清单换了版本，本机现编的旧版应当不算"; else ok "清单换了版本，本机现编的旧版不算"; fi
rc=0; run >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "3" "旧的现编 + zip 不在：退出码 3（会重新现编）"
rm -rf "$dest"

# 7. 评估期留下的软链（指向 build/ 下、多半已经断了）：换成真目录，不顺着软链去删东西。
write_lock kit-a.zip "$(sha "$src/kit-a.zip")" vt-a.zip "$(sha "$src/vt-a.zip")"
rm -rf "$dest"; mkdir -p "$dest" "$tmp/elsewhere/real.xcframework"
touch "$tmp/elsewhere/real.xcframework/keep" "$tmp/elsewhere/real.xcframework/Info.plist"
ln -s "$tmp/elsewhere/real.xcframework" "$dest/GhosttyKit.xcframework"
ln -s "$tmp/nowhere" "$dest/ghostty-vt.xcframework"
run >/dev/null
[ -d "$dest/GhosttyKit.xcframework" ] && [ ! -L "$dest/GhosttyKit.xcframework" ] && ok "软链换成了真目录" || bad "软链没换掉"
[ -d "$dest/ghostty-vt.xcframework" ] && [ ! -L "$dest/ghostty-vt.xcframework" ] && ok "断掉的软链也换成了真目录" || bad "断掉的软链没换掉"
[ -f "$tmp/elsewhere/real.xcframework/keep" ] && ok "软链指向的东西没被删" || bad "顺着软链把外面的东西删了"

# 8. 环境变量 UTERM_GHOSTTY_ARTIFACTS 指定 zip 目录。
rm -rf "$dest"
UTERM_GHOSTTY_ARTIFACTS="$src" "$FETCH" --lock "$lock" --dest "$dest" >/dev/null \
	&& ok "UTERM_GHOSTTY_ARTIFACTS 指定 zip 目录" || bad "UTERM_GHOSTTY_ARTIFACTS 不起作用"

# 9. 清单不全 / 目录名带路径：拒绝。
printf 'ghosttykit_zip=kit-a.zip\n' > "$lock"
if run >/dev/null 2>&1; then bad "清单不全应当失败"; else ok "清单不全时失败"; fi
write_lock kit-a.zip "$(sha "$src/kit-a.zip")" vt-a.zip "$(sha "$src/vt-a.zip")"
sed -i '' 's#^ghosttykit_dir=.*#ghosttykit_dir=../escape.xcframework#' "$lock"
if run >/dev/null 2>&1; then bad "目录名带路径应当失败"; else ok "目录名带路径时失败"; fi

# 10. --print。
write_lock kit-a.zip "$(sha "$src/kit-a.zip")" vt-a.zip "$(sha "$src/vt-a.zip")"
assert_eq "$(run --print engine_version)" "test-engine/1" "--print 读出清单里的一项"
if run --print no_such_key >/dev/null 2>&1; then bad "--print 不存在的键应当失败"; else ok "--print 不存在的键失败"; fi

# 11. 仓库里那份清单（只读）：每一项都在、sha256 是 64 位十六进制、版本串和源码里的常量一致。
real="$REPO_ROOT/vendor/libghostty-spm/ENGINE.lock"
if [ -f "$real" ]; then
	for key in engine_version ghosttykit_zip ghosttykit_sha256 ghosttykit_dir ghosttyvt_zip ghosttyvt_sha256 ghosttyvt_dir; do
		"$FETCH" --lock "$real" --print "$key" >/dev/null 2>&1 && ok "ENGINE.lock 有 $key" || bad "ENGINE.lock 缺 $key"
	done
	for key in ghosttykit_sha256 ghosttyvt_sha256; do
		v="$("$FETCH" --lock "$real" --print "$key")"
		[[ "$v" =~ ^[0-9a-f]{64}$ ]] && ok "$key 是 64 位十六进制" || bad "$key 形状不对：$v"
	done
	swift_file="$REPO_ROOT/uTerm/Features/Terminal/Shadow/TerminalEngineVersion.swift"
	want="$("$FETCH" --lock "$real" --print engine_version)"
	if grep -qF "static let current = \"$want\"" "$swift_file"; then
		ok "engine_version 与 TerminalEngineVersion.current 一致"
	else
		bad "engine_version（$want）与 TerminalEngineVersion.swift 里的 TerminalEngineVersion.current 不一致"
	fi
	if grep -qE '^download_base=' "$real"; then bad "download_base 还没上传，应当保持注释状态"; else ok "download_base 仍是注释（没上传，不下载）"; fi
else
	bad "找不到 vendor/libghostty-spm/ENGINE.lock"
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "TESTS FAILED"; exit 1; }
