import SwiftUI

/// uTerm 开屏页面 · 方向 A「星空之上」。
///
/// 移植自 Claude Design 交付包 `splash.jsx` 的 `SplashNebula`（意图见 `chats/chat23.md`）：
/// 近黑底 + 三团低透明度色晕（accent / 紫 / 粉）+ 稀疏星点，居中 `ULogo` 与 "uTerm"
/// 文字标识。**静态**画面（无动效，符合 Apple 启动屏规范）——由 `MobileApp` 在启动后
/// 短暂停留再淡出切到主界面（淡出是过渡，原型刻意不含入场动画）。
///
/// 强调色固定为品牌蓝 `#3b82f6`（与烘焙进 `ULogoMark` 资产里的 logo 主色一致），
/// 不随用户可切换的 UI accent 变化——开屏是品牌时刻，需与居中的 logo 协调。
/// （原型 `splash.jsx` 用 `#0a84ff` 占位，因其 `ULogo` 会按 accent 重新着色；这里
/// logo 是固定 PNG，故整屏统一到真实 logo 色而非占位色。）
struct SplashView: View {
    @Environment(\.horizontalSizeClass) private var hSize

    /// 品牌蓝；对齐 `ULogoMark` 烘焙色。
    private static let brand = Color(hexString: "#3b82f6")
    /// 星云最暗的底色，用作兜底背景，避免任何缝隙露出系统底色。
    private static let base = Color(hexString: "#050509")

    private var isBig: Bool { hSize == .regular }      // iPad
    private var logoSize: CGFloat { isBig ? 132 : 104 }
    private var wordSize: CGFloat { isBig ? 58 : 46 }
    private var gap: CGFloat { isBig ? 30 : 24 }

    var body: some View {
        ZStack {
            Self.base
            NebulaField(accent: Self.brand)
            VStack(spacing: gap) {
                ULogo(size: logoSize)
                    .shadow(color: Self.brand.opacity(0.33), radius: 20, x: 0, y: 14)
                wordmark
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("uTerm")
    }

    /// 文字标识：极细 "u" + 品牌蓝 "Term"（对齐 app 内 lockup，见 `EmptyServersState`/
    /// `AboutSettingsView`）。用 `Text(verbatim:)` 而非 `Text("u")`，避免把 "u"/"Term"
    /// 当成 `LocalizedStringKey` 污染 xcstrings；用两段 `Text` 而非 `Text + Text`
    /// （`+` 在新系统弃用）。`.tracking` 作用于后代 `Text`，两段统一生效。
    private var wordmark: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: "u")
                .font(.system(size: wordSize, weight: .thin))     // 原型 weight 200
                .foregroundStyle(Color(hexString: "#f3f3f5"))
            Text(verbatim: "Term")
                .font(.system(size: wordSize, weight: .light))    // 原型 weight 300
                .foregroundStyle(Self.brand)
        }
        .tracking(-wordSize * 0.02)
        .lineLimit(1)
        .fixedSize()
    }
}

// MARK: - 星云场

/// 全屏星云：暗夜径向底 + 三团色晕 + 26 颗确定性星点（坐标固定，画面稳定可截图）。
private struct NebulaField: View {
    let accent: Color

    /// `[x%, y%, 半径pt, 不透明度]`——直接搬运自 `splash.jsx` 的 `SPLASH_STARS`。
    private static let stars: [(x: CGFloat, y: CGFloat, r: CGFloat, o: Double)] = [
        (12, 18, 1.4, 0.55), (22, 9, 1.0, 0.40), (34, 24, 1.2, 0.32), (44, 12, 0.9, 0.50),
        (58, 7, 1.5, 0.60),  (69, 19, 1.0, 0.36), (78, 11, 1.1, 0.45), (88, 22, 1.3, 0.40),
        (9, 38, 1.1, 0.42),  (28, 44, 0.9, 0.30), (52, 36, 1.4, 0.50), (63, 47, 1.0, 0.34),
        (84, 41, 1.2, 0.46), (94, 33, 0.9, 0.30), (16, 58, 1.3, 0.40), (38, 63, 1.0, 0.32),
        (72, 60, 1.1, 0.38), (90, 66, 1.4, 0.44), (7, 74, 1.0, 0.30),  (26, 82, 1.2, 0.40),
        (48, 78, 0.9, 0.30), (60, 88, 1.3, 0.46), (80, 83, 1.0, 0.34), (95, 91, 1.1, 0.36),
        (40, 92, 0.9, 0.28), (18, 92, 1.0, 0.30),
    ]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                // 暗夜径向底（顶部略亮，向下沉到近黑）。
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color(hexString: "#0c0c16"), location: 0),
                        .init(color: Color(hexString: "#07070d"), location: 0.6),
                        .init(color: Color(hexString: "#050509"), location: 1),
                    ]),
                    center: UnitPoint(x: 0.5, y: 0),
                    startRadius: 0, endRadius: max(w, h) * 1.05)

                // 三团色晕：accent（左下）/ 紫（中）/ 粉（右上），低透明度软晕。
                bloom(accent,                    o0: 0.149, o1: 0.05, cx: 0.26, cy: 0.74, r: w * 0.70)
                bloom(Color(hexString: "#a78bfa"), o0: 0.20, o1: 0.05, cx: 0.55, cy: 0.46, r: w * 0.88)
                bloom(Color(hexString: "#f472b6"), o0: 0.14, o1: 0.04, cx: 0.80, cy: 0.22, r: w * 0.64)

                // 星点（白点 + 柔光）。
                ForEach(Array(Self.stars.enumerated()), id: \.offset) { _, s in
                    Circle()
                        .fill(Color.white)
                        .frame(width: s.r * 2, height: s.r * 2)
                        .opacity(s.o)
                        .shadow(color: .white.opacity(s.o * 0.5), radius: s.r * 1.5)
                        .position(x: w * s.x / 100, y: h * s.y / 100)
                }
            }
            .frame(width: w, height: h)
        }
    }

    /// 一团软色晕：以 `(cx, cy)` 为中心、半径 `r` 的径向渐变，由 `o0` 渐隐到透明。
    private func bloom(_ c: Color, o0: Double, o1: Double, cx: CGFloat, cy: CGFloat, r: CGFloat) -> some View {
        Rectangle().fill(
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: c.opacity(o0), location: 0),
                    .init(color: c.opacity(o1), location: 0.55),
                    .init(color: c.opacity(0), location: 1),
                ]),
                center: UnitPoint(x: cx, y: cy),
                startRadius: 0, endRadius: r))
    }
}

#Preview {
    SplashView()
}
