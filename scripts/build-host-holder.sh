#!/usr/bin/env bash
# 编出主机上的会话保持进程（holder/，Go），压好放进 App 的资源目录。两个 App 都带着它，
# 第一次连某台主机时传上去（见 uTerm/Services/SSH/HostHolder/）。
#
#   scripts/build-host-holder.sh          # 源码没变就什么都不做
#   scripts/build-host-holder.sh --force
#
# 产物不进版本库：uTerm/Services/SSH/HostHolder/Binaries/uterm-holder-linux-{amd64,arm64}.lzma
# 用 LZMA 而不是 LZFSE：两份合计小 0.68 MB（2.9 → 2.2 MB），解压只在第一次上传时做一次。
# 需要 Go（版本见 holder/go.mod）和系统自带的 compression_tool。
set -euo pipefail

cd "$(dirname "$0")/.."
output="uTerm/Services/SSH/HostHolder/Binaries"
stamp="build/host-holder.stamp"
architectures="amd64 arm64"

command -v go >/dev/null || { echo "build-host-holder: 找不到 go，装了之后再跑（brew install go）" >&2; exit 1; }

# 指纹 = 全部非测试源码 + go.mod + Go 版本。和上次一样、产物也都在，就不用重编。
fingerprint="$( { go version; cat holder/go.mod; find holder -name '*.go' ! -name '*_test.go' -print0 | sort -z | xargs -0 cat; } \
    | shasum -a 256 | cut -d' ' -f1)"
up_to_date=1
for arch in $architectures; do
    [ -f "$output/uterm-holder-linux-$arch.lzma" ] || up_to_date=0
done
if [ "${1:-}" != "--force" ] && [ "$up_to_date" = 1 ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$fingerprint" ]; then
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$output" build
# Binaries/ 在同步组里，留着的旧格式产物会被一起打进包。
rm -f "$output"/*.lzfse
for arch in $architectures; do
    (cd holder && GOWORK=off GOOS=linux GOARCH="$arch" CGO_ENABLED=0 \
        go build -trimpath -ldflags='-s -w -buildid=' -o "$work/uterm-holder-linux-$arch" ./cmd/uterm-holder)
    compression_tool -encode -a lzma -i "$work/uterm-holder-linux-$arch" -o "$output/uterm-holder-linux-$arch.lzma"
done
echo "$fingerprint" > "$stamp"
version="$(sed -n 's/^const version = "\(.*\)"/\1/p' holder/cmd/uterm-holder/main.go)"
echo "Built uterm-holder $version for linux ($architectures) into $output"
