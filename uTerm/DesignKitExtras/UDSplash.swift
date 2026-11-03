import SwiftUI

/// 本文件被 uTermMobile 共享；这里只用到十六进制转 sRGB Color 一个能力，
/// 本地化成纯 SwiftUI helper 以保持跨平台、不依赖 `UD` 的动态 token。
/// 语义与 `UD.ColorSpec.hex(_:).color()` 一致（sRGB、不透明）。
private func splashHex(_ h: UInt32, _ opacity: Double = 1) -> Color {
    Color(.sRGB,
          red: Double((h >> 16) & 0xFF) / 255,
          green: Double((h >> 8) & 0xFF) / 255,
          blue: Double(h & 0xFF) / 255,
          opacity: opacity)
}

// uTerm DesignKit 品牌 · 开屏 —— Claude Design `splash.jsx`「星空之上 · 昼夜」的 SwiftUI 复刻。
//
// 2026-11-03 重设计：开屏从「恒暗星云」改为随外观切换的昼 / 夜两版，同一构图：
// - 夜：近黑夜空（顶部微亮）+ 居中蓝紫光晕 + 白色星点（靠近标记处淡出）；
// - 昼：白→雾蓝天空 + 同位置更淡的光晕 + 灰蓝「尘点」（无辉光）。
// 中央锁定 `ULogo` + 文字标识，不带页脚 / 文案（user 定）。
//
// 组件清单（均为纯展示，跨 macOS / iOS 两个 target 共享）：
// - `UDWordmark`      文字标识：极细 "u" + 品牌色 "Term"
// - `UDSplashPalette` 昼 / 夜两套配色
// - `UDNebulaField`   天空场：底色 + 三团色晕 + 26 颗确定性星点
// - `UDSplash`        开屏：天空场 + 居中标记锁定，按 `\.colorScheme` 取配色
//
// 开屏为**静态**画面（无动效，符合 Apple 启动屏规范）。底色与
// `SplashLaunchBackground`（Info.plist 的 UILaunchScreen）两档逐值一致，
// 系统启动屏切到开屏时只「长出」光晕与标记，不跳底色。

// MARK: - 文字标识 Wordmark

/// "uTerm" 文字标识：极细 "u"（weight 200→`.thin`）+ 品牌色 "Term"（300→`.light`）。
///
/// 用 `Text(verbatim:)` 而非 `Text("u")`，避免把 "u"/"Term" 当成
/// `LocalizedStringKey` 污染 xcstrings；用两段 `Text` 而非 `Text + Text`
/// （`+` 在新系统弃用）。`.tracking` 作用于后代 `Text`，两段统一生效。
struct UDWordmark: View {
    /// 字号（pt）。设计稿：开屏 46 / iPad 58。
    var size: CGFloat = 46
    /// "Term" 的强调色。默认品牌蓝（logo 烘焙色）。
    var accent: Color = splashHex(0x3B82F6)
    /// "u" 的颜色。默认近白 `#f3f3f5`（暗场景用）；放在随主题的面上时传 `UD.text`。
    var color: Color = splashHex(0xF3F3F5)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: "u")
                .font(.system(size: size, weight: .thin))
                .foregroundStyle(color)
            Text(verbatim: "Term")
                .font(.system(size: size, weight: .light))
                .foregroundStyle(accent)
        }
        .tracking(-size * 0.02)
        .lineLimit(1)
        .fixedSize()
    }
}

// MARK: - 配色

/// 开屏昼 / 夜两套配色（真值在设计稿 `splash.jsx` 的 `SPLASH_THEMES`）。
struct UDSplashPalette {
    /// 底色：画面下半与四角的颜色，= `SplashLaunchBackground`。
    var base: Color
    /// 顶部天光（线性渐变到 55% 处并入 `base`）。
    var top: Color
    /// 主光晕（品牌蓝）与其外圈（紫）、右上角余晖（粉）。
    var halo: Color
    var haloMid: Color
    var rim: Color
    /// 星点颜色、整体不透明度系数、是否带辉光。
    var star: Color
    var starOpacity: Double
    var starGlow: Bool
    /// 文字标识 "u" / "Term"。
    var wordmark: Color
    var wordmarkAccent: Color
    /// logo 底下的投影。
    var logoShadow: Color
    var logoShadowRadius: CGFloat
    var logoShadowY: CGFloat

