import UDesignKit
import SwiftUI

/// iOS/iPadOS 设计 token 门面。直接复用 DesignKit 的 `UD`（携带设计稿深/浅两套
/// 精确色值，已跨平台），再补充移动端需要的字体与排版常量。
///
/// 设计稿（`uTerm iOS · iPadOS.html`）的 M_TOP=72 是浏览器模拟器里的状态栏避让；
/// 原生 iOS 由 safe area 处理状态栏/灵动岛，故这里只保留少量「呼吸」留白。
enum M {
    // 表面
    static var bg: Color { UD.bg }
    static var panel: Color { UD.panel }
    static var panelHi: Color { UD.panelHi }
    static var overlay: Color { UD.overlay }
    static var overlayHi: Color { UD.overlayHi }
    /// 工作面：终端 / Agent / 文件浏览 / 命令面板 / 并行执行这类**整屏单面**的底色——
    /// 暗夜 #141414（`UD.panel`，Ant container）/ 日间 #FFFFFF。屏内的标签条、键盘条、路径条、
    /// 底栏都铺同一个面，区块之间只靠 1pt `divider` 分开（「线或底色差，二选一」，对齐 macOS
    /// v3.3 分区规则）；不要再给条子单独上 `overlay` / `panel` 色。
    static let surface = UD.panel
    /// 真实 SwiftTerm 终端的底色 = `surface`：暗夜 #141414 / 日间 #FFFFFF，与
    /// `MTerminalColors` 两套配色的 background 逐值一致（macOS 08f3b111 同改：纯黑终端在卡面里
    /// 成一块黑洞）。命令块 / Shell 网格用 `cmdSurface`。
    static let terminalBg = UD.panel
    /// 命令块 / Shell 网格的「终端面」底色——**随主题翻**：暗夜 #000000 / 日间 #FFFFFF（对齐 macOS
    /// `ParTermSurface`）。翻面后文字直接用 M.text/text2/text3 即两档都可读。
    static let cmdSurface = UD.bg
    /// 屏幕画布：承载卡片的屏 / 滚动区 / 卡片式抽屉的底。暗夜与 `bg` 同值（视觉零变化）；
    /// 日间浅灰，让白卡浮起。整屏工作面（终端 / 文件浏览……）用 `surface`，别用它。
    static let canvas = UD.pageBg
    /// 卡片面（Ant container）：暗夜 #141414 / 日间纯白，靠与 `canvas`（#000 / #F5F5F5）的
    /// 填充差区分，不加投影、不描边。旧值暗夜白 4.5%（≈#0B0B0B）在纯黑画布上几乎看不出卡片边界。
    /// chip / 键帽 / 次按钮等小控件仍用 fillFaint / `button`，别用它。
    static let card = UD.card

    // 描边
    static var border: Color { UD.border }
    static var borderHi: Color { UD.borderHi }
    /// 区块分区 hairline（工作面上标签条 / 键盘条 / 路径条与内容之间）。取 `UD.border`
    /// （白 12% / 黑 9%）：两侧同底色时全靠这条线分区，旧值白 5% 压在 #141414 上看不见。
    /// 列表行分隔用系统 `Divider`（`MRowDivider`）。
    static let divider = UD.border

    // 文本
    static var text: Color { UD.text }
    static var text2: Color { UD.text2 }
    static var text3: Color { UD.text3 }
    static var text4: Color { UD.text4 }

    // 强调（用户可切换；读 AccentState）
    static var accent: Color { UD.accent }
    static var aiAccent: Color { UD.aiAccent }

    // 语义状态
    static var success: Color { UD.success }
    static var warning: Color { UD.warning }
    static var caution: Color { UD.caution }
    static var danger: Color { UD.danger }
    static var info: Color { UD.info }

    // 输入底 / 行态 / 填充
    static var inputBg: Color { UD.inputBg }
    static var rowSelected: Color { UD.rowSelected }
    static var fillFaint: Color { UD.fillFaint }
    static var fillMed: Color { UD.fillMed }
    /// 次按钮 / 键帽底（Ant button2：暗夜白 8% / 日间黑 4%），在 `surface` 与 `card` 上都成形。
    static let button = UD.button2
    /// 按压 / 悬停的中性灰（`UD.panelHover`：白 8% / 黑 4%）。按压态一律中性，不染强调色；
    /// 选中态才用强调色淡底（`rowSelected`）。
    static let pressed = UD.panelHover

    // 弹层遮罩（暗夜黑 35% / 日间透明）
    static var backdrop: Color { UD.dyn(.black(0.35), .black(0)) }

    // 文件夹 / 文档（SFTP 文件图标，对齐设计稿 SftpFileIcon）
    static var folder1: Color { UD.folder1 }
    static var folder2: Color { UD.folder2 }
    static var folderArrow: Color { UD.folderArrow }
    static var docBg: Color { UD.docBg }
    static var docLine: Color { UD.docLine }
    static var docFold: Color { UD.docFold }
    static var docDetail: Color { UD.docDetail }
    static var iconTeal: Color { UD.iconTeal }

