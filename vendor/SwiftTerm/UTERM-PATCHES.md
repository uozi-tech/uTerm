# uTerm 对 vendored SwiftTerm 的本地补丁

上游：`https://github.com/migueldeicaza/SwiftTerm`，基线 revision
`c068a905c5aeab60852fb865bee05dc8a5af190c`（2026-05-17）。

更新方式：拉取上游新 revision 覆盖 `Sources/SwiftTerm`（保留本文件与裁剪版
`Package.swift`），然后逐条重放下列补丁。

## 1. 渲染期最低对比度（minimum contrast ratio）

对齐 VS Code `terminal.integrated.minimumContrastRatio` / xterm.js 的同名能力。
远端 prompt / TUI（p10k、oh-my-posh 等）常按深色背景硬编码 256 色 / 真彩色，
这些颜色不经过可主题化的 ANSI 16 色表，在浅色背景下不可读；渲染时对每个
cell 的前景色按 WCAG 对比度向黑/白方向钳制。

涉及文件：

- `Sources/SwiftTerm/Apple/MinimumContrast.swift`（**新增**）
  - `TerminalContrast`：WCAG 相对亮度 / 对比度计算 + `ensureContrast(fg:bg:ratio:)`。
    方向按**背景**判定（`preferLighten = bgY < 0.5`）：深 / 中灰段底一律提亮
    前景（prompt 文字在 powerline 段上读作亮色），仅在确为浅背景时压暗；提亮
    够不到目标比（浅灰段底）时回退反方向压暗。**不沿用 xterm.js 的 fg-vs-bg
    方向**——那在中灰段底上会把「比段底略暗」的前景压成纯黑、把「略亮」的压成
    纯白（典型：路径分隔符 ansi31 #3D6D7E 落在 #6D6D6D 段上被压成 #000206 发黑，
    而旁边路径文字却提亮），按背景判定可让同一段上所有前景朝同一可读方向走。
    调整本身**保色相**：OKLCH 空间二分明度逼近 WCAG 亮度目标，色相固定、饱和度
    仅在超出 sRGB 色域时收缩（xterm.js 是向黑/白混色会洗成灰白）；只有目标在
    极点附近才退化为黑 / 白。
  - **不做装饰字形豁免**：盒线 / 块元素 / powerline 字形与普通文本一样钳制。
    曾按 xterm.js 思路豁免 U+2500–259F / U+E0B0–E0BF（靠与相邻 cell 背景同色
    无缝拼接），但远端 prompt（p10k 等）把段分隔符的前景硬编码成深色背景下的
    灰，在浅色终端上渲染成不可读的灰块——用户明确要求一律钳制成可读色，宁可
    贴着彩色段的分隔三角出现轻微色差，也不要灰块。
- `Sources/SwiftTerm/Mac/MacTerminalView.swift` / `Sources/SwiftTerm/iOS/iOSTerminalView.swift`
  - 新增存储属性 `public var minimumContrastRatio: CGFloat = 1`（1 = 关闭，
    保持上游默认行为；didSet 触发 `colorsChanged()` 重建属性缓存）。
- `Sources/SwiftTerm/Apple/AppleTerminalView.swift`
  - `getAttributes(_:withUrl:)`：fg 经 `mapColor` 后、dim 处理前做对比度钳制
    （先钳制再 dim，保留 SGR 2 的「变暗」语义）；所有 cell 走同一条钳制路径。
  - `buildAttributedString` 的盒线 / 块元素自绘分支取 `getAttributes` 已钳制的
    前景色（不再有未钳制变体）。

uTerm 侧入口：`TerminalTheme.applyColorScheme` 统一设
`view.minimumContrastRatio = TerminalColorScheme.minimumContrastRatio`（4.5）。

## 2. iOS 终端键盘可强制英文 ASCII

上游 `iOSTerminalView.swift` 的 `keyboardType` 是 get-only 计算属性，恒返回
`.default`（跟随用户当前语言键盘，可能弹出中文等候选栏）。移动端终端的命令输入
应为纯 ASCII，故让该属性可写。

涉及文件：

- `Sources/SwiftTerm/iOS/iOSTerminalView.swift`
  - `keyboardType` 由 get-only 计算属性改为可写存储属性
    `public var keyboardType: UIKeyboardType = .default`（默认不变，保持上游语义）。

uTerm 侧入口：`uTermMobile/Screens/Terminal/SwiftTermView.swift` 的 `makeUIView`
设 `view.keyboardType = .asciiCapable`。联想 / 自动更正 / 智能标点上游已默认关闭
（`autocorrectionType` 等均为 `.no`）。Agent（AI 模式）走独立 SwiftUI 输入框，不受影响。