    static let night = UDSplashPalette(
        base: splashHex(0x05060B), top: splashHex(0x0B0D18),
        halo: splashHex(0x3B82F6, 0.20), haloMid: splashHex(0xA78BFA, 0.10), rim: splashHex(0xF472B6, 0.08),
        star: .white, starOpacity: 1, starGlow: true,
        wordmark: splashHex(0xF3F3F5), wordmarkAccent: splashHex(0x3B82F6),
        logoShadow: splashHex(0x3B82F6, 0.30), logoShadowRadius: 18, logoShadowY: 14)

    static let day = UDSplashPalette(
        base: splashHex(0xF4F6FA), top: splashHex(0xFFFFFF),
        halo: splashHex(0x3B82F6, 0.13), haloMid: splashHex(0xA78BFA, 0.10), rim: splashHex(0xF472B6, 0.07),
        star: splashHex(0x7F98C2), starOpacity: 0.55, starGlow: false,
        wordmark: splashHex(0x1F1F1F), wordmarkAccent: splashHex(0x1677FF),
        logoShadow: splashHex(0x172854, 0.22), logoShadowRadius: 15, logoShadowY: 16)

    static func resolve(_ scheme: ColorScheme) -> UDSplashPalette {
        scheme == .dark ? .night : .day
    }
}

// MARK: - 天空场

/// 全屏天空：顶部天光渐变 + 三团色晕（中央光晕 / 右上余晖 / 左下回光）+ 26 颗确定性星点
/// （坐标固定，画面稳定可截图 / 导出）。星点离标记越近越淡，不与 logo 抢视线。
struct UDNebulaField: View {
    var palette: UDSplashPalette = .night
    /// 标记锁定的视觉中心（占高度比例），星点围绕它淡出、主光晕以它为圆心。
    var focusY: CGFloat = 0.47

    /// `[x%, y%, 半径pt, 不透明度]`——直接搬运自 `splash.jsx` 的 `SPLASH_STARS`。
    static let stars: [(x: CGFloat, y: CGFloat, r: CGFloat, o: Double)] = [
        (12, 18, 1.4, 0.55), (22, 9, 1.0, 0.40), (34, 24, 1.2, 0.32), (44, 12, 0.9, 0.50),
        (58, 7, 1.5, 0.60),  (69, 19, 1.0, 0.36), (78, 11, 1.1, 0.45), (88, 22, 1.3, 0.40),
        (9, 38, 1.1, 0.42),  (28, 44, 0.9, 0.30), (52, 36, 1.4, 0.50), (63, 47, 1.0, 0.34),
        (84, 41, 1.2, 0.46), (94, 33, 0.9, 0.30), (16, 58, 1.3, 0.40), (38, 63, 1.0, 0.32),
        (72, 60, 1.1, 0.38), (90, 66, 1.4, 0.44), (7, 74, 1.0, 0.30),  (26, 82, 1.2, 0.40),
        (48, 78, 0.9, 0.30), (60, 88, 1.3, 0.46), (80, 83, 1.0, 0.34), (95, 91, 1.1, 0.36),
        (40, 92, 0.9, 0.28), (18, 92, 1.0, 0.30),
    ]

