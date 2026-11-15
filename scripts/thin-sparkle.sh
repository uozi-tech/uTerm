#!/usr/bin/env bash
# 把 archive 里 Sparkle.framework 的 Mach-O 去掉 x86_64（只发 arm64，见 CLAUDE.md「Release」）。
# Sparkle 是预编译的双架构包，Xcode 不按 ARCHS 给它瘦身；去掉之后约小 1.3 MB。
#
#   scripts/thin-sparkle.sh <uTerm.app>
#
# 改完 archive 里的签名就失效了：只能在 `xcodebuild -exportArchive` 之前跑，export 会给包内全部代码
# 重签 Developer ID（`make verify-distribution-signing` 核）。别在 Debug 构建产物上跑。
set -euo pipefail

app="${1:?usage: thin-sparkle.sh <uTerm.app>}"
framework="$app/Contents/Frameworks/Sparkle.framework"
test -d "$framework" || { echo "thin-sparkle: $framework 不存在" >&2; exit 1; }

thinned=0
while IFS= read -r -d '' file; do
    archs="$(lipo -archs "$file" 2>/dev/null)" || continue   # 不是 Mach-O
    case " $archs " in
        *" x86_64 "*) ;;
        *) continue ;;
    esac
    case " $archs " in
        *" arm64 "*) ;;
        *) echo "thin-sparkle: $file 没有 arm64（$archs）" >&2; exit 1 ;;
    esac
    lipo -remove x86_64 "$file" -output "$file"
    thinned=$((thinned + 1))
done < <(find "$framework" -type f -print0)

echo "thin-sparkle: 去掉了 $thinned 个文件的 x86_64"
