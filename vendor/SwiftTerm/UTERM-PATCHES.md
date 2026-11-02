# uTerm 对 vendored SwiftTerm 的本地补丁

上游：`https://github.com/migueldeicaza/SwiftTerm`，基线 revision
`464df5207fc2432e16c9a23abe538187196daf5f`（tag `v1.19.0`，2026-08-18）。

更新方式：拉取上游新 revision 覆盖 `Sources/SwiftTerm`（保留本文件与裁剪版
`Package.swift`），然后逐条重放下列补丁。**不要直接整目录覆盖**——`Sources/SwiftTerm`
里混着本地新增文件（`Apple/MinimumContrast.swift`、`SwiftTermBuildInfo.swift`、`TerminalSnapshot.swift`），
整目录覆盖会把它们冲掉。

校验手法：把上游对应 revision 的 tarball 解到临时目录，`diff -rq` 比对
`Sources/SwiftTerm`，输出应当**恰好**是下面各条补丁涉及的文件，多一个少一个都要查。

## 1. 渲染期最低对比度（minimum contrast ratio）

对齐 VS Code `terminal.integrated.minimumContrastRatio` / xterm.js 的同名能力。
远端 prompt / TUI（p10k、oh-my-posh 等）常按深色背景硬编码 256 色 / 真彩色，
这些颜色不经过可主题化的 ANSI 16 色表，在浅色背景下不可读；渲染时对每个
cell 的前景色按 WCAG 对比度向黑/白方向钳制。

涉及文件：

- `Sources/SwiftTerm/Apple/MinimumContrast.swift`（**新增**，纯本地文件，上游无对应物）
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
    保持上游默认行为；didSet 触发 `colorsChanged()` 重建属性缓存）。锚点是
    `attributes` / `urlAttributes` 两个缓存字典的声明处。
- `Sources/SwiftTerm/Apple/AppleTerminalView.swift`
  - `getAttributes(_:withUrl:)`：fg 经 `mapColor` 后、dim 处理前做对比度钳制
    （先钳制再 dim，保留 SGR 2 的「变暗」语义）；所有 cell 走同一条钳制路径。
    这是本组补丁在 AppleTerminalView 里**唯一**的改动。

  注意：装饰字形（盒线 / 块元素 / powerline）**不需要**单独打补丁。
  `buildAttributedString` 里那三个自绘分支都是从
  `currentAttributes[.foregroundColor]` 把前景色读回来的，而这个值正是
  `getAttributes` 产出的、已钳制的颜色，所以它们自动继承钳制。
  （v1.19.0 新增的 `Apple/PowerlineRenderer.swift` 同理——它接收的
  `foregroundColor` 也来自同一个属性字典。）

uTerm 侧入口：`TerminalTheme.applyColorScheme` 统一设
`view.minimumContrastRatio = TerminalColorScheme.minimumContrastRatio`；
移动端在 `SwiftTermView.makeUIView` 设 `MTerminalColors.minimumContrastRatio`。
两侧当前取值均为 **3.0**。

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

## 3. 手写 SwiftTermBuildInfo，替掉上游的 build tool plugin

**v1.19.0 新增的补丁**（基线 c068a905 时不存在此问题）。

上游从 v1.19.0 起，把 `SwiftTermBuildInfo`（XTVERSION 应答用的版本信息）改成由
build tool plugin `SwiftTermBuildInfoPlugin` + 可执行 target
`SwiftTermBuildInfoGenerator` 在编译期生成。vendored 副本不带这两个 target，
改为手写一份固定值。

涉及文件：

- `Sources/SwiftTerm/SwiftTermBuildInfo.swift`（**新增**，替代上游的生成物）
- `Package.swift`：不声明 `plugins:`，不带 generator / plugin 两个 target。

不采用上游 plugin 的原因：

