#!/usr/bin/env bash
# scripts/translations.py 的离线自测：造一个小目录，核 check / missing / merge 的判定。
set -euo pipefail
cd "$(dirname "$0")/.."
tool="python3 -I scripts/translations.py"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

cat > "$tmp/Localizable.xcstrings" <<'EOF'
{
  "sourceLanguage" : "zh-Hans",
  "strings" : {
    "" : { "shouldTranslate" : false },
    "打开" : { },
    "%lld 台主机" : { },
    "%@ 上的 %@" : { }
  },
  "version" : "1.0"
}
EOF

$tool check --catalog "$tmp/Localizable.xcstrings" >/dev/null 2>&1 && fail "缺翻译时 check 应失败"
$tool missing --catalog "$tmp/Localizable.xcstrings" --out "$tmp/todo.json" >/dev/null
python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); assert len(d)==3, d" "$tmp/todo.json" || fail "missing 应列出 3 个键"

cat > "$tmp/good.json" <<'EOF'
{
  "打开": {"en": "Open", "zh-Hant": "開啟", "ja": "開く", "ko": "열기"},
  "%lld 台主机": {"en": {"one": "%lld host", "other": "%lld hosts"}, "zh-Hant": "%lld 台主機", "ja": "%lld 台のホスト", "ko": "호스트 %lld대"},
  "%@ 上的 %@": {"en": "%2$@ on %1$@", "zh-Hant": "%1$@ 上的 %2$@", "ja": "%1$@ の %2$@", "ko": "%1$@의 %2$@"}
}
EOF
$tool merge --catalog "$tmp/Localizable.xcstrings" "$tmp/good.json" >/dev/null || fail "合格的译文应全部并入"
$tool check --catalog "$tmp/Localizable.xcstrings" >/dev/null || fail "并入后 check 应通过"

cat > "$tmp/bad.json" <<'EOF'
{
  "%@ 上的 %@": {"en": "%@ on %lld", "ja": "%1$@ の %@", "ko": "50% %1$@ %2$@", "zh-Hant": ""},
  "不存在": {"en": "x"}
}
EOF
out=$($tool merge --catalog "$tmp/Localizable.xcstrings" "$tmp/bad.json" 2>&1) && fail "坏译文应让 merge 非零退出"
for want in "未知的键" "[en]" "[ja]" "[ko]" "[zh-Hant]"; do
  [[ "$out" == *"$want"* ]] || fail "merge 输出里应有 $want：$out"
done
$tool check --catalog "$tmp/Localizable.xcstrings" >/dev/null || fail "坏译文不应覆盖已有的好译文"
echo "translations 自测全部通过"
