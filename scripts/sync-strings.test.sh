#!/usr/bin/env bash
# scripts/sync-strings.swift 的离线自测：假目录 + 假 .stringsdata，核合并规则与 Xcode 格式。
# 不需要 Xcode 工程，只要 swiftc。跑法：bash scripts/sync-strings.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fail=0

ok()   { echo "ok: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected '$2', got '$1')"; fi; }
assert_contains() { if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3 (missing '$2')"; fi; }
assert_not_contains() { if grep -qF -- "$2" "$1"; then bad "$3 (unexpected '$2')"; else ok "$3"; fi; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tool="$tmp/sync-strings"
swiftc -O -o "$tool" "$SCRIPT_DIR/sync-strings.swift"

# --- 夹具：一份 Xcode 写出来的目录（含已翻译 / 未翻译 / stale / manual 四种条目） -------------
cat > "$tmp/Localizable.xcstrings" <<'EOF'
{
  "sourceLanguage" : "zh-Hans",
  "strings" : {
    "保留给手写" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Kept by hand"
          }
        }
      }
    },
    "已翻译但代码里没了" : {
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Gone but translated"
          }
        }
      }
    },
    "未翻译且代码里没了" : {

    },
    "曾经 stale 现在回来了" : {
      "extractionState" : "stale",
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Back again"
          }
        }
      }
    },
    "连接" : {

    }
  },
  "version" : "1.0"
}
EOF
cp "$tmp/Localizable.xcstrings" "$tmp/original.xcstrings"

mkdir -p "$tmp/mac/arm64" "$tmp/ios/arm64"
cat > "$tmp/mac/arm64/A.stringsdata" <<'EOF'
{"source":"/src/A.swift","tables":{"Localizable":[
  {"comment":"","key":"连接","location":{"startingColumn":1,"startingLine":1}},
  {"comment":"侧栏标题","key":"同步诊断","location":{"startingColumn":1,"startingLine":2}},
  {"comment":"","key":"%@:%@","location":{"startingColumn":1,"startingLine":3}},
  {"comment":"","key":"%@：%@","location":{"startingColumn":1,"startingLine":4}}
]}}
EOF
cat > "$tmp/ios/arm64/B.stringsdata" <<'EOF'
{"source":"/src/B.swift","tables":{"Localizable":[
  {"comment":"","key":"曾经 stale 现在回来了","location":{"startingColumn":1,"startingLine":1}},
  {"comment":"","key":"带\n换行","location":{"startingColumn":1,"startingLine":2}},
  {"comment":"","key":"Other-table-key","location":{"startingColumn":1,"startingLine":3}}
]},"other":{"Other":[{"comment":"","key":"不该进来","location":{"startingColumn":1,"startingLine":1}}]}}
EOF

# --- 规则 -----------------------------------------------------------------------------------
"$tool" --catalog "$tmp/Localizable.xcstrings" --stringsdata-dir "$tmp/mac" --stringsdata-dir "$tmp/ios" > "$tmp/run1.log"
out="$tmp/Localizable.xcstrings"

assert_contains "$out" '"同步诊断" : {' "新键作为空壳加入"
assert_contains "$out" '"comment" : "侧栏标题"' "代码里的注释写进 comment"
assert_contains "$out" '"带\n换行" : {' "换行按 JSON 转义"
assert_contains "$out" '"连接" : {' "仍在代码里的未翻译键保留"
assert_not_contains "$out" '未翻译且代码里没了' "未翻译且消失的键被删除"
assert_not_contains "$out" '不该进来' "别的 table 不混进来"
if python3 - "$out" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))["strings"]
assert d["已翻译但代码里没了"]["extractionState"] == "stale", "gone+translated must be stale"
assert "extractionState" not in d["曾经 stale 现在回来了"], "reappearing key must lose stale"
assert d["保留给手写"]["extractionState"] == "manual", "manual untouched"
assert d["保留给手写"]["localizations"]["en"]["stringUnit"]["value"] == "Kept by hand"
keys = list(d.keys())
assert keys.index("%@:%@") < keys.index("%@：%@"), "ASCII colon sorts before fullwidth"
EOF
then ok "stale / 恢复 / manual / 排序规则"; else bad "stale / 恢复 / manual / 排序规则"; fi

# 空壳的写法要和 Xcode 一样：`{`、空行、缩进的 `}`。
if awk '/"同步诊断" : \{/{getline a; getline b; getline c; if (a=="      \"comment\" : \"侧栏标题\"" && b=="    },") found=1} END{exit !found}' "$out" \
   && awk '/"连接" : \{/{getline a; getline b; if (a=="" && (b=="    }," || b=="    }")) found=1} END{exit !found}' "$out"; then
	ok "空壳与带注释条目的排版对齐 Xcode"
