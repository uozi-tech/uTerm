import SwiftUI

/// uTerm 开屏页面 · 方向 A「星空之上」。
///
/// 视觉本体在 DesignKit：`UDSplashNebula`（`uTerm/DesignKit/Brand/UDSplash.swift`，
/// 两端共享，移植自 Claude Design 交付包 `splash.jsx`，意图见 `chats/chat23.md`）。
/// 此处只做 Shell 侧组装：按 size class 选 iPhone / iPad 尺寸档、铺满忽略安全区。
/// **静态**画面（无动效，符合 Apple 启动屏规范）——由 `MobileApp` 在启动后短暂
/// 停留再淡出切到主界面（淡出是过渡，原型刻意不含入场动画）。
///
/// 强调色用 `UD.brand` 品牌蓝（与烘焙进 `ULogoMark` 资产里的 logo 主色一致），
/// 不随用户可切换的 UI accent 变化——开屏是品牌时刻，需与居中的 logo 协调。
struct SplashView: View {
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        UDSplashNebula(big: hSize == .regular)
            .ignoresSafeArea()
    }
}

#Preview {
    SplashView()
}
