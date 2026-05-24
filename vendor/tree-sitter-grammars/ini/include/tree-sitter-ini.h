// vendor 化生成。暴露 tree-sitter grammar 入口 C 函数。
#ifndef TREE_SITTER_INI_H
#define TREE_SITTER_INI_H

typedef struct TSLanguage TSLanguage;

#ifdef __cplusplus
extern "C" {
#endif

const TSLanguage *tree_sitter_ini(void);

#ifdef __cplusplus
}
#endif

#endif
