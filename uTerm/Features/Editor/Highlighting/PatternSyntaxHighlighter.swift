import Foundation
import AppKit

/// Lightweight fallback for code-like files without a registered tree-sitter grammar.
@MainActor
final class PatternSyntaxHighlighter: SyntaxHighlighter {
    private let rules: [(NSRegularExpression, NSColor)]
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceMs: Int

    init(language: String, debounceMs: Int = 80) {
        self.debounceMs = debounceMs
        self.rules = Self.makeRules(language: language)
    }

    func initialHighlight(text: String, apply: @escaping ([(NSRange, NSColor)]) -> Void) {
        apply(highlights(in: text))
    }

    func didEdit(range: NSRange, replacement: String, fullText: String,
                 apply: @escaping ([(NSRange, NSColor)]) -> Void) {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            apply(self.highlights(in: fullText))
        }
        debounceWorkItem = work
        if debounceMs == 0 {
            work.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(debounceMs), execute: work)
        }
    }

    func dispose() {
        debounceWorkItem?.cancel()
    }

    private func highlights(in text: String) -> [(NSRange, NSColor)] {
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        return rules.flatMap { regex, color in
            regex.matches(in: text, range: fullRange).map { ($0.range, color) }
        }
    }

    private static func makeRules(language: String) -> [(NSRegularExpression, NSColor)] {
        var rules: [(String, NSColor)] = [
            (#"\b\d+(?:\.\d+)?\b"#, EditorTheme.synNumber),
            (#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#, EditorTheme.synString)
        ]

        let keywords = keywordPattern(for: language)
        if !keywords.isEmpty {
            rules.insert((keywords, EditorTheme.synKeyword), at: 0)
        }

        rules.append((#"(?m)(#|//|;).*$"#, EditorTheme.synComment))

        return rules.compactMap { pattern, color in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
            return (regex, color)
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
        let alternation = words.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return #"(?<![A-Za-z0-9_])("# + alternation + #")(?![A-Za-z0-9_])"#
    }
}
