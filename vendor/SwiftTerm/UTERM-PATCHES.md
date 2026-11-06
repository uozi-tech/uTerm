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
设 `view.keyboardType`。2026-11 起改回 `.default`：`.asciiCapable` 让地球键只能在 ASCII
键盘之间切，用户切不到中文输入法；「默认英文」改由 `MTerminalView` 覆盖 `textInputMode`
实现（见补丁 #8）。属性保持可写，不影响这条补丁本身。联想 / 自动更正 / 智能标点上游已默认关闭
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
  - **续行的第一格必须真的打印出来**：上一行写满后光标处于「待折行」，只有打印字符才会折行，CUF
    不会。所以开头是空格子、或者整行全空的续行（zsh 的 PROMPT_SP 填充在变窄重排后就会切出这种行）
    也至少写一个空格，否则这一行丢失、下面整体上移。远控时手机每次转屏 / 弹键盘都会走「重排后重发快照」。
  - DECSC 保存的光标在改尺寸后可能越界（上游调整 `savedY` 时不设下限，会变成负数），而 DECRC 恢复时
    会夹回合法范围：快照与指纹都按夹过之后的值处理。
  - 两块缓冲区的制表位**无条件**写一遍（不活跃的备用屏用 `?1047h … ?1047l` 进去写，回来再 `ESC [H`
    归位，因为 1047 不保存光标）。原因：接收端自己就可能带着残缺的制表位——**直接按超过 80 列创建
    的终端，备用屏制表位只设到第 72 列**，RIS 也修不好。手机端恰好就是「按自身宽度直接创建」的一方。
- `Sources/SwiftTerm/Terminal.swift`：四处去掉 `private`，均带 `// uTerm patch:` 注释，
  不改任何逻辑——
  - `var mouseProtocol`（鼠标上报编码 1005/1006/1015/1016；丢了的话手机点 htop/vim 发的是旧格式）
  - `var gCharsets`（G0–G3 字符集；丢了的话 `lqqk` 不会画成 `┌──┐`）
  - `var readingBuffer` 及其类型 `struct ReadingBuffer`（看暂存的半个 UTF-8 字符）

uTerm 侧：`uTermTests/Features/Terminal/TerminalSnapshotTests.swift`，语料在
`uTermTests/Support/Fixtures/TerminalCorpus/`（`record.py` 可重录）。**升级上游后必须跑这组测试**：
上游改了任何渲染相关的内部状态（新模式、新的格子属性），指纹比对会第一个红。新增的状态要同时加进
`snapshotSequence` 与 `snapshotFingerprint`。

## 7. 终端放宽时，铺满整行的右边距跟着放宽

上游 `Buffer.resize` 只在变窄时把 `marginRight` 收进来，放宽时不动，于是它停在旧宽度上。
Mac 端的终端都是先按 80 列创建、再按窗口放宽的，所以两块缓冲区的右边距都停在第 79 列。
VT420 的列操作即使没开左右边距模式（DECLRMM）也会读它——`csiCloseBrace` 里 DECIC 的判断
`marginMode && x < left || x > right` 因 `&&` / `||` 优先级失误，变成「x 超过右边距就直接返回」；
`columnScroll` 也一样——于是在旧宽度以右，插入 / 删除列静默失效。远控快照会比对两块缓冲区的边距，
这里不一致也会让镜像端与 Mac 端分叉。

涉及文件：

- `Sources/SwiftTerm/Buffer.swift`：`resize(newCols:newRows:)` 开头加三行——右边距原本等于
  `cols - 1`（铺满）且在放宽时，跟到 `newCols - 1`。自定义的边距保持不动。

uTerm 侧：`uTermTests/Features/Terminal/SwiftTermResizeMarginTests.swift`（撤掉补丁时 DECIC 用例必红）。
上游若修了 `resize` 里的边距逻辑，或修了 DECIC 的优先级失误，重放前先跑这个测试再决定是否保留。

## 8. iOS 输入法组字可见 + 候选框跟着光标

上游 iOS 视图实现了 `UITextInput` 的 marked text（中文 / 日文输入法的组字），但**不画**它：
拼音打到一半终端上什么也看不见；`caretRect(for:)` / `firstRect(for:)` 又恒返回整个 `bounds`，
候选框与浮动光标落在视图左上角。

涉及文件：

- `Sources/SwiftTerm/iOS/iOSTerminalView.swift`：新增 `public var textInputCaretFrame: CGRect?`（光标格子，
  光标没显示时 nil；上游已有的 `caretFrame` 在没光标时给 `.zero`，不好判断）与 `open func textInputDidChange()`（空实现的钩子）。
