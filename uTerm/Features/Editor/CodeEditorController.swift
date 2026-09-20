// uTerm/Editor/CodeEditorController.swift
import SwiftUI
import AppKit
import CodeEditTextView

/// 编辑器中枢。NSViewRepresentable + Coordinator 统一在此。
/// 公开接口先全暴露（fatalError 占位），让 Track A/B/C 并行填实现而不抢同一文件。
@MainActor
final class CodeEditorController: NSObject {

    // MARK: 由 makeNSView 注入
    fileprivate(set) weak var textView: TextView?
    fileprivate(set) weak var scrollView: NSScrollView?
    fileprivate(set) weak var buffer: FileBuffer?
    private var _isUpdatingFromBinding = false
    private var renderedTextVersion: Int?

    // MARK: 焦点请求（FilePreviewModel.editorFocusRequest）
    /// 已消费的焦点请求代数 —— updateNSView 用它判重，避免每次视图刷新都抢焦点。
    var handledFocusGeneration = 0

    /// 把窗口第一响应者交给编辑器正文。updateNSView 调用时视图可能还没进 window
    /// （makeNSView 后的首次 update），异步一帧后重试一次（与 refreshGutter 同款兜底）。
    func focusTextView(retryIfNoWindow: Bool = true) {
        guard let textView else { return }
        if let window = textView.window {
            if window.firstResponder !== textView {
                window.makeFirstResponder(textView)
            }
        } else if retryIfNoWindow {
            DispatchQueue.main.async { [weak self] in
                self?.focusTextView(retryIfNoWindow: false)
            }
        }
    }

    // MARK: Find/Replace（Track B）
    var currentFindController: FindReplaceController?
    /// Local key event monitor installed in makeNSView; removed on deinit。
    /// nonisolated(unsafe) 让 deinit 能读 token 调 NSEvent.removeMonitor。
    nonisolated(unsafe) var keyEventMonitor: Any?

    // MARK: Track C — 语法高亮
    private var highlighter: SyntaxHighlighter = NoopHighlighter()
    private var latestHighlights: [(NSRange, NSColor)] = []
    private var highlightedApplicationRange: NSRange?

    /// caret 宽度。CodeEditTextView 的 `CursorView` 固定 1pt（`init` 是 internal，
    /// 包外改不了默认值），1pt 在 Retina 上只有 2 个物理像素 —— 浅色主题下细到看不见。
    /// 取 2pt 起步并随字号线性放大（当前 `EditorTheme.textFontSize` = 12 → 2pt），
    /// 上限 4pt 免得字号调大后盖住半个字符位。
    static func cursorWidth(for font: NSFont) -> CGFloat {
        min(4, max(2, (font.pointSize / 7).rounded()))
    }

    /// 把库给的 caret frame 修成：高度夹到字形高度并垂直居中（行高 1.4 倍时不顶满整行）、
    /// 宽度取 ``cursorWidth(for:)``、x 吸附到物理像素网格。
    ///
    /// 像素对齐是 caret 这类实心细矩形的必需项：排版给的 x 常带小数，2pt 的矩形落在
    /// 半像素上会被抗锯齿摊成两条半透明边 —— 看上去比 1pt 还虚。`scale` 传窗口的
    /// `backingScaleFactor`，非正值时跳过对齐。
    static func normalizedCursorFrame(_ frame: CGRect, font: NSFont, scale: CGFloat = 2) -> CGRect {
        var normalized = frame

        let targetHeight = min(frame.height, max(1, ceil(font.ascender - font.descender)))
        if frame.height > targetHeight {
            normalized.origin.y += (frame.height - targetHeight) / 2
            normalized.size.height = targetHeight
        }

        normalized.size.width = cursorWidth(for: font)
        if scale > 0 {
            normalized.origin.x = (normalized.origin.x * scale).rounded() / scale
        }
        return normalized
    }

    /// 按 buffer 的语言挑高亮策略：注册了 tree-sitter grammar → TreeSitter；
    /// 其余 code-like 文件 → PatternSyntaxHighlighter；纯文本/图片 → Noop。
    private func makeHighlighter(for buffer: FileBuffer) -> SyntaxHighlighter {
        let langId: String
        switch buffer.kind {
        case .code(let l): langId = l
        case .markdown:    langId = "markdown"
        case .plainText:   langId = ""
        case .image:       langId = ""
        }
        if let entry = GrammarRegistry.entry(for: langId) {
            return TreeSitterHighlighter(language: entry.language,
                                         highlightsQueryText: entry.highlightsQueryText)
        } else if !langId.isEmpty {
            return PatternSyntaxHighlighter(language: langId)
        } else {
            return NoopHighlighter()
        }
    }

