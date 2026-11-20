#!/bin/sh
# Install, update and inspect uterm-relay on a Linux server with systemd.
#
#   curl -fsSL <发布地址>/install.sh | sudo sh -s -- install --public-host relay.example.com
#
# <发布地址> 是 `make relay-dist UTERM_RELAY_BASE_URL=<地址>` 打包时写进来的（放 latest.json、各版本二进制的目录），
# 也可以运行时用环境变量 UTERM_RELAY_BASE_URL 覆盖。
#
# Subcommands:
#   install --public-host H [--port P] [--name N] [--open-firewall] [--version V]
#                             without --port a random free port in 1000-65535 is picked: every relay on
#                             its own port, so a scan of the default one finds nothing
#   update [--version V]      replace the binary with the latest (or V) and restart; rolls back if it will not start
#   status                    installed / latest version, service state, online hosts
#   client-config             write the device configuration again (after `uterm-relay rotate`)
#
# Nothing here prints the member key. The device configuration goes to
# ~/.config/uterm-relay/client.json of the user who ran sudo (0600), where uTerm reads it over SFTP.
# Every result is a `key=value` line on stdout; problems go to stderr.
set -eu

BASE_URL=${UTERM_RELAY_BASE_URL:-@RELAY_BASE_URL@}
# Tests install into a scratch tree and run without root.
ROOT=${UTERM_RELAY_ROOT:-}
SERVICE=uterm-relay
BIN=$ROOT/usr/local/bin/uterm-relay
ENV_DIR=$ROOT/etc/uterm-relay
ENV_FILE=$ENV_DIR/relay.env
UNIT=$ROOT/etc/systemd/system/$SERVICE.service
DATA=$ROOT/var/lib/uterm-relay
CLIENT_DIR_NAME=.config/uterm-relay

die() {
	echo "uterm-relay install: $*" >&2
	exit 1
}

case $BASE_URL in
	@*) die "这份安装脚本没有发布地址：设 UTERM_RELAY_BASE_URL=<放 latest.json 与二进制的地址> 再跑，或从源码编译（见 uTerm 仓库 relay/README.md）" ;;
esac

say() { echo "$1=$2"; }

need_root() {
	[ -n "$ROOT" ] && return 0
	[ "$(id -u)" = 0 ] || die "需要 root：用 root 登录，或在命令前加 sudo"
}

need() {
	command -v "$1" >/dev/null 2>&1 || die "缺少 $1"
}

fetch() { # url dest
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --retry 2 -o "$2" "$1"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$2" "$1"
	else
		die "需要 curl 或 wget"
	fi
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

arch() {
	machine=${UTERM_RELAY_ARCH:-$(uname -m)}
	case "$machine" in
	x86_64 | amd64) echo amd64 ;;
	aarch64 | arm64) echo arm64 ;;
	*) die "不支持的 CPU 架构：${machine}（只有 amd64 和 arm64）" ;;
	esac
}

latest_version() {
	file=$WORK/latest.json
	fetch "$BASE_URL/latest.json" "$file" || die "取不到 $BASE_URL/latest.json"
	version=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -n 1)
	[ -n "$version" ] || die "latest.json 里没有 version"
	echo "$version"
}

# download_binary <version> -> $WORK/uterm-relay, checked against SHA256SUMS
download_binary() {
	asset=uterm-relay-linux-$(arch)
	fetch "$BASE_URL/$1/$asset" "$WORK/uterm-relay" || die "下载 $asset $1 失败"
	fetch "$BASE_URL/$1/SHA256SUMS" "$WORK/SHA256SUMS" || die "下载 SHA256SUMS 失败"
	expected=$(awk -v n="$asset" '$2 == n { print $1 }' "$WORK/SHA256SUMS")
	[ -n "$expected" ] || die "SHA256SUMS 里没有 $asset"
	actual=$(sha256_of "$WORK/uterm-relay")
	[ "$expected" = "$actual" ] || die "$asset 校验不符：期望 ${expected}，实际 $actual"
	chmod 755 "$WORK/uterm-relay"
	"$WORK/uterm-relay" version >/dev/null 2>&1 || die "下载的程序在这台机器上跑不起来"
}

