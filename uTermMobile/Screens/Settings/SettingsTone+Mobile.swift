import SwiftUI

extension SettingsTone {
    /// 共享状态色调在 iOS 设置页上的颜色。`active` 用当前强调色（视图从 `\.mAccent` 传入）。
    func mColor(accent: Color) -> Color {
        switch self {
        case .muted:   return M.text3
        case .neutral: return M.text2
        case .active:  return accent
        case .warning: return M.warning
        case .success: return M.success
        case .danger:  return M.danger
        }
    }
}