1. **它会报错版本**。plugin 把 `context.package.directoryURL` 传给 generator 去跑
   git，而这个目录是 `<uTerm 仓库>/vendor/SwiftTerm`——git 会一路向上找到 uTerm
   自己的 `.git`，于是 XTVERSION 报出去的分支 / commit / dirty 状态是 **uTerm 的**，
   不是 SwiftTerm 的。对 vendored 副本来说这是错的。
2. vendored 副本本就钉死在一个上游 revision 上，版本信息是常量，没有「编译期才
   知道」的部分；带上 plugin 只会让 xcodebuild 多一步 host 工具构建和 plugin 校验。

唯一消费者是 `Terminal.cmdXTVERSION`（`CSI > 0 q` 的应答）。**升级 vendored 副本时，
记得把该文件里的 `tag` / `commit` 两个常量改成新的上游 tag / commit。**

## 4. Xcode 27 警告清理（与行为无关）

`Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift` 两处 `memcpy(...)` 丢弃返回值，
Xcode 27 起报未使用结果警告 → 改写成 `_ = memcpy(...)`。纯诊断层面，语义不变；上游若已
自行处理，重放时跳过即可。

2026-11-02 追加一批同类清理（iOS 构建在 Xcode 里报 19 条）：

- `Apple/AppleTerminalView.swift`：`cellDimension` 是非可选 `CGSize`，`cellDimension != nil`
  恒真 → 从 `guard` 里删掉。
- `iOS/iOSTerminalView.swift`：`terminalAccessory?.controlModifier ?? controlModifier ?? false`
  三处去掉多余的 `?? false`（`controlModifier` 本身是 `Bool`）；无障碍那几个函数里从不改的
  `var` 改 `let`，删掉没用到的 `lineWidth` / `text` 局部量；`showContextMenu` 的 `items`
  改 `let`。
- `iOS/iOSTextInput.swift`：日志里插值可选的 `_markedTextRange` 改成 `String(describing:)`。

## 5. iOS 终端视图不拉伸位图（contentMode = .topLeft）

现象（uTermMobile）：连上会话、键盘弹起的那一段动画里，终端文字被纵向拉伸（行距变大、
光标与文字错位），随键盘升到位才缩回正常——看起来像「连接后内容被拉伸，直到键盘展开才恢复」。

根因：上游 iOS `TerminalView` 走 `draw(_:)`（未开 Metal），沿用 UIView 默认的
`contentMode = .scaleToFill`。键盘避让是**带动画**的 frame 变化：`layoutSubviews` 先按
**终值**尺寸重绘位图，presentation 层的 bounds 却还在从旧（更高）尺寸往新尺寸插值，
`.scaleToFill` 就把这张矮位图拉伸铺满更高的动画中 bounds。旋转、分屏改宽同理。

涉及文件：

- `Sources/SwiftTerm/iOS/iOSTerminalView.swift`
  - `setup()` 里加 `contentMode = .topLeft`：位图钉在左上角、不缩放，动画期露出的条带
    显示 `layer.backgroundColor`（即终端底色，视图本就 `isOpaque = false`）。
    Metal 路径不受影响（绘制在 `MTKView` 子视图里，自有 autoresizing）。

uTerm 侧无需改动。复现与验证配方：模拟器开软键盘（Simulator「Toggle Software Keyboard」），
`xcrun simctl io <udid> recordVideo` 录下键盘弹起过程逐帧看；修复前键盘上升的几帧文字明显
被拉高，修复后逐帧字形不变。上游若已自行设了非缩放的 contentMode，重放时跳过即可。

## 6. 终端状态快照（远控镜像接入用）

远控时另一台设备接入一条正在跑的会话：Mac 端发一份快照，之后只转发原始字节。快照要让接收端
与源终端**逐格**一致，并且之后的字节在两边产生同样的结果——光标、各种模式、制表位、字符集、
鼠标编码、备用屏之下的主屏、滚动历史都得带上。这些状态大多是 internal，有三个还是 `private`，
包外做不了，所以放进模块里。

涉及文件：

