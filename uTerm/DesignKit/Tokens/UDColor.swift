import SwiftUI
import AppKit

/// uTerm DesignKit 色彩 token —— Claude Design 交付包 `Components.html` 的设计系统。
///
/// 与 `AppTheme.Palette`（系统语义色）和 `WS`（工作区**固定深色**）并存：`UD` 携带
/// 设计稿的**两套精确值（深 + 浅）**，通过动态 `NSColor` 随系统外观自动切换。
/// DesignKit 组件只读 `UD` token + 普通值输入，不依赖任何 domain model。
///
/// 命名空间用扁平静态属性（对齐 `WS` 的用法），并按需挂 `UD.Radius` / `UD.Space`
/// / `UD.Shadow` / 排版子组（见 `UDMetrics.swift` / `UDTypography.swift`）。
/// 标 `nonisolated` 让 token 能在任意上下文读取；`Color` 是 `Sendable`。
enum UD {
    // MARK: - 动态色构造

    /// 一个外观无关的 sRGB 颜色描述（`Sendable`，可安全被动态 provider 闭包捕获）。
    nonisolated struct ColorSpec: Sendable {
        let r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat

        nonisolated func nsColor() -> NSColor {
            NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        }
        nonisolated func color() -> Color {
            Color(.sRGB, red: r, green: g, blue: b, opacity: a)
        }
        /// `0xRRGGBB` + alpha。
        nonisolated static func hex(_ h: UInt32, _ a: CGFloat = 1) -> ColorSpec {
            ColorSpec(r: CGFloat((h >> 16) & 0xFF) / 255,
                      g: CGFloat((h >> 8) & 0xFF) / 255,
                      b: CGFloat(h & 0xFF) / 255, a: a)
        }
        /// 白色叠加（深色面上的描边 / 文本透明度）。
        nonisolated static func white(_ a: CGFloat) -> ColorSpec { ColorSpec(r: 1, g: 1, b: 1, a: a) }
        /// 黑色叠加（浅色面上的描边 / 文本透明度）。
        nonisolated static func black(_ a: CGFloat) -> ColorSpec { ColorSpec(r: 0, g: 0, b: 0, a: a) }
    }

