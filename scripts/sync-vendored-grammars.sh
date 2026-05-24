#!/usr/bin/env bash
# 重新拉取 vendor/tree-sitter-grammars/ 下的 grammar C 源。
#
# 用法：./scripts/sync-vendored-grammars.sh
#
# 升 grammar 版本时改下面的 PINS 数组 (repo/sha)，跑一遍，commit。
# 工作目录由仓库根决定，不依赖 cwd。

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

declare -a PINS=(
  "python tree-sitter/tree-sitter-python 26855eabccb19c6abf499fbc5b8dc7cc9ab8bc64"
  "javascript tree-sitter/tree-sitter-javascript 58404d8cf191d69f2674a8fd507bd5776f46cb11"
  "yaml tree-sitter-grammars/tree-sitter-yaml a1c4812a73ec5e089de8e441fdea3a921e8d5079"
)

# 每个 grammar 需要的额外文件（yaml 的 schema.*.c）
declare -A EXTRA
EXTRA[yaml]="src/schema.core.c src/schema.json.c src/schema.legacy.c"

for entry in "${PINS[@]}"; do
  read lang repo sha <<<"$entry"
  echo "=== $lang ($repo @ ${sha:0:7}) ==="
  out="vendor/tree-sitter-grammars/$lang"
  base="https://raw.githubusercontent.com/$repo/$sha"

  # 标准 5 个核心文件 + 头文件 + queries
  rm -rf "$out/src" "$out/queries"
  mkdir -p "$out/src/tree_sitter" "$out/queries" "$out/include"
  for f in src/parser.c src/scanner.c \
           src/tree_sitter/parser.h src/tree_sitter/alloc.h src/tree_sitter/array.h \
           queries/highlights.scm; do
    code=$(curl -sf -o /dev/null -w "%{http_code}" "$base/$f")
    if [ "$code" = "200" ]; then
      curl -sf "$base/$f" -o "$out/$f"
      echo "  ✓ $f"
    else
      echo "  - $f ($code, skip)"
    fi
  done

  # 额外文件
  if [ -n "${EXTRA[$lang]:-}" ]; then
    for f in ${EXTRA[$lang]}; do
      curl -sf "$base/$f" -o "$out/$f"
      echo "  ✓ $f (extra)"
    done
  fi

  # 重写 include header
  UP=$(echo "$lang" | tr '[:lower:]' '[:upper:]')
  fn="tree_sitter_$lang"
  cat > "$out/include/tree-sitter-$lang.h" <<EOF
// vendor 化生成。暴露 tree-sitter grammar 入口 C 函数。
#ifndef TREE_SITTER_${UP}_H
#define TREE_SITTER_${UP}_H

typedef struct TSLanguage TSLanguage;

#ifdef __cplusplus
extern "C" {
#endif

const TSLanguage *${fn}(void);

#ifdef __cplusplus
}
#endif

#endif
EOF
done

echo
echo "Done. 现在跑：cd vendor/tree-sitter-grammars && swift build  ←  验证编译"
