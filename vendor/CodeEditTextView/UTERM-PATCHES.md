# uTerm 对 vendored CodeEditTextView 的本地补丁

上游：`https://github.com/CodeEditApp/CodeEditTextView`，基线 tag `0.12.1`
（revision `d7ac3f11f22ec2e820187acce8f3a3fb7aa8ddec`）。

## 为什么 vendor

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
   `var maxFoundLineWidth = maxFoundLineWidth`），再按上面两条重做 manifest 裁剪。
3. 更新本文件顶部的基线 tag / revision。
4. 用上面的验证方法确认横向滚动仍然生效。
