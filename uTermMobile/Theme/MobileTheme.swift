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
    /// 真实 SwiftTerm 终端用的底色（`UD.terminal`）——**日夜都深**。命令块 / Shell 网格别用它。
    static var terminalBg: Color { UD.terminal }
    /// 命令块 / Shell 网格的「终端面」底色——**随主题翻**：暗夜 #08080A / 日间 #FFFFFF（对齐 macOS
    /// `ParTermSurface`）。不要用 `terminalBg`（日夜都深，是真实终端用的）：否则日间得到黑底命令块，
    /// 其上的 text/text2/text3 深字读不出。翻面后文字直接用 M.text/text2/text3 即两档都可读。
    static let cmdSurface = UD.dyn(.hex(0x08080A), .hex(0xFFFFFF))

    // 描边
    static var border: Color { UD.border }
    static var borderHi: Color { UD.borderHi }

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
