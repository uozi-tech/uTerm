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

    // MARK: Find/Replace（Track B）
    var currentFindController: FindReplaceController?
    /// Local key event monitor installed in makeNSView; removed on deinit。
    /// nonisolated(unsafe) 让 deinit 能读 token 调 NSEvent.removeMonitor。
    nonisolated(unsafe) var keyEventMonitor: Any?

    // MARK: Track C — 语法高亮
    private var highlighter: SyntaxHighlighter = NoopHighlighter()

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
        storage.beginEditing()
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.foregroundColor, range: fullRange)
        storage.addAttribute(.foregroundColor,
                             value: EditorTheme.foreground,
                             range: fullRange)
        for (range, color) in pairs where NSMaxRange(range) <= storage.length {
            storage.addAttribute(.foregroundColor, value: color, range: range)
        }
        storage.endEditing()
        textView.layoutManager.invalidateLayoutForRange(fullRange)
        textView.needsLayout = true
        textView.needsDisplay = true
    }

    func clearHighlights(in range: NSRange?) {
        guard let textView, let storage = textView.textStorage else { return }
        let target = range ?? NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.foregroundColor, range: target)
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
                self?.updateGutter(activeLineIndex: self?.lastActiveLineIndex)
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
                self?.refreshGutter(bootstrap: false)
            }
        }

        // 订阅文本变化：行数可能变 → 重算宽度（若变了刷正文 edgeInsets）+ 刷行号
        textDidChangeObserver = NotificationCenter.default.addObserver(
            forName: TextView.textDidChangeNotification,
            object: textView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // refreshGutter 一站包：重挂检查 + 宽度 + edgeInsets + 行号
                self?.refreshGutter(bootstrap: false)
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

        // Track C · 文本变化时增量重高亮。包裹既有 onTextChange，避免覆盖订阅者。
        let existingOnTextChange = onTextChange
        onTextChange = { [weak self] range, str in
            existingOnTextChange?(range, str)
            guard let self else { return }
            let full = self.textView?.string ?? ""
            self.highlighter.didEdit(range: range, replacement: str, fullText: full) { [weak self] pairs in
                self?.applyHighlights(pairs)
            }
        }
    }

    func textView(_ textView: TextView,
                  didReplaceContentsIn range: NSRange,
                  with string: String) {
        guard !_isUpdatingFromBinding else { return }
        let newText = textView.string
        buffer?.text = newText
        buffer?.isDirty = true
        onTextChange?(range, string)
    }
}

// MARK: - Find/Replace key handling (Track B)
extension CodeEditorController {

    func handleKeyEvent(_ event: NSEvent,
                        openFind: (_ showReplace: Bool) -> Void,
                        closeFind: () -> Void) -> Bool {
        guard event.type == .keyDown else { return false }
        let cmd   = event.modifierFlags.contains(.command)
        let opt   = event.modifierFlags.contains(.option)
        let shift = event.modifierFlags.contains(.shift)
        let chars = event.charactersIgnoringModifiers ?? ""

        switch (cmd, opt, shift, chars) {
        case (true, false, _, "f"):
            openFind(false); return true
        case (true, true, _, "f"):
            openFind(true); return true
        case (true, false, false, "g"):
            currentFindController?.next(); return true
        case (true, false, true, "g"):
            currentFindController?.previous(); return true
        default:
            // Esc handled by FindReplaceBar via .keyboardShortcut(.escape)
            return false
        }
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
        // Non-active matches
        applyEmphases(fc.matches, group: "find",
                      style: .standard, active: nil)
        // Active match (outline + fill)
        // findMatchBorder = #F38518 from EditorTheme (Track A); inline here so Track B compiles standalone
        let findMatchBorderColor = NSColor(red: 0xF3/255, green: 0x85/255, blue: 0x18/255, alpha: 1)
        applyEmphases([fc.matches[fc.activeIndex]], group: "find.active",
                      style: .outline(color: findMatchBorderColor, fill: true),
                      active: 0)
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
}