    /// SwiftUI 把同一 view identity 的 coordinator 复用 —— 两个同 kind 的 .code 文件
    /// 切换时 body 上没有 `.id(buffer.id)`，不会重跑 makeNSView/attach，只进 updateNSView。
    /// 所以"每个文件各自一份"的状态（语法高亮策略 + buffer 引用）必须在这里随新 buffer
    /// 重选，否则新文件会沿用上一个文件的 grammar 上色（残留高亮），且后续编辑会写回上一个
    /// 文件的 FileBuffer。返回 true 表示 buffer 确实换了（updateNSView 据此强制重渲染）。
    @discardableResult
    func rebind(to newBuffer: FileBuffer) -> Bool {
        guard buffer !== newBuffer else { return false }
        buffer = newBuffer
        renderedTextVersion = nil
        latestHighlights = []
        highlightedApplicationRange = nil
        highlighter.dispose()
        highlighter = makeHighlighter(for: newBuffer)
        return true
    }

    // MARK: 外部钩子（订阅文本/选中变化）
    var onTextChange: ((NSRange, String) -> Void)?
    var onSelectionChange: ((NSRange) -> Void)?

    // MARK: Track A — 视觉
    /// 当前行底色 overlay。CodeEditTextView 内置 `highlightSelectedLine` 只在选区
    /// 为空时绘，drag-select 会消失（VSCode 是常显），所以走自己的 overlay。
    private var activeLineOverlay: ActiveLineOverlay?
    /// VSCode-style indentation guide overlay, driven by the same visible-line
    /// refresh cadence as the gutter.
    private var indentGuideOverlay: IndentGuideOverlay?
    // nonisolated(unsafe): deinit is nonisolated and needs to remove this observer
    nonisolated(unsafe) private var selectionObserver: NSObjectProtocol?

    // MARK: 行号 gutter
    private var lineNumberGutter: LineNumberGutter?
    /// 最近一次拿到的活动行号，scroll 事件下用作 fallback 防止滚动时
    /// textLineForOffset 返回 nil 让 gutter 全行变灰。
    private var lastActiveLineIndex: Int?
    nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?
    nonisolated(unsafe) private var textDidChangeObserver: NSObjectProtocol?
    /// 订 clipView 的 frameDidChange —— size 变化（不是 scroll）。
    /// 触发源：window resize / split adjust / SwiftUI 首次 layout。
    /// 这是唯一能驱动 CodeEditTextView updatedViewport 链的 size 事件。
    nonisolated(unsafe) private var clipFrameObserver: NSObjectProtocol?

    // MARK: PR-final — sameword emphasis debounce
    private var sameWordDebounce: DispatchWorkItem?

    // MARK: 高亮（Track C 实现）
    func applyHighlights(_ pairs: [(NSRange, NSColor)]) {
        guard let textView, let storage = textView.textStorage else { return }
        latestHighlights = pairs
        applyCachedHighlights(to: storage, in: highlightApplicationRange(storageLength: storage.length))
    }

    private func applyCachedHighlights(to storage: NSTextStorage, in target: NSRange) {
        guard let textView, target.length > 0 else { return }
        storage.beginEditing()
        storage.removeAttribute(.foregroundColor, range: target)
        storage.addAttribute(.foregroundColor,
                             value: EditorTheme.foreground,
                             range: target)
        for (range, color) in latestHighlights where range.location < NSMaxRange(target) {
            let intersection = NSIntersectionRange(range, target)
            if intersection.length > 0, NSMaxRange(intersection) <= storage.length {
                storage.addAttribute(.foregroundColor, value: color, range: intersection)
            }
        }
        storage.endEditing()
        highlightedApplicationRange = target
        textView.layoutManager.invalidateLayoutForRange(target)
        textView.needsLayout = true
        textView.needsDisplay = true
    }

