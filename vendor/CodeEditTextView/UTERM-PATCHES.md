# uTerm 对 vendored CodeEditTextView 的本地补丁

上游：`https://github.com/CodeEditApp/CodeEditTextView`，基线 tag `0.12.1`
（revision `d7ac3f11f22ec2e820187acce8f3a3fb7aa8ddec`）。

## 为什么 vendor

三个补丁都改不到包外。

补丁 #3 改的 `CGRectArray.boundingRect()` 是 internal 扩展方法，包外不可见、也无法替换
其调用方。

补丁 #2 涉及 `TextSelectionManager` 的 internal `getFillRects` 与 private
`drawSelectedRange`：`TextSelectionManager` 是 `public class` 而非 `open`（无法子类化），
`TextView.selectionManager` 是 `package(set) public`（无法换实例），
`TextView.draw(_:)` 声明在 extension 里且是 `public` 而非 `open`（无法 override）。

补丁 #1 修的是**上游的数据流 bug**，它让「不折行 + 横向滚动」这条路彻底走不通。
涉及 `TextLayoutManager` 的 private 方法与 internal 属性 `maxLineWidth`，
从包外既改不了也覆盖不了：

- `maxLineWidth` 是 internal，外部读写不到；
- `TextView.updateFrameIfNeeded()` 是 `public` 而非 `open`，无法在别的 module 里 override；
- 每次视口更新（滚动 / resize / 我们自己的 `updatedViewport`）它都会把文档视图宽度重置为
  `max(estimatedWidth(), 视口宽)`，所以在 app 层手动改 `textView.frame.size.width` 会被立刻打回。

升级上游前先确认该 bug 是否已被上游修掉（写作时最新发布版 `0.12.1` 仍有）。修掉了就可以
弃用本 vendored 副本，改回 `XCRemoteSwiftPackageReference`。

## 补丁 #1：`layoutLine` 遮蔽 `inout maxFoundLineWidth`，导致不折行时无法横向滚动

文件：`Sources/CodeEditTextView/TextLayoutManager/TextLayoutManager+Layout.swift`

上游 `layoutLine(_:usedFragmentIDs:textStorage:yRange:maxFoundLineWidth:)` 收一个
`maxFoundLineWidth: inout CGFloat`，却在函数体里写了：

```swift
var maxFoundLineWidth = maxFoundLineWidth   // ← 把 inout 参数遮蔽成局部副本
...
if maxFoundLineWidth < lineSize.width {
    maxFoundLineWidth = lineSize.width      // ← 只写进副本
}
return (yContentAdjustment, wasLineHeightChanged)   // ← 宽度没有任何出口
```

量到的行宽全写进那个局部副本，函数返回即丢弃。后果链：

`layoutLines` 里的 `maxFoundLineWidth` 永不增长 → `maxLineWidth` 恒为 `0` →
`estimatedWidth()`（= `maxLineWidth + edgeInsets.horizontal`）只剩 insets →
`TextView.updateFrameIfNeeded()` 里 `frame.size.width = max(newWidth, availableSize.width)`
恒等于视口宽 → **文档视图永远不比视口宽，`wrapLines = false` 时也产生不了横向溢出**，
`NSScrollView.hasHorizontalScroller = true` 也没有任何东西可滚。

修法：删掉那行遮蔽声明，让赋值直接写回 `inout` 参数（其余逻辑一字未动）。

复现/验证：给一条远超视口宽的单行（如 `authorized_keys` 里的公钥），排版后读
`layoutManager.estimatedWidth()` 与 `textView.frame.width`。修前 `estimatedWidth`
恒等于 `edgeInsets.horizontal`、`frame.width == clipView.bounds.width`；修后
`estimatedWidth` 为真实行宽、`frame.width > clipView.bounds.width`，横向滚动条出现。

## 补丁 #2：整行被选中的行填到视口宽，⌘A 糊成一整块蓝

文件：`Sources/CodeEditTextView/TextSelectionManager/TextSelectionManager+FillRects.swift`

上游 `getFillRects(in:for:)` 先算一个「可绘制区」上界：

```swift
let maxWidth = max(textWidth, layoutManager.wrapLinesWidth)
let validTextDrawingRect = CGRect(x: layoutManager.edgeInsets.left, y: rect.minY,
                                  width: maxWidth, height: rect.height).intersection(rect)
```

