import SwiftUI

/// uTerm 的语义化色彩 token 命名空间。所有 view 必须用 token 而非硬编码颜色。
/// Termius 冷灰蓝深色为默认；未来若加浅色主题，在 Palette 上做条件分支。
///
/// 标 `nonisolated` 让 token 能在任意上下文读取（含单测）；Color 是 Sendable，
/// `Color(hex:)` 已声明为 nonisolated init，常量化静态属性跨线程安全。
enum AppTheme {
    enum Palette {
        // 背景层次（由深到浅）
        nonisolated static let bgBase     = Color(hex: 0x1B1D23)
        nonisolated static let bgPanel    = Color(hex: 0x14161B)
        nonisolated static let bgRaised   = Color(hex: 0x1F2128)
        nonisolated static let bgSelected = Color(hex: 0x2A3041)

        // 描边
        nonisolated static let border       = Color(hex: 0x2A2C33)
        nonisolated static let borderStrong = Color(hex: 0x3B3D44)

        // 文本
        nonisolated static let textPrimary   = Color(hex: 0xE8EAEF)
        nonisolated static let textSecondary = Color(hex: 0xC8CACF)
        nonisolated static let textMuted     = Color(hex: 0x7A7C82)

        // 强调色（唯一）
        nonisolated static let accent = Color(hex: 0x4F70D8)
        // 注：原 `accentSubtle` 与 bgSelected 同值且无用例，已删除（Fix #12）；
        // 选中底色统一用 `bgSelected`。

        // 状态色（success/warning/caution/danger 互不相同）
        nonisolated static let success = Color(hex: 0x6FCF97)  // 已连接
        nonisolated static let warning = Color(hex: 0xF2C94C)  // 连接中 / 重连中（黄）
        nonisolated static let caution = Color(hex: 0xF2994A)  // 已断开（橙，区别于 warning）
        nonisolated static let danger  = Color(hex: 0xEB5757)  // 连接失败
    }
}