- `Sources/SwiftTerm/iOS/iOSTextInput.swift`：`endTextInputEdit()` 末尾调 `textInputDidChange()`；
  `caretRect` / `firstRect` 返回 `textInputCaretFrame ?? bounds`。

uTerm 侧：`uTermMobile/Screens/Terminal/SwiftTermView.swift` 的 `MTerminalView` 覆盖
`textInputDidChange()`，在光标处叠一个标签显示组字中的文字；同一个类覆盖 `textInputMode`
让键盘默认英文、用户切走后记住所选。上游若开始自己画 marked text，删掉这条补丁和 uTerm 侧的叠层。

## 9. iOS 换字号后重绘整个可见区

上游 `resetFont()` 在 iOS 上调 `setNeedsDisplay(frame)`，但这个矩形是 bounds 坐标系。终端是
`UIScrollView`，一有回滚历史 `bounds.origin.y` 就大于 0，`frame` 落在可见区之外：换字号而尺寸与滚动位置
都没变时不重绘，屏上留着旧字号、旧位置的字（uTermMobile 拖完分屏分隔条松手时换字号就是这条路）。

涉及文件：`Sources/SwiftTerm/Apple/AppleTerminalView.swift` 的 `resetFont()`，iOS 分支改成
`setNeedsDisplay(bounds)`。uTerm 侧无需改动。上游若已修，跳过。

## 10. 输出到达时保留选区

上游只要 `allowMouseReporting` 为真（默认值，鼠标程序要靠它），`feedPrepare` 与 `linefeed`
就清选区：**任意一字节输出都会清**，连不换行的 spinner 帧也算。拖选途中选区被清，下一个
`mouseDragged` 又从当前位置重新起头，于是 Claude Code 这类持续刷新的程序运行时几乎选不中，
停下来才恢复。

涉及文件：

- `Mac/MacTerminalView.swift` / `iOS/iOSTerminalView.swift`：新增
  `public var preservesSelectionDuringOutput: Bool = false`（默认保持上游语义），`linefeed`
  改看 `clearsSelectionOnOutput`。
- `Apple/AppleTerminalView.swift`：新增 `clearsSelectionOnOutput`，`feedPrepare` 改看它。
- `Terminal.swift`：新增 `selectionsInvalidate()`，在 ED 2、ED 3、切换屏幕缓冲区时清选区。这三种
  情况下原文已经没了，ED 3 还会让绝对行号错位（`trimStart` 不通知选区）。scrollback 回收不用管，
  上游已经用 `adjustForInPlaceScroll` 平移选区。

选区内的文字被程序就地改写时高亮不动，复制到的是改写后的内容，这是有意的取舍。

uTerm 侧入口：`TerminalSession.init` 设 `true`；iOS 未开启。

## 11. 注册 OSC 处理器后还能调回内置处理

`registerOscHandler` 注册的处理器优先于内置分发。uTerm 要在 OSC 133 上多做一件事（新提示符出现
时清掉上一个程序的状态），要接管 OSC 9 里 SwiftTerm 不处理的纯文本通知，都得先调回内置逻辑，否则
语义提示符和 `9;4` 进度条就失效了。

涉及文件：

- `Terminal.swift`：`oscSemanticPrompt`、`oscProgressReport` 由 internal 改 `public`，行为不变。

uTerm 侧入口：`TerminalSession+ProgramStatus.swift`。

## 12. 往上翻时，程序重绘不把光标画回屏幕

光标所在行滚出可视区时，`updateCursorPosition` 会移除 `caretView` 并提前返回，它的 frame 停在
最后一次可见的位置。上游 macOS 的 `showCursor(source:)` 不看可视区，收到 `?25h` 就 `addSubview`，
下一次 `updateDisplay` 才再移除。Claude Code 每帧都发 `?25l` … `?25h`，所以翻到输入框看不见时，
光标会在输入框原来的位置（窗口左下角）反复闪现。

涉及文件：

- `Apple/AppleTerminalView.swift`：新增 `caretRowIsInViewport`，`updateCursorPosition` 改用它，
  判定不变。
- `Mac/MacTerminalView.swift`：`showCursor(source:)` 只在光标行可见时才加回 `caretView`。翻回底部时
  由 `updateCursorPosition` 加回并更新位置。

iOS 未改：`caretView` 的 frame 是滚动内容坐标，旧位置会随内容滚出屏幕。

uTerm 侧无入口，回归测试见 `uTermTests/Features/Terminal/TerminalCaretViewportTests.swift`。

## 13. 绘制节流可调