再在每个 fragment 上，只要选区盖到了行尾（`endOfLine`）且不是文档最后一行，就把右边界
直接怼到这个上界：

```swift
if endOfLine && !(endOfDocument && !emptyLine) {
    maxRect = CGRect(x: rect.maxX, ...)   // ← rect 就是 validTextDrawingRect
}
```

后果链：`wrapLinesWidth`（= `textViewportSize().width - edgeInsets.horizontal`）并不受
`wrapLines` 开关约束，`maxLineLayoutWidth` 在 `wrapLines = false` 时恒为
`.greatestFiniteMagnitude`，于是 `textWidth` 取 `maxLineWidth`（真实最长行宽），再被
`max(..., wrapLinesWidth)` 抬到**视口宽**。任何比窗口窄的文件，⌘A 后每一行都从正文左缘
一路填到滚动条 —— 空行（`emptyLine` 判的是 `linePosition.range.isEmpty`，装着 `"\n"`
的空行为 `false`）也整行铺满，逐行矩形上下相接，视觉上就是一整块实心蓝。只有文档最后
一行靠 `endOfDocument` 走 `else` 分支贴住文本。

这是上游沿用 NSTextView/Xcode 的约定，不是补丁 #1 引入的回归；补丁 #1 只是把「有超宽行」
的文件的这个上界从视口宽换成了文档宽。⌘A 快捷键（`CodeEditorController.handleKeyEvent`）
只是让这个问题第一次被看见。

修法：`endOfLine` 分支不再取 `rect.maxX`，改成本行 fragment 自己的文本右缘
（`edgeInsets.left + fragment.width`）再补一个空格宽的小方块代表被选中的换行符 ——
VSCode 的画法。`maxWidth` 同步加上这个方块宽，否则最长那行的方块会被函数末尾的
`.intersection(validTextDrawingRect)` 削掉。方块宽由新的私有 `lineBreakFillWidth()`
按 `textView.font` / `textView.kern` 量一个空格得到（文件的 `import Foundation` 因此
改成 `import AppKit`）。

注意：uTerm 恒为 `wrapLines = false`，一行一个 fragment。折行时中间 fragment 现在也贴
文本右缘而不是填到折行宽，与上游有差异 —— 若将来开折行需重新评估。为此 `endOfLine`
分支额外加了 `isLastFragmentOfLine`（`fragmentRange.max >= linePosition.range.max`）守卫：
不折行时恒真，折行时保证换行方块只补在该行**最后**一个 fragment 之后，中间 fragment 走
`else` 分支贴文本右缘。

### 顺带修掉的上游 bug：以 `\n` 结尾的文件，最后一个真实行没有选中底色

上游用 `endOfDocument`（`intersectionRange.max == lineStorage.length`）判「文档末行」。
文件以 `\n` 结尾时，`lineStorage` 末尾会有一个零长的「幽灵空行」，于是**最后一个真实行**
的 range 末尾（含那个 `\n`）恰好等于文档长度 → 被误判成文档末行 → 走 `else` 分支，
`rectForOffset(行尾)` 落在幽灵空行的原点 → 零宽矩形 → **整行没有任何选中底色**。
配置文件几乎都以换行结尾，命中率很高；这是上游既有行为，1.9.3 / 1.9.4 均可复现
（未打补丁的构建实测：⌘A 只填到倒数第二行）。反过来幽灵空行自己因 `!emptyLine` 为假
而**被**补上一个方块，VSCode 不画它。

改判「后面还有没有行」，两头都对：

```swift
let hasLineBreak = linePosition.index + 1 < layoutManager.lineCount
```

末行带 `\n` → 补方块；幽灵空行 / 无 `\n` 的末行 → 不补，走 `else` 贴文本右缘（幽灵空行
因此得零宽矩形，不绘制）。中间空行不受影响，仍有方块。`endOfDocument` 随之不再需要。

实测（doc = 4 个真实行 + 幽灵空行，其中第 3 行是中间空行，⌘A）：
`119 / 245 / 7（中间空行方块）/ 141 / 不画（幽灵空行）` —— 修前第 4 行完全没有填充。

