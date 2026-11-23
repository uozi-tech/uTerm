import SwiftUI

/// 搜索命中的前后文画成一段文字：命中的字加粗、着色。两端共用（颜色由平台给）。是记录里的原文，不进文案目录。
enum AgentHistorySnippetText {
    static func attributed(_ snippet: AgentHistorySnippet, match color: Color) -> AttributedString {
        var match = AttributedString(snippet.match)
        match.inlinePresentationIntent = .stronglyEmphasized
        match.foregroundColor = color
        return AttributedString(snippet.before) + match + AttributedString(snippet.after)
    }
}
