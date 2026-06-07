// uTerm/Editor/Highlighting/CodeHighlighter.swift
import Foundation
import AppKit
import SwiftTreeSitter

/// 把一段代码同步高亮成 AttributedString（聊天代码块用，一次性、不增量）。
/// 复用 GrammarRegistry 的 grammar/query + EditorTheme 的 capture→色映射。
/// 未注册语言 / 解析失败 → 返回纯等宽文本（无色）。
@MainActor
enum CodeHighlighter {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    static func attributed(code: String, language: String?) -> AttributedString {
        let base = NSMutableAttributedString(
            string: code,
            attributes: [.font: font, .foregroundColor: EditorTheme.foreground])

        guard let language,
              let entry = GrammarRegistry.entry(for: language) else {
            return AttributedString(base)
        }

        let parser = Parser()
        try? parser.setLanguage(entry.language)
        guard let tree = parser.parse(code), let root = tree.rootNode,
              !entry.highlightsQueryText.isEmpty,
              let data = entry.highlightsQueryText.data(using: .utf8),
              let query = try? Query(language: entry.language, data: data) else {
            return AttributedString(base)
        }

        let cursor = query.execute(node: root, in: tree)
        let total = (code as NSString).length
        while let match = cursor.next() {
            for capture in match.captures {
                let r = capture.node.range
                guard r.location != NSNotFound, r.length > 0,
                      r.location + r.length <= total else { continue }
                let color = EditorTheme.color(for: capture.name ?? "")
                base.addAttribute(.foregroundColor, value: color, range: r)
            }
        }
        return AttributedString(base)
    }
}
