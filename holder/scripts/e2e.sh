#!/usr/bin/env bash
# 起一个真的 sshd（容器），把 uterm-holder 放上去，经 ssh 的 exec 通道跑端到端用例。
#
#   holder/scripts/e2e.sh                 # 跑全部端到端用例
#   holder/scripts/e2e.sh -run Latency -v # 其余参数原样交给 go test
#
# 需要 docker 和本机的 ssh。测量用例（延迟、吞吐）默认跳过，UTERM_HOLDER_MEASURE=1 打开。
set -euo pipefail

cd "$(dirname "$0")/.."
work="$(mktemp -d /tmp/uterm-holder-e2e.XXXXXX)"
container=""
cleanup() {
    [ -n "$container" ] && docker rm -f "$container" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N '' -f "$work/key"
cp "$work/key.pub" e2e/sshd/authorized_keys
docker build -q -t uterm-holder-e2e-sshd e2e/sshd >/dev/null
rm -f e2e/sshd/authorized_keys

container="$(docker run -d --rm -p 127.0.0.1::22 uterm-holder-e2e-sshd)"
port="$(docker port "$container" 22/tcp | sed 's/.*://')"
arch="$(docker exec "$container" uname -m)"
case "$arch" in
    x86_64) goarch=amd64 ;;
    aarch64 | arm64) goarch=arm64 ;;
    *) echo "unsupported container arch: $arch" >&2; exit 1 ;;
esac

GOWORK=off GOOS=linux GOARCH="$goarch" CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' \
    -o "$work/uterm-holder" ./cmd/uterm-holder

ssh_options=(-p "$port" -i "$work/key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR -o IdentitiesOnly=yes -o BatchMode=yes)
for _ in $(seq 1 50); do
    ssh "${ssh_options[@]}" dev@127.0.0.1 true 2>/dev/null && break
    sleep 0.2
done
# 和 App 一样：放在用户目录下，不需要 root。
ssh "${ssh_options[@]}" dev@127.0.0.1 'mkdir -p ~/.local/share/uterm/bin'
scp -q -P "$port" -i "$work/key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "$work/uterm-holder" dev@127.0.0.1:.local/share/uterm/bin/uterm-holder

export UTERM_HOLDER_E2E_SSH="ssh ${ssh_options[*]} dev@127.0.0.1"
export UTERM_HOLDER_E2E_BIN='$HOME/.local/share/uterm/bin/uterm-holder'
export UTERM_HOLDER_E2E_CONTAINER="$container"
GOWORK=off go test -count=1 ./e2e "$@"
