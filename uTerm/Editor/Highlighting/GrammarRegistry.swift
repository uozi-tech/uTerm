// uTerm/Editor/Highlighting/GrammarRegistry.swift
import Foundation
import AppKit
import SwiftTreeSitter
import TreeSitterGo
import TreeSitterTypeScript
import TreeSitterJSON
import TreeSitterBash
import TreeSitterMarkdown
import TreeSitterSwift
import TreeSitterPython
import TreeSitterJavaScript
import TreeSitterYAML

/// language id（如 "go" / "swift"）→ 已注册 grammar 句柄。
///
/// 全部 9 门：
/// - 外部 SPM：swift（alex-pinkus/with-generated-files 分支）/ go / typescript /
///   json / bash / markdown
/// - 内部 vendor（`vendor/tree-sitter-grammars/`）：python / javascript / yaml
///   —— 因上游 Package.swift 用 `FileManager.fileExists` 条件加 scanner.c
///   在 SPM manifest eval 不可靠，vendor 化后自写硬编码 sources 一次性绕开。
@MainActor
enum GrammarRegistry {

    struct Entry {
        let language: Language
        let highlightsQueryText: String
    }

    static func entry(for language: String) -> Entry? {
        switch language {
        case "swift":
            let grammar = Language(language: tree_sitter_swift())
            return Entry(language: grammar,
                         highlightsQueryText: loadQuery(named: "swift", language: grammar))
        case "go":
            let grammar = Language(language: tree_sitter_go())
            return Entry(language: grammar,
                         highlightsQueryText: loadQuery(named: "go", language: grammar))

        case "typescript":
            let grammar = Language(language: tree_sitter_typescript())
            return Entry(language: grammar,
                         highlightsQueryText: loadQuery(named: "typescript", language: grammar))
        case "json":
            let grammar = Language(language: tree_sitter_json())
            return Entry(language: grammar,
                         highlightsQueryText: loadQuery(named: "json", language: grammar))
        case "bash":
            let grammar = Language(language: tree_sitter_bash())
            return Entry(language: grammar,
                         highlightsQueryText: loadQuery(named: "bash", language: grammar))
        case "markdown":
            let grammar = Language(language: tree_sitter_markdown())
            return Entry(language: grammar,
                         highlightsQueryText: loadQuery(named: "markdown", language: grammar))
        case "python":
            let grammar = Language(language: tree_sitter_python())
            return Entry(language: grammar,
                         highlightsQueryText: loadQuery(named: "python", language: grammar))
        case "javascript":
            let grammar = Language(language: tree_sitter_javascript())
            return Entry(language: grammar,
                         highlightsQueryText: loadQuery(named: "javascript", language: grammar))
        case "yaml":
            let grammar = Language(language: tree_sitter_yaml())
            return Entry(language: grammar,
                         highlightsQueryText: loadQuery(named: "yaml", language: grammar))
        default:
            return nil
        }
    }

    /// 加载 highlights query 文本。优先用 grammar 包自带的 highlights.scm；
    /// 找不到走内置 fallback（仅 keyword/string/number/comment 四色）。
    private static func loadQuery(named language: String, language grammar: Language) -> String {
        // Grammar SPM packages ship queries as bundle resources.
        // The bundle resource path depends on SPM layout; try common patterns.
        let baseBundleName = bundleBaseNames[language] ?? "TreeSitter\(language.capitalized)"
        let bundleNames = [
            "\(baseBundleName)_\(baseBundleName)",
            baseBundleName
        ]
        for bundleName in bundleNames {
            if let bundleURL = Bundle.main.url(forResource: bundleName, withExtension: "bundle"),
               let bundle = Bundle(url: bundleURL),
               let url = bundle.url(forResource: "highlights", withExtension: "scm", subdirectory: "queries"),
               let text = try? String(contentsOf: url, encoding: .utf8),
               canUseQuery(text, language: grammar, sample: sampleSnippets[language] ?? "") {
                return text
            }
        }
        if let fallback = fallbackQueries[language],
           canUseQuery(fallback, language: grammar, sample: sampleSnippets[language] ?? "") {
            return fallback
        }
        return ""
    }

    private static func canUseQuery(_ text: String, language: Language, sample: String) -> Bool {
        guard !text.isEmpty,
              !sample.isEmpty,
              let data = text.data(using: .utf8),
              let query = try? Query(language: language, data: data) else {
            return false
        }

        let parser = Parser()
        do {
            try parser.setLanguage(language)
        } catch {
            return false
        }
        guard let tree = parser.parse(sample), let root = tree.rootNode else { return false }
        let cursor = query.execute(node: root, in: tree)
        while let match = cursor.next() {
            if match.captures.contains(where: { capture in
                let range = capture.node.range
                return range.location != NSNotFound && range.length > 0
            }) {
                return true
            }
        }
        return false
    }

    private static let bundleBaseNames: [String: String] = [
        "swift": "TreeSitterSwift",
        "go": "TreeSitterGo",
        "typescript": "TreeSitterTypeScript",
        "json": "TreeSitterJSON",
        "bash": "TreeSitterBash",
        "markdown": "TreeSitterMarkdown"
    ]