    private func highlightApplicationRange(storageLength: Int) -> NSRange {
        EditorHighlightWindow.applicationRange(
            textLength: storageLength,
            visibleRange: textView?.visibleTextRange
        )
    }

    private func refreshVisibleHighlightsIfNeeded() {
        guard let textView, let storage = textView.textStorage,
              storage.length > EditorHighlightWindow.fullDocumentThreshold,
              let visibleRange = textView.visibleTextRange else { return }
        if let highlightedApplicationRange,
           EditorHighlightWindow.contains(visibleRange, in: highlightedApplicationRange) {
            return
        }
        applyCachedHighlights(
            to: storage,
            in: EditorHighlightWindow.applicationRange(
                textLength: storage.length,
                visibleRange: visibleRange
            )
        )
    }

    func clearHighlights(in range: NSRange?) {
        guard let textView, let storage = textView.textStorage else { return }
        let target = range ?? NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.foregroundColor, range: target)
        if range == nil {
            latestHighlights = []
            highlightedApplicationRange = nil
        }
    }

    // MARK: Emphasis（Track B / PR-final 调）
    func applyEmphases(_ ranges: [NSRange], group: String, style: EmphasisStyle, active: Int?) {
        guard let textView, let mgr = textView.emphasisManager else { return }
        let emphases: [Emphasis] = ranges.enumerated().map { idx, range in
            Emphasis(range: range, style: style, flash: false, inactive: idx != active, selectInDocument: false)
        }
        mgr.replaceEmphases(emphases, for: group)
    }

    func clearEmphases(group: String) {
        textView?.emphasisManager?.removeEmphases(for: group)
    }

    // MARK: 替换 / undo（Track B 调）
    func performReplace(_ range: NSRange, with replacement: String) {
        guard let textView else { return }
        textView.replaceCharacters(in: [range], with: replacement)
    }

    func beginReplaceAllUndoGroup() {
        textView?.undoManager?.beginUndoGrouping()
    }

    func endReplaceAllUndoGroup() {
        textView?.undoManager?.endUndoGrouping()
    }

    // MARK: 滚动
    func scrollRangeToVisible(_ range: NSRange) {
        guard let textView else { return }
        let rect = textView.layoutManager.rectForOffset(range.location) ??
                   CGRect(x: 0, y: 0, width: 1, height: 1)
        textView.scrollToVisible(rect)
    }

    // MARK: textStorage 读访问
    var textStorage: NSTextStorage {
        guard let s = textView?.textStorage else { fatalError("textView or textStorage not yet attached") }
        return s
    }

    deinit {
        let center = NotificationCenter.default
        if let observer = selectionObserver     { center.removeObserver(observer) }
        if let observer = scrollObserver        { center.removeObserver(observer) }
        if let observer = textDidChangeObserver { center.removeObserver(observer) }
        if let observer = clipFrameObserver     { center.removeObserver(observer) }
        // NSEvent.removeMonitor 必须配对 addLocalMonitorForEvents，否则全局 key-down
        // 监听 token 永久泄漏 —— 每开一次文件多一个 monitor，每次按键多触发一次。
        if let monitor = keyEventMonitor        { NSEvent.removeMonitor(monitor) }
    }
}

// MARK: - Coordinator role (TextViewDelegate) — added in PR-1
extension CodeEditorController: TextViewDelegate {

    var isUpdatingFromBinding: Bool {
        get { _isUpdatingFromBinding }
        set { _isUpdatingFromBinding = newValue }
    }

    /// 在 updateNSView 的 setText 之后调，确保 gutter 还挂着。
    /// 背景：CodeEditTextView 的 `setTextStorage` 会 nuke 所有 subview，
    /// SFTP 下载完成 / reloadFromRemote 都会触发 setText。setText 也会换掉
    /// textStorage，所以全文语法色需要跟 gutter 一起恢复。
    func ensureGutterAttached() {
        // 同步跑一次（重挂 / 宽度）+ 异步 bootstrap viewport（等 layout 稳定）
        refreshGutter(bootstrap: false)
        refreshGutter(bootstrap: true, defer: true)
        rehighlightAllText()
    }

    private func rehighlightAllText() {
        guard let text = textView?.string else { return }
        highlighter.initialHighlight(text: text) { [weak self] pairs in
            self?.applyHighlights(pairs)
        }
    }

