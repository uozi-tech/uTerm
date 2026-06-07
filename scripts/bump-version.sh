#!/usr/bin/env bash
# Single source of truth version manager for uTerm.
# Reads / writes MARKETING_VERSION (semver X.Y.Z) in Config/Version.xcconfig.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
XCCONFIG="${VERSION_XCCONFIG:-$REPO_ROOT/Config/Version.xcconfig}"

usage() {
	cat >&2 <<'EOF'
Usage: bump-version.sh <command>
  print            Print current MARKETING_VERSION
  patch            X.Y.Z -> X.Y.(Z+1)
  minor            X.Y.Z -> X.(Y+1).0
  major            X.Y.Z -> (X+1).0.0
  set X.Y.Z        Set explicit version
EOF
	exit 2
}

read_version() {
	if [ ! -f "$XCCONFIG" ]; then
		echo "ERROR: $XCCONFIG not found" >&2
		exit 1
	fi
	local v
	v="$(grep -E '^[[:space:]]*MARKETING_VERSION[[:space:]]*=' "$XCCONFIG" | head -n1 | sed -E 's/.*=[[:space:]]*//; s/[[:space:]]*$//')"
	if ! printf '%s' "$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
		echo "ERROR: MARKETING_VERSION in $XCCONFIG is not semver X.Y.Z: '$v'" >&2
		exit 1
	fi
	printf '%s' "$v"
}

write_version() {
	local new="$1"
	if ! printf '%s' "$new" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
		echo "ERROR: version must be X.Y.Z: '$new'" >&2
		exit 1
	fi
	local tmp
	tmp="$(mktemp)"
	sed -E "s/^([[:space:]]*MARKETING_VERSION[[:space:]]*=[[:space:]]*).*/\1$new/" "$XCCONFIG" > "$tmp"
	mv "$tmp" "$XCCONFIG"
	printf '%s\n' "$new"
}

cmd="${1:-}"
case "$cmd" in
	print)
		read_version; echo
		;;
	patch|minor|major)
		cur="$(read_version)"
		IFS=. read -r vmajor vminor vpatch <<EOF
$cur
EOF
		case "$cmd" in
			patch) vpatch=$((vpatch + 1)) ;;
			minor) vminor=$((vminor + 1)); vpatch=0 ;;
			major) vmajor=$((vmajor + 1)); vminor=0; vpatch=0 ;;
		esac
		write_version "$vmajor.$vminor.$vpatch"
		;;
	set)
		[ "$#" -eq 2 ] || usage
		write_version "$2"
		;;
	*)
		usage
		;;
esac
