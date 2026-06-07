#!/usr/bin/env bash
# Self-contained test for bump-version.sh. Uses a temp xcconfig via VERSION_XCCONFIG.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUMP="$SCRIPT_DIR/bump-version.sh"
fail=0

assert_eq() {
	if [ "$1" != "$2" ]; then
		echo "FAIL: expected '$2' got '$1' ($3)"; fail=1
	else
		echo "ok: $3"
	fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cfg="$tmp/Version.xcconfig"
printf 'MARKETING_VERSION = 1.2.3\n' > "$cfg"
export VERSION_XCCONFIG="$cfg"

assert_eq "$("$BUMP" print)"      "1.2.3" "print"
assert_eq "$("$BUMP" patch)"      "1.2.4" "patch (1.2.3 -> 1.2.4)"
assert_eq "$("$BUMP" minor)"      "1.3.0" "minor (1.2.4 -> 1.3.0)"
assert_eq "$("$BUMP" major)"      "2.0.0" "major (1.3.0 -> 2.0.0)"
assert_eq "$("$BUMP" set 5.6.7)"  "5.6.7" "set"
assert_eq "$("$BUMP" print)"      "5.6.7" "persisted after set"

if "$BUMP" set 1.2 2>/dev/null; then echo "FAIL: invalid set '1.2' accepted"; fail=1; else echo "ok: invalid set rejected"; fi
if "$BUMP" bogus 2>/dev/null;  then echo "FAIL: unknown cmd accepted";       fail=1; else echo "ok: unknown cmd rejected"; fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "TESTS FAILED"; exit 1; }
