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
    static let cmdSurface = UD.dyn(.hex(0x000000), .hex(0xFFFFFF))
    /// 屏幕画布：承载卡片的屏 / 滚动区 / 卡片式抽屉的底。暗夜与 `bg` 同值（视觉零变化）；
    /// 日间浅灰，让白卡浮起。整屏工作面（终端 / 文件浏览……）用 `surface`，别用它。
    static let canvas = UD.dyn(.hex(0x000000), .hex(0xF5F5F5))
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

    // 等宽字体：用系统等宽（避免打包 JetBrains Mono 字体资源）。
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

/// 把十六进制字符串转 Color（设计稿 seed 数据里的分组色等使用）。
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
