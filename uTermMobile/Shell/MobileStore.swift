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

    // MARK: - 连接中页（设计稿 m-connect `ConnectingCover`）

    /// 受保护连接请求：非空时根视图在所有标签之上呈现全屏「连接中」中转页。
    /// 在选定主机与会话/文件浏览打开之间插入一个稳定等待态，防止误触 / 快速返回打断半开连接。
    var connecting: MConnectRequest?
    /// 取消 / 重试时要求终端屏丢弃指定会话 tab 的视图状态（控制器已由 store 关闭）。
    var terminalTeardownID: UUID?
    /// 取消 / 重试时要求文件屏关闭并复位当前 SFTP 会话。
    var sftpTeardownPending = false

    func runCommand(_ cmd: QuickCommand) {
        parallelRun = ParallelRunRequest(commandID: cmd.id, name: cmd.name, command: cmd.command,
                                         intent: cmd.intent, aiAssisted: cmd.aiAssisted, serverIDs: cmd.serverIDs)
    }

    /// 所有「连接主机」入口都走这里：切到目标标签、记录来源、呈现连接中页。
    /// 连接本体随之跑在目标屏（终端 / 文件）里，连接中页观察其真实状态推进阶段。
    func requestConnect(_ host: ServerProfile, kind: MConnectKind, allowDuplicate: Bool = false) {
        guard connecting == nil else { return }   // 中转页已盖住下层，不应再有并发请求
        // 仅 SFTP 主机无法开终端：自动改走文件浏览（否则连接中页会卡在无法绑定的连接态）。
        let resolved: MConnectKind = (kind == .terminal && host.sftpOnly) ? .sftp : kind
        let req = MConnectRequest(host: host, kind: resolved, origin: tab)
        req.allowDuplicate = allowDuplicate
        connecting = req
        switch resolved {
        case .terminal:
            terminalTarget = host.persistentModelID
            tab = .terminal
        case .sftp:
            sftpTarget = host.persistentModelID
            tab = .sftp
        }
    }

    func openTerminal(_ host: ServerProfile) { requestConnect(host, kind: .terminal) }
    func openSFTP(_ host: ServerProfile) { requestConnect(host, kind: .sftp) }

    /// 连接中页跑完（已连接）：撤下中转页，露出目标会话。
    func finishConnect() { connecting = nil }

    /// 长按取消 / 失败返回：关闭刚建立的会话并回到来源页。
    func cancelConnect() {
        guard let req = connecting else { return }
        switch req.kind {
        case .terminal:
            req.terminal?.close()
            terminalTeardownID = req.terminalTabID
            terminalTarget = nil
        case .sftp:
            req.sftp?.close()
            sftpTeardownPending = true
            sftpTarget = nil
        }
        tab = req.origin
        connecting = nil
    }

    /// 失败后重试：在同一控制器上重连，保持中转页（继续观察重连状态）。
    func retryConnect() { connecting?.restart() }
}
