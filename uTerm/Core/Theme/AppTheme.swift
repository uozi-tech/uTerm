import SwiftUI

/// 旧的系统语义色 token 命名空间。全 app chrome 已迁移到 DesignKit `UD`（深 / 浅
/// 动态固定色板）；生产代码现仅剩 `hitTestFill` 一处在用（命中区填充，非配色）。
/// 其余成员保留以支撑 `AppThemeTests`（验证系统语义色行为），新代码请用 `UD.*`。
/// editor / terminal 各自有钉死配色，不受影响。
///
/// 标 `nonisolated` 让 token 能在任意上下文读取（含单测）；Color 是 Sendable。
enum AppTheme {
    enum Palette {
        // 文本（系统语义色）
        nonisolated static let textPrimary = Color.primary

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
