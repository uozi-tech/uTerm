import SwiftUI
import SwiftData
import Observation

/// 主标签（对齐设计稿 `shared.jsx` 的 `TABS`）。
enum MTab: String, CaseIterable, Identifiable {
    case hosts, terminal, sftp, commands, settings
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hosts: return "主机"
        case .terminal: return "终端"
        case .sftp: return "文件"
        case .commands: return "命令"
        case .settings: return "设置"
        }
    }
    var icon: String {
        switch self {
        case .hosts: return "grid"
        case .terminal: return "term"
        case .sftp: return "folder"
        case .commands: return "bolt"
        case .settings: return "gear"
        }
    }
}

/// 全局 UI 状态（Pinia 等价物）。导航、当前标签、活动会话目标。
/// `@Observable` —— SwiftUI 自动追踪读取依赖。
@MainActor
@Observable
final class MobileStore {
    var tab: MTab = .hosts

    /// 终端 tab 当前要连接 / 展示的主机 id。从主机列表「连接」跳转时写入。
    var terminalTarget: PersistentIdentifier?
    /// 文件 tab 当前浏览的主机 id。
    var sftpTarget: PersistentIdentifier?

    /// iPad regular 布局下侧栏选中的主机（详情面板）。
    var inspectedHost: PersistentIdentifier?

    /// 命令面板（⌘K）是否展开。由根视图在所有标签之上呈现（设计稿 `CommandPalette`）。
    var showPalette = false

    /// 命令面板里「新建主机」触发：切到主机标签并弹出新建表单。
    var requestNewServer = false

    /// 并行执行请求（命令详情「运行」发起）。根视图以全屏覆盖呈现（设计稿 `ParallelRun`）。
    var parallelRun: ParallelRunRequest?

    func runCommand(_ cmd: QuickCommand) {
        parallelRun = ParallelRunRequest(commandID: cmd.id, name: cmd.name, command: cmd.command,
                                         intent: cmd.intent, aiAssisted: cmd.aiAssisted, serverIDs: cmd.serverIDs)
    }

    func openTerminal(_ host: ServerProfile) {
        terminalTarget = host.persistentModelID
        tab = .terminal
    }
    func openSFTP(_ host: ServerProfile) {
        sftpTarget = host.persistentModelID
        tab = .sftp
    }
}
