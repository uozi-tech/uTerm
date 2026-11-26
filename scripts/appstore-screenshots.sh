#!/bin/bash
# App Store 截图：在指定模拟器上跑 AppStoreScreenshotTests，测试每摆好一屏就用 simctl 整屏截一张（带状态栏与屏幕圆角）。
#
# 用法：scripts/appstore-screenshots.sh <iphone|ipad|duo> <模拟器名> <输出目录> [xcodebuild 的其余参数...]
#   例：scripts/appstore-screenshots.sh duo "uTerm Promo Duo" build/appstore/raw/duo -derivedDataPath build/DerivedData
# 尺寸由模拟器决定：iPhone 17 Pro Max = 1320×2868（6.9 英寸）、iPad Pro 13 英寸 = 2064×2752、
# iPhone Duo 展开横握的内屏 = 2853×2007（Duo 有两块屏，内屏是 --display=3，DUO_DISPLAY 可改；模拟器要先展开）。
# 远程桌面的画面取 Mac 画廊的出图（先 `make gallery GALLERY_FILTER=窗口模式`，再放一份「桌面/远程桌面」），
# 目录由 MAC_SHOTS 指定，默认 build/ui-gallery/latest。LANGUAGE_CODE（默认 zh-Hans）选界面语言；
# 默认日间，UTERM_APPSTORE_DARK=1 拍夜间。iPad 由测试转成横屏拍（2752×2064）。
# 截出来的是带透明圆角的原始整屏，商店图由 internal/appstore/compose/ 加标题与底色后再上传。
# 灵动岛（只在 iphone 拍，`10-live`）：测试摆好终端后，这里把 App 切到后台、停在主屏幕上拍收起的灵动岛，再请测试
# 推一次带提醒的更新、拍展开的灵动岛。主屏幕上的 App 名字跟着模拟器的系统语言，所以 iphone 会先把模拟器的系统语言
# 改成 LANGUAGE_CODE 再开机。
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
rm -f "$out"/ready-* "$out"/done-* "$out"/signal-* "$out"/signaled-*

if [ "$device" = iphone ] || [ "$device" = ipad ]; then
    # 系统语言（锁屏与 iPad 状态栏的日期、主屏幕的 App 名字）跟着截图语言；改了要重开机才生效。
    case "$lang" in zh-Hans) locale=zh_CN ;; zh-Hant) locale=zh_TW ;; ja) locale=ja_JP ;; ko) locale=ko_KR ;; *) locale=en_US ;; esac
    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid" -b >/dev/null
    current="$(xcrun simctl spawn "$udid" defaults read -g AppleLanguages 2>/dev/null | tr -d ' \n()"' | cut -d, -f1)"
    if [ "$current" != "$lang" ]; then
        xcrun simctl spawn "$udid" defaults write -g AppleLanguages -array "$lang"
        xcrun simctl spawn "$udid" defaults write -g AppleLocale "$locale"
        xcrun simctl shutdown "$udid"
    fi
fi

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
# iPad 横握拍：App 在 iPad 上改不了自己的方向，由 devicectl 转模拟器（重开机会回到竖屏，所以每次都转）。
if [ "$device" = ipad ]; then
    xcrun devicectl device orientation set --device "$udid" landscapeLeft >/dev/null
    sleep 2
fi
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
            shoot() { xcrun simctl io "$udid" screenshot --type=png --mask=alpha ${display_args[@]+"${display_args[@]}"} \
                "$out/$1.png" >/dev/null 2>&1; }
            if [ "$name" = 10-live ]; then
                # App 回到后台：开一下「设置」再关掉，停在主屏幕上（Face ID 机型的 Home 键 HID 事件不管用），拍收起的灵动岛。
                xcrun simctl launch "$udid" com.apple.Preferences >/dev/null; sleep 1.5
                xcrun simctl terminate "$udid" com.apple.Preferences; sleep 2.5; shoot "$name-island"
                # 请测试推一次带提醒的更新：灵动岛展开几秒，隔一会儿拍几张，挑展开完整的那张。
                touch "$out/signal-$name"
                for _ in $(seq 50); do [ -e "$out/signaled-$name" ] && break; sleep 0.1; done
                for i in 1 2 3 4; do sleep 0.6; shoot "$name-expanded-$i"; done
            else
                shoot "$name"
                # iPad 由测试转成横屏拍，模拟器的屏幕按竖着存：转正。
                if [ "$device" = ipad ]; then
                    w=$(sips -g pixelWidth "$out/$name.png" | awk '/pixelWidth/{print $2}')
                    h=$(sips -g pixelHeight "$out/$name.png" | awk '/pixelHeight/{print $2}')
                    [ "$h" -gt "$w" ] && sips -r "${IPAD_ROTATE:-270}" "$out/$name.png" >/dev/null
                fi
            fi
            touch "$out/done-$name"
        done
        sleep 0.3
    done
) &
watcher=$!
trap 'kill $watcher 2>/dev/null || true' EXIT

TEST_RUNNER_UTERM_APPSTORE_SHOTS_DIR="$out" TEST_RUNNER_UTERM_APPSTORE_DEVICE="$device" \
TEST_RUNNER_UTERM_APPSTORE_DARK="${UTERM_APPSTORE_DARK:-0}" \
TEST_RUNNER_UTERM_PROMO_MAC_SHOTS="$mac_shots" \
xcodebuild test-without-building -project uTerm.xcodeproj -scheme uTermMobile -configuration Debug \
    -destination "id=$udid" -testLanguage "$lang" -enableCodeCoverage NO \
    -only-testing:uTermMobileTests/AppStoreScreenshotTests "$@" | grep -E "error:|Test Case|TEST (SUCC|FAIL)" || true
rm -f "$out"/ready-* "$out"/done-* "$out"/signal-* "$out"/signaled-*
xcrun simctl status_bar "$udid" clear
ls -1 "$out"/*.png