    /// 重新聚焦后把 caret 补回来（由 `EditorTextView.becomeFirstResponder()` 调）。
    ///
    /// 上游 0.12.1 的 bug：`TextSelectionManager.removeCursors()`（失焦时走）只做
    /// `textSelection.view?.removeFromSuperview()`，**不把 `textSelection.view` 置 nil**。
    /// 重新聚焦后 `repositionCursorSelection` 的守卫是
    /// `view == nil || doesViewNeedReposition` —— view 还指着那个已经脱离父视图的旧
    /// CursorView，光标又没动过（origin/height 完全相等），守卫直接 return false，
    /// CursorView 再也没被 addSubview 回去。**屏幕上就此没有 caret**。
    ///
    /// 而且光把 view 置 nil 也不够：`becomeFirstResponder()` 压根不调
    /// `updateSelectionViews()`，`needsDisplay = true` 不置 `needsLayout`，
    /// 所以在下一次滚动 / resize 触发 layout 之前没人会重建（探针实测）。
    ///
    /// 走 public 的 `setSelectedRanges` 绕开这两层：它重建 TextSelection 对象
    /// （新对象 `view == nil`）→ `updateSelectionViews` 走创建分支 → 新 CursorView
    /// 被 addSubview 并重新注册进闪烁计时器（`removeCursors` 里的 `stopTimer()` 把
    /// 注册表清空过，复用旧 view 也不会再闪）。范围一字未改，`setSelectedRanges`
    /// 因此不会发 selectionChangedNotification，观察者不受打扰 —— 也正因如此，
    /// caret 高度归一化要在这里显式补一次。
    func restoreCaretsIfNeeded() {
        guard let textView else { return }
        let selections = textView.selectionManager.textSelections
        // 只有空选区（纯光标）才有 caret；有选中内容时本来就不该画。
        guard selections.contains(where: { $0.range.isEmpty }) else { return }
        guard !hasCaretView(in: textView) else { return }
        textView.selectionManager.setSelectedRanges(selections.map(\.range))
        normalizeEditorCursors()
    }

    private func hasCaretView(in textView: TextView) -> Bool {
        // NSTextInsertionIndicator 是 useSystemCursor = true 时上游用的系统 caret
        // （uTerm 恒为 false，一并认掉以免将来翻开关时这里静默失效）。
        textView.subviews.contains { $0 is CursorView || $0 is NSTextInsertionIndicator }
    }

    /// 由 `EditorTextView.viewWillDraw` 每轮绘制前调用，另外选中变化 / 滚动 / 视口
    /// resize 时也各调一次（那几处顺带把 gutter、底色带一起刷了）。幂等：frame 已经
    /// 是目标值就不写，不会自己触发新一轮绘制。
    func normalizeEditorCursors() {
        guard let textView else { return }
        let scale = textView.window?.backingScaleFactor ?? 2
        for cursorView in textView.subviews where cursorView is CursorView {
            let normalized = Self.normalizedCursorFrame(cursorView.frame, font: textView.font, scale: scale)
            if cursorView.frame != normalized {
                cursorView.frame = normalized
            }
        }
    }

