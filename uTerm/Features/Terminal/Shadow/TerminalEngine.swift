import Foundation
import GhosttyKit

/// 回滚上限：影子终端和 surface 必须设成同一个值，否则回放进 surface 的历史长度和它自己攒的不一样（M4 的前提）。
/// 两端都用这一个函数算：Mac 传设置里的行数，iOS 传固定的 1 万行。
///
/// 行数之外还要给字节上限：vt 默认的字节上限很小（只设行数时 1 万行只剩约 1 千行），Ghostty 默认 50 MB。
/// 按「每行 1 KB」放宽（实测每行 0.15–0.5 KB，M1），不低于 10 MB。
nonisolated struct TerminalScrollbackLimits: Equatable, Sendable {
    let lines: Int
    let bytes: Int

    init(lines: Int) {
        self.lines = max(0, lines)
        bytes = max(10_000_000, self.lines * 1000)
    }

    /// 影子终端的选项（只有回滚上限）。
    var shadowOptions: ShadowTerminal.Options {
        ShadowTerminal.Options(scrollbackLines: lines, scrollbackBytes: bytes)
    }

    /// 影子终端的选项：回滚上限之外，和 surface 的配置对得上的那几项（两端都用这一份）——surface 不吃字节时由影子
    /// 答查询，要答得一样：光标闪烁（mode 12）的初值跟 surface 的配置走；XTVERSION（`CSI > q`）surface 答的是
    /// 「ghostty <版本>」，影子默认答「libghostty」。
    func shadowOptions(cursorBlink: Bool) -> ShadowTerminal.Options {
        var options = shadowOptions
        options.cursorBlink = cursorBlink
        options.versionReport = Self.surfaceVersionReport
        return options
    }

    /// surface 答 XTVERSION 的串：「ghostty」+ GhosttyKit 自己报的版本。
    static let surfaceVersionReport: String = {
        let info = ghostty_info()
        guard info.version_len > 0 else { return "" }
        let bytes = UnsafeBufferPointer(start: UnsafeRawPointer(info.version).assumingMemoryBound(to: UInt8.self),
                                        count: Int(info.version_len))
        return "ghostty " + String(decoding: bytes, as: UTF8.self)
    }()

    /// Ghostty 配置里对应的两项（键名、取值）。只对之后新建的 surface 生效。
    /// 键是 `scrollback-limit-lines` / `-bytes`；旧键 `scrollback-limit` 这个版本不认、静默忽略。
    var ghosttyConfiguration: [(key: String, value: String)] {
        [("scrollback-limit-lines", String(lines)), ("scrollback-limit-bytes", String(bytes))]
    }
}

/// 终端里的按键绑定：Ghostty 自带的默认绑定全部清掉，只把下面这几条加回去。两端共用这一份（Mac 的
/// `GhosttyTerminalConfig.base`；iOS 接硬件键盘时同样会走到引擎的绑定表）。
///
/// 为什么清：Ghostty 的默认绑定是给它自己的 App 用的——⌘T 新标签、⌘W 关闭、⌘N、⌘D / ⌘⇧D 分屏、⌘K 清屏、⌘↩ 全屏、
/// ⌘+ / ⌘- / ⌘0 字号、⌘F 查找、⌘1…9 切标签、⌘[ / ⌘] 切分屏、⌃Tab、⌘, ⌘Q……引擎认下绑定就把按键吞掉：
/// uTerm 自己的菜单和快捷键收不到，认下的动作多数在 uTerm 里没人接（白吞），有的还会背着影子终端改画面
/// （⌘K 只清 surface 的屏、⌘+ 只改这一个窗格的字号）。清掉之后，没有菜单 / 快捷键接的组合按终端的规矩编码发给程序
/// （legacy 模式下带 ⌘ 的组合编不出字节，等于没按；程序开了 kitty 键盘协议就收得到）。
///
/// 加回去的三组：
/// - 拷贝 / 粘贴 / 全选：平时由主菜单的「编辑」触发（`GhosttySurfaceView` 先问菜单），这里是菜单接不了时的兜底。
///   `performable:` = 做不了（没有选区）就不吞。
/// - 「自然文本编辑」：⌥← / ⌥→ 按词移动（`ESC b` / `ESC f`）、⌘← / ⌘→ 到行首 / 行尾（`^A` / `^E`）、⌘⌫ 删到行首（`^U`）。
///   这是 Ghostty 在 macOS 上的默认值，和 Terminal.app 一致，shell 默认的 emacs 键位下不用任何配置就生效。
///   旧引擎发的不是这几串（⌥← / ⌥→ 是 `CSI 1;3D` / `CSI 1;3C`，⌘← / ⌘→ 是 Home / End，⌘⌫ 不发），
///   在没配过键位的 zsh / bash 里不起作用；这里取能用的那一种。⌥⌫（`ESC DEL`）、⌥字母（`ESC` + 字母）两边相同，不需要绑定。
/// - 翻回滚：⌘Home / ⌘End 到顶 / 到底，⌘PageUp / ⌘PageDown 翻一页。
nonisolated enum TerminalKeyBindings {
    /// Ghostty 配置项（键名、取值），按顺序写进配置：第一条 `keybind = clear` 必须在最前。
    /// 配置里有一条写错，引擎会拒收整份配置（退回默认值）——`TerminalKeyBindingTests` 核配置被接受。
    static let ghosttyConfiguration: [(key: String, value: String)] = [
        ("keybind", "clear"),
        ("keybind", "performable:super+c=copy_to_clipboard"),
        ("keybind", "performable:super+v=paste_from_clipboard"),
        ("keybind", "super+a=select_all"),
        ("keybind", "alt+arrow_left=esc:b"),
        ("keybind", "alt+arrow_right=esc:f"),
        ("keybind", "super+arrow_left=text:\\x01"),
        ("keybind", "super+arrow_right=text:\\x05"),
        ("keybind", "super+backspace=text:\\x15"),
        ("keybind", "super+home=scroll_to_top"),
        ("keybind", "super+end=scroll_to_bottom"),
        ("keybind", "super+page_up=scroll_page_up"),
        ("keybind", "super+page_down=scroll_page_down"),
        // ⌥ 一律当 Alt（Meta）：⌥b 发 `ESC b`，不是「∫」。不写时引擎按键盘布局猜（美式布局才当 Alt），
        // 换成 ABC 之外的布局 ⌥ 组合就变成输入特殊字符；旧引擎一直是 Alt。
        ("macos-option-as-alt", "true"),
    ]
}
