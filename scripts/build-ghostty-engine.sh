#!/usr/bin/env bash
# 从上游源码编出终端引擎的两个 xcframework（GhosttyKit + libghostty-vt），装进 vendor/libghostty-spm/BinaryTarget/。
#
# 什么时候用：`make engine` 取不到 ENGINE.lock 里那两个 zip（新克隆的仓库、换了机器）时自动退到这里；也可以手动跑
# `make engine-build`，顺便验证钉住的源码现在还编得出来。步骤和 vendor/libghostty-spm/BUILD.md 一致，那份文档写原理，
# 这里是能跑的版本。
#
# 钉住的东西全从 ENGINE.lock 读：libghostty-spm 的 tag 与提交、Ghostty 提交、Zig 版本与 tarball 的 sha256、engine_version。
# 我们自己的引擎补丁取 vendor/libghostty-spm/Patches/ghostty/ 下的全部文件，接在上游补丁后面。
#
# 编出来的和 zip 里的不逐字节相同（构建路径进了调试信息），所以不核 sha256：装好后 stamp 写成
# `local-build <engine_version>`，fetch-ghostty-engine.sh 认这一种 stamp。源码相同、engine_version 相同，远控两端照样互认。
# 发版要用测过的那两个 zip，不用这里现编的。
#
#   build-ghostty-engine.sh                       编 macOS + iOS 两组，装进 BinaryTarget/
#   build-ghostty-engine.sh --platforms <csv>     换平台组（上游支持 macos,ios,maccatalyst,visionos；出正式 zip 时四组都编）
#   build-ghostty-engine.sh --pack <目录>         另外按清单里的文件名打两个 zip 放进 <目录>，打印 sha256（升级引擎出包用）
#   build-ghostty-engine.sh --no-install          不动 BinaryTarget/（配 --pack 用）
#   build-ghostty-engine.sh --keep-source         编完留着源码树（默认成功后删掉，约 5 GB）
#   build-ghostty-engine.sh --dry-run             只解析清单、找 Zig、打印要做什么，不联网、不编
#
# 工作目录：UTERM_GHOSTTY_BUILD_DIR，默认 ~/Library/Caches/uTerm/ghostty-engine-build（`make clean` 不碰；Zig 工具链和
# Zig 包缓存留在这里，下次不用重下）。Zig：UTERM_ZIG 指到 zig 可执行文件，或 PATH 里版本对的 zig，或
# ~/.local/zig/zig-aarch64-macos-<版本>/zig，都没有就从 ziglang.org 下、按清单核 sha256。
# 要联网：github.com、deps.files.ghostty.org、ziglang.org。全局 gitconfig 里的 url.*.insteadOf 改写（比如把 GitHub 的 HTTPS
# 改成 SSH）在这个脚本里一律不生效：克隆用的是去掉了 url.* 小节的一份副本。
# 测试用：--lock PATH 换清单，--dest DIR 换输出目录，--patches DIR 换我们的补丁目录。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPM_DIR="$REPO_ROOT/vendor/libghostty-spm"
LOCK="$SPM_DIR/ENGINE.lock"
DEST="$SPM_DIR/BinaryTarget"
OUR_PATCHES="$SPM_DIR/Patches/ghostty"
PRELINK="$SPM_DIR/Scripts/prelink-vt.sh"
WORK="${UTERM_GHOSTTY_BUILD_DIR:-$HOME/Library/Caches/uTerm/ghostty-engine-build}"
SPM_REPO_URL="https://github.com/Lakr233/libghostty-spm"
PLATFORMS="macos,ios"
PACK_DIR=
INSTALL=1
KEEP_SOURCE=0
DRY_RUN=0
SELF_TEST=

