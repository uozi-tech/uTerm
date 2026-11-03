import SwiftUI
import SwiftData
import Observation

/// 主标签（对齐设计稿 `shared.jsx` 的 `TABS`）。终端与文件浏览不占标签：从「主机」进入，
/// 在盖住标签栏的全屏工作区里打开（多态标签 + 分屏，见 `MobileWorkspace` / `WorkspaceScreen`）。
enum MTab: String, CaseIterable, Identifiable {
    case hosts, commands, settings
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hosts: return "主机"
        case .commands: return "命令"
        case .settings: return "设置"
        }
    }
    var icon: String {
        switch self {
        case .hosts: return "grid"
        case .commands: return "bolt"
        case .settings: return "gear"
        }
    }
}

/// 一次「在工作区打开主机」的请求。`token` 让同一台主机的连续请求也能被 `onChange` 看到。
struct MOpenTarget: Equatable {
    let hostID: PersistentIdentifier
    let kind: MConnectKind
    /// 非 nil：经 Mac 接入它上面的终端，而不是直连主机。
    var remote: MRemoteSource? = nil
    let token = UUID()
}

/// 全局 UI 状态（Pinia 等价物）。导航、当前标签、活动会话目标。
/// `@Observable` —— SwiftUI 自动追踪读取依赖。
@MainActor
@Observable
final class MobileStore {
    var tab: MTab = .hosts

    /// 会话工作区是否盖在标签之上。返回主机列表时只是收起，会话不断。
    var showWorkspace = false

    /// 待工作区消费的打开请求（终端或文件浏览）。从主机列表 / 命令面板「连接」时写入。
    var openTarget: MOpenTarget?

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
    /// 取消时要求工作区移除指定会话标签（控制器已由 store 关闭）。
    var teardownTabID: UUID?

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
        req.originInWorkspace = showWorkspace
        connecting = req
        openTarget = MOpenTarget(hostID: host.persistentModelID, kind: resolved)
        showWorkspace = true
    }

    func openTerminal(_ host: ServerProfile) { requestConnect(host, kind: .terminal) }

    /// 接入 Mac 上一个正在运行的终端（远控）。`host` 是本机同步过来的同一台主机，只用来显示与归类。
    func openRemoteTerminal(_ host: ServerProfile, source: MRemoteSource) {
        guard connecting == nil else { return }
        let req = MConnectRequest(host: host, kind: .terminal, origin: tab)
        req.remote = source
        req.originInWorkspace = showWorkspace
        connecting = req
        openTarget = MOpenTarget(hostID: host.persistentModelID, kind: .terminal, remote: source)
        showWorkspace = true
    }
    func openSFTP(_ host: ServerProfile) { requestConnect(host, kind: .sftp) }

    /// 连接中页跑完（已连接）：撤下中转页，露出目标会话。
    func finishConnect() { connecting = nil }

    /// 长按取消 / 失败返回：关闭刚建立的会话并回到来源页。
    func cancelConnect() {
        guard let req = connecting else { return }
        req.terminal?.close()
        req.sftp?.close()
        teardownTabID = req.tabID
        openTarget = nil
        showWorkspace = req.originInWorkspace
        tab = req.origin
        connecting = nil
    }

    /// 失败后重试：在同一控制器上重连，保持中转页（继续观察重连状态）。
    func retryConnect() { connecting?.restart() }
}
