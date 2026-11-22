#!/bin/bash
# App Store 截图：在指定模拟器上跑 AppStoreScreenshotTests，测试每摆好一屏就用 simctl 整屏截一张（带状态栏与屏幕圆角）。
#
# 用法：scripts/appstore-screenshots.sh <iphone|ipad|duo> <模拟器名> <输出目录> [xcodebuild 的其余参数...]
#   例：scripts/appstore-screenshots.sh duo "uTerm Promo Duo" build/appstore/raw/duo -derivedDataPath build/DerivedData
# 尺寸由模拟器决定：iPhone 17 Pro Max = 1320×2868（6.9 英寸）、iPad Pro 13 英寸 = 2064×2752、
# iPhone Duo 展开横握的内屏 = 2853×2007（Duo 有两块屏，内屏是 --display=3，DUO_DISPLAY 可改；模拟器要先展开）。
# 远程桌面的画面取 Mac 画廊的出图（先 `make gallery GALLERY_FILTER=窗口模式`，再放一份「桌面/远程桌面」），
# 目录由 MAC_SHOTS 指定，默认 build/ui-gallery/latest。LANGUAGE_CODE（默认 zh-Hans）选界面语言。
# 截出来的是带透明圆角的原始整屏，商店图由 internal/appstore/compose/ 加标题与底色后再上传。
set -euo pipefail
device="$1"; sim="$2"; out="$3"; shift 3
case "$device" in iphone|ipad|duo) ;; *) echo "设备只能是 iphone / ipad / duo：$device" >&2; exit 1 ;; esac
lang="${LANGUAGE_CODE:-zh-Hans}"
mac_shots="$(cd "${MAC_SHOTS:-build/ui-gallery/latest}" && pwd)"
display_args=()
[ "$device" = duo ] && display_args=(--display="${DUO_DISPLAY:-3}")
udid="$(xcrun simctl list devices available | grep -F "    $sim (" | head -1 | grep -oE '[0-9A-F-]{36}')"
[ -n "$udid" ] || { echo "找不到模拟器：$sim" >&2; exit 1; }
mkdir -p "$out"
out="$(cd "$out" && pwd)"
rm -f "$out"/ready-* "$out"/done-*

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
xcrun simctl ui "$udid" appearance dark

# 拍照的那一头：看到 ready-<名字> 就截，截完写 done-<名字>。
(
    while true; do
        for ready in "$out"/ready-*; do
            [ -e "$ready" ] || continue
            name="${ready##*/ready-}"
            [ -e "$out/done-$name" ] && continue
            sleep 0.5
            xcrun simctl io "$udid" screenshot --type=png --mask=alpha ${display_args[@]+"${display_args[@]}"} \
                "$out/$name.png" >/dev/null 2>&1
            touch "$out/done-$name"
        done
        sleep 0.3
    done
) &
watcher=$!
trap 'kill $watcher 2>/dev/null || true' EXIT

TEST_RUNNER_UTERM_APPSTORE_SHOTS_DIR="$out" TEST_RUNNER_UTERM_APPSTORE_DEVICE="$device" \
TEST_RUNNER_UTERM_PROMO_MAC_SHOTS="$mac_shots" \
xcodebuild test-without-building -project uTerm.xcodeproj -scheme uTermMobile -configuration Debug \
    -destination "id=$udid" -testLanguage "$lang" -enableCodeCoverage NO \
    -only-testing:uTermMobileTests/AppStoreScreenshotTests "$@" | grep -E "error:|Test Case|TEST (SUCC|FAIL)" || true
rm -f "$out"/ready-* "$out"/done-*
xcrun simctl status_bar "$udid" clear
ls -1 "$out"/*.png
