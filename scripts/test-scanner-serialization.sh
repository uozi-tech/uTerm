#!/usr/bin/env bash
# Check full-buffer serialization and restoration against the vendored scanners.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
for language in python yaml; do
  defines=(-DSCANNER_TEST=1)
  if [ "$language" = python ]; then defines=(-DPYTHON); fi
  xcrun clang -Werror=shorten-64-to-32 "${defines[@]}" \
    -DSCANNER_SOURCE=\""$root/vendor/tree-sitter-grammars/$language/src/scanner.c"\" \
    "$root/scripts/tests/scanner-serialization.c" -o "$test_dir/$language"
  "$test_dir/$language"
  echo "$language: serialization boundary and round-trip passed"
done