    /// 星点在标记附近的淡出系数（0.15…1），与 `splash.jsx` 的 `starFade` 同式。
    static func fade(x: CGFloat, y: CGFloat, focusY: CGFloat) -> Double {
        let d = hypot((x - 50) * 0.46, y - focusY * 100)
        return Double(min(1, max(0.15, (d - 8) / 22)))
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                palette.base
                LinearGradient(
                    stops: [.init(color: palette.top, location: 0), .init(color: palette.base, location: 0.55)],
                    startPoint: .top, endPoint: .bottom)

                bloom([palette.halo, palette.haloMid, .clear], at: [0, 0.45, 0.75],
                      cx: 0.50, cy: focusY, rx: 0.70, ry: 0.40, in: geo.size)
                bloom([palette.rim, .clear], at: [0, 0.70],
                      cx: 0.85, cy: 0.12, rx: 0.60, ry: 0.40, in: geo.size)
                bloom([palette.halo, .clear], at: [0, 0.70],
                      cx: 0.12, cy: 0.92, rx: 0.60, ry: 0.40, in: geo.size)

                ForEach(Array(Self.stars.enumerated()), id: \.offset) { _, s in
                    let o = s.o * Self.fade(x: s.x, y: s.y, focusY: focusY) * palette.starOpacity
                    Circle()
                        .fill(palette.star)
                        .frame(width: s.r * 2, height: s.r * 2)
                        .opacity(o)
                        .shadow(color: palette.starGlow ? .white.opacity(o * 0.5) : .clear, radius: s.r * 1.5)
                        .position(x: w * s.x / 100, y: h * s.y / 100)
                }
            }
            .frame(width: w, height: h)
        }
    }

    /// 一团椭圆软色晕，等价 CSS `radial-gradient(rx ry at cx cy, …)`：中心 `(cx, cy)`、
    /// 横 / 纵半径分别为宽 / 高的 `rx` / `ry` 倍。`EllipticalGradient` 的椭圆内切于自身
    /// frame，所以把 frame 设成 2rx×2ry 再摆到中心点。
    private func bloom(_ colors: [Color], at locations: [CGFloat],
                       cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat,
                       in size: CGSize) -> some View {
        let stops = zip(colors, locations).map { Gradient.Stop(color: $0, location: $1) }
        return EllipticalGradient(stops: stops, center: .center)
            .frame(width: size.width * rx * 2, height: size.height * ry * 2)
            .position(x: size.width * cx, y: size.height * cy)
            .allowsHitTesting(false)
    }
}

// MARK: - 开屏 · 星空之上 · 昼夜

/// 开屏：天空场 + 居中 `ULogo` 与文字标识锁定。按环境 `\.colorScheme` 取昼 / 夜配色；
/// 铺满宿主给的空间（Shell 侧自行 `.ignoresSafeArea()`）。
struct UDSplash: View {
    /// 宽屏尺寸档（iPad / regular size class）。
    var big: Bool = false

    @Environment(\.colorScheme) private var scheme

    var logoSize: CGFloat { big ? 132 : 104 }
    var wordSize: CGFloat { big ? 58 : 46 }
    private var gap: CGFloat { big ? 28 : 22 }

    var body: some View {
        let palette = UDSplashPalette.resolve(scheme)
        GeometryReader { geo in
            ZStack {
                UDNebulaField(palette: palette)
                VStack(spacing: gap) {
                    ULogo(size: logoSize)
                        .shadow(color: palette.logoShadow, radius: palette.logoShadowRadius,
                                x: 0, y: palette.logoShadowY)
                    UDWordmark(size: wordSize, accent: palette.wordmarkAccent, color: palette.wordmark)
                }
                // 视觉中心略高于几何中心（≈47%），与天空场的 focusY 对齐。
                .padding(.bottom, geo.size.height * 0.06)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(palette.base)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "uTerm"))
    }
}

// MARK: - Preview

#Preview("夜") {
    UDSplash()
        .frame(width: 390, height: 844)
        .environment(\.colorScheme, .dark)
}

#Preview("昼") {
    UDSplash()
        .frame(width: 390, height: 844)
        .environment(\.colorScheme, .light)
}