    /// 统一刷新入口。
    ///
    /// `bootstrap`：是否需要显式启 CodeEditTextView 的 viewport-driven layout 链
    /// （`updatedViewport` + 必要时 `layoutLines`）。只在首次 attach 和 setText
    /// 之后需要 —— 其他场景（scroll、resize 中途）CodeEdit 内部观察者已经驱动。
    ///
    /// `defer`：把工作异步到下一 runloop tick。在 NSViewRepresentable.makeNSView /
    /// updateNSView 调用栈里 SwiftUI/AppKit 自己的 layout 还没跑完，
    /// `scrollView.documentVisibleRect` 可能是 `.zero`，异步后才稳定。
    private func refreshGutter(bootstrap: Bool, defer doDefer: Bool = false) {
        if doDefer {
            DispatchQueue.main.async { [weak self] in
                self?.refreshGutter(bootstrap: bootstrap, defer: false)
            }
            return
        }

        guard let textView, let gutter = lineNumberGutter, let scrollView else { return }

        // 1. 重挂（如被 setTextStorage 干掉）
        if gutter.superview !== textView {
            gutter.frame = NSRect(x: 0, y: 0, width: gutter.gutterWidth, height: textView.bounds.height)
            textView.addSubview(gutter)
        }

        // 2. Bootstrap viewport layout 链。
        //
        // updatedViewport 内部是 `if !updateFrameIfNeeded { layoutLines() }`：
        // - frame 变了 → updateFrameIfNeeded returns true → 短路 layoutLines
        // - frame 没变 → updateFrameIfNeeded returns false → 自己跑 layoutLines
        //
        // 第一次 setText 后必然走"frame 变了"分支（高度从 17 跳到几万），所以
        // 内部 layoutLines 不跑。我们检测 frame 是否扩展，只在扩展时再补一刀
        // layoutLines；frame 没变就 skip（不再重复 layout）。
        if bootstrap {
            if scrollView.documentVisibleRect.isEmpty {
                // 视口还没出来 —— 再 defer 一帧重试，最多两次
                DispatchQueue.main.async { [weak self] in
                    self?.refreshGutter(bootstrap: true, defer: false)
                }
                return
            }
            let oldHeight = textView.frame.height
            textView.updatedViewport(scrollView.documentVisibleRect)
            if textView.frame.height != oldHeight {
                textView.layoutManager.layoutLines()
            }
        }

        // 3. 宽度 / edgeInsets 兜底
        let widthChanged = gutter.recomputeWidth()
        let desired = 12 + gutter.gutterWidth
        if widthChanged || textView.edgeInsets.left != desired {
            textView.edgeInsets = HorizontalEdgeInsets(left: desired, right: 12)
        }

        // 4. 刷行号 —— bootstrap 时 layout 已经做完，textLineForOffset 可靠；
        //    非 bootstrap 时回退到 lastActiveLineIndex 防 layout 滞后导致 nil。
        let activeOffset = textView.selectionManager.textSelections.first?.range.location ?? 0
        let active = lineIndex(ofOffset: activeOffset) ?? lastActiveLineIndex
        if let active { lastActiveLineIndex = active }
        updateGutter(activeLineIndex: active)
        updateIndentGuides(activeLineIndex: active)
        normalizeEditorCursors()
    }

