import UDesignKit
// uTerm/Models/HighlightedText.swift
import SwiftUI

/// 命中字符高亮工具。把 source 转 AttributedString，所有匹配 query 的子串加
/// warning 背景色。query 为空 / source 为空 / 无命中时退化为无属性。
nonisolated enum HighlightedText {

    static func attributed(_ source: String, highlighting query: String) -> AttributedString {
        var result = AttributedString(source)
        guard !query.isEmpty, !source.isEmpty else { return result }

        // 大小写不敏感扫描所有命中区间。
        let lowered = source.lowercased()
        let needle = query.lowercased()
        var searchStart = lowered.startIndex
        while let range = lowered.range(of: needle, range: searchStart..<lowered.endIndex) {
            // 把 String.Range<String.Index> 映射到 AttributedString 上。
            if let attrRange = Range(range, in: result) {
                result[attrRange].backgroundColor = UD.warning.opacity(0.35)
                result[attrRange].foregroundColor = UD.warning
            }
            searchStart = range.upperBound
        }
        return result
    }
}