usage() {
	sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//' >&2
	exit 2
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--platforms)   [ "$#" -ge 2 ] || usage; PLATFORMS="$2"; shift 2 ;;
		--pack)        [ "$#" -ge 2 ] || usage; PACK_DIR="$2"; shift 2 ;;
		--no-install)  INSTALL=0; shift ;;
		--keep-source) KEEP_SOURCE=1; shift ;;
		--dry-run)     DRY_RUN=1; shift ;;
		--lock)        [ "$#" -ge 2 ] || usage; LOCK="$2"; shift 2 ;;
		--dest)        [ "$#" -ge 2 ] || usage; DEST="$2"; shift 2 ;;
		--patches)     [ "$#" -ge 2 ] || usage; OUR_PATCHES="$2"; shift 2 ;;
		--work)        [ "$#" -ge 2 ] || usage; WORK="$2"; shift 2 ;;
		# 自测入口（scripts/build-ghostty-engine.test.sh 用），不在 usage 里。
		--self-test-filter-gitconfig) [ "$#" -ge 3 ] || usage; SELF_TEST=filter; ST_A="$2"; ST_B="$3"; shift 3 ;;
		--self-test-stage-patches)    [ "$#" -ge 2 ] || usage; SELF_TEST=stage; ST_A="$2"; shift 2 ;;
		-h|--help) usage ;;
		*) usage ;;
	esac
done

die() { echo "build-ghostty-engine: $*" >&2; exit 1; }
say() { echo "[engine-build] $*"; }

# ---------- 小工具（自测会单独调） ----------

# 全局 gitconfig 去掉所有 url.* 小节（insteadOf / pushInsteadOf 改写）写到 $2。没有全局配置时写一份空文件。
filter_gitconfig() {
	local src="$1" out="$2" section
	if [ -f "$src" ]; then cp "$src" "$out"; else : > "$out"; fi
	for section in $(git config --file "$out" --name-only --get-regexp '^url\.' 2>/dev/null | sed -E 's/\.[^.]+$//' | sort -u); do
		git config --file "$out" --remove-section "$section"
	done
}