    func attach(textView: TextView, scrollView: NSScrollView, buffer: FileBuffer) {
        // Idempotent —— 防 future refactor 再次 attach 时 leak 老的 observer。
        let center = NotificationCenter.default
        if let o = selectionObserver     { center.removeObserver(o); selectionObserver = nil }
        if let o = scrollObserver        { center.removeObserver(o); scrollObserver = nil }
        if let o = textDidChangeObserver { center.removeObserver(o); textDidChangeObserver = nil }
        if let o = clipFrameObserver     { center.removeObserver(o); clipFrameObserver = nil }
        if let m = keyEventMonitor       { NSEvent.removeMonitor(m); keyEventMonitor = nil }

        self.textView = textView
        self.scrollView = scrollView
        self.buffer = buffer
        renderedTextVersion = buffer.textVersion

        // Track A · VSCode Dark+ 配色
        textView.selectionManager.selectionBackgroundColor = EditorTheme.selectionBg
        textView.selectionManager.insertionPointColor = EditorTheme.caret
        // 关掉 CodeEditTextView 自带的"光标行整行底色"。它对空选区（仅光标、无选中）
        // 无条件绘制（drawSelections: range.isEmpty → drawHighlightedLine），用
        // selectedLineBackgroundColor（系统选中色）铺满整行 —— 跟我们自己的
        // ActiveLineOverlay 叠成两条带，多出来那条蓝的就是要去掉的"多余高亮"。
        // 坑：0.12.1 的 highlightSelectedLine 是死属性（声明后 draw 路径从不读），
        // 设 false 无效；真正关它得把那条带的填充色清成透明。flag 一并置 false，
        // 以便将来库把它接回 draw 路径时也走对分支。正文选中走的是另一条路径
        // （drawSelectedRange + selectionBackgroundColor），不受影响。
        textView.selectionManager.highlightSelectedLine = false
        textView.selectionManager.selectedLineBackgroundColor = .clear

        // active-line 底色 overlay（始终显示，横跨 gutter 区）
        self.activeLineOverlay = ActiveLineOverlay(textView: textView)
        let initial = textView.selectionManager.textSelections.first?.range ?? NSRange(location: 0, length: 0)
        self.activeLineOverlay?.update(selection: initial)

        self.indentGuideOverlay?.removeFromTextView()
        self.indentGuideOverlay = IndentGuideOverlay(textView: textView)

        // 行号 gutter —— 挂在 textView 子视图，随文档滚动。
        let gutter = LineNumberGutter(textView: textView)
        gutter.frame = NSRect(x: 0, y: 0, width: gutter.gutterWidth, height: textView.bounds.height)
        gutter.autoresizingMask = [.height]
        textView.addSubview(gutter)
        self.lineNumberGutter = gutter
        // 让正文给 gutter 让出空间（原本 left = 12）
        textView.edgeInsets = HorizontalEdgeInsets(left: 12 + gutter.gutterWidth, right: 12)
        // 首次给 activeLineIndex = 0（顶部）—— layout 还没跑时 textLineForOffset
        // 会 nil，传 0 让 gutter 首帧第一行就是高亮态，避免短暂全灰。
        lastActiveLineIndex = 0
        updateGutter(activeLineIndex: 0)
        refreshGutter(bootstrap: true, defer: true)

        // 订阅滚动：contentView 的 bounds 变化驱动行号重排
        // 不重算 activeLineIndex —— 用 lastActiveLineIndex；快速滚动时
        // textLineForOffset 容易返回 nil，导致 active 行号瞬间变灰闪一下。
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateGutter(activeLineIndex: self.lastActiveLineIndex)
                self.updateIndentGuides(activeLineIndex: self.lastActiveLineIndex)
                // 不折行时文档宽度会随排版到更长的行而增长，当前行底色带的宽度是
                // 快照 —— 不在滚动时重画，横滚过视口宽后那条带会半路截断。
                self.activeLineOverlay?.refresh()
                self.normalizeEditorCursors()
                self.refreshVisibleHighlightsIfNeeded()
            }
        }

        // 订阅 clipView frame 变化：window resize / split adjust / SwiftUI 首次 layout。
        // 非 bootstrap —— CodeEdit 内部 frameDidChange 观察者已驱动 layoutLines；
        // 这里只需要刷 gutter 显示（重画 + 重算宽度）。
        scrollView.contentView.postsFrameChangedNotifications = true
        clipFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshGutter(bootstrap: false)
                self.activeLineOverlay?.refresh()   // 视口尺寸变了，底色带宽度要跟上
            }
        }

        // 订阅文本变化：行数可能变 → 重算宽度（若变了刷正文 edgeInsets）+ 刷行号
        textDidChangeObserver = NotificationCenter.default.addObserver(
            forName: TextView.textDidChangeNotification,
            object: textView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // refreshGutter 一站包：重挂检查 + 宽度 + edgeInsets + 行号
                self.refreshGutter(bootstrap: false)
                // find bar 开着时，文本被外部编辑会让缓存的 NSRange 失效（缩短文本后
                // next()/previous() 会用越界 range 命中 NSRangeException）。重跑 search()
                // 让匹配重新对齐新文本。replace* 自身会重搜，重复一次也无害（幂等）。
                self.currentFindController?.search()
            }
        }

        // Track A · 订阅选中变化通知（TextViewDelegate 无 selection callback，用 NotificationCenter）
        selectionObserver = NotificationCenter.default.addObserver(
            forName: TextSelectionManager.selectionChangedNotification,
            object: textView.selectionManager,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let range = self.textView?.selectionManager.textSelections.first?.range
                    ?? NSRange(location: 0, length: 0)
                self.activeLineOverlay?.update(selection: range)
                let idx = self.lineIndex(ofOffset: range.location)
                if let idx { self.lastActiveLineIndex = idx }
                self.updateGutter(activeLineIndex: idx ?? self.lastActiveLineIndex)
                self.updateIndentGuides(activeLineIndex: idx ?? self.lastActiveLineIndex)
                self.normalizeEditorCursors()
                self.onSelectionChange?(range)
                self.scheduleSameWordRefresh(selection: range)
            }
        }

        // Track C · 初始化语法高亮（策略选择见 makeHighlighter；切文件复用见 rebind）
        highlighter.dispose()
        highlighter = makeHighlighter(for: buffer)
        highlighter.initialHighlight(text: buffer.text) { [weak self] pairs in
            self?.applyHighlights(pairs)
        }

    }

    func textView(_ textView: TextView,
                  didReplaceContentsIn range: NSRange,
                  with string: String) {
        guard !_isUpdatingFromBinding else { return }
        let newText = textView.string
        buffer?.text = newText
        buffer?.isDirty = true
        renderedTextVersion = buffer?.textVersion
        onTextChange?(range, string)
        highlighter.didEdit(range: range, replacement: string, fullText: newText) { [weak self] pairs in
            self?.applyHighlights(pairs)
        }
    }

    /// SwiftUI updateNSView 只比较整数代数，不再为每次按键读取并比较整个 TextView.string。
    func needsBindingTextUpdate(for buffer: FileBuffer) -> Bool {
        self.buffer !== buffer || renderedTextVersion != buffer.textVersion
    }

    func didRenderBindingText(for buffer: FileBuffer) {
        renderedTextVersion = buffer.textVersion
    }
}

