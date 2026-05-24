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

/// language id（如 "go" / "swift"）→ 已注册 grammar 句柄。
/// 6 个 grammar SPM 包验证可用（swift/go/ts/json/bash/markdown）。
/// swift grammar 用 alex-pinkus/tree-sitter-swift 的 `with-generated-files` 分支
/// （main 分支没 ship 生成的 parser.c）。
/// Excluded (broken SPM packages — FileManager.default.fileExists 在 Package.swift
/// manifest evaluation 不可靠，scanner.c 未编译进而 linker error):
/// tree-sitter-python, tree-sitter-javascript, tree-sitter-yaml.
@MainActor
enum GrammarRegistry {

    struct Entry {
        let language: Language
        let highlightsQueryText: String
    }

    static func entry(for language: String) -> Entry? {
        switch language {
        case "swift":
            return Entry(language: Language(language: tree_sitter_swift()),
                         highlightsQueryText: loadQuery(named: "swift"))
        case "go":
            return Entry(language: Language(language: tree_sitter_go()),
                         highlightsQueryText: loadQuery(named: "go"))

        case "typescript":
            return Entry(language: Language(language: tree_sitter_typescript()),
                         highlightsQueryText: loadQuery(named: "typescript"))
        case "json":
            return Entry(language: Language(language: tree_sitter_json()),
                         highlightsQueryText: loadQuery(named: "json"))
        case "bash":
            return Entry(language: Language(language: tree_sitter_bash()),
                         highlightsQueryText: loadQuery(named: "bash"))
        case "markdown":
            return Entry(language: Language(language: tree_sitter_markdown()),
                         highlightsQueryText: loadQuery(named: "markdown"))
        default:
            return nil
        }
    }

    /// 加载 highlights query 文本。优先用 grammar 包自带的 highlights.scm；
    /// 找不到走内置 fallback（仅 keyword/string/number/comment 四色）。
    private static func loadQuery(named language: String) -> String {
        // Grammar SPM packages ship queries as bundle resources.
        // The bundle resource path depends on SPM layout; try common patterns.
        let bundleName = "TreeSitter\(language.capitalized)"
        if let bundleURL = Bundle.main.url(forResource: bundleName, withExtension: "bundle"),
           let bundle = Bundle(url: bundleURL),
           let url = bundle.url(forResource: "highlights", withExtension: "scm", subdirectory: "queries"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return fallbackQueries[language] ?? ""
    }

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
             "switch" "make" "new" "nil" "true" "false"] @keyword
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
