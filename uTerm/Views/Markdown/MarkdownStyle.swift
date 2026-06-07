// uTerm/Views/Markdown/MarkdownStyle.swift
import SwiftUI

/// Markdown 渲染的主题 token —— 颜色 + 字号 + 间距。
/// 两个预设：`.preview`（文件预览）/ `.chat`（Agent 聊天），都跟随 UD 深浅色 token。
struct MarkdownStyle {
    var textPrimary: Color
    var textSecondary: Color
    var textMuted: Color
    /// 正文段落色。预览=次要色（text2，对齐设计稿预览页）；聊天=主色（text，
    /// 对齐工作区设计稿助手消息 `color: U.text` 的高对比正文）。
    var bodyColor: Color
    var accent: Color
    var border: Color
    var bgRaised: Color
    /// 块级代码背景独立于 inline code，避免聊天代码块误用固定终端黑底。
    var codeBlockBackground: Color
    var inlineCodeBackground: Color
    var baseFontSize: CGFloat
    var blockSpacing: CGFloat
    /// 段落行距。聊天稍松（≈设计稿 lineHeight 1.55 的呼吸感）。
    var lineSpacing: CGFloat
    /// 聊天皮肤用 ChatCodeBlock（高亮 + 复制）；预览皮肤用纯等宽块。
    var usesChatCodeBlock: Bool

    static let preview = MarkdownStyle(
        textPrimary: UD.text,
        textSecondary: UD.text2,
        textMuted: UD.text3,
        bodyColor: UD.text2,
        accent: UD.accent,
        border: UD.border,
        bgRaised: UD.panelHi,
        codeBlockBackground: UD.panelHi,
        inlineCodeBackground: UD.panelHi,
        baseFontSize: 13,
        blockSpacing: 10,
        lineSpacing: 0,
        usesChatCodeBlock: false)

    static let chat = MarkdownStyle(
        textPrimary: UD.text,
        textSecondary: UD.text2,
        textMuted: UD.text3,
        bodyColor: UD.text,
        accent: UD.accent,
        border: UD.border,
        bgRaised: UD.panelHi,
        codeBlockBackground: UD.panelHi,
        inlineCodeBackground: UD.panelHi,
        baseFontSize: 12.5,
        blockSpacing: 8,
        lineSpacing: 3,
        usesChatCodeBlock: true)
}
