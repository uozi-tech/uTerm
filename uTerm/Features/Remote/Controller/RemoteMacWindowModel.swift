import AppKit
import Observation
import UPaneGroups

/// 远程 Mac 窗口的身份：一台 Mac 一个窗口（同一个值再开会带出已有的那个）。
nonisolated struct RemoteMacWindowID: Codable, Hashable, Sendable {
    /// `RemoteMacDirectory.Mac.id`（设备 ID 的字符串）。
    let macID: String
}

/// 远程 Mac 上的一个终端在本机的标签。`id` 就是那台 Mac 上的会话 id。
///
/// 不登记进本机的会话注册表：否则控制这台 Mac 的手机会在列表里看到「别的 Mac 上的终端」，连环接管。
@MainActor
@Observable
final class RemoteTerminalPane: Identifiable {
    let id: UUID
    let session = TerminalSession()
    @ObservationIgnored private let client: RemoteMacClient

    init(id: UUID, client: RemoteMacClient) {
        self.id = id
        self.client = client
    }

    /// 接入（或重新接入）这个终端。第一帧是那台 Mac 发来的快照，接上屏幕就对齐。
    func start() async {
        guard session.connectionState != .connected, session.connectionState != .connecting else { return }
        await session.close()
        await session.connect(using: RemoteTerminalBackend(client: client, sessionID: id))
    }

    /// 关标签 / 关窗口：只断开接入，那台 Mac 上的终端照常运行。
    func dispose() {
        session.closeForDisposal()
    }

    /// 标签上的名字：终端自己设的标题，否则那台 Mac 报的。
    func title(in sessions: [RemoteSessionInfo]) -> String {
        session.shellTitle.map(TerminalArea.clippedTabTitle)
            ?? sessions.first { $0.id == id }?.displayTitle
            ?? String(localized: "终端")
    }
}

/// 那台 Mac 的屏幕在本机的标签。一个窗口最多一个（那台 Mac 同一时间也只推一路画面）。
@MainActor
@Observable
final class RemoteDesktopPane: Identifiable {
    let id = UUID()
    let session: RemoteDesktopSession
    var scaleMode: RemoteDesktopScaleMode = .fit

    init(session: RemoteDesktopSession) {
        self.session = session
    }

    /// 关标签 / 关窗口：停掉这一路画面（那台 Mac 停止采集，帘幕随之撤掉）。
    func dispose() {
        session.stop()
    }

    /// 要多大的画面：按本机最大那块屏幕的像素，至少 1080p。那台 Mac 会按自己显示器的比例套进这个框里。
    static func requestedPixels(screens: [NSScreen] = NSScreen.screens) -> (width: Int, height: Int) {
        var width = 1920, height = 1080
        for screen in screens {
            let scale = screen.backingScaleFactor
            let w = Int(screen.frame.width * scale), h = Int(screen.frame.height * scale)
            width = max(width, max(w, h))
            height = max(height, min(w, h))
        }
        return (width, height)
    }
}

/// 窗口里的一个标签：那台 Mac 上的一个终端，或它的屏幕。
@MainActor
enum RemoteMacPane: Identifiable {
    case terminal(RemoteTerminalPane)
    case desktop(RemoteDesktopPane)

    var id: UUID {
        switch self {
        case .terminal(let pane): return pane.id
        case .desktop(let pane): return pane.id
        }
    }

    var terminal: RemoteTerminalPane? {
        if case .terminal(let pane) = self { return pane }
        return nil
    }

    var desktop: RemoteDesktopPane? {
        if case .desktop(let pane) = self { return pane }
        return nil
    }

    func dispose() {
        switch self {
        case .terminal(let pane): pane.dispose()
        case .desktop(let pane): pane.dispose()
        }
    }
}

/// 一台远程 Mac 的窗口：整台接管它的终端，每个一个标签，之后跟着它增减（`RemoteSessionFollower`）；
/// 另可开一个「屏幕」标签看 / 控它的桌面。
@MainActor
@Observable
final class RemoteMacWindowModel {
    let client: RemoteMacClient
    let groups = UPaneGroupsModel<RemoteMacPane>(policy: UPaneGroupsPolicy(
        splitButtonMaxGroups: nil,
        collapsesEmptyGroups: true,
        allowsLastGroupEmpty: true,
        releasesHiddenEditorFocusOnTabSwitch: true,
        keepAlive: TerminalPaneAreaTuning.keepAlive))
    /// 接管之后的对账；nil = 还没接管（没连上过）。
    @ObservationIgnored private(set) var follower: RemoteSessionFollower?
    private let startTerminal: @MainActor (RemoteTerminalPane) -> Void
    private let makeDesktop: @MainActor (RemoteMacClient) -> RemoteDesktopPane