    /// 把 (深, 浅) 两个 spec 合成一个随系统外观切换的动态 `Color`。
    nonisolated static func dyn(_ dark: ColorSpec, _ light: ColorSpec) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return (isDark ? dark : light).nsColor()
        })
    }

    // MARK: - 表面 Surfaces
    nonisolated static let bg         = dyn(.hex(0x101012), .hex(0xFFFFFF))
    nonisolated static let panel      = dyn(.hex(0x17171A), .hex(0xF6F6F3))
    nonisolated static let panelHi    = dyn(.hex(0x1C1C20), .hex(0xEEEEEA))
    nonisolated static let panelHover = dyn(.hex(0x202026), .black(0.05))
    nonisolated static let terminal   = dyn(.hex(0x08080A), .hex(0x0B0B0D))
    /// 浮层实体面（下拉 / 菜单 / popover）。浅色用纯白面板。
    nonisolated static let overlay    = dyn(.hex(0x1B1B1F), .hex(0xFFFFFF))
    /// 模态实体面（指标卡 / 菜单栏面板）。
    nonisolated static let overlayHi  = dyn(.hex(0x202024), .hex(0xFFFFFF))

    // MARK: - 描边 Stroke（深=白叠加 / 浅=黑叠加）
    nonisolated static let border     = dyn(.white(0.07), .black(0.10))
    nonisolated static let borderHi   = dyn(.white(0.10), .black(0.14))

    // MARK: - 文本 Text（深=白叠加 / 浅=黑叠加）
    nonisolated static let text       = dyn(.hex(0xEDEDEE), .hex(0x1D1D1F))
    nonisolated static let text2      = dyn(.white(0.46), .black(0.58))
    nonisolated static let text3      = dyn(.white(0.28), .black(0.46))
    nonisolated static let text4      = dyn(.white(0.18), .black(0.34))

    // MARK: - 强调 Accent（macOS 系统蓝）
    nonisolated static let accent     = dyn(.hex(0x0A84FF), .hex(0x007AFF))
    /// 加深的 accent（浅色按下 / 文字用 #0067e0；深色略提亮）。
    nonisolated static let accentInk  = dyn(.hex(0x4DA3FF), .hex(0x0067E0))
    /// accent 软底（选中底 / ghost hover）。深 10% / 浅 13%。
    nonisolated static let accentSoft = dyn(.hex(0x0A84FF, 0.10), .hex(0x007AFF, 0.13))
    /// 按下态去饱和板岩蓝（设计稿 active：按下时颜色往回收而非更跳，饱和度低于 hover）。
    /// 深色作半透明叠加底（×0.26 填 / ×0.55 描边），浅色用实底（#5A7099）。
    nonisolated static let accentPressed = dyn(.hex(0x96ACCD), .hex(0x5A7099))

    // 备选强调色（设计稿固定 macOS 系统色，深浅同值）。
    nonisolated static let accentViolet = ColorSpec.hex(0xBF5AF2).color()   // 雾紫
    nonisolated static let accentSage   = ColorSpec.hex(0x30D158).color()   // 鼠尾草
    nonisolated static let accentGold   = ColorSpec.hex(0xFFD60A).color()   // 黯金
    nonisolated static let accentRose   = ColorSpec.hex(0xFF5A5A).color()   // 藕薇

    // MARK: - 语义状态 Semantic（macOS 系统色，浅色用更深档）
    nonisolated static let success = dyn(.hex(0x30D158), .hex(0x34C759))
    nonisolated static let warning = dyn(.hex(0xFFD60A), .hex(0xFFAA00))
    nonisolated static let caution = dyn(.hex(0xFF9F0A), .hex(0xFF8A00))   // 断开
    nonisolated static let danger  = dyn(.hex(0xFF5A5A), .hex(0xFF3B30))
    nonisolated static let info    = dyn(.hex(0x64D2FF), .hex(0x007AFF))

    // MARK: - 行态 Row（hover / selected 底）
    nonisolated static let rowHover    = dyn(.white(0.025), .black(0.04))
    nonisolated static let rowSelected = dyn(.white(0.055), .hex(0x007AFF, 0.13))

    // MARK: - 叠加填充 Fill（面上的细微实体填充；深=白叠加 / 浅=黑叠加）
    nonisolated static let fillFaint = dyn(.white(0.03),  .black(0.035))   // 卡片 / 气泡静态底
    nonisolated static let fillSoft  = dyn(.white(0.05),  .black(0.055))   // 选中段 / 代码片
    nonisolated static let fillMed   = dyn(.white(0.08),  .black(0.08))    // 进度槽等需更明显处

    // MARK: - 遥测分类色 Telemetry（状态栏 / 指标卡，深浅各一套）
    nonisolated static let mPlatform = dyn(.hex(0x409CFF), .hex(0x007AFF))   // 平台
    nonisolated static let mEndpoint = dyn(.hex(0x9AA7B5), .hex(0x6B7681))   // endpoint / 时间戳
    nonisolated static let mUptime   = dyn(.hex(0x30D158), .hex(0x34C759))   // 运行时长
    nonisolated static let mLoad     = dyn(.hex(0xFF5F7E), .hex(0xFF3B30))   // 负载
    nonisolated static let mCPU      = dyn(.hex(0x3FD6C0), .hex(0x1FC0A8))   // CPU
    nonisolated static let mMem      = dyn(.hex(0xFFD60A), .hex(0xFFAA00))   // 内存
    nonisolated static let mDisk     = dyn(.hex(0xFF9F0A), .hex(0xFF8A00))   // 磁盘
}
