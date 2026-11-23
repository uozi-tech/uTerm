import SwiftUI
import SwiftData

/// 一个终端窗格：绑定一台服务器，持有一条终端会话（`TerminalSession`）。
@MainActor
@Observable
final class PaneModel: Identifiable {
    let id: UUID
    let serverProfileID: UUID
    let fileBuffer: FileBuffer?
    /// Code 标签页（`CodeTabModel`）：不是终端，`session` 不用；里面跑着的会话各有自己的 `PaneModel`，不在标签树里。
    let codeTab: CodeTabModel?
    /// 打开时定下的标签名（服务器名），随工作区快照存盘。标签上优先显示 shell 设的标题
    /// （`session.shellTitle`），它只是没有 shell 标题时的回落。
    let tabTitle: String?
    let session = TerminalSession()
    /// 终端连接的 host-key 审批桥接。
    let hostKeyRelay = HostKeyChallengeRelay()
    private var isConnecting = false
    /// 打开时的时间戳，存进 holder：重启后布局里没有这条会话（旧版写的归属）时按它排先后。
    @ObservationIgnored private let sessionOrder: Double
    /// 所在窗口最近一次的布局，跟归属一起存进 holder：重启后按它放回标签的位置与分屏。
    @ObservationIgnored private var layout: HeldSessionLayout?

    /// 跨窗口会话注册的凭条（CLI 的 `terminals` / `terminal-read` / `terminal-send`）。
    /// 由 `WorkspaceModel.attachSessionRegistry` 在窗口视图注入注册表后 stamp；
    /// 没 stamp（单测 / 预览）时全部 no-op。是接线不是状态，故 `@ObservationIgnored`。
    @ObservationIgnored var registrar: TerminalSessionRegistrar?

    /// 上次连接成功时那台服务器的名字。注册表要它当 `serverName` / `title`，
    /// 而 `PaneModel` 只存 `serverProfileID` —— 连上时顺手记一份，
    /// 供「先连上、后注入注册表」的窗口补登记（`adopt(registrar:)`）。
    @ObservationIgnored private(set) var connectedServerName: String?

    init(id: UUID = UUID(), serverProfileID: UUID, fileBuffer: FileBuffer? = nil, codeTab: CodeTabModel? = nil,
         tabTitle: String? = nil, sessionOrder: Double = Date().timeIntervalSince1970) {
        self.id = id
        self.sessionOrder = sessionOrder
        self.serverProfileID = serverProfileID
        self.fileBuffer = fileBuffer
        self.codeTab = codeTab
        self.tabTitle = tabTitle
        // 连接状态是注册表里「这条会话还活着吗」的唯一真值：远端退出（`exitStream`
        // 把状态翻到 `.disconnected`）之后必须注销，否则 `terminals` 一直列着它，
        // `terminal-read` 一直回同一张冻结的画面、`terminal-send` 往死连接里写。
        session.onConnectionStateChange = { [weak self] state in
            self?.syncRegistration(for: state)
        }
    }

    /// 是终端标签（不是文件、不是 Code 标签页）。只有它连主机、登记、进保持进程的布局。
    var isTerminal: Bool { fileBuffer == nil && codeTab == nil }

    /// 按连接状态同步跨窗口注册表：`.connected` 登记，其余一律注销。
    /// 重连成功会重新登记（`connectedAt` 也随之更新）。
    private func syncRegistration(for state: TerminalSession.ConnectionState) {
        guard isTerminal, let registrar else { return }
        guard state == .connected else {
            registrar.unregister(paneID: id)
            return
        }
        guard let name = connectedServerName else { return }
        registrar.register(paneID: id,
                           serverID: serverProfileID,
                           serverName: name,
                           session: session)
    }

    /// 用给定的服务器配置发起连接。
    func connect(profile: ServerProfile, modelContainer: ModelContainer) async {
        guard isTerminal else { return }
        guard !isConnecting else { return }
        // 重访标签时窗格会重新进入视图层级触发 connect；已连接/连接中则视为 no-op。
        guard session.connectionState != .connected,
              session.connectionState != .connecting else { return }
        isConnecting = true
        defer { isConnecting = false }

        await session.close()
        let timeline = ConnectTimeline(kind: "terminal", target: profile.timingTarget)
        await ConnectTimeline.$current.withValue(timeline) {
            await connect(profile: profile, modelContainer: modelContainer, timeline: timeline)
        }
    }

