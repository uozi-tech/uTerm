// uTerm/Editor/Highlighting/TreeSitterHighlighter.swift
import Foundation
import AppKit
import SwiftTreeSitter

/// 用 SwiftTreeSitter parse + query → 高亮指令列表。
/// 增量 edit 用 Tree.edit + reparse；debounce 80ms。
///
/// API 适配 SwiftTreeSitter 0.10.x:
///   - Query 通过 Query(language:data:) 构造（无 language.query(source:) 方法）
///   - node.range 返回 NSRange（已是 UTF-16 单位，parser 用 UTF-16LE 编码）
///   - InputEdit.startByte = NSRange.location * 2（UTF-16LE: 每个 code unit 2 bytes）
///   - capture.name 是 String?（nameComponents.joined(separator: ".")）
@MainActor
final class TreeSitterHighlighter: SyntaxHighlighter {

    private let language: Language
    private let query: Query?
    private let parser: Parser
    private var tree: MutableTree?
    private var debounceWorkItem: DispatchWorkItem?

    /// `debounceMs == 0` → 同步触发，仅供单测。
    let debounceMs: Int

    init(language: Language, highlightsQueryText: String, debounceMs: Int = 80) {
        self.language = language
        self.parser = Parser()
        try? self.parser.setLanguage(language)
        self.debounceMs = debounceMs
        if let data = highlightsQueryText.data(using: .utf8), !highlightsQueryText.isEmpty {
            self.query = try? Query(language: language, data: data)
        } else {
            self.query = nil
        }
    }

    func initialHighlight(text: String, apply: @escaping ([(NSRange, NSColor)]) -> Void) {
        guard let tree = parser.parse(text) else { return }
        self.tree = tree
        apply(captureColors(in: tree, source: text))
    }

    func didEdit(range: NSRange, replacement: String, fullText: String,
                 apply: @escaping ([(NSRange, NSColor)]) -> Void) {
        guard let tree else {
            initialHighlight(text: fullText, apply: apply)
            return
        }
        // SwiftTreeSitter 0.10.x uses UTF-16LE encoding (2 bytes per UTF-16 code unit).
        // NSRange.location is in UTF-16 units, so byte offsets = location * 2.
        let oldLength = range.length
        let newLength = (replacement as NSString).length
        let edit = InputEdit(
            startByte: range.location * 2,
            oldEndByte: (range.location + oldLength) * 2,
            newEndByte: (range.location + newLength) * 2,
            startPoint: .zero,
            oldEndPoint: .zero,
            newEndPoint: .zero
        )
        tree.edit(edit)
        scheduleReparse(fullText: fullText, apply: apply)
    }

    func dispose() {
        debounceWorkItem?.cancel()
        tree = nil
    }

    private func scheduleReparse(fullText: String, apply: @escaping ([(NSRange, NSColor)]) -> Void) {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let newTree = self.parser.parse(tree: self.tree, string: fullText)
            self.tree = newTree
            if let newTree {
                apply(self.captureColors(in: newTree, source: fullText))
            }
        }
        debounceWorkItem = work
        if debounceMs == 0 {
            work.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(debounceMs), execute: work)
        }
    }

    /// Run the highlights query and map each capture to (NSRange, NSColor).
    /// node.range is already in UTF-16 units (the parser is configured for UTF-16LE).
    private func captureColors(in tree: MutableTree, source: String) -> [(NSRange, NSColor)] {
        guard let query, let root = tree.rootNode else { return [] }
        let cursor = query.execute(node: root, in: tree)
        var results: [(NSRange, NSColor)] = []
        while let match = cursor.next() {
            for capture in match.captures {
                let nsRange = capture.node.range
                guard nsRange.location != NSNotFound, nsRange.length > 0 else { continue }
                let color = EditorTheme.color(for: capture.name ?? "")
                results.append((nsRange, color))
            }
        }
        return results
    }
}
