#!/bin/bash
# 起一个真实的 uterm-relay，跑经它的端到端用例（RemoteRelayEndToEndTests、设备组信箱的
# RemoteGroupRelayMailboxEndToEndTests），结束后关掉。
#
# 用法：scripts/test-relay-e2e.sh [传给 xcodebuild 的其余参数...]
set -euo pipefail

work=$(mktemp -d)
relay_pid=""
cleanup() {
    if [ -n "$relay_pid" ]; then kill "$relay_pid" 2>/dev/null || true; fi
    rm -rf "$work"
}
trap cleanup EXIT

GOWORK=off go -C relay build -o "$work/uterm-relay" ./cmd/uterm-relay

port=${UTERM_RELAY_TEST_PORT:-47399}
export RELAY_DATA="$work/data"
export RELAY_LISTEN="127.0.0.1:$port"
export RELAY_PUBLIC_HOST=127.0.0.1
export RELAY_PUBLIC_PORT="$port"
export RELAY_NAME="E2E"
export RELAY_RATE_PER_IP=0

"$work/uterm-relay" serve > "$work/relay.log" 2>&1 &
relay_pid=$!

for _ in $(seq 1 100); do
    if "$work/uterm-relay" status > /dev/null 2>&1; then break; fi
    sleep 0.1
done
"$work/uterm-relay" status > /dev/null

config=$("$work/uterm-relay" config)
set +e
TEST_RUNNER_UTERM_RELAY_CONFIG="$config" TEST_RUNNER_UTERM_RELAY_VERSION="$("$work/uterm-relay" version)" xcodebuild test \
    -only-testing:uTermTests/RemoteRelayEndToEndTests \
    -only-testing:uTermTests/RemoteGroupRelayMailboxEndToEndTests "$@"
status=$?
set -e
if [ "$status" -ne 0 ]; then
    printf '%s\n' "--- relay log ---" >&2
    tail -40 "$work/relay.log" >&2
fi
exit "$status"
