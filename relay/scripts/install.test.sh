#!/usr/bin/env bash
# Self-test for install.sh: installs into a scratch tree with a fake systemctl and ss,
# from a file:// "OSS" holding a host-built uterm-relay. Run: bash relay/scripts/install.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/install.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

# A fake OSS with two versions. "Linux" binaries are built for this host so they run here.
ARCH=amd64
OSS="$WORK/oss"
# Distinct versions are wrappers around one host build: `version` answers, everything else runs the real relay.
build_versioned() { # version
	mkdir -p "$OSS/$1"
	cat >"$OSS/$1/uterm-relay-linux-$ARCH" <<EOF
#!/bin/sh
if [ "\${1:-}" = version ]; then echo $1; exit 0; fi
exec "$WORK/real-relay" "\$@"
EOF
	chmod 755 "$OSS/$1/uterm-relay-linux-$ARCH"
	(cd "$OSS/$1" && echo "$(sha "uterm-relay-linux-$ARCH")  uterm-relay-linux-$ARCH" >SHA256SUMS)
}
(cd "$HERE/.." && GOWORK=off CGO_ENABLED=0 go build -o "$WORK/real-relay" ./cmd/uterm-relay)
build_versioned 1.1.0
build_versioned 1.2.0
# A broken release: right checksum, but the service never comes up.
build_versioned 9.9.9
echo '{ "version": "1.1.0" }' >"$OSS/latest.json"

# Fake system tools.
BIN="$WORK/fakebin"
mkdir -p "$BIN"
cat >"$BIN/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >>"$FAKE_STATE/calls"
case "$1" in
is-active)
	# The 9.9.9 build "crashes" on start.
	if grep -q 9.9.9 "$UTERM_RELAY_ROOT/usr/local/bin/uterm-relay" 2>/dev/null; then exit 3; fi
	[ -f "$FAKE_STATE/active" ] ;;
restart) touch "$FAKE_STATE/active" ;;
show) exit 0 ;;
*) exit 0 ;;
esac
EOF
cat >"$BIN/ss" <<'EOF'
#!/bin/sh
echo "Netid State Recv-Q Send-Q Local Address:Port Peer Address:Port"
[ -n "${FAKE_BUSY_PORT:-}" ] && echo "tcp LISTEN 0 4096 0.0.0.0:$FAKE_BUSY_PORT 0.0.0.0:*"
exit 0
EOF
chmod 755 "$BIN"/*

ROOT="$WORK/root"
mkdir -p "$ROOT/home/$(id -un)" "$WORK/state"
export PATH="$BIN:$PATH"
export UTERM_RELAY_ROOT="$ROOT" UTERM_RELAY_BASE_URL="file://$OSS" UTERM_RELAY_ARCH=x86_64 FAKE_STATE="$WORK/state"

run() { sh "$SCRIPT" "$@"; }

# --- install --------------------------------------------------------------
out=$(run install --port 47999 --public-host relay.example.com --name "home relay")
echo "$out" | grep -qx 'version=1.1.0' || fail "install version: $out"
echo "$out" | grep -qx 'port=47999' || fail "install port: $out"
echo "$out" | grep -qx 'endpoint=relay.example.com:47999' || fail "install endpoint: $out"
client="$ROOT/home/$(id -un)/.config/uterm-relay/client.json"
echo "$out" | grep -qx "client_config=$client" || fail "client path: $out"
[ -f "$client" ] || fail "client.json missing"
[ "$(stat -f %Lp "$client")" = 600 ] || fail "client.json mode $(stat -f %Lp "$client")"
key=$(sed -n 's/.*"key": "\([^"]*\)".*/\1/p' "$client")
[ -n "$key" ] || fail "client.json has no key"
grep -q '"name": "home relay"' "$client" || fail "name not passed: $(cat "$client")"
echo "$out" | grep -qF "$key" && fail "install printed the member key"
grep -qx 'RELAY_LISTEN=:47999' "$ROOT/etc/uterm-relay/relay.env" || fail "env file"
grep -q 'DynamicUser=yes' "$ROOT/etc/systemd/system/uterm-relay.service" || fail "unit file"
relay_id=$(echo "$out" | sed -n 's/^relay_id=//p')
grep -q "\"relayID\": \"$relay_id\"" "$client" || fail "relay_id does not match client.json"
pass "install writes the binary, unit, env and a private client.json without printing the key"