installed_version() {
	if [ -x "$BIN" ]; then "$BIN" version 2>/dev/null || echo unknown; else echo none; fi
}

# Loads RELAY_* from the env file, or from the unit when it was set up by hand with Environment= lines.
load_settings() {
	if [ -f "$ENV_FILE" ]; then
		set -a
		# shellcheck disable=SC1090
		. "$ENV_FILE"
		set +a
	elif [ -z "$ROOT" ] && command -v systemctl >/dev/null 2>&1; then
		for pair in $(systemctl show -p Environment --value "$SERVICE" 2>/dev/null); do
			# shellcheck disable=SC2163 # exports NAME=value as written in the unit
			case "$pair" in RELAY_*=*) export "$pair" ;; esac
		done
	fi
	: "${RELAY_DATA:=$DATA}"
	export RELAY_DATA
}

# A random free port in 1000-65535. The unit grants CAP_NET_BIND_SERVICE, so ports below 1024 work too.
random_port() {
	tries=0
	while [ $tries -lt 50 ]; do
		candidate=$(awk -v seed="$$$tries$(date +%s)" 'BEGIN { srand(seed); print 1000 + int(rand() * 64536) }')
		if ! port_taken "$candidate"; then
			echo "$candidate"
			return 0
		fi
		tries=$((tries + 1))
	done
	die "找不到空闲端口，用 --port 指定一个"
}

port_taken() {
	command -v ss >/dev/null 2>&1 || return 1
	ss -lntu 2>/dev/null | awk 'NR > 1 { print $5 }' | grep -Eq "[:.]$1\$"
}

wait_active() {
	i=0
	while [ $i -lt 20 ]; do
		systemctl is-active --quiet "$SERVICE" && return 0
		sleep 0.5
		i=$((i + 1))
	done
	return 1
}

# The user whose home receives client.json: whoever ran sudo, else the current user.
target_user() {
	if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then echo "$SUDO_USER"; else id -un; fi
}

target_home() {
	if [ -n "$ROOT" ]; then
		echo "$ROOT/home/$1"
	else
		getent passwd "$1" | cut -d: -f6
	fi
}

