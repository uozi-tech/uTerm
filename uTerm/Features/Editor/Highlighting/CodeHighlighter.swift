// uTerm/Editor/Highlighting/CodeHighlighter.swift
import Foundation
import AppKit
import SwiftTreeSitter

/// 把一段代码同步高亮成 AttributedString（聊天代码块用，一次性、不增量）。
/// 复用 GrammarRegistry 的 grammar/query + EditorTheme 的 capture→色映射。
/// 未注册语言 / 解析失败 → 返回纯等宽文本（无色）。
///
/// 结果按（语言, 代码）缓存、查询按语言编译一次：`ChatCodeBlock` 在 body 里调用，
/// 聊天列表每次重排都会重求已落定代码块的 body。
@MainActor
enum CodeHighlighter {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private static var queries: [String: Query] = [:]
    private static let results: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 128
        return cache
    }()

    static func attributed(code: String, language: String?) -> AttributedString {
        let key = "\(language ?? "")\u{0}\(code)" as NSString
        if let cached = results.object(forKey: key) { return AttributedString(cached) }
        let highlighted = highlight(code: code, language: language)
        results.setObject(highlighted, forKey: key)
        return AttributedString(highlighted)
    }

    private static func highlight(code: String, language: String?) -> NSAttributedString {
        let base = NSMutableAttributedString(
            string: code,
            attributes: [.font: font, .foregroundColor: EditorTheme.foreground])

        guard let language,
              let entry = GrammarRegistry.entry(for: language),
              let query = query(for: language, entry: entry) else {
            return base
        }

        let parser = Parser()
        try? parser.setLanguage(entry.language)
        guard let tree = parser.parse(code), let root = tree.rootNode else { return base }

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
        return base
    }

    private static func query(for language: String, entry: GrammarRegistry.Entry) -> Query? {
        if let cached = queries[language] { return cached }
        guard !entry.highlightsQueryText.isEmpty,
              let data = entry.highlightsQueryText.data(using: .utf8),
              let query = try? Query(language: entry.language, data: data) else { return nil }
        queries[language] = query
        return query
    }
}
