#!/bin/bash
# 把 zig build -Demit-lib-vt -Demit-xcframework=true 出的 ghostty-vt.xcframework 预链接成
# 「每个 slice 一个 .o、只导出 ghostty_*」的版本，再重新组装成 xcframework。
#
#   prelink-vt.sh <in ghostty-vt.xcframework> <out ghostty-vt.xcframework>
#
# 为什么：libghostty-vt 与 GhosttyKit 的 .a 都带 Zig 打包的 ubsan 运行时、memset、simdutf、
# highway、compiler_rt……两份一起链、不开 dead strip 时重复符号（见 vt-snapshot-and-build.md 1.1）。
# ld -r -exported_symbols_list 后这些都变成 vt 私有的局部符号，链接顺序与 dead strip 都无所谓。
set -euo pipefail
IN=${1:?usage: $0 <in.xcframework> <out.xcframework>}
OUT=${2:?usage: $0 <in.xcframework> <out.xcframework>}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

args=()
for slice in "$IN"/*/; do
  slice=${slice%/}
  id=$(basename "$slice")
  lib=$(find "$slice" -maxdepth 1 -name '*.a' | head -1)
  [ -n "$lib" ] || { echo "no .a in $slice" >&2; exit 1; }
  thin_outs=()
  for arch in $(lipo -archs "$lib"); do
    d="$WORK/$id/$arch"
    mkdir -p "$d/o"
    if [ "$(lipo -archs "$lib")" = "$arch" ]; then cp "$lib" "$d/in.a"; else lipo -thin "$arch" "$lib" -output "$d/in.a"; fi
    (cd "$d/o" && ar -x ../in.a && chmod 644 ./*.o && rm -f __.SYMDEF*)
    nm -gU "$d"/o/*.o 2>/dev/null | awk '$3 ~ /^_ghostty_/ {print $3}' | sort -u > "$d/exports.txt"
    ld -r -arch "$arch" -o "$d/ghostty-vt.o" "$d"/o/*.o -exported_symbols_list "$d/exports.txt"
    ar rcs "$d/libghostty-vt.a" "$d/ghostty-vt.o"
    thin_outs+=("$d/libghostty-vt.a")
    echo "[$id/$arch] $(wc -l < "$d/exports.txt" | tr -d ' ') exported ghostty_* symbols," \
         "$(nm -gU "$d/ghostty-vt.o" | grep -vc ' _ghostty_' || true) other globals"
  done
  mkdir -p "$WORK/out/$id"
  if [ ${#thin_outs[@]} -eq 1 ]; then cp "${thin_outs[0]}" "$WORK/out/$id/libghostty-vt.a"
  else lipo -create "${thin_outs[@]}" -output "$WORK/out/$id/libghostty-vt.a"; fi
  args+=(-library "$WORK/out/$id/libghostty-vt.a" -headers "$slice/Headers")
done

rm -rf "$OUT"
xcodebuild -create-xcframework "${args[@]}" -output "$OUT" >/dev/null
echo "wrote $OUT"
