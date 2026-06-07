// uTerm/Editor/Highlighting/SyntaxHighlighter.swift
import Foundation
import AppKit

/// 把源码 → `[(NSRange, NSColor)]` 高亮指令。Track C 实现 tree-sitter 版；
/// 未注册语言走 NoopHighlighter（零开销）。
@MainActor
protocol SyntaxHighlighter: AnyObject {
    /// 文件首次打开时调用，全文 parse。
    func initialHighlight(text: String, apply: @escaping ([(NSRange, NSColor)]) -> Void)

    /// 编辑事件：增量 edit + debounce 后 reparse。
    func didEdit(range: NSRange, replacement: String, fullText: String,
                 apply: @escaping ([(NSRange, NSColor)]) -> Void)

    /// buffer dispose 时清理 parser / tree。
    func dispose()
}
