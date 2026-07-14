import UDesignKit
import SwiftUI

// uTerm DesignKit 品牌 · 开屏 —— Claude Design 交付包 `splash.jsx` 的 SwiftUI 复刻。
//
// 设计语言 v2 定稿：logo / 开屏仅保留「星空之上」（$_ 笔画 + 星云，深底 #0a0a14），
// 其余方向（终端原色 / 极简标记）已废弃删除。
//
// 组件清单（均为纯展示，跨 macOS / iOS 两个 target 共享）：
// - `UDWordmark`    文字标识：极细 "u" + 品牌色 "Term"
// - `UDNebulaField` 星云场：暗夜底 + 三团色晕 + 26 颗确定性星点
// - `UDSplashNebula` 开屏「星空之上」—— 品牌优先，星云场 + 居中标记锁定
//
// 开屏为**静态**画面（无动效，符合 Apple 启动屏规范）、恒暗色（品牌时刻自带
// 夜空）。强调色默认品牌蓝 `#3B82F6`（logo 烘焙色），不随用户可切换的 UI accent 变化。

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
    var accent: Color = UD.ColorSpec.hex(0x3B82F6).color()
    /// "u" 的颜色。默认设计稿定值近白 `#f3f3f5`（恒暗场景用）；
    /// 放在随主题的面上时传 `UD.text`。
    var color: Color = UD.ColorSpec.hex(0xF3F3F5).color()

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

// MARK: - 星云场

/// 全屏星云：暗夜径向底 + 三团色晕（accent / 紫 / 粉）+ 26 颗确定性星点
/// （坐标固定，画面稳定可截图 / 导出）。logo「星空之上」identity 的全屏铺开。
struct UDNebulaField: View {
    var accent: Color = UD.ColorSpec.hex(0x3B82F6).color()

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

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                // 暗夜径向底（顶部略亮，向下沉到近黑）。
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: UD.ColorSpec.hex(0x0C0C16).color(), location: 0),
                        .init(color: UD.ColorSpec.hex(0x07070D).color(), location: 0.6),
                        .init(color: UD.ColorSpec.hex(0x050509).color(), location: 1),
                    ]),
                    center: UnitPoint(x: 0.5, y: 0),
                    startRadius: 0, endRadius: max(w, h) * 1.05)

                // 三团色晕：accent（左下）/ 紫（中）/ 粉（右上），低透明度软晕。
                bloom(accent,                              o0: 0.149, o1: 0.05, cx: 0.26, cy: 0.74, r: w * 0.70)
                bloom(UD.ColorSpec.hex(0xA78BFA).color(),  o0: 0.20,  o1: 0.05, cx: 0.55, cy: 0.46, r: w * 0.88)
                bloom(UD.ColorSpec.hex(0xF472B6).color(),  o0: 0.14,  o1: 0.04, cx: 0.80, cy: 0.22, r: w * 0.64)

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

// MARK: - 开屏 · 星空之上（定稿）

/// 开屏「星空之上」——品牌优先：星云场 + 居中 `ULogo` 与文字标识锁定。
/// 恒暗色；铺满宿主给的空间（Shell 侧自行 `.ignoresSafeArea()`）。
struct UDSplashNebula: View {
    var accent: Color = UD.ColorSpec.hex(0x3B82F6).color()
    /// 宽屏尺寸档（iPad / regular size class）。
    var big: Bool = false

    var logoSize: CGFloat { big ? 132 : 104 }
    var wordSize: CGFloat { big ? 58 : 46 }
    private var gap: CGFloat { big ? 30 : 24 }

    /// 星云最暗的底色，用作兜底背景，避免任何缝隙露出宿主底色。
    private static let base = UD.ColorSpec.hex(0x050509).color()

    var body: some View {
        ZStack {
            Self.base
            UDNebulaField(accent: accent)
            VStack(spacing: gap) {
                ULogo(size: logoSize)
                    .shadow(color: accent.opacity(0.33), radius: 20, x: 0, y: 14)
                UDWordmark(size: wordSize, accent: accent)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("uTerm")
    }
}

// MARK: - Preview

#Preview("星空之上") {
    UDSplashNebula()
        .frame(width: 390, height: 844)
}
