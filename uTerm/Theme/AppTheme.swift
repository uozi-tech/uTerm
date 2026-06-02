import SwiftUI
import AppKit

/// uTerm 的语义化色彩 token 命名空间。所有 view 必须用 token 而非硬编码颜色。
///
/// 所有 chrome color token 现在映射到 macOS 系统语义色（NSColor / SwiftUI 语义
/// Color），随系统外观（浅 / 深）、系统强调色与辅助功能设置自动变化；token 名
/// 保持不变，故 ~160 处 callsite 无需改动。editor / terminal 各自有钉死的配色
/// （见此前的 task），不受这些 token 影响。
///
/// 标 `nonisolated` 让 token 能在任意上下文读取（含单测）；Color 是 Sendable，
/// 常量化静态属性跨线程安全。
enum AppTheme {
    enum Palette {
        // 背景层 —— 系统语义色。chrome 走材质/玻璃的表面见各 view；
        // 这里是不走材质的扁平表面的回退色。
        nonisolated static let bgPanel  = Color(nsColor: .windowBackgroundColor)
        nonisolated static let bgBase   = Color(nsColor: .controlBackgroundColor)
        nonisolated static let bgRaised = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        nonisolated static let bgSelectedInactive = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        nonisolated static let bgSelected = Color(nsColor: .selectedContentBackgroundColor)

        // 描边
        nonisolated static let border       = Color(nsColor: .separatorColor)
        nonisolated static let borderStrong = Color(nsColor: .gridColor)

        // 文本
        nonisolated static let textPrimary   = Color.primary
        nonisolated static let textSecondary = Color.secondary
        nonisolated static let textMuted     = Color(nsColor: .tertiaryLabelColor)

        // 强调（跟随系统强调色）
        nonisolated static let accent = Color.accentColor

        // 状态色（系统鲜艳版）
        nonisolated static let success = Color.green
        nonisolated static let warning = Color.yellow
        nonisolated static let caution = Color.orange
        nonisolated static let danger  = Color.red

        /// SwiftUI hit-test 需要 α>0 的填充才接收鼠标事件。浅深一致。
        nonisolated static let hitTestFill = Color.white.opacity(0.001)
    }
}