上游 `queuePendingDisplay` 固定按 60 fps 排下一次绘制。程序改尺寸后重发整段内容时，一次绘制要 10～18ms，
大部分都画在马上要被覆盖的中间状态上（4MB 语料、185×56：解析约 130ms，绘制 295～518ms）。

涉及文件：

- `Mac/MacTerminalView.swift` / `iOS/iOSTerminalView.swift`：新增 `displayThrottleNanoseconds`，默认等于上游的 16.67ms。
- `Apple/AppleTerminalView.swift`：`queuePendingDisplay` 改读它；新增 `flushPendingDisplay()`，追上积压时立刻画最后一帧。
- `iOS/iOSTerminalView.swift`：`layoutSubviews` 里滚动位置变了就重绘这一条，在已有待执行的绘制时改为交给那一次。
  上游在 iOS 上每个滚动的拍子画两遍（20 次 feed 画 40 次），节流也拦不住这条路。

键盘回显走 `displayImmediately`，不受节流影响。

uTerm 侧入口：`uTerm/Features/Terminal/TerminalFlushPacing.swift` 的 `feedPaced`。

## 14. 换字号不重置终端状态

上游 `resetFont()` 调公开的 `resize(cols:rows:)`，而它最后会执行 `softReset()`：方向键模式、隐藏的光标、
自动折行、插入模式、原点模式、滚动区域、当前颜色、字符集和语义提示符标记全部被清掉。程序不知道字号变了，
不会重新设置，vim 里的方向键就此发错序列。uTermMobile 转屏时字号随宽度变，每次都中招；Mac 改字号、改行距同理。

涉及文件：`Apple/AppleTerminalView.swift` 的 `resetFont()`，改成只调 `terminal.resize` 和 `sizeChanged`。
公开的 `resize(cols:rows:)` 保持上游语义，uTerm 没有调用它。

uTerm 侧无入口，回归测试见 `uTermTests/Features/Terminal/TerminalFontChangeTests.swift` 和
`MTerminalContainerViewTests.testRotationKeepsProgramModes`。上游若已修，跳过。

## 15. 默认光标样式可配

上游把 `CSI 0 q`（以及不带参数的 `CSI q`）固定解释成闪烁方块，完整重置（`ESC c`，`reset` 命令）则不动光标。
vim、fish 这类程序退出时发它们，是想回到终端的默认光标，而默认应该是用户在设置里选的。uTerm 不再反复应用光标设置之后
（补丁 #13 同一轮的 `TerminalTheme.applyLook`），不改的话用户的样式回不来。

涉及文件：`Terminal.swift` 新增 `defaultCursorStyle`，`cmdSetCursorStyle` 和 `resetToInitialState` 读它。
默认 nil，行为与上游相同；`CSI 1 q` 仍是闪烁方块。

uTerm 侧入口：`TerminalTheme.applyCursor`。iOS 没有设置它，行为不变。回归测试见
`uTermTests/Features/Terminal/TerminalThemeTests.swift`。

## 16. 同步输出（DEC 2026）的帧只重绘变过的行，帧没写完时不动光标、不滚动

Claude Code 在 SwiftTerm 里每帧都包 `?2026h` … `?2026l`，思考时约 10 帧/秒、每帧约 150 字节。一帧也可能被拆进两次读取
（实测 144 帧里 47 帧）。上游有三处按「帧很大、很少」来做：

- `Terminal.swift` `endSynchronizedOutput`：帧结束时把整屏标脏。帧内变过的行本来就累积在更新范围里（窗口期视图不消费它），
  删掉后只重绘变过的行。回放真实帧，贴底时单次绘制从约 5ms 降到约 1ms。
- `Mac/MacTerminalView.swift`、`iOS/iOSTerminalView.swift` `showCursor` / `hideCursor`：帧内的 `?25l` / `?25h` 立刻增删
  `caretView`，帧被拆开时光标闪一下，没拆也每帧付一次 AppKit 增删视图的开销。帧内不再处理，帧结束后由
  `updateCursorPosition` 按最终状态摆好。
- `Mac/MacTerminalView.swift` `scrollWheel` + `Apple/AppleTerminalView.swift` `synchronizedOutputChanged`：滚动会立刻按实时
  缓冲重绘，帧没写完时就把半帧画出来。滚轮的行数先攒着，帧结束再滚（`applyScrollDeferredBySync`）。程序卡在帧中间时，
  上游 1 秒的超时会结束这一帧。iOS 的滚动由 `UIScrollView` 驱动，没有改。

uTerm 侧无入口，回归测试见 `uTermTests/Features/Terminal/TerminalSynchronizedOutputTests.swift`。

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
