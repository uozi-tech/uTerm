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
    方向选择沿用 xterm.js `ensureContrastRatio`（暗字更暗 / 亮字更亮，主方向
    到极点仍不达标时回退试反方向取更优者），但调整本身是**保色相**的：在
    OKLCH 空间对明度二分逼近 WCAG 亮度目标，色相固定、饱和度仅在超出 sRGB
    色域时收缩（xterm.js 是向黑/白混色，会把彩色洗成灰白）。只有目标在极点
    附近时才退化为黑/白。
  - `isContrastExempt(codePoint:)`：装饰性字形豁免——盒线 U+2500–257F、
    块元素 U+2580–259F、powerline U+E0B0–E0BF。这些字形靠与相邻 cell 背景
    同色来无缝拼接，钳制会破坏分段视觉（xterm.js 同样豁免）。
- `Sources/SwiftTerm/Mac/MacTerminalView.swift` / `Sources/SwiftTerm/iOS/iOSTerminalView.swift`
  - 新增存储属性 `public var minimumContrastRatio: CGFloat = 1`（1 = 关闭，
    保持上游默认行为；didSet 触发 `colorsChanged()` 重建属性缓存）。
  - 新增豁免字形的属性缓存 `noContrastAttributes`。
- `Sources/SwiftTerm/Apple/AppleTerminalView.swift`
  - `getAttributes(_:withUrl:contrastExempt:)`：fg 经 `mapColor` 后、dim 处理前
    做对比度钳制（先钳制再 dim，保留 SGR 2 的「变暗」语义）；豁免 run 走
    `noContrastAttributes` 缓存。
  - `buildAttributedString`：按字符 codepoint 判定豁免并加入 run 切分条件；
    盒线 / 块元素自绘分支改取未钳制前景色。
  - `colorsChanged()` 与字体重建处同步清空 `noContrastAttributes`。

uTerm 侧入口：`TerminalTheme.applyColorScheme` 统一设
`view.minimumContrastRatio = TerminalColorScheme.minimumContrastRatio`（4.5）。