write_client_config() {
	load_settings
	[ -n "${RELAY_PUBLIC_HOST:-}" ] || die "没有设置对外地址（RELAY_PUBLIC_HOST）"
	user=$(target_user)
	home=$(target_home "$user")
	[ -n "$home" ] || die "找不到用户 $user 的主目录"
	dir=$home/$CLIENT_DIR_NAME
	mkdir -p "$dir"
	chmod 700 "$dir"
	out=$dir/client.json
	umask 077
	"$BIN" config >"$out.tmp" || {
		rm -f "$out.tmp"
		die "生成设备配置失败"
	}
	mv "$out.tmp" "$out"
	if [ -z "$ROOT" ]; then chown -R "$user": "$dir"; fi
	relay_id=$(sed -n 's/.*"relayID"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$out" | head -n 1)
	say relay_id "$relay_id"
	say endpoint "$RELAY_PUBLIC_HOST:${RELAY_PUBLIC_PORT:-47310}"
	say client_config "$out"
}

write_unit() {
	mkdir -p "$(dirname "$UNIT")"
	cat >"$UNIT" <<EOF
[Unit]
Description=uTerm relay
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=/etc/uterm-relay/relay.env
ExecStart=/usr/local/bin/uterm-relay serve
DynamicUser=yes
StateDirectory=uterm-relay
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
LimitNOFILE=65536
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
}

open_firewall() {
	if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
		ufw allow "$1/tcp" >/dev/null && ufw allow "$1/udp" >/dev/null
		say firewall ufw-opened
	elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
		firewall-cmd --permanent --add-port="$1/tcp" >/dev/null
		firewall-cmd --permanent --add-port="$1/udp" >/dev/null
		firewall-cmd --reload >/dev/null
		say firewall firewalld-opened
	else
		say firewall none
	fi
}

firewall_hint() {
	if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
		say firewall ufw-active-not-opened
	elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
		say firewall firewalld-active-not-opened
	else
		say firewall none
	fi
}

cmd_install() {
	port="" public_host="" name="" version="" firewall=0
	while [ $# -gt 0 ]; do
		case "$1" in
		--port) port=${2:-}; shift 2 ;;
		--public-host) public_host=${2:-}; shift 2 ;;
		--name) name=${2:-}; shift 2 ;;
		--version) version=${2:-}; shift 2 ;;
		--open-firewall) firewall=1; shift ;;
		*) die "不认识的参数：$1" ;;
		esac
	done
	[ -n "$port" ] || port=$(random_port) || exit 1
	case "$port" in *[!0-9]*) die "端口要是数字：${port}" ;; esac
	[ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "端口超出范围：$port"
	[ -n "$public_host" ] || die "要用 --public-host 指定设备连接用的域名或公网 IP"
	case "$public_host" in *[[:space:]\"\'\$\`\\]*) die "对外地址里有不允许的字符" ;; esac
	case "$name" in *[\"\'\$\`\\]*) die "名字里有不允许的字符" ;; esac
	need_root
	need systemctl

	if port_taken "$port"; then
		# Reinstalling on the port this relay already listens on is fine.
		current=$(sed -n 's/^RELAY_PUBLIC_PORT=//p' "$ENV_FILE" 2>/dev/null || true)
		if [ "$current" != "$port" ] || ! systemctl is-active --quiet "$SERVICE"; then
			die "端口 $port 已被占用，换一个端口"
		fi
	fi
	[ -n "$version" ] || version=$(latest_version)
	download_binary "$version"

	mkdir -p "$(dirname "$BIN")" "$ENV_DIR"
	install -m 755 "$WORK/uterm-relay" "$BIN"
	umask 022
	{
		echo "RELAY_DATA=$DATA"
		echo "RELAY_LISTEN=:$port"
		echo "RELAY_PUBLIC_HOST=$public_host"
		echo "RELAY_PUBLIC_PORT=$port"
		[ -z "$name" ] || echo "RELAY_NAME=\"$name\""
	} >"$ENV_FILE"
	write_unit
	systemctl daemon-reload
	systemctl enable "$SERVICE" >/dev/null 2>&1 || true
	systemctl restart "$SERVICE"
	wait_active || die "服务没起来：journalctl -u $SERVICE -n 50"

	say version "$version"
	say port "$port"
	if [ $firewall = 1 ]; then open_firewall "$port"; else firewall_hint; fi
	write_client_config
}

cmd_update() {
	version=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--version) version=${2:-}; shift 2 ;;
		*) die "不认识的参数：$1" ;;
		esac
	done
	need_root
	need systemctl
	[ -x "$BIN" ] || die "没有装过 uterm-relay（$BIN 不存在），先用 install"
	previous=$(installed_version)
	[ -n "$version" ] || version=$(latest_version)
	say previous "$previous"
	if [ "$previous" = "$version" ]; then
		say version "$version"
		say updated no
		return 0
	fi
	download_binary "$version"
	cp -p "$BIN" "$BIN.prev"
	install -m 755 "$WORK/uterm-relay" "$BIN"
	systemctl restart "$SERVICE"
	if ! wait_active; then
		install -m 755 "$BIN.prev" "$BIN"
		systemctl restart "$SERVICE" || true
		die "$version 起不来，已换回 ${previous}：journalctl -u $SERVICE -n 50"
	fi
	say version "$version"
	say updated yes
}

cmd_status() {
	say installed_version "$(installed_version)"
	latest=$(latest_version 2>/dev/null || echo unknown)
	say latest_version "$latest"
	if command -v systemctl >/dev/null 2>&1; then
		say active "$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
	fi
	load_settings
	say port "${RELAY_PUBLIC_PORT:-47310}"
	say public_host "${RELAY_PUBLIC_HOST:-}"
	if [ -x "$BIN" ] && { [ -n "$ROOT" ] || [ "$(id -u)" = 0 ]; }; then
		"$BIN" status 2>/dev/null | sed 's/^/relay: /' || true
	fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

command=${1:-}
[ $# -gt 0 ] && shift
case "$command" in
install) cmd_install "$@" ;;
update) cmd_update "$@" ;;
status) cmd_status "$@" ;;
client-config)
	need_root
	write_client_config
	;;
*)
	sed -n '2,14p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' >&2 || true
	die "用法：install.sh install|update|status|client-config"
	;;
esac
