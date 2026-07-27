import Foundation
import AppKit
import SwiftTreeSitter

/// Parser、Query 和 MutableTree 都只在此 actor 内访问。tree-sitter 的同步解析因此不再
/// 阻塞 MainActor；调用方只接收可发送的 range/capture token。
private actor TreeSitterHighlightWorker {
    private let query: Query?
    private let parser: Parser
    private var tree: MutableTree?

    init(language: Language, highlightsQueryText: String) {
        parser = Parser()
        try? parser.setLanguage(language)
        if let data = highlightsQueryText.data(using: .utf8), !highlightsQueryText.isEmpty {
            query = try? Query(language: language, data: data)
        } else {
            query = nil
        }
    }

    func initialHighlight(text: String) -> [SyntaxHighlightToken] {
        guard let parsed = parser.parse(text) else {
            tree = nil
            return []
        }
        tree = parsed
        return captures(in: parsed)
    }

    func didEdit(range: NSRange, replacement: String, fullText: String) -> [SyntaxHighlightToken] {
        guard let tree else { return initialHighlight(text: fullText) }

        // SwiftTreeSitter 使用 UTF-16LE；NSRange 也是 UTF-16 code-unit offset。
        let newLength = (replacement as NSString).length
        tree.edit(InputEdit(
            startByte: range.location * 2,
            oldEndByte: NSMaxRange(range) * 2,
            newEndByte: (range.location + newLength) * 2,
            startPoint: .zero,
            oldEndPoint: .zero,
            newEndPoint: .zero
        ))

        guard let parsed = parser.parse(tree: tree, string: fullText) else {
            self.tree = nil
            return []
        }
        self.tree = parsed
        return captures(in: parsed)
    }

    func reset() {
        tree = nil
        parser.reset()
    }

    private func captures(in tree: MutableTree) -> [SyntaxHighlightToken] {
        guard let query, let root = tree.rootNode else { return [] }
        let cursor = query.execute(node: root, in: tree)
        var results: [SyntaxHighlightToken] = []
        while let match = cursor.next() {
            for capture in match.captures {
                let range = capture.node.range
                guard range.location != NSNotFound, range.length > 0 else { continue }
                results.append(SyntaxHighlightToken(
                    range: range,
                    captureName: capture.name ?? ""
                ))
            }
        }
        return results
    }
}

/// 增量 tree-sitter 高亮。编辑事件在主线程登记，80ms 防抖后由独立 actor 解析；
/// generation 同时防止切文件或连续编辑时较旧结果覆盖新结果。
@MainActor
final class TreeSitterHighlighter: SyntaxHighlighter {
    private let worker: TreeSitterHighlightWorker
    private var highlightTask: Task<Void, Never>?
    private var generation = 0

    /// `debounceMs == 0` 仅表示跳过防抖；解析仍在 worker actor 上执行。
    let debounceMs: Int

    init(language: Language, highlightsQueryText: String, debounceMs: Int = 80) {
        worker = TreeSitterHighlightWorker(
            language: language,
            highlightsQueryText: highlightsQueryText
        )
        self.debounceMs = debounceMs
    }

    func initialHighlight(text: String, apply: @escaping ([(NSRange, NSColor)]) -> Void) {
        generation &+= 1
        let requestedGeneration = generation
        highlightTask?.cancel()
        highlightTask = Task { [weak self, worker] in
            let tokens = await worker.initialHighlight(text: text)
            guard !Task.isCancelled,
                  let self,
                  self.generation == requestedGeneration else { return }
            apply(tokens.map { ($0.range, EditorTheme.color(for: $0.captureName)) })
        }
    }

    func didEdit(range: NSRange, replacement: String, fullText: String,
                 apply: @escaping ([(NSRange, NSColor)]) -> Void) {
        generation &+= 1
        let requestedGeneration = generation
        highlightTask?.cancel()
        highlightTask = Task { [weak self, worker, debounceMs] in
            if debounceMs > 0 {
                do {
                    try await Task.sleep(for: .milliseconds(debounceMs))
                } catch {
                    return
                }
            }
            let tokens = await worker.didEdit(
                range: range,
                replacement: replacement,
                fullText: fullText
            )
            guard !Task.isCancelled,
                  let self,
                  self.generation == requestedGeneration else { return }
            apply(tokens.map { ($0.range, EditorTheme.color(for: $0.captureName)) })
        }
    }

    func dispose() {
        generation &+= 1
        highlightTask?.cancel()
        highlightTask = nil
        Task { [worker] in await worker.reset() }
    }
}
