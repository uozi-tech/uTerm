import Foundation

/// 终端引擎的版本：画面（GhosttyKit）和影子终端（libghostty-vt）是同一棵源码树编的两份二进制，二进制快照的格式、
/// 回放出来的画面都跟着这棵树走。两端（远控的 Mac 与接入的设备、存检查点的那次运行与接回的这次运行）版本串不同，
/// 快照就不能互认：远控拒绝镜像并提示更新，holder 检查点直接丢弃。
///
/// vt 自己报的版本串（`ShadowTerminal.buildVersion`）这个版本只有「0.1.0-dev」，区分不了提交和补丁，所以这里手写。
/// **换引擎的任何一个二进制（换 Ghostty 提交、加减引擎补丁）时必须改这个串**，并且和 `vendor/libghostty-spm/ENGINE.lock` 的
/// `engine_version` 一字不差——`TerminalEngineLockTests` 读那份清单来核，忘了改会失败。步骤见 `vendor/libghostty-spm/UTERM-PATCHES.md`。
nonisolated enum TerminalEngineVersion {
    /// Ghostty 提交 + 引擎补丁的最大编号 + 快照格式的修订号。
    static let current = "ghostty-042b16b6+p0023/snapshot-1"
}

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

    /// 影子终端的选项。
    var shadowOptions: ShadowTerminal.Options {
        ShadowTerminal.Options(scrollbackLines: lines, scrollbackBytes: bytes)
    }

    /// Ghostty 配置里对应的两项（键名、取值）。只对之后新建的 surface 生效。
    /// 键是 `scrollback-limit-lines` / `-bytes`；旧键 `scrollback-limit` 这个版本不认、静默忽略。
    var ghosttyConfiguration: [(key: String, value: String)] {
        [("scrollback-limit-lines", String(lines)), ("scrollback-limit-bytes", String(bytes))]
    }
}
