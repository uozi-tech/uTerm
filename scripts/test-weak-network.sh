#!/bin/bash
# 弱网矩阵（RemoteWeakNetworkMatrixTests）：起一个本机 uterm-relay，带开关跑矩阵用例，把读数表写进
# docs/remote-weak-network-baseline.md（WEAK_NET_REPORT 可改路径）。用例默认跳过，不进 test-fast。
#
# 用法：scripts/test-weak-network.sh [传给 xcodebuild 的其余参数...]
#       WEAK_NET_ONLY="test_matrix_2_3g test_matrix_9_connect_through_relay" 只跑其中几条。
#       WEAK_NET_ROUNDS=1 每格只跑一轮（默认 3 轮，表里给中位数和范围）。
#       WEAK_NET_TRANSPORT=direct|relay 只跑一条路。
set -euo pipefail

report=${WEAK_NET_REPORT:-docs/remote-weak-network-baseline.md}
work=$(mktemp -d)
relay_pid=""
cleanup() {
    if [ -n "$relay_pid" ]; then kill "$relay_pid" 2>/dev/null || true; fi
    rm -rf "$work"
}
trap cleanup EXIT

GOWORK=off go -C relay build -o "$work/uterm-relay" ./cmd/uterm-relay

port=${UTERM_RELAY_TEST_PORT:-47397}
export RELAY_DATA="$work/data"
export RELAY_LISTEN="127.0.0.1:$port"
export RELAY_PUBLIC_HOST=127.0.0.1
export RELAY_PUBLIC_PORT="$port"
export RELAY_NAME="WeakNet"
export RELAY_RATE_PER_IP=0

"$work/uterm-relay" serve > "$work/relay.log" 2>&1 &
relay_pid=$!
for _ in $(seq 1 100); do
    if "$work/uterm-relay" status > /dev/null 2>&1; then break; fi
    sleep 0.1
done
"$work/uterm-relay" status > /dev/null
relay_version=$("$work/uterm-relay" version)

only=()
if [ -n "${WEAK_NET_ONLY:-}" ]; then
    for name in $WEAK_NET_ONLY; do only+=(-only-testing:"uTermTests/RemoteWeakNetworkMatrixTests/$name"); done
else
    only=(-only-testing:uTermTests/RemoteWeakNetworkMatrixTests)
fi

log="$work/xcodebuild.log"
load_before=$(sysctl -n vm.loadavg)
set +e
rounds=${WEAK_NET_ROUNDS:-3}
TEST_RUNNER_UTERM_WEAK_NET_MATRIX=1 \
TEST_RUNNER_UTERM_WEAK_NET_ROUNDS="$rounds" \
TEST_RUNNER_UTERM_WEAK_NET_TRANSPORT="${WEAK_NET_TRANSPORT:-}" \
TEST_RUNNER_UTERM_RELAY_CONFIG="$("$work/uterm-relay" config)" \
TEST_RUNNER_UTERM_RELAY_VERSION="$relay_version" \
    xcodebuild test "${only[@]}" -parallel-testing-enabled NO "$@" 2>&1 | tee "$log" | grep -E '^\[弱网矩阵\]|Test Case .*(passed|failed|skipped)|error:|\*\* TEST'
status=${PIPESTATUS[0]}
set -e
load_after=$(sysctl -n vm.loadavg)
# 完整的 xcodebuild 输出留一份在报告旁边（逐轮读数、断言失败都在里面）。
cp "$log" "${report%.md}.log" 2>/dev/null || true

table=$(awk '/<!-- weak-net-matrix:begin -->/{on=1; next} /<!-- weak-net-matrix:end -->/{on=0} on' "$log")
if [ -z "$table" ]; then
    echo "没有读到矩阵结果（用例被跳过或中途失败），不写报告" >&2
    exit "$status"
fi
{
    echo "# 弱网矩阵基线"
    echo
    echo "- 生成：$(date '+%Y-%m-%d %H:%M')，提交 $(git rev-parse --short HEAD)$(git diff --quiet || echo '（工作区有改动）')"
    echo "- 机器：$(sysctl -n hw.model)，$(sysctl -n machdep.cpu.brand_string)，macOS $(sw_vers -productVersion)"
    echo "- 中继：本机 uterm-relay ${relay_version}；每格 ${rounds} 轮"
    echo "- 平均负载（1/5/15 分钟）：开跑前 ${load_before}，跑完 ${load_after}"
    echo "- 重跑：\`make test-weak-network\`（用例 \`uTermTests/Core/Remote/RemoteWeakNetworkMatrixTests.swift\`）"
    echo
    echo "$table"
    echo
    echo "### 读数的边界"
    echo
    echo "- 同一档各轮之间可能差很多（2026-11-08 高丢包 5% 直连一次 7.6 Mbps / 16 fps、一次 1.7 Mbps / 1.7 fps），看中位数也要看范围。"
    echo "- 抖动按包独立取值，UDP 上会大量乱序，比真实网络（多为排队造成的、基本有序的抖动）更狠。"
    echo "- 中继 TCP 是把手机到 Mac 整段当一跳模拟：丢包表现为该段数据晚到 200 ms（重传），没有真实 TCP 的拥塞窗口收缩。"
    echo "- 建连那组的打洞在本机回环上进行，差网络只加在手机到中继这一段。"
    echo "- 模拟测不到的：真实 TCP 拥塞控制、蜂窝空口调度、Wi-Fi 与蜂窝切换时系统的真实时序——这些要用 Network Link Conditioner 在真机上补。"
} > "$report"
echo "报告：$report"
exit "$status"
