import Foundation
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
        // 状态是那台 Mac 推来的：到达时这个标签正看着，就当场算看过（同本机终端），不用等下次获得焦点。
        client.setProgramStatusLooker(id) { [weak session] in session?.isUserLooking ?? false }
        await session.connect(using: RemoteTerminalBackend(client: client, sessionID: id))
    }

    /// 关标签 / 关窗口：只断开接入，那台 Mac 上的终端照常运行。
    func dispose() {
        client.setProgramStatusLooker(id, nil)
        session.closeForDisposal()
    }

    /// 标签上的名字：以那台 Mac 上这枚标签的名字为准（`RemoteSessionInfo.remoteTabTitle`，手机上同一规则）。
    func title(in sessions: [RemoteSessionInfo]) -> String {
        RemoteSessionInfo.remoteTabTitle(sessions.first { $0.id == id }, shellTitle: session.shellTitle,
                                         fallback: String(localized: "终端"))
    }
}

/// 一台远程 Mac 的窗口：整台接管它的终端，每个一个标签，之后跟着它增减（`RemoteSessionFollower`）。
/// 屏幕不在这里，单独开一扇窗口（`RemoteDesktopWindow`）。
@MainActor
@Observable
final class RemoteMacWindowModel {
    let client: RemoteMacClient
    let groups = UPaneGroupsModel<RemoteTerminalPane>(policy: UPaneGroupsPolicy(
        splitButtonMaxGroups: nil,
        collapsesEmptyGroups: true,
        allowsLastGroupEmpty: true,
        releasesHiddenEditorFocusOnTabSwitch: true,
        keepAlive: TerminalPaneAreaTuning.keepAlive))
    /// 接管之后的对账（两端共用的 `RemoteTakeoverState`）；nil = 还没接管（没连上过）。
    private(set) var takeover: RemoteTakeoverState?
    /// 上次自己摆完标签时各组的顺序：下次对账前比一比，看用户有没有亲手拖过（`UPaneGroups` 没有拖动排序的回调）。
    @ObservationIgnored private var lastLayout: [[UUID]] = []
    /// 正在自动新建第一个终端（防重入）。
    private var isOpeningFirstShell = false
    /// 刚连上、第一个标签还没就位：界面显示「正在打开终端」，不闪一下「没有打开的终端」的空态。
    var isPreparingFirstShell: Bool { takeover?.awaitingFirstList == true || isOpeningFirstShell }
    /// 用户亲手排过这台 Mac 的标签：之后它推来的顺序不再覆盖，直到重新接管。
    var isArrangedByHand: Bool { takeover?.arrangedByHand ?? false }
    private let startTerminal: @MainActor (RemoteTerminalPane) -> Void

    var panes: [RemoteTerminalPane] { groups.allTabs.map(\.payload) }
    var active: RemoteTerminalPane? { groups.activeTab?.payload }

    init(client: RemoteMacClient,
         startTerminal: @escaping @MainActor (RemoteTerminalPane) -> Void = { pane in Task { await pane.start() } }) {
        self.client = client
        self.startTerminal = startTerminal
        groups.onTabRemoved = { removed, _ in removed.payload.dispose() }
    }

    /// 连上了：接管它上面的全部终端，第一个放前台。重连后再调不重复开。
    /// 列表本来就按那台 Mac 上的标签顺序发来（老版本 Mac 是打开先后），照着开就是它的顺序。
    func takeOver() {
        guard takeover == nil else { return }
        let ids = client.listedSessionIDs ?? client.sessions.map(\.id)
        takeover = RemoteTakeoverState(takingOver: ids, listReceived: client.listedSessionIDs != nil)
        for id in ids { open(id, activate: false) }
        if let first = ids.first, let at = groups.locateTab(first) {
            groups.activateTab(groupID: at.groupID, index: at.index)
        }
        if client.listedSessionIDs != nil { openFirstShellIfNone(ids) }
        recordLayout()
    }

