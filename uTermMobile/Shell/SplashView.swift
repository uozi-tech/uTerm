import SwiftUI
import UIKit

/// uTerm 开屏页面 ·「星空之上 · 昼夜」。
///
/// 视觉本体在 `UDSplash`（`uTerm/DesignKitExtras/UDSplash.swift`，两端共享，
/// 移植自 Claude Design `splash.jsx`）。此处只做 Shell 侧组装：按 size class
/// 选 iPhone / iPad 尺寸档、铺满忽略安全区、决定用昼还是夜。
/// **静态**画面（无动效，符合 Apple 启动屏规范）——由 `MobileApp` 在启动后短暂
/// 停留再淡出切到主界面（淡出是过渡，原型刻意不含入场动画）。
///
/// 昼 / 夜跟**系统**外观走，而不是 App 内的外观偏好：它前面那一帧是系统启动屏
/// （`SplashLaunchBackground`，只认系统外观），两者必须同档才不会在切换瞬间闪一下底色；
/// App 偏好与系统不同时，交给随后的淡出把开屏过渡到主界面。窗口被
/// `preferredColorScheme` 覆盖后，环境里的 `colorScheme` 已是偏好值，所以要从
/// 屏幕的 trait 读系统值。
struct SplashView: View {
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.colorScheme) private var appScheme

    var body: some View {
        UDSplash(big: hSize == .regular)
            .environment(\.colorScheme, Self.systemScheme ?? appScheme)
            .ignoresSafeArea()
    }

    private static var systemScheme: ColorScheme? {
        let scene = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first
        switch scene?.screen.traitCollection.userInterfaceStyle {
        case .dark: return .dark
        case .light: return .light
        default: return nil
        }
    }
}

#Preview {
    SplashView()
}
