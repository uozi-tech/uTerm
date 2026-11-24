# 第三方组件 / Third-party notices

uTerm 以 AGPL-3.0 发布，使用了下列第三方组件，各自保留原许可证。

## 仓库里带着源码的（`vendor/`）

| 组件 | 上游 | 许可证 | 原文 |
|---|---|---|---|
| libghostty-spm（含 Ghostty 补丁） | github.com/Lakr233/libghostty-spm | MIT | `vendor/libghostty-spm/LICENSE` |
| Ghostty（编进两个 xcframework） | github.com/ghostty-org/ghostty | MIT | 随 Ghostty 源码；`make engine-build` 现编时一并取得 |
| CodeEditTextView | github.com/CodeEditApp/CodeEditTextView | MIT | `vendor/CodeEditTextView/LICENSE.md` |
| tree-sitter grammars（python / javascript / yaml / toml / ini） | 见 `scripts/sync-vendored-grammars.sh` | MIT；ini 为 Apache-2.0 | `vendor/tree-sitter-grammars/LICENSES.md` |
| libjuice | github.com/paullouisageneau/libjuice | MPL-2.0 | `vendor/libjuice/LICENSE` |
| kcp | github.com/skywind3000/kcp | MIT | `vendor/kcp/LICENSE` |
| zstd（只有解压部分） | github.com/facebook/zstd | BSD-3-Clause（上游双许可 BSD / GPLv2，取 BSD） | `vendor/zstd/LICENSE` |

## Swift 包依赖（构建时由 SwiftPM 拉取，版本见 `Package.resolved`）

| 包 | 上游 | 许可证 |
|---|---|---|
| uAppKit（含 swift-nio-ssh 源码、OpenBSD 的 bcrypt_pbkdf） | github.com/uozi-tech/uAppKit | AGPL-3.0（其中 swift-nio-ssh Apache-2.0、bcrypt_pbkdf BSD，见其 `THIRD_PARTY_NOTICES.md` 与 `ThirdParty/`） |
| swift-nio、swift-crypto、swift-asn1、swift-log、swift-atomics、swift-collections、swift-system | github.com/apple | Apache-2.0 |
| swift-markdown、swift-cmark | github.com/swiftlang | Apache-2.0；cmark 部分为 BSD-2-Clause |
| Sparkle | github.com/sparkle-project/Sparkle | MIT |
| BigInt | github.com/attaswift/BigInt | MIT |
| DisplayLink | github.com/Lakr233/DisplayLink | MIT |
| Rearrange、TextStory | github.com/ChimeHQ | BSD-3-Clause |
| swift-tree-sitter | github.com/tree-sitter/swift-tree-sitter | BSD-3-Clause |
| tree-sitter 与各语言 grammar | github.com/tree-sitter 等 | MIT |

许可证以各上游仓库为准；这张表只是索引。