else
	bad "空壳与带注释条目的排版对齐 Xcode"
fi
if [ "$(tail -c 1 "$out" | od -An -c | tr -d ' ')" = "}" ]; then ok "文件末尾无换行（同 Xcode）"; else bad "文件末尾无换行（同 Xcode）"; fi

# --- 幂等与 --check ---------------------------------------------------------------------------
cp "$out" "$tmp/after1.xcstrings"
"$tool" --catalog "$out" --stringsdata-dir "$tmp/mac" --stringsdata-dir "$tmp/ios" > "$tmp/run2.log"
if cmp -s "$out" "$tmp/after1.xcstrings"; then ok "第二次运行无改动（幂等）"; else bad "第二次运行无改动（幂等）"; fi
assert_contains "$tmp/run2.log" "目录已是最新" "幂等时报告「已是最新」"

cp "$tmp/original.xcstrings" "$tmp/check.xcstrings"
if "$tool" --catalog "$tmp/check.xcstrings" --check --stringsdata-dir "$tmp/mac" --stringsdata-dir "$tmp/ios" > /dev/null; then
	bad "--check 在目录落后时应非零退出"
else
	ok "--check 在目录落后时非零退出"
fi
if cmp -s "$tmp/check.xcstrings" "$tmp/original.xcstrings"; then ok "--check 不写文件"; else bad "--check 不写文件"; fi

cp "$tmp/original.xcstrings" "$tmp/dry.xcstrings"
"$tool" --catalog "$tmp/dry.xcstrings" --dry-run --stringsdata-dir "$tmp/mac" --stringsdata-dir "$tmp/ios" > /dev/null
if cmp -s "$tmp/dry.xcstrings" "$tmp/original.xcstrings"; then ok "--dry-run 不写文件"; else bad "--dry-run 不写文件"; fi

# --- --no-prune：消失的未翻译键只标 stale ---------------------------------------------------------
cp "$tmp/original.xcstrings" "$tmp/noprune.xcstrings"
"$tool" --catalog "$tmp/noprune.xcstrings" --no-prune --stringsdata-dir "$tmp/mac" --stringsdata-dir "$tmp/ios" > /dev/null
if python3 - "$tmp/noprune.xcstrings" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))["strings"]
assert d["未翻译且代码里没了"]["extractionState"] == "stale"
EOF
then ok "--no-prune 只标 stale 不删"; else bad "--no-prune 只标 stale 不删"; fi

# --- 防呆：某个目录下没有 .stringsdata 要报错 ---------------------------------------------------------
mkdir -p "$tmp/empty"
if "$tool" --catalog "$tmp/Localizable.xcstrings" --stringsdata-dir "$tmp/mac" --stringsdata-dir "$tmp/empty" > /dev/null 2>&1; then
	bad "空目录应报错（多半是没构建）"
else
	ok "空目录报错"
fi

# --- 真实目录 round-trip：把仓库目录里现有的键原样喂回去，输出必须逐字节相同 -------------------------
real="$REPO_ROOT/uTerm/Localizable.xcstrings"
if [ -f "$real" ]; then
	mkdir -p "$tmp/rt/sd"
	cp "$real" "$tmp/rt/Localizable.xcstrings"
	python3 - "$real" "$tmp/rt/sd/all.stringsdata" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))["strings"]
keys = [k for k, v in d.items() if v.get("extractionState") != "stale"]
entries = [{"comment": v.get("comment", ""), "key": k, "location": {"startingColumn": 1, "startingLine": 1}} for k in keys for v in [d[k]]]
json.dump({"source": "/x.swift", "tables": {"Localizable": entries}}, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False)
EOF
	"$tool" --catalog "$tmp/rt/Localizable.xcstrings" --stringsdata-dir "$tmp/rt/sd" > /dev/null
	if cmp -s "$real" "$tmp/rt/Localizable.xcstrings"; then
		ok "仓库目录 round-trip 逐字节相同（排序与排版对齐 Xcode）"
	else
		bad "仓库目录 round-trip 有差异：$(diff "$real" "$tmp/rt/Localizable.xcstrings" | head -5 | tr '\n' ' ')"
	fi
fi

if [ "$fail" -ne 0 ]; then echo "sync-strings.test.sh: FAILED"; exit 1; fi
echo "sync-strings.test.sh: all passed"