    /// 终端标签（不含屏幕）。
    var panes: [RemoteTerminalPane] { groups.allTabs.compactMap(\.payload.terminal) }
    var desktop: RemoteDesktopPane? { groups.allTabs.lazy.compactMap(\.payload.desktop).first }
    var active: RemoteMacPane? { groups.activeTab?.payload }
    /// 一个标签也没有（终端、屏幕都没开）。
    var isEmpty: Bool { groups.allTabs.isEmpty }
    var tabCount: Int { groups.allTabs.count }

    init(client: RemoteMacClient,
         startTerminal: @escaping @MainActor (RemoteTerminalPane) -> Void = { pane in Task { await pane.start() } },
         makeDesktop: @escaping @MainActor (RemoteMacClient) -> RemoteDesktopPane = RemoteMacWindowModel.liveDesktop) {
        self.client = client
        self.startTerminal = startTerminal
        self.makeDesktop = makeDesktop
        groups.onTabRemoved = { removed, _ in removed.payload.dispose() }
    }

    /// 真的开流：按本机屏幕要画面大小，建好就开始。
    static func liveDesktop(_ client: RemoteMacClient) -> RemoteDesktopPane {
        let size = RemoteDesktopPane.requestedPixels()
        let pane = RemoteDesktopPane(session: RemoteDesktopSession(client: client, maxWidth: size.width,
                                                                   maxHeight: size.height))
        Task { await pane.session.start() }
        return pane
    }

    /// 打开（或带到前台）屏幕标签。
    func openDesktop() {
        if let pane = desktop, let at = groups.locateTab(pane.id) {
            groups.activateTab(groupID: at.groupID, index: at.index)
            return
        }
        let pane = makeDesktop(client)
        groups.openTab({ UPaneTab(id: pane.id, payload: .desktop(pane)) })
    }

    /// 连上了：接管它上面的全部终端，第一个放前台。重连后再调不重复开。
    func takeOver() {
        guard follower == nil else { return }
        let ids = client.listedSessionIDs ?? client.sessions.map(\.id)
        follower = RemoteSessionFollower(takingOver: ids)
        for id in ids { open(id, activate: false) }
        if let first = ids.first, let at = groups.locateTab(first) {
            groups.activateTab(groupID: at.groupID, index: at.index)
        }
    }

    /// 那台 Mac 的终端列表变了：新开的在后台加标签，关掉的摘标签。nil = 还没收到列表，什么也不动。
    func follow(_ sessionIDs: [UUID]?) {
        guard let sessionIDs, var follower else { return }
        let (gone, fresh) = follower.update(sessionIDs)
        self.follower = follower
        for id in gone { close(id) }
        for id in fresh { open(id, activate: false) }
    }

    /// 在那台 Mac 上新开一个本机终端（它那边也会弹出窗口），开成前台标签。
    func openNewShell(directory: String? = nil) async throws {
        let id = try await client.openLocalShell(directory: directory)
        open(id, activate: true)
    }

    /// 打开（或带到前台）一个终端的标签。已有标签且还接着就不重开；接入已结束的换一个新的。
    func open(_ id: UUID, activate: Bool) {
        if let at = groups.locateTab(id), let pane = groups.tab(id)?.payload.terminal {
            switch pane.session.connectionState {
            case .disconnected, .failed:
                groups.closeTab(groupID: at.groupID, index: at.index)
            default:
                if activate { groups.activateTab(groupID: at.groupID, index: at.index) }
                return
            }
        }
        let pane = RemoteTerminalPane(id: id, client: client)
        startTerminal(pane)
        let tab = UPaneTab(id: id, payload: RemoteMacPane.terminal(pane))
        if activate || groups.allTabs.isEmpty {
            groups.openTab({ tab })
        } else {
            let previous = groups.activeTab?.id
            groups.openTab({ tab })
            if let previous, let at = groups.locateTab(previous) {
                groups.activateTab(groupID: at.groupID, index: at.index)
            }
        }
    }

    /// 关掉本机的标签（只断开，那台 Mac 上照常运行）。
    @discardableResult
    func close(_ id: UUID) -> Bool {
        guard let at = groups.locateTab(id) else { return false }
        groups.closeTab(groupID: at.groupID, index: at.index)
        return true
    }

    /// 连那台 Mac 上的终端一起关（里面的程序也会结束）。标签随列表更新摘掉，这里先摘。
    func closeOnRemote(_ id: UUID) {
        client.closeSessionOnMac(id)
        close(id)
    }

    func disposeAll() {
        for tab in groups.allTabs { tab.payload.dispose() }
        groups.reset()
        follower = nil
    }
}
