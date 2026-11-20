#!/usr/bin/env bash
# 真机验证：会话留在主机上这条链路，在真的 iOS 上从外面动手走一遍。
#
#   holder/scripts/device-verify.sh --device <udid>    # 真机（要解锁、和这台 Mac 在同一个局域网）
#   holder/scripts/device-verify.sh --simulator 'iPhone 18 Pro'           # 模拟器（先在这上面跑通）
#   holder/scripts/device-verify.sh --device … --phases suspend           # 只跑一组：suspend / restore
#   holder/scripts/device-verify.sh --device … --keep-connection          # 挂起期间不掐 SSH 连接
#
# 做的事：在这台 Mac 上起一个一次性的 sshd 容器（随机密码），把测试宿主装到设备上，然后按阶段跑
# uTermMobileTests/MobileTerminalDeviceVerifyTests：
#
#   suspend  连上、主机上起一个每半秒吐一行的循环 → 把 App 切到后台 → 挂起进程 → 在主机那头掐掉 SSH 连接
#            → 恢复进程、切回前台。用例核对输出一行不多一行不少、shell 没换、画面一致。
#   restore  连上、屏幕上放内容 → 切到后台（终端状态存到主机上）→ 杀掉进程 → 重新起一个进程凭归档开回来。
#            用例核对被杀前后的内容都在、shell 没换。
#
# 需要 docker。真机上 App 会被切到「设置」再切回来；别碰手机。
set -euo pipefail

cd "$(dirname "$0")/../.."
bundle_id=${UTERM_BUNDLE_ID:-com.uozi.uTerm}
other_app=com.apple.Preferences
suite=uTermMobileTests/MobileTerminalDeviceVerifyTests

kind=""
target=""
phases="suspend,restore"
cut_connection=1
background_seconds="${UTERM_VERIFY_BACKGROUND_SECONDS:-35}"
after_cut_seconds="${UTERM_VERIFY_AFTER_CUT_SECONDS:-20}"
skip_build=0
while [ $# -gt 0 ]; do
    case "$1" in
        --device) kind=device; target="$2"; shift 2 ;;
        --simulator) kind=simulator; target="$2"; shift 2 ;;
        --phases) phases="$2"; shift 2 ;;
        --keep-connection) cut_connection=0; shift ;;
        --skip-build) skip_build=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$kind" ] || { echo "usage: $0 --device <udid> | --simulator <name-or-udid> [--phases suspend,restore] [--keep-connection]" >&2; exit 2; }

out="build/device-verify"
mkdir -p "$out"
work="$(mktemp -d /tmp/uterm-device-verify.XXXXXX)"
container=""
restore_pending=0
runner_pid=""

if [ "$kind" = device ]; then
    destination="platform=iOS,id=$target"
    extra_args=(-allowProvisioningUpdates)
    publish="0.0.0.0::22"
    if [ -n "${UTERM_VERIFY_HOST:-}" ]; then
        host="$UTERM_VERIFY_HOST"
    else
        # 默认路由可能是代理的虚拟网卡（没有局域网地址），所以挨个物理网卡找。
        host=""
        for interface in $(route -n get default 2>/dev/null | awk '/interface:/{print $2}') en0 en1; do
            host="$(ipconfig getifaddr "$interface" 2>/dev/null || true)"
            [ -z "$host" ] || break
        done
        [ -n "$host" ] || { echo "找不到这台 Mac 的局域网地址，用 UTERM_VERIFY_HOST 指定" >&2; exit 2; }
    fi
