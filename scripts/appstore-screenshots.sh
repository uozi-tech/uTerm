#!/bin/bash
# App Store 截图：在指定模拟器上跑 AppStoreScreenshotTests，测试每摆好一屏就用 simctl 整屏截一张（带状态栏）。
#
# 用法：scripts/appstore-screenshots.sh <模拟器名> <输出目录> [xcodebuild 的其余参数...]
#   例：scripts/appstore-screenshots.sh "uTerm Shots 6.9" build/appstore/iphone -derivedDataPath build/DerivedData
# 尺寸由模拟器决定：iPhone 17 Pro Max = 1320×2868（6.9 英寸），iPad Pro 13 英寸 = 2064×2752。
# 环境变量 UTERM_APPSTORE_DARK=1 拍深色；LANGUAGE（默认 zh-Hans）选界面语言。
set -euo pipefail
sim="$1"; out="$2"; shift 2
lang="${LANGUAGE_CODE:-zh-Hans}"
udid="$(xcrun simctl list devices available | grep -F "    $sim (" | head -1 | grep -oE '[0-9A-F-]{36}')"
[ -n "$udid" ] || { echo "找不到模拟器：$sim" >&2; exit 1; }
mkdir -p "$out"
out="$(cd "$out" && pwd)"
rm -f "$out"/ready-* "$out"/done-*

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
[ "${UTERM_APPSTORE_DARK:-0}" = 1 ] && xcrun simctl ui "$udid" appearance dark || xcrun simctl ui "$udid" appearance light

# 拍照的那一头：看到 ready-<名字> 就截，截完写 done-<名字>。
(
    while true; do
        for ready in "$out"/ready-*; do
            [ -e "$ready" ] || continue
            name="${ready##*/ready-}"
            [ -e "$out/done-$name" ] && continue
            sleep 0.5
            xcrun simctl io "$udid" screenshot --type=png "$out/$name.png" >/dev/null 2>&1
            touch "$out/done-$name"
        done
        sleep 0.3
    done
) &
watcher=$!
trap 'kill $watcher 2>/dev/null || true' EXIT

TEST_RUNNER_UTERM_APPSTORE_SHOTS_DIR="$out" TEST_RUNNER_UTERM_APPSTORE_DARK="${UTERM_APPSTORE_DARK:-0}" \
xcodebuild test-without-building -project uTerm.xcodeproj -scheme uTermMobile -configuration Debug \
    -destination "id=$udid" -testLanguage "$lang" -enableCodeCoverage NO \
    -only-testing:uTermMobileTests/AppStoreScreenshotTests "$@" | grep -E "error:|Test Case|TEST (SUCC|FAIL)" || true
rm -f "$out"/ready-* "$out"/done-*
xcrun simctl status_bar "$udid" clear
ls -1 "$out"/*.png
