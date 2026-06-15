import SwiftUI

/// 页面 / 功能切换的统一过渡，柔和无回弹，避免「生硬」的瞬切。
extension Animation {
    /// 同屏内容 / 模式切换统一动画。
    static var mSwap: Animation { .smooth(duration: 0.32) }
}

extension AnyTransition {
    /// 淡入 + 极轻缩放：同屏内容 / 状态切换（列表 ↔ 空态、连接中 ↔ 失败 等）。
    static var mFade: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.99, anchor: .center))
    }
    /// 钻入式：从右侧推入；关闭时向下滑出 + 淡出（dismiss 式），与入场区分、更利落。
    /// 用于「列表 → 会话 / 浏览」这类下钻（终端会话、SFTP 浏览）。
    static var mDrill: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .bottom).combined(with: .opacity))
    }
}