# 把我们的补丁放进上游检出的 Patches/ghostty/。同名文件、或编号和上游某个补丁撞了，都停下：上游按文件名排序打补丁，
# 编号撞了顺序就说不准（升级时上游新增了 0023 这种），要先给我们的补丁改号（UTERM-PATCHES.md「升级步骤」）。
stage_patches() {
	local upstream="$1" patch name num
	[ -d "$upstream" ] || die "上游补丁目录不存在：$upstream"
	[ -d "$OUR_PATCHES" ] || die "我们的补丁目录不存在：$OUR_PATCHES"
	local count=0
	for patch in "$OUR_PATCHES"/*; do
		[ -f "$patch" ] || continue
		name="$(basename "$patch")"
		num="${name%%-*}"
		[ -e "$upstream/$name" ] && die "上游已经有同名补丁 $name"
		if compgen -G "$upstream/$num-*" >/dev/null; then
			die "我们的补丁 $name 和上游的 $(basename "$(compgen -G "$upstream/$num-*" | head -n1)") 编号相同，先给我们的改号"
		fi
		cp "$patch" "$upstream/$name"
		echo "  + $name"
		count=$((count + 1))
	done
	[ "$count" -gt 0 ] || die "$OUR_PATCHES 里没有补丁"
}

if [ "$SELF_TEST" = filter ]; then filter_gitconfig "$ST_A" "$ST_B"; exit 0; fi
if [ "$SELF_TEST" = stage ]; then stage_patches "$ST_A"; exit 0; fi

# ---------- 清单 ----------

[ -f "$LOCK" ] || die "找不到清单 $LOCK"
lock_value() { sed -n -E "s/^$1=(.*)$/\1/p" "$LOCK" | head -n1 | sed -E 's/[[:space:]]+$//'; }
need() { local v; v="$(lock_value "$1")"; [ -n "$v" ] || die "清单 $LOCK 里没有 $1"; printf '%s' "$v"; }

ENGINE_VERSION="$(need engine_version)"
SPM_TAG="$(need libghostty_spm_tag)"
SPM_COMMIT="$(need libghostty_spm_commit)"
GHOSTTY_COMMIT="$(need ghostty_commit)"
ZIG_VERSION="$(need zig_version)"
ZIG_SHA256="$(need zig_aarch64_macos_sha256)"
KIT_DIR="$(need ghosttykit_dir)"
VT_DIR="$(need ghosttyvt_dir)"
KIT_ZIP="$(need ghosttykit_zip)"
VT_ZIP="$(need ghosttyvt_zip)"
[ "${#GHOSTTY_COMMIT}" -eq 40 ] || die "清单里 ghostty_commit 要写全 40 位：$GHOSTTY_COMMIT"

case "$(uname -m)" in
	arm64) ;;
	*) die "只支持 Apple Silicon（清单里只记了 aarch64-macos 的 Zig）" ;;
esac

# ---------- Zig ----------

zig_ok() { [ -x "$1" ] && [ "$("$1" version 2>/dev/null)" = "$ZIG_VERSION" ]; }

ZIG=
if [ -n "${UTERM_ZIG:-}" ]; then
	zig_ok "$UTERM_ZIG" || die "UTERM_ZIG=$UTERM_ZIG 不是 Zig $ZIG_VERSION"
	ZIG="$UTERM_ZIG"
else
	for candidate in "$(command -v zig 2>/dev/null || true)" \
		"$HOME/.local/zig/zig-aarch64-macos-$ZIG_VERSION/zig" \
		"$WORK/zig-aarch64-macos-$ZIG_VERSION/zig"; do
		if [ -n "$candidate" ] && zig_ok "$candidate"; then ZIG="$candidate"; break; fi
	done
fi

if [ "$DRY_RUN" = 1 ]; then
	echo "engine_version=$ENGINE_VERSION"
	echo "libghostty-spm=$SPM_TAG ($SPM_COMMIT)"
	echo "ghostty=$GHOSTTY_COMMIT"
	echo "zig=${ZIG:-（要下载 $ZIG_VERSION）}"
	echo "platforms=$PLATFORMS"
	echo "patches=$(cd "$OUR_PATCHES" && ls | tr '\n' ' ')"
	echo "work=$WORK"
	echo "install=$([ "$INSTALL" = 1 ] && echo "$DEST" || echo no)"
	echo "pack=${PACK_DIR:-no}"
	exit 0
fi

mkdir -p "$WORK"
if [ -z "$ZIG" ]; then
	tarball="zig-aarch64-macos-$ZIG_VERSION.tar.xz"
	say "下载 Zig $ZIG_VERSION"
	/usr/bin/curl -fL --retry 3 -o "$WORK/$tarball.part" "https://ziglang.org/download/$ZIG_VERSION/$tarball"
	actual="$(/usr/bin/shasum -a 256 "$WORK/$tarball.part" | awk '{print $1}')"
	[ "$actual" = "$ZIG_SHA256" ] || { rm -f "$WORK/$tarball.part"; die "$tarball 的 sha256 对不上（清单 $ZIG_SHA256，实际 $actual）"; }
	rm -rf "$WORK/zig-aarch64-macos-$ZIG_VERSION"
	/usr/bin/tar -xJf "$WORK/$tarball.part" -C "$WORK"
	rm -f "$WORK/$tarball.part"
	ZIG="$WORK/zig-aarch64-macos-$ZIG_VERSION/zig"
	zig_ok "$ZIG" || die "解出来的 Zig 跑不起来：$ZIG"
fi
say "Zig $ZIG_VERSION：$ZIG"

# ---------- 源码 ----------

started=$(date +%s)
SRC="$WORK/src"
rm -rf "$SRC" "$WORK/out" "$WORK/vt-prefix"
mkdir -p "$WORK/out"
GITCONFIG="$WORK/gitconfig"
filter_gitconfig "${GIT_CONFIG_GLOBAL:-$HOME/.gitconfig}" "$GITCONFIG"
export GIT_CONFIG_GLOBAL="$GITCONFIG"
# 构建全程只用系统工具 + 这份 Zig：Homebrew 的 rsync 排在前面时组装 xcframework 那步会出错（BUILD.md）。
export PATH="$(dirname "$ZIG"):/usr/bin:/bin:/usr/sbin:/sbin"
export ZIG_GLOBAL_CACHE_DIR="$WORK/zig-cache"

say "克隆 libghostty-spm $SPM_TAG"
git clone -q --depth 1 --branch "$SPM_TAG" "$SPM_REPO_URL" "$SRC"
head="$(git -C "$SRC" rev-parse HEAD)"
case "$head" in "$SPM_COMMIT"*) ;; *) die "tag $SPM_TAG 现在指向 $head，清单记的是 $SPM_COMMIT（上游移动过 tag？）" ;; esac
ref="$(tr -d '[:space:]' < "$SRC/Ghostty.ref")"
[ "$ref" = "$GHOSTTY_COMMIT" ] || die "$SPM_TAG 的 Ghostty.ref 是 $ref，清单记的是 $GHOSTTY_COMMIT"

say "接上我们的引擎补丁"
stage_patches "$SRC/Patches/ghostty"

# ---------- GhosttyKit ----------

say "编 GhosttyKit（$PLATFORMS；整套约 10–20 分钟）"
# 不传 --ref：源码树不存在时 build.sh 自己完整克隆 Ghostty 并检出 Ghostty.ref（上面核过等于清单）。完整克隆才有
# 9 位短哈希的版本串。
(cd "$SRC" && ./build.sh --platforms "$PLATFORMS" --skip-tests)
KIT_OUT="$SRC/BinaryTarget/GhosttyKit.xcframework"
[ -f "$KIT_OUT/Info.plist" ] || die "build.sh 跑完了，但没有 $KIT_OUT"

# ---------- libghostty-vt ----------

say "编 libghostty-vt（同一棵打过补丁的树）"
(cd "$SRC/References/ghostty-upstream" && zig build --prefix "$WORK/vt-prefix" -Demit-lib-vt -Demit-xcframework=true -Doptimize=ReleaseFast)
VT_OUT="$WORK/out/ghostty-vt.xcframework"
"$PRELINK" "$WORK/vt-prefix/lib/ghostty-vt.xcframework" "$VT_OUT"
[ -f "$VT_OUT/Info.plist" ] || die "预链接之后没有 $VT_OUT"

# ---------- 核对 ----------

say "核对产物"
short9="${GHOSTTY_COMMIT:0:9}"
macos_kit="$(find "$KIT_OUT" -path '*macos-*' -name '*.a' | head -n1)"
[ -n "$macos_kit" ] || die "GhosttyKit 里没有 macOS slice"
# 不用 grep -q：它找到就退出，strings 吃 SIGPIPE，pipefail 下整条管道算失败。
strings -a "$macos_kit" | grep -F "+$short9" >/dev/null || die "GhosttyKit 的版本串里没有 +$short9（Ghostty 没有完整克隆、或检出的不是钉住的提交）"
for slice in "$KIT_OUT" "$VT_OUT"; do
	for want in 'macos-*' 'ios-arm64' 'ios-*simulator'; do
		compgen -G "$slice/$want" >/dev/null || die "$(basename "$slice") 缺 $want slice"
	done
done
for a in $(find "$VT_OUT" -name '*.a'); do
	extra="$(nm -gU "$a" | awk 'NF >= 3 && $3 !~ /^_ghostty_/ && n++ < 3')"
	[ -z "$extra" ] || die "$a 导出了 ghostty_* 以外的符号：$extra"
	[ "$(nm -gU "$a" | grep -c ' _ghostty_')" -gt 0 ] || die "$a 一个 ghostty_* 都没导出"
done
echo "  版本串 +$short9、slice 齐全、vt 只导出 ghostty_*"

# ---------- 打包 / 装进去 ----------

if [ -n "$PACK_DIR" ]; then
	mkdir -p "$PACK_DIR"
	stage="$WORK/out/pack"; rm -rf "$stage"; mkdir -p "$stage"
	cp -R "$KIT_OUT" "$stage/$KIT_DIR"
	(cd "$stage" && /usr/bin/ditto -c -k --keepParent "$KIT_DIR" "$PACK_DIR/$KIT_ZIP")
	(cd "$WORK/out" && /usr/bin/ditto -c -k --keepParent "$(basename "$VT_OUT")" "$PACK_DIR/$VT_ZIP")
	rm -rf "$stage"
	say "打包到 $PACK_DIR（清单的 sha256 要改成下面这两个；平台组是 $PLATFORMS）"
	(cd "$PACK_DIR" && /usr/bin/shasum -a 256 "$KIT_ZIP" "$VT_ZIP")
fi

if [ "$INSTALL" = 1 ]; then
	mkdir -p "$DEST"
	for pair in "$KIT_OUT:$KIT_DIR" "$VT_OUT:$VT_DIR"; do
		from="${pair%%:*}"; dir="${pair##*:}"
		rm -f "$DEST/$dir.stamp"
		rm -rf "${DEST:?}/$dir"
		mv "$from" "$DEST/$dir"
		printf 'local-build %s\n' "$ENGINE_VERSION" > "$DEST/$dir.stamp"
	done
	say "装进 $DEST（stamp：local-build $ENGINE_VERSION）"
fi

if [ "$KEEP_SOURCE" = 0 ]; then
	rm -rf "$SRC" "$WORK/vt-prefix" "$WORK/out"
else
	say "源码树留在 $SRC"
fi
say "完成，用时 $(( ($(date +%s) - started) / 60 )) 分钟"
