// uTerm/Editor/Highlighting/NoopHighlighter.swift
import Foundation
import AppKit

/// plainText 或未注册 grammar 的语言走这个。零开销。
@MainActor
final class NoopHighlighter: SyntaxHighlighter {
    func initialHighlight(text: String, apply: @escaping ([(NSRange, NSColor)]) -> Void) {}
    func didEdit(range: NSRange, replacement: String, fullText: String,
                 apply: @escaping ([(NSRange, NSColor)]) -> Void) {}
    func dispose() {}
}
