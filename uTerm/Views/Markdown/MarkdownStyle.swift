// uTerm/Views/Markdown/MarkdownStyle.swift
import SwiftUI

/// Markdown 渲染的主题 token —— 颜色 + 字号 + 间距。
/// 两个预设：`.preview`（文件预览，AppTheme 跟随系统外观）/ `.chat`（工作区 WS 固定暗色）。
struct MarkdownStyle {
    var textPrimary: Color
    var textSecondary: Color
    var textMuted: Color
    var accent: Color
    var border: Color
    var bgRaised: Color
    var inlineCodeBackground: Color
    var baseFontSize: CGFloat
    var blockSpacing: CGFloat
    /// 聊天皮肤用 ChatCodeBlock（高亮 + 复制）；预览皮肤用纯等宽块。
    var usesChatCodeBlock: Bool

    static let preview = MarkdownStyle(
        textPrimary: AppTheme.Palette.textPrimary,
        textSecondary: AppTheme.Palette.textSecondary,
        textMuted: AppTheme.Palette.textMuted,
        accent: AppTheme.Palette.accent,
        border: AppTheme.Palette.border,
        bgRaised: AppTheme.Palette.bgRaised,
        inlineCodeBackground: AppTheme.Palette.bgRaised,
        baseFontSize: 13,
        blockSpacing: 10,
        usesChatCodeBlock: false)

    static let chat = MarkdownStyle(
        textPrimary: WS.text,
        textSecondary: WS.text2,
        textMuted: WS.text3,
        accent: WS.accent,
        border: WS.border,
        bgRaised: WS.panelHi,
        inlineCodeBackground: WS.panelHi,
        baseFontSize: 12.5,
        blockSpacing: 8,
        usesChatCodeBlock: true)
}
