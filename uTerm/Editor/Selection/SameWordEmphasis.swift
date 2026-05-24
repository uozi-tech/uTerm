// uTerm/Editor/Selection/SameWordEmphasis.swift
import Foundation

/// 选中 word 后，在文档内所有同名 token 加细描边（VSCode selectionHighlight）。
/// 纯函数，nonisolated 让非 MainActor 单测可以直接调用（与 FindMatcher 一致）。
nonisolated enum SameWordEmphasis {

    /// 决定选中是否触发：长度 ≥ 2、不跨行、全部是标识符字符。
    static func targetWord(in text: String, selection: NSRange) -> String? {
        guard selection.length >= 2 else { return nil }
        let ns = text as NSString
        guard selection.location + selection.length <= ns.length else { return nil }
        let slice = ns.substring(with: selection)
        if slice.contains("\n") || slice.contains("\r") { return nil }
        for scalar in slice.unicodeScalars {
            let isIdent = CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
            if !isIdent { return nil }
        }
        return slice
    }

    /// 用 FindMatcher 的"全词 + 大小写敏感 + 字面量"模式查同名 token。
    static func matches(of word: String, in text: String) -> [NSRange] {
        (try? FindMatcher.find(in: text, query: word,
                               options: .init(caseSensitive: true, regex: false, wholeWord: true))) ?? []
    }
}
