import Foundation
import AppKit

/// NSRegularExpression 实例只在该 actor 内访问，避免 fallback 语言的全文 regex 扫描
/// 占用 MainActor。
private actor PatternHighlightWorker {
    private let rules: [(NSRegularExpression, String)]

    init(language: String) {
        rules = Self.makeRules(language: language)
    }

    func highlights(in text: String) -> [SyntaxHighlightToken] {
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        return rules.flatMap { regex, captureName in
            regex.matches(in: text, range: fullRange).map {
                SyntaxHighlightToken(range: $0.range, captureName: captureName)
            }
        }
    }

    private static func makeRules(language: String) -> [(NSRegularExpression, String)] {
        var rules: [(String, String)] = [
            (#"\b\d+(?:\.\d+)?\b"#, "number"),
            (#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#, "string")
        ]

        let keywords = keywordPattern(for: language)
        if !keywords.isEmpty {
            rules.insert((keywords, "keyword"), at: 0)
        }
        rules.append((#"(?m)(#|//|;).*$"#, "comment"))

        return rules.compactMap { pattern, captureName in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, captureName)
        }
    }

    private static func keywordPattern(for language: String) -> String {
        let common = [
            "if", "else", "for", "while", "do", "return", "switch", "case",
            "default", "break", "continue", "true", "false", "null", "nil"
        ]
        let languageKeywords: [String]
        switch language {
        case "nginx":
            languageKeywords = [
                "server", "location", "listen", "root", "index", "proxy_pass",
                "upstream", "include", "rewrite", "return", "ssl", "http"
            ]
        case "dockerfile":
            languageKeywords = [
                "FROM", "RUN", "COPY", "ADD", "CMD", "ENTRYPOINT", "ENV", "ARG",
                "WORKDIR", "EXPOSE", "USER", "VOLUME", "LABEL", "ONBUILD"
            ]
        case "makefile":
            languageKeywords = [
                "include", "define", "endef", "override", "export", "unexport",
                "private", "vpath", "ifeq", "ifneq", "ifdef", "ifndef", "else", "endif"
            ]
        default:
            languageKeywords = common
        }

        let words = Array(Set(common + languageKeywords)).sorted()
        guard !words.isEmpty else { return "" }
        let alternation = words.map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        return #"(?<![A-Za-z0-9_])("# + alternation + #")(?![A-Za-z0-9_])"#
    }
}

/// Lightweight fallback for code-like files without a registered tree-sitter grammar.
@MainActor
final class PatternSyntaxHighlighter: SyntaxHighlighter {
    private let worker: PatternHighlightWorker
    private var highlightTask: Task<Void, Never>?
    private var generation = 0
    private let debounceMs: Int

    init(language: String, debounceMs: Int = 80) {
        self.debounceMs = debounceMs
        worker = PatternHighlightWorker(language: language)
    }

    func initialHighlight(text: String, apply: @escaping ([(NSRange, NSColor)]) -> Void) {
        schedule(text: text, delay: false, apply: apply)
    }

    func didEdit(range: NSRange, replacement: String, fullText: String,
                 apply: @escaping ([(NSRange, NSColor)]) -> Void) {
        schedule(text: fullText, delay: true, apply: apply)
    }

    func dispose() {
        generation &+= 1
        highlightTask?.cancel()
        highlightTask = nil
    }

    private func schedule(text: String, delay: Bool,
                          apply: @escaping ([(NSRange, NSColor)]) -> Void) {
        generation &+= 1
        let requestedGeneration = generation
        highlightTask?.cancel()
        highlightTask = Task { [weak self, worker, debounceMs] in
            if delay, debounceMs > 0 {
                do {
                    try await Task.sleep(for: .milliseconds(debounceMs))
                } catch {
                    return
                }
            }
            let tokens = await worker.highlights(in: text)
            guard !Task.isCancelled,
                  let self,
                  self.generation == requestedGeneration else { return }
            apply(tokens.map { ($0.range, EditorTheme.color(for: $0.captureName)) })
        }
    }
}
