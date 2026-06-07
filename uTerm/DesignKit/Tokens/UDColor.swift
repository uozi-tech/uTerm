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
    nonisolated struct ColorSpec: Sendable, Equatable {
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
    // 日间「全部统一用 UDInput 的白」= 纯白 #FFFFFF（用户定）。画布 + 面板 + chrome（标题栏 /
    // 侧栏）+ 输入 + 浮层全用 #FFFFFF，整 app 单一纯白面、区域靠 1px 描边分区、无缝。
    // 次面板 #EEEEEA（嵌套 / code block，比白基面略深一档）。深色保持原分层。
    // 中性灰一律用纯黑 alpha（rgba(0,0,0,α)），不发蓝。
    nonisolated static let bg         = dyn(.hex(0x101012), .hex(0xFFFFFF))
    nonisolated static let panel      = dyn(.hex(0x17171A), .hex(0xFFFFFF))
    nonisolated static let panelHi    = dyn(.hex(0x1C1C20), .hex(0xEEEEEA))
    nonisolated static let panelHover = dyn(.hex(0x202026), .black(0.05))
    nonisolated static let terminal   = dyn(.hex(0x08080A), .hex(0x0B0B0D))
    /// 浮层实体面（下拉 / 菜单 / popover）。浅色用纯白面板。
    nonisolated static let overlay    = dyn(.hex(0x1B1B1F), .hex(0xFFFFFF))
    /// 模态实体面（指标卡 / 菜单栏面板）。
    nonisolated static let overlayHi  = dyn(.hex(0x202024), .hex(0xFFFFFF))

    // MARK: - 描边 Stroke（深=白叠加 / 浅=纯黑叠加）
    nonisolated static let border     = dyn(.white(0.07), .black(0.10))
    nonisolated static let borderHi   = dyn(.white(0.10), .black(0.16))

    // MARK: - 文本 Text（深=白叠加 / 浅=纯黑叠加，中性不发蓝）
    nonisolated static let text       = dyn(.hex(0xEDEDEE), .hex(0x1C1C1E))
    nonisolated static let text2      = dyn(.white(0.46), .black(0.56))
    nonisolated static let text3      = dyn(.white(0.28), .black(0.40))
    nonisolated static let text4      = dyn(.white(0.18), .black(0.26))

    // MARK: - 强调 Accent（可切换；见 AccentColor / AccentState。getter 同步读 selected →
    // SwiftUI body 求值期访问被 Observation 追踪 → 切色全局自动重渲染。默认蓝 = 原手调值。）
    @MainActor static var accent: Color {
        let a = AccentState.shared.selected
        return dyn(a.accentSpec(dark: true), a.accentSpec(dark: false))
    }
    @MainActor static var accentInk: Color {
        let a = AccentState.shared.selected
        return dyn(a.inkSpec(dark: true), a.inkSpec(dark: false))
    }
    @MainActor static var accentSoft: Color {
        let a = AccentState.shared.selected
        return dyn(a.softSpec(dark: true), a.softSpec(dark: false))
    }
    @MainActor static var accentPressed: Color {
        let a = AccentState.shared.selected
        return dyn(a.pressedSpec(dark: true), a.pressedSpec(dark: false))
    }

    // 备选强调色（设计稿固定 macOS 系统色，深浅同值）。
    nonisolated static let accentViolet = ColorSpec.hex(0xBF5AF2).color()   // 雾紫
    nonisolated static let accentSage   = ColorSpec.hex(0x30D158).color()   // 鼠尾草
    nonisolated static let accentGold   = ColorSpec.hex(0xFFD60A).color()   // 黯金
    nonisolated static let accentRose   = ColorSpec.hex(0xFF5A5A).color()   // 藕薇

    // MARK: - 语义状态 Semantic（设计稿 --u-status-*）
    // 暗夜：iOS 鲜艳系统色（保持原样）。日间：低饱和、年轻化——白底上仍清晰可辨，
    // 由设计稿 oklch 值转 sRGB（绿 0.70/0.13/156、黄 0.78/0.115/82、橙 0.72/0.125/56、
    // 红 0.64/0.15/24、蓝 0.67/0.115/242）。状态点 / 徽章 / danger 态等全经此 token。
    nonisolated static let success = dyn(.hex(0x30D158), .hex(0x4EB67C))   // 已连接
    nonisolated static let warning = dyn(.hex(0xFFD60A), .hex(0xDCB05B))   // 连接中
    nonisolated static let caution = dyn(.hex(0xFF9F0A), .hex(0xE08E52))   // 断开
    nonisolated static let danger  = dyn(.hex(0xFF5A5A), .hex(0xD8625E))   // 失败 / 危险
    nonisolated static let info    = dyn(.hex(0x64D2FF), .hex(0x4D9DD6))   // 信息

    // MARK: - 文件夹 / 图标色 Folder & Icon（设计稿 --u-folder-1/2 · --u-icon-teal）
    // 暗夜保持原样（鲜艳双色蓝 + 青）；日间文件夹换 macOS Finder 风格鲜亮饱和蓝
    // （旧低饱和雾霾蓝看起来发灰），符号链接转向箭头仍柔青。
    nonisolated static let folder1    = dyn(.hex(0x5B8FD6), .hex(0x2B86E6))   // 文件夹背片（深蓝）
    nonisolated static let folder2    = dyn(.hex(0x79A9E8), .hex(0x4CA7F8))   // 文件夹前片（亮蓝，主填充）
    nonisolated static let folderArrow = dyn(.hex(0x0E2742), .hex(0xFFFFFF))  // 文件夹「返回上级」箭头
    nonisolated static let iconTeal   = dyn(.hex(0x2DD4BF), .hex(0x0FB6AC))   // 符号链接转向箭头（日间 = oklch(0.70 0.12 188)）

    // MARK: - 文档图标色 Doc（设计稿 --u-doc-bg/line/fold/detail）
    // 暗夜：白叠加纸面（半透叠在深底）。日间：纯白纸 + 1pt 暖中性灰描边 + 暖白右上折角 +
    // 暖灰内文线——取代旧「灰色纸片」（doc.fill 填 text4），且不发蓝（与暖中性白底统一）。
    nonisolated static let docBg     = dyn(.white(0.09), .hex(0xFFFFFF))   // 纸张填充
    nonisolated static let docLine   = dyn(.white(0.26), .hex(0xC9C7C4))   // 描边（纸 + 折角共用）
    nonisolated static let docFold   = dyn(.white(0.16), .hex(0xEEEDEA))   // 右上折角
    nonisolated static let docDetail = dyn(.white(0.32), .hex(0xA8A6A3))   // 内部文本线

    // MARK: - 输入底 Input（设计稿 --u-input-bg / --u-input-bg-soft）
    // 暗夜：白叠加细底（原样）。日间：纯白底（配 UD.border 细描边——更干净）。
    nonisolated static let inputBg     = dyn(.white(0.035), .hex(0xFFFFFF))
    nonisolated static let inputBgSoft = dyn(.white(0.03),  .hex(0xFFFFFF))

    // MARK: - 行态 Row（hover / selected 底）
    // 日间 hover = 纯黑 4.5% 叠加（中性，不发蓝）；selected = accent-soft #007AFF 13%
    // —— 设计稿里唯一允许的「选中填充」（kit L.sel）。深色保持原中性白叠加。
    nonisolated static let rowHover    = dyn(.white(0.025), .black(0.045))
    nonisolated static let rowSelected = dyn(.white(0.055), .hex(0x007AFF, 0.13))

    // MARK: - 叠加填充 Fill（面上的细微实体填充）
    // 深色=白叠加。日间：基面是暖白 #F6F6F3，卡片 / 气泡 / chip 用比基面略深一档、同色温的
    // 暖灰实底（嵌套感、可见、不发蓝）。fillMed 用中性黑叠加——进度槽等**功能轨道**，
    // handoff 要求保留中性灰。
    nonisolated static let fillFaint = dyn(.white(0.03),  .hex(0xF0F0ED))   // 卡片 / 气泡静态底（暖、略深于基面）
    nonisolated static let fillSoft  = dyn(.white(0.05),  .hex(0xE9E9E5))   // 选中段 / 代码片（暖、更深一档）
    nonisolated static let fillMed   = dyn(.white(0.08),  .black(0.08))     // 进度槽等功能轨道（保留中性灰）

    // MARK: - 遥测分类色 Telemetry（状态栏 / 指标卡，深浅各一套）
    nonisolated static let mPlatform = dyn(.hex(0x409CFF), .hex(0x007AFF))   // 平台
    nonisolated static let mEndpoint = dyn(.hex(0x9AA7B5), .hex(0x6B7681))   // endpoint / 时间戳
    nonisolated static let mUptime   = dyn(.hex(0x30D158), .hex(0x34C759))   // 运行时长
    nonisolated static let mLoad     = dyn(.hex(0xFF5F7E), .hex(0xFF3B30))   // 负载
    nonisolated static let mCPU      = dyn(.hex(0x3FD6C0), .hex(0x1FC0A8))   // CPU
    nonisolated static let mMem      = dyn(.hex(0xFFD60A), .hex(0xFFAA00))   // 内存
    nonisolated static let mDisk     = dyn(.hex(0xFF9F0A), .hex(0xFF8A00))   // 磁盘
}