- `Sources/SwiftTerm/TerminalSnapshot.swift`（**新增**，纯本地文件，上游无对应物）
  - `Terminal.isAtSnapshotBoundary`：解析器在 ground 且没有跨 `feed` 暂存的半个 UTF-8 字符。
    只有这时拍的快照能接上后续字节（实测切在半个汉字处，300 个切点里 112 个续播出错）。
  - `Terminal.snapshotSequence(scrollbackLimit:)`：把状态重放成 VT 字节流（以 RIS 开头）。
    文件里每一条特殊处理都对应一个实测失败过的切点，简化前先读注释。
  - `Terminal.snapshotFingerprint(historyLines:)` + `TerminalSnapshotFingerprint`：快照必须
    复原的全部状态，测试的对照基准。
  - 已知不复原：Kitty 键盘协议的模式栈深度（只复原当前生效的标志位）、DECSC 保存的字符集。
- `Sources/SwiftTerm/Terminal.swift`：四处去掉 `private`，均带 `// uTerm patch:` 注释，
  不改任何逻辑——
  - `var mouseProtocol`（鼠标上报编码 1005/1006/1015/1016；丢了的话手机点 htop/vim 发的是旧格式）
  - `var gCharsets`（G0–G3 字符集；丢了的话 `lqqk` 不会画成 `┌──┐`）
  - `var readingBuffer` 及其类型 `struct ReadingBuffer`（看暂存的半个 UTF-8 字符）

uTerm 侧：`uTermTests/Features/Terminal/TerminalSnapshotTests.swift`，语料在
`uTermTests/Support/Fixtures/TerminalCorpus/`（`record.py` 可重录）。**升级上游后必须跑这组测试**：
上游改了任何渲染相关的内部状态（新模式、新的格子属性），指纹比对会第一个红。新增的状态要同时加进
`snapshotSequence` 与 `snapshotFingerprint`。

## 升级记录

### c068a905 → v1.19.0（464df520，2026-08-29）

上游跨了 128 个提交。三条补丁的重放结果：

- 补丁 1（最低对比度）：**原样重放，仅行号偏移**。`getAttributes` 里
  `mapColor` → dim 的代码形状与基线逐字节相同，钳制块插在同一位置。
  上游对该函数唯一的改动是给 `attributes` / `urlAttributes` 缓存加了 4096 条上限
  （truecolor 属性无界，超了就整体清空）——钳制结果本就是 (fg, bg, ratio) 的纯函数，
  缓存被清只是重算，语义不受影响。`colorsChanged()` 仍然清这两个缓存，
  `minimumContrastRatio` 的 didSet 契约成立。
- 补丁 2（iOS keyboardType）：**原样重放**。上游该属性一字未动。
- 补丁 3（SwiftTermBuildInfo）：**本次新增**，见上。

顺带确认的上游结构变化（不需要改补丁，但值得知道）：

- 新增 `Apple/PowerlineRenderer.swift`（#605，powerline 分隔符改为按 cell 几何自绘）。
  它的前景色取自 `getAttributes` 的属性字典，**自动继承最低对比度钳制**——与补丁 1
  「装饰字形一律钳制」的既定意图一致，无需额外打补丁。
- 新增 BiDi（阿拉伯语 / 希伯来语）渲染整套：`Bidi.swift`、`Apple/TerminalBidi.swift`、
  `Apple/ArabicShapingData.swift`、`Apple/BidiMirroringData.swift`。
- 新增 `SemanticPrompt.swift`（OSC 133）、`Apple/BellStyle.swift`、
  `Apple/ColorBridge.swift`（Color ↔ NSColor/UIColor 公开桥接）、`HangulInput.swift`、
  `SyncDebug.swift`。
- 反色（reverse video）改为「交换默认前景 / 背景色」而非按位取反。
- macOS 滚动条语义未变（仍然从不设 `isHidden`，`scrollerStyle` 默认 `.overlay`），
  所以 uTerm 的 `CopyableTerminalView` 用 `alphaValue` 管理浮现 / 淡出的做法继续成立。
