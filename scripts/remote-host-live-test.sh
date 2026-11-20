#!/bin/bash
# 实测远控进程（uTermRemoteHost）：把 DerivedData 里刚编好的那份登记成 launchd 任务（不经 SMAppService，不碰已装的
# uTerm），带 TEST_RUNNER_UTERM_REMOTE_HOST_LIVE=1 跑 RemoteHostAgentLiveTests，结束时注销任务。
# 先 build-for-testing（Debug）。用法：scripts/remote-host-live-test.sh [DerivedData 路径]
set -euo pipefail
cd "$(dirname "$0")/.."
derived="${1:-build/DerivedData}"
app="$PWD/$derived/Build/Products/Debug/uTerm.app"
agent="$app/Contents/Helpers/uTermRemoteHost.app/Contents/MacOS/uTermRemoteHost"
label=${UTERM_BUNDLE_ID:-com.uozi.uTerm}.RemoteHost
domain="gui/$(id -u)"
test -x "$agent" || { echo "找不到 $agent，先 build-for-testing" >&2; exit 1; }
if launchctl print "$domain/$label" >/dev/null 2>&1; then
    echo "已经有 $label 任务（装好的 uTerm 注册的？），不覆盖。先退出 uTerm 或手动 launchctl bootout。" >&2
    exit 1
fi
workdir="$(mktemp -d)"
plist="$workdir/$label.plist"
cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$label</string>
	<key>Program</key><string>$agent</string>
	<key>MachServices</key><dict><key>$label</key><true/></dict>
	<key>EnvironmentVariables</key><dict><key>UTERM_REMOTE_HOST_NO_BONJOUR</key><string>1</string></dict>
</dict>
</plist>
EOF
launchctl bootstrap "$domain" "$plist"
cleanup() {
    launchctl bootout "$domain/$label" 2>/dev/null || true
    rm -f "$plist"
    rmdir "$workdir" 2>/dev/null || true
}
trap cleanup EXIT
TEST_RUNNER_UTERM_REMOTE_HOST_LIVE=1 xcodebuild -project uTerm.xcodeproj -scheme uTerm -destination 'platform=macOS' \
    -derivedDataPath "$derived" -enableCodeCoverage NO test-without-building \
    -only-testing:uTermTests/RemoteHostAgentLiveTests
