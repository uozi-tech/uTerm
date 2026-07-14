import UDesignKit
import SwiftUI

extension ForwardKind {
    /// 类型色：local=UD.accent（蓝）、remote=#bf5af2（紫）、dynamic=UD.success（绿）。
    /// 放在 UI 层而非模型层 —— 模型只依赖 Foundation + SwiftData。
    var tint: Color {
        switch self {
        case .local:   return UD.accent
        case .remote:  return Color(red: 0.749, green: 0.353, blue: 0.949)  // #bf5af2
        case .dynamic: return UD.success
        }
    }
}
