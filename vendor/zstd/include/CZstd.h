// CZstd 模块的伞头文件（本目录唯一不是上游的 C 文件）：只露出上游的公开头文件 `zstd.h`。
// 内部头文件留在 `lib/` 下不进模块，Swift 看不到它们。
#include "../lib/zstd.h"
