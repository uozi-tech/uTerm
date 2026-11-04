#!/bin/bash
# 并行跑全量，再把并行时失败的用例串行复核一遍，串行结果才算数。
#
# 悬停探针要独占合成光标、性能探针对负载敏感，并行时会假红；只有串行也失败才算真失败。
# 并行红、串行绿的用例会列出来，它们不算失败，但也说明这条用例并行不了。
#
# 用法：scripts/test-parallel.sh <scheme> <destination> <workers> [传给 xcodebuild 的其余参数...]
set -uo pipefail

if [ "$#" -lt 3 ]; then
    printf '%s\n' "usage: $0 <scheme> <destination> <workers> [xcodebuild args...]" >&2
    exit 2
fi

scheme=$1
destination=$2
workers=$3
shift 3

results_dir=build/test-results
parallel_bundle="$results_dir/$scheme-parallel.xcresult"
serial_bundle="$results_dir/$scheme-serial.xcresult"
log="$results_dir/$scheme.log"
mkdir -p "$results_dir"
rm -rf "$parallel_bundle" "$serial_bundle"
: > "$log"

run() {
    xcodebuild "$@" -scheme "$scheme" -destination "$destination" >> "$log" 2>&1
}

# 读 xcresult：第一行是通过 / 失败 / 跳过 / 总数，其后每行一个失败用例的 -only-testing 标识。
summary_py=$(cat <<'PY'
import json, sys
s = json.load(sys.stdin)
print(f"{s['passedTests']} passed, {s['failedTests']} failed, {s['skippedTests']} skipped, {s['totalTestCount']} total")
ids = {f"{f['targetName']}/{f['testIdentifierString'].removesuffix('()')}" for f in s.get('testFailures', [])}
print("\n".join(sorted(ids)))
PY
)

summarize() {
    xcrun xcresulttool get test-results summary --path "$1" | python3 -I -c "$summary_py"
}

# 钥匙串用例在锁屏时必失败（-25308），串行复核也救不回来；先说清楚，免得当成回归。
if [ "$(ioreg -n Root -d1 -a | plutil -extract IOConsoleUsers.0.CGSSessionScreenIsLocked raw - 2>/dev/null)" = true ]; then
    printf '%s\n' 'warning: screen is locked; keychain tests will fail with -25308' >&2
fi

if ! run build-for-testing "$@"; then
    printf '%s\n' "build-for-testing failed; see $log" >&2
    exit 1
fi

start=$SECONDS
run test-without-building "$@" \
    -parallel-testing-enabled YES \
    -parallel-testing-worker-count "$workers" \
    -resultBundlePath "$parallel_bundle"
parallel_summary=$(summarize "$parallel_bundle") || {
    printf '%s\n' "no parallel test results; see $log" >&2
    exit 1
}
printf 'parallel (%s workers, %ss): %s\n' "$workers" "$((SECONDS - start))" "$(head -n 1 <<<"$parallel_summary")"

failed=$(tail -n +2 <<<"$parallel_summary")
if [ -z "$failed" ]; then
    exit 0
fi

only_testing=()
while IFS= read -r test_id; do
    only_testing+=("-only-testing:$test_id")
done <<<"$failed"

start=$SECONDS
run test-without-building "$@" \
    -parallel-testing-enabled NO \
    -resultBundlePath "$serial_bundle" \
    "${only_testing[@]}"
serial_summary=$(summarize "$serial_bundle") || {
    printf '%s\n' "no serial test results; see $log" >&2
    exit 1
}
printf 'serial recheck (%ss): %s\n' "$((SECONDS - start))" "$(head -n 1 <<<"$serial_summary")"

still_failing=$(tail -n +2 <<<"$serial_summary")
if [ -n "$still_failing" ]; then
    printf 'FAILED:\n%s\n' "$still_failing"
    exit 1
fi
printf 'failed only in parallel:\n%s\n' "$failed"