    private func connect(profile: ServerProfile,
                         modelContainer: ModelContainer,
                         timeline: ConnectTimeline) async {
        // 名字先记下来：`session.connect` 里状态一翻到 `.connected`，
        // `onConnectionStateChange` 就会立刻回调 `syncRegistration`，
        // 那时必须已经有 `connectedServerName` 可用。
        connectedServerName = profile.name
        defer { SSHSessionRestorer.shared.settled(id) }
        do {
            // 辅助程序出了问题也不能连不上服务器：退回到 App 进程内的连接，只是活不过重启。
            let endpoint = Self.endpointKey(profile)
            let viaHelper = !Self.inProcessEndpoints.contains(endpoint)
            if viaHelper, (try? await LocalShellService.shared.client.ping()) != nil {
                let held = makeHeldBackend(profile: profile, modelContainer: modelContainer)
                timeline.mark("backend")
                await session.connect(using: held)
                // `uterm-ssh` 是自己的「责任进程」，局域网权限单独问；用户拒绝或没回答时它一直路由不可达。
                // App 自己的权限通常早有了：这台主机本次运行改走进程内连接，免得每开一个标签都等一轮重试。
                guard case .failed = session.connectionState, await held.failedOnLocalNetwork else {
                    registerIfConnected(profile)
                    return
                }
                Self.inProcessEndpoints.insert(endpoint)
                AppLogger.error("终端辅助程序连不到局域网（权限未授予？），这台主机改走 App 进程内连接", category: "ssh")
            } else if viaHelper {
                AppLogger.error("终端辅助程序不可用，这条 SSH 连接留在 App 进程内", category: "ssh")
            }
            let backend = try await SSHConnection.make(profile: profile, container: modelContainer,
                                                       approver: hostKeyRelay.makeApprover())
            timeline.mark("backend")
            await session.connect(using: backend)
            registerIfConnected(profile)
        } catch {
            timeline.finish("failed")
            session.markFailed("\(error)")
        }
    }

    /// 连上了才登记 —— `terminals` 列的是「能读能写的活会话」，
    /// 连接中 / 已失败的窗格对 CLI 没有意义。钩子通常已经登记过了，
    /// 这一次是幂等兜底（同 id 重复登记 = 原地更新）。
    private func registerIfConnected(_ profile: ServerProfile) {
        guard session.connectionState == .connected else { return }
        registrar?.register(paneID: id, serverID: profile.id, serverName: profile.name, session: session)
    }

    /// 本次运行里辅助程序连不到局域网的主机（`host:port`），之后直接走进程内连接。不持久化：
    /// 用户去系统设置里放行后，重启 uTerm 就回到能活过重启的连接。
    private static var inProcessEndpoints: Set<String> = []

    private static func endpointKey(_ profile: ServerProfile) -> String {
        "\(profile.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()):\(profile.port)"
    }

    private func makeHeldBackend(profile: ServerProfile, modelContainer: ModelContainer) -> HeldSSHBackend {
        let size = session.currentProcessSize
        return HeldSSHBackend(
            client: LocalShellService.shared.client, sessionID: id, columns: Int(size.cols), rows: Int(size.rows),
            target: .make(profile: profile, container: modelContainer, approver: hostKeyRelay.makeApprover()),
            attributes: sessionAttributes(title: profile.name))
    }

    /// 重启后据此把标签放回原来的窗口。窗口还没把凭条发下来时是 nil，`adopt(registrar:)` 时补。
    private func sessionAttributes(title: String?) -> Data? {
        heldAttributes(title: title).flatMap { try? JSONEncoder().encode($0) }
    }

    func heldAttributes(title: String? = nil) -> SSHSessionAttributes? {
        guard let registrar else { return nil }
        return SSHSessionAttributes(
            windowID: registrar.windowID, windowKind: registrar.windowKind, serverID: serverProfileID,
            title: tabTitle ?? title ?? "", order: sessionOrder, layout: layout)
    }

    /// 窗口布局变了。已经交给 holder 的会话立刻改写归属；还没建连的等 `makeHeldBackend` 时一起带上。
    func updateLayout(_ layout: HeldSessionLayout) {
        guard isTerminal else { return }
        self.layout = layout
        guard let backend = session.backend as? HeldSSHBackend,
              let attributes = sessionAttributes(title: connectedServerName) else { return }
        backend.sendAttributes(attributes)
    }

    /// 窗口把注册表凭条补发下来时调用（窗口视图的 `.task` 可能晚于窗格建连）。
    /// 已经连上的窗格立刻补登记，未连上的等 `connect` 走正常路径。
    func adopt(registrar: TerminalSessionRegistrar) {
        guard isTerminal else { return }
        self.registrar = registrar
        if let backend = session.backend as? HeldSSHBackend, let attributes = sessionAttributes(title: connectedServerName) {
            Task { await backend.setAttributes(attributes) }
        }
        guard session.connectionState == .connected, let name = connectedServerName else { return }
        registrar.register(paneID: id,
                           serverID: serverProfileID,
                           serverName: name,
                           session: session)
    }

    /// 服务器配置已不存在时调用。
    func markServerMissing() {
        guard isTerminal else { return }
        session.markFailed(String(localized: "主机已被删除"))
    }

    /// 窗格被关闭/移除时调用。
    func dispose() {
        if let codeTab {
            codeTab.close()
            return
        }
        guard isTerminal else { return }
        registrar?.unregister(paneID: id)
        session.closeForDisposal()
        hostKeyRelay.abandon()
    }
}

/// Code 标签页里跑着会话的终端就是一个不在标签树里的 `PaneModel`（见 `WorkspaceModel.makeCodeRun`）。
extension PaneModel: CodeTabTerminal {
    func runCodeCommand(_ command: String) { session.startCodeCommand(command) }
    var codeCommandHasEnded: Bool { session.codeCommandHasEnded }
}