    private static let sampleSnippets: [String: String] = [
        "swift": "func main() { return }",
        "go": "func main() { return }",
        "typescript": "function main() { return 1 }",
        "json": #"{"value": 1}"#,
        "bash": "if true; then echo \"ok\"; fi",
        "markdown": "# Title\n`code`",
        "python": "def main():\n    return 1",
        "javascript": "function main() { return 1 }",
        "yaml": "key: value"
    ]

    // Minimal four-color fallback queries for each language.
    // These cover the most visible tokens without needing the full grammar query file.
    private static let fallbackQueries: [String: String] = [
        "swift": """
            (line_comment) @comment
            (multiline_comment) @comment
            ["let" "var" "func" "if" "else" "guard" "return" "import" "class"
             "struct" "enum" "protocol" "extension" "init" "deinit" "self"
             "Self" "super" "for" "in" "while" "do" "catch" "throw" "throws"
             "rethrows" "try" "as" "is" "where" "switch" "case" "default"
             "break" "continue" "fallthrough" "static" "public" "private"
             "internal" "fileprivate" "open" "final" "lazy" "weak" "unowned"
             "mutating" "nonmutating" "convenience" "required" "override"
             "associatedtype" "typealias" "inout" "indirect" "nil" "true" "false"
             "async" "await" "actor" "isolated" "nonisolated" "any" "some"] @keyword
            (integer_literal) @number
            (real_literal) @number
            (line_string_literal) @string
            (raw_string_literal) @string
            (multi_line_string_literal) @string
            """,
        "go": """
            (comment) @comment
            ["func" "var" "const" "return" "if" "else" "for" "range" "import"
             "package" "type" "struct" "interface" "map" "chan" "go" "defer"
             "select" "case" "default" "break" "continue" "goto" "fallthrough"
             "switch"] @keyword
            [(true) (false) (nil)] @constant
            (int_literal) @number
            (float_literal) @number
            (interpreted_string_literal) @string
            (raw_string_literal) @string
            """,
        "typescript": """
            (comment) @comment
            (template_string) @string
            ["function" "const" "let" "var" "if" "else" "return" "import"
             "export" "from" "class" "new" "this" "super" "for" "while" "do"
             "break" "continue" "switch" "case" "default" "typeof" "instanceof"
             "in" "of" "delete" "void" "throw" "try" "catch" "finally" "async"
             "await" "yield" "null" "undefined" "true" "false"
             "type" "interface" "enum" "namespace" "module" "declare" "abstract"
             "implements" "extends" "readonly" "keyof" "infer" "is" "as" "any"
             "unknown" "never" "object"] @keyword
            (number) @number
            (string) @string
            """,
        "json": """
            (number) @number
            (string) @string
            ["true" "false" "null"] @keyword
            """,
        "python": """
            (comment) @comment
            ["def" "class" "if" "else" "elif" "return" "import" "from" "as"
             "for" "while" "break" "continue" "pass" "in" "is" "not" "and"
             "or" "try" "except" "finally" "raise" "with" "yield" "async"
             "await" "lambda" "global" "nonlocal" "del" "assert" "None"
             "True" "False" "match" "case"] @keyword
            (integer) @number
            (float) @number
            (string) @string
            """,
        "javascript": """
            (comment) @comment
            (template_string) @string
            ["function" "const" "let" "var" "if" "else" "return" "import"
             "export" "from" "class" "new" "this" "super" "for" "while" "do"
             "break" "continue" "switch" "case" "default" "typeof" "instanceof"
             "in" "of" "delete" "void" "throw" "try" "catch" "finally" "async"
             "await" "yield" "null" "undefined" "true" "false"] @keyword
            (number) @number
            (string) @string
            """,
        "yaml": """
            (comment) @comment
            (block_mapping_pair key: (_) @keyword)
            (flow_mapping (_ key: (_) @keyword))
            ((plain_scalar) @number (#match? @number "^-?[0-9]+(\\\\.[0-9]+)?$"))
            ((plain_scalar) @keyword (#match? @keyword "^(true|false|null|~|yes|no|on|off)$"))
            (single_quote_scalar) @string
            (double_quote_scalar) @string
            (block_scalar) @string
            """,
        "toml": """
            (comment) @comment
            (bare_key) @property
            (quoted_key) @property
            (table ("[" @punctuation "]" @punctuation))
            (table_array_element ("[[" @punctuation "]]" @punctuation))
            (string) @string
            (integer) @number
            (float) @number
            (boolean) @keyword
            (offset_date_time) @number
            (local_date_time) @number
            (local_date) @number
            (local_time) @number
            """,
        "ini": """
            (comment) @comment
            (section_name) @keyword
            (setting_name) @property
            (setting_value) @string
            """,
        "bash": """
            (comment) @comment
            ["if" "then" "else" "elif" "fi" "for" "while" "do" "done"
             "case" "esac" "in" "function" "return" "local" "export"
             "source" "." "true" "false" "exit"] @keyword
            (string) @string
            (raw_string) @string
            (number) @number
            """,
        "markdown": """
            (atx_heading) @keyword
            (setext_heading) @keyword
            (code_span) @string
            (fenced_code_block) @string
            (link_title) @string
            (link_destination) @string
            """,
    ]
}
