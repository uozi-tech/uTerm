// uTerm/Editor/Find/FindMatcher.swift
import Foundation

/// 纯函数匹配。返回 NSRange 列表（UTF-16 单位，与 NSTextStorage 一致）。
/// nonisolated: 所有方法只用 Foundation，不碰 UI；可从任何 isolation 调用。
nonisolated enum FindMatcher {

    struct Options: Equatable {
        let caseSensitive: Bool
        let regex: Bool
        let wholeWord: Bool
    }

    enum FindError: Error {
        case invalidRegex(String)
    }

    static func find(in text: String, query: String, options: Options) throws -> [NSRange] {
        guard !query.isEmpty else { return [] }

        if options.regex {
            return try findRegex(in: text, pattern: query, options: options)
        }
        return findLiteral(in: text, needle: query, options: options)
    }

    private static func findLiteral(in text: String, needle: String, options: Options) -> [NSRange] {
        let ns = text as NSString
        var results: [NSRange] = []
        var searchRange = NSRange(location: 0, length: ns.length)
        let opts: NSString.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive]

        while searchRange.location < ns.length {
            let found = ns.range(of: needle, options: opts, range: searchRange)
            guard found.location != NSNotFound else { break }
            if !options.wholeWord || isWholeWord(in: ns, range: found) {
                results.append(found)
            }
            let next = found.location + max(found.length, 1)
            searchRange = NSRange(location: next, length: ns.length - next)
        }
        return results
    }

    private static func findRegex(in text: String, pattern: String, options: Options) throws -> [NSRange] {
        var regexOptions: NSRegularExpression.Options = []
        if !options.caseSensitive { regexOptions.insert(.caseInsensitive) }
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: regexOptions)
        } catch {
            throw FindError.invalidRegex(error.localizedDescription)
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { m in
            guard m.range.length > 0 else { return nil }
            if options.wholeWord, !isWholeWord(in: ns, range: m.range) { return nil }
            return m.range
        }
    }

    private static func isWholeWord(in ns: NSString, range: NSRange) -> Bool {
        let before = range.location - 1
        let after = range.location + range.length
        let isBoundary: (Int) -> Bool = { idx in
            if idx < 0 || idx >= ns.length { return true }
            let c = ns.character(at: idx)
            guard let scalar = Unicode.Scalar(c) else { return true }
            return !CharacterSet.alphanumerics.contains(scalar) && scalar != "_"
        }
        return isBoundary(before) && isBoundary(after)
    }

    // MARK: - Replacement

    /// 把一个匹配范围算出实际写入的替换文本。
    /// - literal 模式：直接返回 `template`（按字面写入，`$1` 不展开）。
    /// - regex 模式：用 `NSRegularExpression` 的 template 替换，`$1`/`$0` 等捕获组展开。
    ///
    /// regex 模式下需要重跑一次正则去定位 `range` 对应的 `NSTextCheckingResult`
    /// —— 因为 capture-group 展开必须拿到那一次匹配的子组。无法定位（理论上不该
    /// 发生：调用方传的 range 来自 `find`）或正则非法时，退回字面 template，绝不抛。
    static func replacement(for range: NSRange,
                            in text: String,
                            query: String,
                            template: String,
                            options: Options) -> String {
        guard options.regex else { return template }
        var regexOptions: NSRegularExpression.Options = []
        if !options.caseSensitive { regexOptions.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: query, options: regexOptions) else {
            return template
        }
        let ns = text as NSString
        let searchRange = NSRange(location: 0, length: ns.length)
        // 在全文里重跑一遍，按 range 精确定位那一次匹配 —— 不能用 firstMatch(in:range:)
        // 限制到子范围搜，否则带 ^ / \b / lookaround 的模式在子范围里会错配或不配。
        guard let match = regex.matches(in: text, range: searchRange).first(where: { $0.range == range })
        else { return template }
        return regex.replacementString(for: match, in: text, offset: 0, template: template)
    }
}