# --- no --port: a random free high port, not the well-known default --------
ROOT2="$WORK/root2"
mkdir -p "$ROOT2/home/$(id -un)"
out=$(UTERM_RELAY_ROOT="$ROOT2" run install --public-host relay.example.com)
random=$(echo "$out" | sed -n 's/^port=//p')
[ -n "$random" ] && [ "$random" -ge 20000 ] && [ "$random" -le 32767 ] || fail "random port out of range: $out"
[ "$random" != 47310 ] || fail "random port is the default"
grep -qx "RELAY_LISTEN=:$random" "$ROOT2/etc/uterm-relay/relay.env" || fail "random port not in env file"
pass "without --port a random high port is picked ($random)"

# --- reinstall on the port the relay already holds -------------------------
FAKE_BUSY_PORT=47999 run install --port 47999 --public-host relay.example.com >/dev/null ||
	fail "reinstall on own port refused"
pass "reinstalling on the relay's own port is allowed"

# --- port taken by someone else -------------------------------------------
if FAKE_BUSY_PORT=48000 run install --port 48000 --public-host relay.example.com 2>"$WORK/err" >/dev/null; then
	fail "busy port accepted"
fi
grep -q '已被占用' "$WORK/err" || fail "busy port message: $(cat "$WORK/err")"
pass "a port taken by another program is refused"

# --- bad input -------------------------------------------------------------
run install --port 47999 2>/dev/null && fail "missing --public-host accepted"
run install --port 70000 --public-host x 2>/dev/null && fail "port out of range accepted"
run install --port 47999 --public-host 'a b' 2>/dev/null && fail "space in host accepted"
pass "bad arguments are refused"

# --- update ---------------------------------------------------------------
out=$(run update)
echo "$out" | grep -qx 'updated=no' || fail "update to same version: $out"
echo '{ "version": "1.2.0" }' >"$OSS/latest.json"
out=$(run update)
echo "$out" | grep -qx 'previous=1.1.0' || fail "update previous: $out"
echo "$out" | grep -qx 'version=1.2.0' || fail "update version: $out"
[ "$("$ROOT/usr/local/bin/uterm-relay" version)" = 1.2.0 ] || fail "binary not replaced"
pass "update replaces the binary and restarts"

# --- rollback --------------------------------------------------------------
if run update --version 9.9.9 >/dev/null 2>"$WORK/err"; then fail "broken update succeeded"; fi
[ "$("$ROOT/usr/local/bin/uterm-relay" version)" = 1.2.0 ] || fail "not rolled back"
grep -q '已换回 1.2.0' "$WORK/err" || fail "rollback message: $(cat "$WORK/err")"
pass "an update that will not start is rolled back"

# --- checksum mismatch ----------------------------------------------------
echo "0000  uterm-relay-linux-$ARCH" >"$OSS/1.2.0/SHA256SUMS"
mkdir -p "$OSS/1.3.0" && cp "$OSS/1.2.0/uterm-relay-linux-$ARCH" "$OSS/1.3.0/" && cp "$OSS/1.2.0/SHA256SUMS" "$OSS/1.3.0/"
if run update --version 1.3.0 >/dev/null 2>"$WORK/err"; then fail "bad checksum accepted"; fi
grep -q '校验不符' "$WORK/err" || fail "checksum message: $(cat "$WORK/err")"
[ "$("$ROOT/usr/local/bin/uterm-relay" version)" = 1.2.0 ] || fail "binary changed despite bad checksum"
pass "a binary with the wrong checksum is not installed"

# --- status and client-config never print the key -------------------------
out=$(run status)
echo "$out" | grep -qx 'installed_version=1.2.0' || fail "status: $out"
echo "$out" | grep -qx 'latest_version=1.2.0' || fail "status latest: $out"
echo "$out" | grep -qF "$key" && fail "status printed the key"
out=$(run client-config)
echo "$out" | grep -qF "$key" && fail "client-config printed the key"
echo "$out" | grep -q '^client_config=' || fail "client-config: $out"
pass "status and client-config keep the key out of their output"

echo "all install.sh tests passed"