else
    if [[ "$target" =~ ^[0-9A-F-]{36}$ ]]; then
        simulator_udid="$target"
    else
        simulator_udid="$(xcrun simctl list devices available | grep -F "$target (" | head -1 | grep -oE '[0-9A-F-]{36}')"
    fi
    destination="platform=iOS Simulator,id=$simulator_udid"
    extra_args=()
    publish="127.0.0.1::22"
    host="127.0.0.1"
fi

xcode_args=(-project uTerm.xcodeproj -scheme uTermMobile -configuration Debug -destination "$destination"
    -derivedDataPath build/DerivedData -onlyUsePackageVersionsFromResolvedFile -enableCodeCoverage NO)
[ ${#extra_args[@]} -eq 0 ] || xcode_args+=("${extra_args[@]}")

say() { printf '\n== %s\n' "$*"; }

# ---- 设备上的动作 ----

app_to_background() {
    if [ "$kind" = device ]; then
        xcrun devicectl device process launch --device "$target" "$other_app" >/dev/null
    else
        xcrun simctl launch "$simulator_udid" "$other_app" >/dev/null
    fi
}

app_to_foreground() {
    if [ "$kind" = device ]; then
        xcrun devicectl device process launch --device "$target" "$bundle_id" >/dev/null
    else
        xcrun simctl launch "$simulator_udid" "$bundle_id" >/dev/null
    fi
}

app_pid() {
    if [ "$kind" = device ]; then
        xcrun devicectl device info processes --device "$target" --json-output "$work/processes.json" >/dev/null 2>&1
        python3 -c '
import json, sys
for process in json.load(open(sys.argv[1]))["result"]["runningProcesses"]:
    if process.get("executable", "").endswith("/uTermMobile.app/uTermMobile"):
        print(process["processIdentifier"])
        break
' "$work/processes.json"
    else
        pgrep -f "CoreSimulator/Devices/$simulator_udid/.*/uTermMobile.app/uTermMobile" | head -1
    fi
}

# 测试会话在的时候系统不会挂起宿主进程（实测 Duo：后台 60 多秒照常收输出），所以由这里动手停住进程，
# 和系统挂起时一样：进程一条指令都不跑，连接上来的数据没人收。
suspend_app() {
    suspended_pid="$(app_pid)"
    [ -n "$suspended_pid" ] || { echo "找不到 uTermMobile 进程" >&2; return 1; }
    if [ "$kind" = device ]; then
        xcrun devicectl device process suspend --device "$target" --pid "$suspended_pid" >/dev/null
    else
        kill -STOP "$suspended_pid"
    fi
}

resume_app() {
    if [ "$kind" = device ]; then
        xcrun devicectl device process resume --device "$target" --pid "$suspended_pid" >/dev/null
    else
        kill -CONT "$suspended_pid"
    fi
}

kill_app() {
    local pid
    pid="$(app_pid)"
    [ -n "$pid" ] || { echo "找不到 uTermMobile 进程" >&2; return 1; }
    if [ "$kind" = device ]; then
        xcrun devicectl device process signal --device "$target" --pid "$pid" --signal SIGKILL >/dev/null
    else
        kill -9 "$pid"
    fi
    echo "已杀掉进程 $pid"
}

# ---- 主机（容器）上的动作 ----

on_host() { docker exec "$container" "$@"; }

wait_marker() {
    local name="$1" seconds="${2:-240}" i
    for i in $(seq 1 $((seconds * 2))); do
        on_host test -e "/tmp/uterm-verify/$name" 2>/dev/null && return 0
        if [ -n "$runner_pid" ] && ! kill -0 "$runner_pid" 2>/dev/null; then
            echo "用例在写出 $name 之前就结束了" >&2
            return 1
        fi
        sleep 0.5
    done
    echo "等不到主机上的标记 $name" >&2
    return 1
}

holders() { on_host pgrep -f 'uterm-holder' 2>/dev/null | wc -l | tr -d ' '; }

expect_no_holder() {
    local i
    for i in $(seq 1 20); do
        [ "$(holders)" = 0 ] && { echo "主机上没有留下保持进程"; return 0; }
        sleep 0.5
    done
    echo "主机上还有保持进程：" >&2
    on_host ps -o pid,args >&2
    return 1
}

# ---- 跑一个阶段的用例 ----

start_phase() {
    local phase="$1" test="$2"
    : >"$out/$phase.log"
    TEST_RUNNER_UTERM_DEVICE_PHASE="$phase" \
    TEST_RUNNER_UTERM_LIVE_SSH_HOST="$host" \
    TEST_RUNNER_UTERM_LIVE_SSH_PORT="$port" \
    TEST_RUNNER_UTERM_LIVE_SSH_USER=dev \
    TEST_RUNNER_UTERM_LIVE_SSH_PASSWORD="$password" \
        xcodebuild test-without-building "${xcode_args[@]}" "-only-testing:$suite/$test" >"$out/$phase.log" 2>&1 &
    runner_pid=$!
}

finish_phase() {
    local phase="$1" status=0
    wait "$runner_pid" || status=$?
    runner_pid=""
    if [ "$status" -ne 0 ]; then
        echo "$phase 阶段的用例没过（日志 $out/$phase.log）：" >&2
        grep -E "error:|XCTAssert|等不到|failed" "$out/$phase.log" | head -20 >&2 || true
        return 1
    fi
    echo "$phase 阶段的用例通过"
}

passed=0
cleanup() {
    [ -z "$runner_pid" ] || kill "$runner_pid" 2>/dev/null || true
    if [ "$restore_pending" = 1 ]; then
        # create 之后没走到 restore：把设备上的钥匙串条目和归档清掉。
        TEST_RUNNER_UTERM_DEVICE_PHASE=cleanup xcodebuild test-without-building "${xcode_args[@]}" \
            "-only-testing:$suite/testCleanup" >"$out/cleanup.log" 2>&1 || true
    fi
    [ -z "$container" ] || docker rm -f "$container" >/dev/null 2>&1 || true
    rm -rf "$work"
    [ "$passed" = 1 ] || exit 1
}
trap cleanup EXIT

# ---- 准备 ----

say "测试用的 sshd 容器"
ssh-keygen -q -t ed25519 -N '' -f "$work/key"
cp "$work/key.pub" holder/e2e/sshd/authorized_keys
docker build -q -t uterm-holder-e2e-sshd holder/e2e/sshd >/dev/null
rm -f holder/e2e/sshd/authorized_keys
container="$(docker run -d --rm -p "$publish" uterm-holder-e2e-sshd)"
port="$(docker port "$container" 22/tcp | head -1 | sed 's/.*://')"
password="$(openssl rand -hex 16)"
printf 'dev:%s\n' "$password" | docker exec -i "$container" chpasswd
echo "sshd 在 ${host}:${port}（容器 ${container:0:12}，$(on_host uname -m)）"
if ! nc -z -G 3 "$host" "$port" 2>/dev/null; then
    echo "这台 Mac 自己都连不上 $host:$port；真机更连不上（docker 没把端口发布到局域网？可用 UTERM_VERIFY_HOST 指定地址）" >&2
    exit 1
fi

if [ "$skip_build" = 0 ]; then
    say "编译测试宿主（${destination}）"
    make engine holder >/dev/null
    if ! xcodebuild build-for-testing "${xcode_args[@]}" >"$out/build.log" 2>&1; then
        grep -E "error:|BUILD FAILED" "$out/build.log" | head -20 >&2
        exit 1
    fi
fi

# ---- suspend ----

if [[ ",$phases," == *,suspend,* ]]; then
    say "suspend：进后台 → 被挂起 → 连接断 → 回前台"
    start_phase suspend testSuspendedInBackgroundThenBack
    wait_marker suspend-ready
    sleep 5
    echo "把 App 切到后台，${background_seconds}s 后挂起进程"
    app_to_background
    sleep "$background_seconds"
    suspend_app
    echo "进程 $suspended_pid 已挂起"
    sleep 5
    if [ "$cut_connection" = 1 ]; then
        echo "在主机那头掐掉 SSH 连接（会话里的 shell 不动）"
        on_host pkill -u dev -f '^sshd' || echo "（没有找到 dev 的 sshd 进程：连接已经不在了）"
    fi
    sleep "$after_cut_seconds"
    echo "恢复进程，把 App 切回前台"
    resume_app
    app_to_foreground
    finish_phase suspend
    say "suspend 的经过"
    on_host cat /tmp/uterm-verify/suspend-report
    expect_no_holder
fi

# ---- restore ----

if [[ ",$phases," == *,restore,* ]]; then
    say "restore：进后台 → 进程被杀 → 重新打开"
    restore_pending=1
    start_phase create testCreateSessionThenGetKilled
    wait_marker create-ready
    sleep 5
    echo "把 App 切到后台（终端状态存到主机上），5s 后杀掉进程"
    app_to_background
    sleep 5
    kill_app
    # 进程没了 xcodebuild 会把宿主重新拉起来、再干等几分钟才收场；不等它。
    kill "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
    runner_pid=""
    shell_pid="$(on_host cat /tmp/uterm-verify/shell-pid)"
    sleep 5
    if on_host kill -0 "$shell_pid" 2>/dev/null && [ "$(holders)" != 0 ]; then
        echo "进程被杀之后，主机上的 shell（${shell_pid}）和保持进程都还在"
    else
        echo "进程被杀之后，主机上的会话没了" >&2
        on_host ps -o pid,args >&2
        exit 1
    fi
    start_phase restore testRestoreAfterBeingKilled
    finish_phase restore
    restore_pending=0
    say "restore 的经过"
    on_host cat /tmp/uterm-verify/restore-report
    expect_no_holder
fi

passed=1
say "全部通过"
