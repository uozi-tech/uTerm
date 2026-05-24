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
    /// Local key event monitor installed in makeNSView; removed on deinit.
    var keyEventMonitor: Any?

    // MARK: Track C — 语法高亮
    private var highlighter: SyntaxHighlighter = NoopHighlighter()

    // MARK: 外部钩子（订阅文本/选中变化）
    var onTextChange: ((NSRange, String) -> Void)?
    var onSelectionChange: ((NSRange) -> Void)?

    // MARK: Track A — 视觉
    private var activeLineOverlay: ActiveLineOverlay?
    // nonisolated(unsafe): deinit is nonisolated and needs to remove this observer
    nonisolated(unsafe) private var selectionObserver: NSObjectProtocol?

    // MARK: PR-final — sameword emphasis debounce
    private var sameWordDebounce: DispatchWorkItem?

    // MARK: 高亮（Track C 实现）
    func applyHighlights(_ pairs: [(NSRange, NSColor)]) {
        guard let textView, let storage = textView.textStorage else { return }
        storage.beginEditing()
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.foregroundColor, range: fullRange)
        storage.addAttribute(.foregroundColor,
                             value: NSColor(AppTheme.Palette.textPrimary),
                             range: fullRange)
        for (range, color) in pairs where NSMaxRange(range) <= storage.length {
            storage.addAttribute(.foregroundColor, value: color, range: range)
        }
        storage.endEditing()
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
        if let observer = selectionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

// MARK: - Coordinator role (TextViewDelegate) — added in PR-1
extension CodeEditorController: TextViewDelegate {

    var isUpdatingFromBinding: Bool {
        get { _isUpdatingFromBinding }
        set { _isUpdatingFromBinding = newValue }
    }

    func attach(textView: TextView, scrollView: NSScrollView, buffer: FileBuffer) {
        self.textView = textView
        self.scrollView = scrollView
        self.buffer = buffer

        // Track A · VSCode Dark+ 配色
        textView.selectionManager.selectionBackgroundColor = EditorTheme.selectionBg
        textView.selectionManager.insertionPointColor = EditorTheme.caret

        // Track A · 当前行高亮 overlay
        self.activeLineOverlay = ActiveLineOverlay(textView: textView)
        let initial = textView.selectionManager.textSelections.first?.range ?? NSRange(location: 0, length: 0)
        self.activeLineOverlay?.update(selection: initial)

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
                self.onSelectionChange?(range)
                self.scheduleSameWordRefresh(selection: range)
            }
        }

        // Track C · 初始化语法高亮
        let langId: String
        switch buffer.kind {
        case .code(let l): langId = l
        case .markdown:    langId = "markdown"
        case .plainText:   langId = ""
        case .image:       langId = ""
        }
        if let entry = GrammarRegistry.entry(for: langId) {
            highlighter = TreeSitterHighlighter(language: entry.language,
                                                highlightsQueryText: entry.highlightsQueryText)
        } else {
            highlighter = NoopHighlighter()
        }
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
