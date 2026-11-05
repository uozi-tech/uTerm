import SwiftUI
import SwiftTerm
import UIKit

/// iOS 终端配色入口：转发到两端共用的 `TerminalColorScheme`（VS Code Dark / Light），
/// 装进视图走 `TerminalAppearance`。
///
/// 日间终端为白底（设计稿 `--u-term-bg:#ffffff`），暗夜为卡面色 #141414（`UD.panel`，即
/// `M.terminalBg` / `M.surface`）：终端与上下的标签条、键盘条铺同一个面，只靠 hairline 分区；
/// 纯黑 #000 会让终端在条子之间成一块黑洞（与 macOS 08f3b111 同改）。
enum MTerminalColors {
    nonisolated static func resolve(dark: Bool) -> TerminalColorScheme { TerminalColorScheme.resolve(dark: dark) }

    /// 终端区域的 SwiftUI 背景色（头部 / 键盘条之外的留白随终端底色）。
    nonisolated static func background(dark: Bool) -> SwiftUI.Color {
        SwiftUI.Color(uiColor: resolve(dark: dark).backgroundColor)
    }
}