// MARK: - Find/Replace key handling (Track B)
extension CodeEditorController {

    func handleKeyEvent(_ event: NSEvent,
                        openFind: (_ showReplace: Bool) -> Void,
                        closeFind: () -> Void,
                        requestSave: () -> Void) -> Bool {
        guard event.type == .keyDown else { return false }
        let cmd   = event.modifierFlags.contains(.command)
        let opt   = event.modifierFlags.contains(.option)
        let shift = event.modifierFlags.contains(.shift)
        let chars = event.charactersIgnoringModifiers ?? ""

        switch (cmd, opt, shift, chars) {
        case (true, false, false, "a"):
            // ⌘A 全选 / ⌘C 复制本该由 Edit 菜单走响应链，但工作区窗口里该路径
            // 不可靠（user 实测编辑器内 ⌘A/⌘C 无效）。与 ⌘S 同款：编辑器聚焦时
            // 由本地监听器直接消费，行为确定；消费掉事件也避免菜单路径二次触发。
            textView?.selectAll(nil); return true
        case (true, false, false, "c"):
            guard let textView else { return false }
            textView.copy(textView); return true
        case (true, false, _, "f"):
            openFind(false); return true
        case (true, true, _, "f"):
            openFind(true); return true
        case (true, false, false, "g"):
            currentFindController?.next(); return true
        case (true, false, true, "g"):
            currentFindController?.previous(); return true
        case (true, false, false, "s"):
            // ⌘S 在编辑器聚焦时直接保存“正在编辑的这个 buffer”——而不是依赖窗口的
            // activeBufferID。由本地 keyDown 监听器拦截（已确保只在 textView 是
            // firstResponder 的 key 窗口里触发），消费事件（return true）避免菜单项
            // 再触发一次造成双保存。
            //
            // 这条路径原本是在绕一个根因：分屏下点进非聚焦面板的编辑器，NSTextView
            // 吃掉点击、`PreviewArea` 的 `.onTapGesture` 不触发，活动面板与活动
            // buffer 都不更新，⌘S 就投到另一个未脏 buffer 上变成 no-op。该根因已修
            // （按下即激活改走 NSEvent 旁观探针 `onPointerDown`，现在在共享组件
            // `UPaneGroupArea` 里），这里保留是双保险：它按 firstResponder 认 buffer，
            // 比按窗口状态更直接。
            requestSave(); return true
        default:
            // Esc handled by FindReplaceBar via .keyboardShortcut(.escape)
            return false
        }
    }

    /// 由本地 keyDown 监听器在 ⌘S 时调用：把“当前编辑的 buffer”的 id 带进
    /// `.savePreviewBuffer` 通知，让 WorkspaceWindowView 精确保存它（而非 activeBufferID）。
    /// buffer 未绑定时静默忽略。
    func requestSaveCurrentBuffer() {
        guard let buffer else { return }
        NotificationCenter.default.post(
            name: .savePreviewBuffer,
            object: nil,
            userInfo: [SavePreviewBufferKey.bufferID: buffer.id])
    }