    /// 大标题屏的顶部呼吸留白（safe area 之外的额外间距）。
    static let topBreath: CGFloat = 8
    /// 底部 home indicator 区已由 safe area 处理，这里仅给 tab/工具条额外留白。
    static let bottomBreath: CGFloat = 6

    /// 顶边最小净空：状态栏不在顶边时（横屏 iPhone 隐藏状态栏、iPhone Duo 外屏 / 内屏把
    /// 状态栏与灵动岛挪到侧边），安全区顶边 ≈ 0，页头只剩 `topBreath` 会贴着屏幕顶。
    /// 见 `mTopClearance()`。
    static let minTopClearance: CGFloat = 16
    /// 最小可点区域（HIG 44×44pt）。视觉尺寸可以更小，命中区不行。
    static let minTarget: CGFloat = 44

    /// 宽屏（横屏 / iPad）内容易读最大宽度——超出则内容列居中、两侧留白，避免横屏铺满拉伸。
    static let readableWidth: CGFloat = 680
    /// 卡片网格页（主机 / 终端 / 文件 / 命令四个选择页）的内容最大宽度：宽屏放得下 3 列 `cardMinColumnWidth` 卡片。
    static let gridContentWidth: CGFloat = 1080
    /// 卡片网格的最小列宽：iPhone Duo 展开（669pt）恰好两列，iPad 竖 / 横屏三列。
    nonisolated static let cardMinColumnWidth: CGFloat = 300

    // 等宽字体：用系统等宽（避免打包 JetBrains Mono 字体资源）。
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

/// 圆角刻度。新写圆角一律从这里取，不要再手写数字。规则有三条：
///
/// 1. **叶子元素按高度取档**（图标块、按钮、输入框、chip……）：`xs`…`lg`，大致是高度的 1/4。
/// 2. **容器与贴角的内元素同心**：外圆角 = 内圆角 + 二者间距（`concentric`），或反过来
///    内圆角 = 外圆角 − 间距（`inner`）。不同心时内角看着比外角「更圆」，角落那一圈间距
///    会一头宽一头窄——分组卡片里的行图标、弹窗底部的按钮、分段控件的选中块都属于这种。
///    间距大于外圆角时内元素已不在角的弧线范围里，按第 1 条取档即可。
/// 3. **曲率一律连续**（squircle）：SwiftUI 的 `RoundedRectangle` 默认就是 `.continuous`，
///    别写 `.circular`，也别用已废弃的 `.cornerRadius(_:)` 修饰符。
///
/// 屏幕 / 系统抽屉那一级的同心交给系统（`ConcentricRectangle`，见 `MBottomPanel`）。
nonisolated enum MRadius {
    /// ≤ 24pt：chip、标签、复选框、角标。
    static let xs: CGFloat = 6
    /// 26–34pt：行图标块、小按钮、分段控件的选中块、终端标签。
    static let sm: CGFloat = 8
    /// 36–42pt：头像、表头图标块、搜索框。
    static let md: CGFloat = 10
    /// 44–56pt：主按钮 `MBtn`、输入框、大图标块。
    static let lg: CGFloat = 12

    /// 分组列表卡片（`MInsetGroup` 及同形的成员 / 关联主机 / 权限列表）：
    /// 行图标 `sm` + 行内边距 10pt（50pt 行高里 30pt 图标上下各留 10）。
    static let list = concentric(sm, inset: 10)
    /// 选择页卡片网格（主机 / 终端 / 文件 / 命令）：38pt 头像 `md` + 卡片内边距 14pt。
    static let card = concentric(md, inset: 14)
    /// 居中弹窗（`MCenterModalContainer`）：底部按钮 `lg` + 底边距 16pt。
    static let dialog = concentric(lg, inset: 16)

    /// 外圆角 = 内圆角 + 间距。
    static func concentric(_ inner: CGFloat, inset: CGFloat) -> CGFloat { inner + inset }

    /// 内圆角 = 外圆角 − 间距，下限 `minimum`（间距接近外圆角时不至于变成直角）。
    static func inner(of outer: CGFloat, inset: CGFloat, minimum: CGFloat = 4) -> CGFloat {
        max(outer - inset, minimum)
    }
}

/// 把十六进制字符串转 Color。仅剩 `MFileIcon` 在用；新代码用共享的 `Color(hex:)`
/// （`uTerm/Core/Theme/Color+Hex.swift`）。
extension Color {
    init(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b, a: Double
        switch s.count {
        case 8:
            r = Double((v >> 24) & 0xFF) / 255
            g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8) & 0xFF) / 255
            a = Double(v & 0xFF) / 255
        default:
            r = Double((v >> 16) & 0xFF) / 255
            g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255
            a = 1
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