`lineBreakFillWidth()` 按 `font + kern` 记忆化到 `TextSelectionManager.cachedLineBreakFill`
（该存储属性加在 `TextSelectionManager.swift`，因为 Swift extension 不能有存储属性）——
否则每个选区每帧都要量一次空格宽，列选择下是 O(选中行数)/帧。

复现/验证：打开一个比窗口窄的文件（如 `app.ini`）按 ⌘A。修前整块蓝横跨到滚动条、空行
铺满；修后右缘随每行长短参差，空行只剩一个空格宽的小方块，最后一行不带方块。
离线可重跑的像素级验证脚手架见「验证方法」一节。

## 补丁 #3：`CGRectArray.boundingRect()` 宽度取错

文件：`Sources/CodeEditTextView/Extensions/CGRectArray+BoundingRect.swift`

上游宽度取的是「`maxY` 最大那个 rect」的 `maxX`，而不是所有 rect 里最大的 `maxX`：

```swift
let max = self.max(by: { $0.maxY < $1.maxY }) ?? .zero
let size = CGSize(width: max.maxX - minX, height: max.maxY - minY)
```

只要各行右缘不齐，包围盒宽度就会被算窄。上游各行选区恒等宽（都填到同一右缘），这个
bug 一直不可见；**补丁 #2 把右缘改成参差之后才暴露**：三行选区 `[52…171] / [52…297] /
[52…90]` 会算出宽度 38，实际应为 245。

消费方：`TextView+ReplaceCharacters.swift`（`!visibleRect.contains(selection.boundingRect)`
的「要不要滚动到选区」判据，宽度偏小只会少滚一次、不会误滚）、
`TextView+Accessibility.swift` 的 `accessibilityFrame(for:)`（VoiceOver 报的范围偏窄）。

修法：`maxX` / `maxY` 各自独立取最大值。

## 补丁 #4：Xcode 27 新警告清理（与行为无关）

Xcode 27 把几条以前只是提示的诊断升成了警告，本工程按 warning 编译会吵到看不见真问题。
四处，都只删死代码 / 显式丢弃返回值，**不改任何行为**：

- `TextLine.swift`：`typesetter.typeset(...)` 的返回值 `maxWidth` 声明了却没用 → 去掉绑定。
- `TextView+Insert.swift`：`var attachments` 从未被改写 → 改 `let`。
- `TextView+ScrollToVisible.swift`：`let animated = false` 的 feature flag 与其恒不执行的
  `NSAnimationContext` 分支 → 只留 `scrollView.contentView.scroll(to:)` 那条活路。
- `TextLayoutManager+Layout.swift`：`relativeMinY` / `relativeMaxY` 只被一段注释掉的
  `linesStartingAt(...)` 循环使用 → 连同那段注释一起删。

升级重放时如果上游已自行清掉，跳过即可；本补丁没有需要保住的语义。

## 已知上游 bug（未打补丁，app 侧绕过）：失焦再聚焦后 caret 不回来

文件：`TextSelectionManager.swift` 的 `removeCursors()` 与
`TextView/TextView+FirstResponder.swift` 的 `becomeFirstResponder()`。

两处合起来才是完整病因：

1. `resignFirstResponder()` → `removeCursors()` 只做
   `textSelection.view?.removeFromSuperview()`，**不把 `textSelection.view` 置 nil**。
   重新聚焦后 `repositionCursorSelection` 的守卫
   `view == nil || doesViewNeedReposition` 两边都不成立（view 还指着那个已脱离父视图的
   旧 CursorView，光标没动过所以 origin/height 完全相等）→ 直接 return false。
2. 就算把 view 置了 nil 也不够：`becomeFirstResponder()` 只 `resetTimer()` +
   `needsDisplay = true`，**从不调 `updateSelectionViews()`**，而 `needsDisplay` 不置
   `needsLayout`，所以在下一次滚动 / resize 触发 `layout()` 之前没人重建 CursorView。
   另外 `removeCursors()` 里的 `stopTimer()` 已经把 `CursorTimer` 的注册表清空，
   复用旧 view 也不会再闪。

探针实测（600pt 视口、12pt SF Mono、`useSystemCursor = false`）：

| 变体 | 重新聚焦后 |
|---|---|
| 上游原样 | 无 CursorView；强制 `layout()`、`updateSelectionViews(force:)` 都救不回来 |
| 仅 `removeCursors()` 置 nil | 仍无 CursorView，要等到下一次 `layout()` 才出现 |
| 置 nil + `becomeFirstResponder()` 调 `updateSelectionViews()` | caret 立刻回来并闪烁 |

**uTerm 没有为此打补丁**，改在 app 侧绕过：`CodeEditorView.EditorTextView`
（`TextView` 子类）在 `becomeFirstResponder()` 之后调
`CodeEditorController.restoreCaretsIfNeeded()`，检测到「是第一响应者但一个 CursorView
子视图都没有」时，把选中范围用 public 的 `setSelectedRanges` 原样重设一遍 ——
TextSelection 对象因此重建（`view == nil`），走到创建分支。范围没变所以不会发
`selectionChangedNotification`。同一份探针里 A/B 实测该绕法在 `makeFirstResponder`
与真实 key window 转移（⌘Tab）两条路径上都成立。

升级上游时：若上游已修（`removeCursors` 置 nil **且** 聚焦时会重建 cursor view），
可以把 app 侧那段绕过删掉；没修就原样保留，本副本不需要改动。

## 验证方法（离线、可重跑）

补丁 #1 与 #2 都在热绘制路径上，公式复算容易自欺。用像素级 probe 量**真实落笔**：
把选区色设成纯红，调 public 的 `selectionManager.drawSelections(in:)` 画进离屏
`NSBitmapImageRep`，再逐行扫描取每行填充的 `minX` / `maxX`。

坑：①依赖 `.o` 要列全（漏 `ContainersPreview` 会 undefined symbol）②C target 用
`GeneratedModuleMaps` 里的 modulemap ③产物带覆盖率插桩 → probe 也要 `-profile-generate`
④**必须把视图挂进真实 `NSWindow` 并跑 runloop**，否则不布局，量出来全是假的
⑤`bitmapImageRepForCachingDisplay` 给的是**像素**尺寸（Retina 2x），按点坐标采样会全部错位。

实测基线（视口 600pt、`edgeInsets` l=52 r=12、最长行 5326pt）：

| 场景 | 补丁 #1 前 | 仅补丁 #1 | 补丁 #1+#2 |
|---|---|---|---|
| 整行选中含换行 | x[52→588] | x[52→600] | x[52→297] |
| ⌘A 全选 | 整块 [52→588] | 整块 [52→600] | 171/297/600/304/193/82 参差 |
| 横滚到 x=2000 | — | 2000→2600 整屏铺满 | 仅超宽行有色 |

## manifest 改动（相对上游）

`Package.swift` 两处裁剪，源码不受影响：

1. 删掉 `SwiftLintPlugin` 依赖与两个 target 上的 `.plugin(name: "SwiftLint", ...)`。
   vendored 副本不跑上游的 lint；且该 build-tool 插件会让 CLI 构建需要额外传
   `-skipPackagePluginValidation` 才能过校验。
2. 删掉 `CodeEditTextViewTests` testTarget —— 本副本不 vendor `Tests/`（与
   `vendor/Citadel` 一致，只保留 `Sources/`、`Package.swift`、LICENSE）。

## 引用方式

pbxproj 以 `XCLocalSwiftPackageReference "vendor/CodeEditTextView"` 引用本目录，替换原先的
`XCRemoteSwiftPackageReference "CodeEditTextView"`。app target 的 `CodeEditTextView`
product 依赖改指向本地包。`TextStory` / `swift-collections` 仍由本包 manifest 从远程拉取。

## 升级重放步骤

1. 取上游新 tag 的源码，比对本文件列出的补丁是否已被上游修掉。
2. 未修掉：把 `Sources/` 整体换成新版本，重放补丁 #1（搜
   `var maxFoundLineWidth = maxFoundLineWidth`）、补丁 #2（搜
   `x: rect.maxX,` 与 `endOfDocument`，在 `TextSelectionManager+FillRects.swift` 里，连同
   `TextSelectionManager.swift` 里的 `cachedLineBreakFill` 存储属性）与补丁 #3（搜
   `CGRectArray+BoundingRect.swift` 里的 `$0.maxY < $1.maxY`），
   再按上面两条重做 manifest 裁剪。
3. 补丁 #4 只是警告清理，上游若已修掉直接跳过。
4. 更新本文件顶部的基线 tag / revision。
5. 用各补丁的验证方法确认横向滚动与 ⌘A 选区右缘仍然正确。