    func openFindController(showReplace: Bool) -> FindReplaceController {
        if let existing = currentFindController {
            existing.isReplaceShown = existing.isReplaceShown || showReplace
            return existing
        }
        let fc = FindReplaceController(text: { [weak self] in self?.textView?.string ?? "" })
        fc.isReplaceShown = showReplace
        fc.onApplyEmphases = { [weak self, weak fc] in self?.refreshFindEmphases(fc) }
        fc.onScrollToActive = { [weak self, weak fc] in
            guard let self, let fc, !fc.matches.isEmpty else { return }
            self.scrollRangeToVisible(fc.matches[fc.activeIndex])
        }
        fc.onReplace = { [weak self] range, str in
            self?.performReplace(range, with: str)
        }
        fc.onBeginUndoGroup = { [weak self] in self?.beginReplaceAllUndoGroup() }
        fc.onEndUndoGroup   = { [weak self] in self?.endReplaceAllUndoGroup() }
        self.currentFindController = fc
        // Spec §3.2: suppress sameword emphasis while find is open
        clearEmphases(group: "sameword")
        return fc
    }

    func dismissFindController() {
        clearEmphases(group: "find")
        clearEmphases(group: "find.active")
        currentFindController = nil
        // Spec §3.2: resume sameword emphasis when find closes
        if let active = textView?.selectionManager.textSelections.first?.range {
            scheduleSameWordRefresh(selection: active)
        }
    }

    private func refreshFindEmphases(_ fc: FindReplaceController?) {
        guard let fc else { return }
        clearEmphases(group: "find")
        clearEmphases(group: "find.active")
        guard !fc.matches.isEmpty else { return }
        // 防御性裁剪：若文本在 search 与本次绘制之间又被改短，越界 range 喂给
        // EmphasisManager（内部走 attributedSubstring / rangeOfComposedCharacterSequence）
        // 会抛 NSRangeException 直接崩。upperBound 超出文本长度的 range 一律跳过。
        let textLength = textView?.textStorage?.length ?? 0
        let validMatches = fc.matches.filter { $0.location >= 0 && NSMaxRange($0) <= textLength }
        guard !validMatches.isEmpty else { return }
        // Non-active matches
        applyEmphases(validMatches, group: "find",
                      style: .standard, active: nil)
        // Active match (outline + fill)
        // findMatchBorder = #F38518 from EditorTheme (Track A); inline here so Track B compiles standalone
        let findMatchBorderColor = NSColor(red: 0xF3/255, green: 0x85/255, blue: 0x18/255, alpha: 1)
        let active = fc.matches.indices.contains(fc.activeIndex) ? fc.matches[fc.activeIndex] : nil
        if let active, active.location >= 0, NSMaxRange(active) <= textLength {
            applyEmphases([active], group: "find.active",
                          style: .outline(color: findMatchBorderColor, fill: true),
                          active: 0)
        }
    }
}

// MARK: - SameWord emphasis (PR-final)
extension CodeEditorController {

    private func scheduleSameWordRefresh(selection: NSRange) {
        sameWordDebounce?.cancel()
        // Find toolbar open → suppress; spec §3.2.
        if currentFindController != nil {
            clearEmphases(group: "sameword")
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let text = self.textView?.string else { return }
                guard let word = SameWordEmphasis.targetWord(in: text, selection: selection) else {
                    self.clearEmphases(group: "sameword")
                    return
                }
                let matches = SameWordEmphasis.matches(of: word, in: text)
                // Don't outline the selection itself.
                let filtered = matches.filter { $0 != selection }
                self.applyEmphases(filtered, group: "sameword",
                                   style: .outline(color: EditorTheme.sameWordOutline, fill: false),
                                   active: nil)
            }
        }
        sameWordDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
    }
}

// MARK: - Line number gutter helpers
extension CodeEditorController {

    /// 把字符 offset 解析为 0-based 行号。失败返回 nil。
    fileprivate func lineIndex(ofOffset offset: Int) -> Int? {
        textView?.layoutManager.textLineForOffset(offset)?.index
    }

    /// 用当前 scrollView 可视带 + 给定活动行号刷一次 gutter。
    fileprivate func updateGutter(activeLineIndex: Int?) {
        guard let gutter = lineNumberGutter, let scrollView else { return }
        gutter.update(visibleRect: scrollView.documentVisibleRect,
                      activeLineIndex: activeLineIndex)
    }

    /// 用当前 scrollView 可视带刷新缩进指示线。
    fileprivate func updateIndentGuides(activeLineIndex: Int?) {
        guard let scrollView else { return }
        indentGuideOverlay?.update(visibleRect: scrollView.documentVisibleRect,
                                   activeLineIndex: activeLineIndex)
    }
}
