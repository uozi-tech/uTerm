import Foundation

/// 终端引擎的版本：画面（GhosttyKit）和影子终端（libghostty-vt）是同一棵源码树编的两份二进制，二进制快照的格式、
/// 回放出来的画面都跟着这棵树走。两端（远控的 Mac 与接入的设备、存检查点的那次运行与接回的这次运行）版本串不同，
/// 快照就不能互认：远控改发回放流（`RemoteTerminalReplay`，对端是不认它的老版本时拒绝镜像并提示更新），holder 检查点改用退出时另存的回放流（见 `TerminalCheckpointBlob`）。
///
/// vt 自己报的版本串（`ShadowTerminal.buildVersion`）这个版本只有「0.1.0-dev」，区分不了提交和补丁，所以这里手写。
/// **换引擎的任何一个二进制（换 Ghostty 提交、加减引擎补丁）时必须改这个串**，并且和 `vendor/libghostty-spm/ENGINE.lock` 的
/// `engine_version` 一字不差——`TerminalEngineLockTests` 读那份清单来核，忘了改会失败。步骤见 `vendor/libghostty-spm/UTERM-PATCHES.md`。
nonisolated enum TerminalEngineVersion {
    /// Ghostty 提交 + 引擎补丁的最大编号 + 快照格式的修订号。
    static let current = "ghostty-56de3f0f+p0026/snapshot-1"

    /// 快照和后一个版本互认的旧版本：旧版本 → 新版本。
    ///
    /// 只改渲染的补丁（GhosttyKit 的 `src/renderer`、`Surface.zig`、`apprt`；libghostty-vt 不编这些）不动快照格式，
    /// 换了这种补丁时把旧串记在这里，旧版本存的 holder 检查点照常接回、两端照常镜像。**动了 `src/terminal`、换了 Ghostty
    /// 提交、快照修订号加了一，都不能记**（宁可走回放流也别拿另一种格式去解）。每一条都要能一路走到 `current`，
    /// 键和值的 Ghostty 提交、快照修订号必须相同（`TerminalEngineLockTests` 核这两条）。
    ///
    /// 2026-11-24 换了 Ghostty 提交（`5ebe501a` → `56de3f0f`，上游 libghostty-spm `2.2.2026112401`），之前的
    /// `5ebe501a+p0023` / `+p0024` 都不再互认。旧版本存的检查点走回放流接回；远控镜像对着旧引擎改发回放流，对端不认回放流（更早的版本）时要两端一起更新。
    /// 同一天加了 0025（空闲后的第一帧当场画，只动 `src/renderer/Thread.zig`）：`p0024` 和它互认。
    /// 2026-11-25 加了 0026（按键的回显那一帧也当场画，同一个文件）：`p0025` 和它互认。
    static let sameSnapshotFormat: [String: String] = [
        "ghostty-56de3f0f+p0024/snapshot-1": "ghostty-56de3f0f+p0025/snapshot-1",
        "ghostty-56de3f0f+p0025/snapshot-1": "ghostty-56de3f0f+p0026/snapshot-1",
    ]

    /// 两个版本存的快照能不能互相解。对称：远控进程拿手机报的版本和 App 报的版本比，两边谁新谁旧都有可能。
    static func snapshotsCompatible(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || canonical(lhs) == canonical(rhs)
    }

    /// 顺着 `sameSnapshotFormat` 走到底。有环（表写错了）时停在走过的地方，不死循环。
    private static func canonical(_ version: String) -> String {
        var version = version
        var seen: Set<String> = [version]
        while let next = sameSnapshotFormat[version], seen.insert(next).inserted {
            version = next
        }
        return version
    }
}

// 单独成文件、不依赖 GhosttyKit：远控进程（`uTermRemoteHost`）不链接终端引擎，也要知道 App 用的是哪个版本。