    /// 打开窗口时那台 Mac 上一个终端都没有：直接新建一个，不让人对着空态再点一次「新建终端」。
    /// 只在接管时做一次——之后用户把标签关光了，就是想要空着，不再自动开。老版本 Mac 不能新建，照旧显示空态；
    /// 新建失败也退回空态，按钮还在。
    private func openFirstShellIfNone(_ ids: [UUID]) {
        guard ids.isEmpty, client.supportsLocalShell, !isOpeningFirstShell else { return }
        isOpeningFirstShell = true
        Task {
            defer { isOpeningFirstShell = false }
            do { try await openNewShell() } catch {
                AppLogger.notice("远程 Mac 窗口：自动新建第一个终端失败：\(error.localizedDescription)", category: RemoteLog.category)
            }
        }
    }

    /// 那台 Mac 的终端列表变了：新开的在后台加标签，关掉的摘标签，按它上面的顺序排（`order`，老版本 Mac 不发）。
    /// nil = 还没收到列表，什么也不动。
    /// 用户在这扇窗口里亲手拖过这台 Mac 的标签之后，不再跟着它的顺序排（同手机，直到重新接管）。
    func follow(_ sessionIDs: [UUID]?, order: [UUID]? = nil) {
        guard let sessionIDs else { return }
        noticeHandReorder()
        guard var takeover else { return }
        let update = takeover.update(sessionIDs)
        self.takeover = takeover
        if update.firstListIsEmpty { openFirstShellIfNone(sessionIDs) }
        for id in update.gone { close(id) }
        for id in update.fresh { open(id, activate: false) }
        if let order = takeover.arrangement(order) { arrange(by: order) }
        recordLayout()
    }

    /// 各组标签的顺序。
    private var layout: [[UUID]] {
        groups.groupIDs.map { groups.groups[$0]?.tabs.map(\.id) ?? [] }
    }

    /// 我们自己挪完标签记一份布局；下次动之前比一比，组里的相对顺序变了就是用户拖过。
    private func recordLayout() {
        lastLayout = layout
    }

    private func noticeHandReorder() {
        guard RemoteTabArrangement.reorderedByHand(from: lastLayout, to: layout) else { return }
        takeover?.noteArrangedByHand()
    }

    /// 每个组各排各的，只在组里这些标签原来的位置之间换（`RemoteTabArrangement`）。各组的前台标签和活动组不变，
    /// 正看着的那个不会被切走。
    func arrange(by order: [UUID]) {
        let fronts = groups.groupIDs.compactMap { id in groups.groups[id]?.activeTab.map { (group: id, tab: $0.id) } }
        let activeGroup = groups.activeGroupID
        var moved = false
        for groupID in groups.groupIDs {
            guard let current = groups.groups[groupID]?.tabs.map(\.id) else { continue }
            let arranged = RemoteTabArrangement.arranged(current, order: order) { $0 }
            for (index, id) in arranged.enumerated() {
                guard let tabs = groups.groups[groupID]?.tabs, tabs[index].id != id else { continue }
                groups.reorderTab(id, before: tabs[index].id)
                moved = true
            }
        }
        guard moved else { return }
        // `reorderTab` 会把挪动的标签切到前台：还回去，活动组最后还，它才是最终的活动组。
        for front in fronts.filter({ $0.group != activeGroup }) + fronts.filter({ $0.group == activeGroup }) {
            if let at = groups.locateTab(front.tab) { groups.activateTab(groupID: at.groupID, index: at.index) }
        }
    }

    /// 在那台 Mac 上新开一个本机终端（它那边也会弹出窗口），开成前台标签。
    func openNewShell(directory: String? = nil) async throws {
        let id = try await client.openLocalShell(directory: directory)
        noticeHandReorder()
        open(id, activate: true)
        recordLayout()
    }

    /// 打开（或带到前台）一个终端的标签。已有标签且还接着就不重开；接入已结束的换一个新的。
    func open(_ id: UUID, activate: Bool) {
        if let at = groups.locateTab(id), let pane = groups.tab(id)?.payload {
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
        let tab = UPaneTab(id: id, payload: pane)
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
        for pane in panes { pane.dispose() }
        groups.reset()
        takeover = nil
        lastLayout = []
    }
}
