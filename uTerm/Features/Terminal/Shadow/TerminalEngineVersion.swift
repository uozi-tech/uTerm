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
    static let current = "ghostty-5ebe501a+p0024/snapshot-1"
}

// 单独成文件、不依赖 GhosttyKit：远控进程（`uTermRemoteHost`）不链接终端引擎，也要知道 App 用的是哪个版本。
