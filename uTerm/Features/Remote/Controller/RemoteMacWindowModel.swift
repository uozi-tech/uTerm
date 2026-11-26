import Foundation
import Observation
import UPaneGroups

/// 远程 Mac 窗口的身份：一台 Mac 一个窗口（同一个值再开会带出已有的那个）。
nonisolated struct RemoteMacWindowID: Codable, Hashable, Sendable {
    /// `RemoteMacDirectory.Mac.id`（设备 ID 的字符串）。
    let macID: String
}

/// 远程 Mac 上的一个终端在本机的标签。`id` 就是那台 Mac 上的会话 id。
/// 也可能是这扇窗口里的 Code 标签页（`codeTab`，镜像那台 Mac 的 Code 标签页，见 `RemoteMacWindowModel+Code`）：
/// 它不是终端，不接入；里面跑着的会话各有自己的 `RemoteTerminalPane`，不在标签树里。
///
/// 不登记进本机的会话注册表：否则控制这台 Mac 的手机会在列表里看到「别的 Mac 上的终端」，连环接管。
@MainActor
@Observable
final class RemoteTerminalPane: Identifiable {
    let id: UUID
    let session = TerminalSession()
    let codeTab: CodeTabModel?
    @ObservationIgnored private let client: RemoteMacClient

    init(id: UUID, client: RemoteMacClient, codeTab: CodeTabModel? = nil) {
        self.id = id
        self.client = client
        self.codeTab = codeTab
    }

    /// 接入（或重新接入）这个终端。第一帧是那台 Mac 发来的快照，接上屏幕就对齐。
    func start() async {
        guard codeTab == nil, session.connectionState != .connected, session.connectionState != .connecting else { return }
        await session.close()
        // 状态是那台 Mac 推来的：到达时这个标签正看着，就当场算看过（同本机终端），不用等下次获得焦点。
        client.setProgramStatusLooker(id) { [weak session] in session?.isUserLooking ?? false }
        await session.connect(using: RemoteTerminalBackend(client: client, sessionID: id))
    }

    /// 关标签 / 关窗口：只断开接入，那台 Mac 上的终端照常运行。
    func dispose() {
        if let codeTab {
            codeTab.close()
            return
        }
        client.setProgramStatusLooker(id, nil)
        session.closeForDisposal()
    }

    /// 标签上的名字：以那台 Mac 上这枚标签的名字为准（`RemoteSessionInfo.remoteTabTitle`，手机上同一规则）。
    func title(in sessions: [RemoteSessionInfo]) -> String {
        if codeTab != nil { return TerminalArea.codeTabBaseTitle }
        return RemoteSessionInfo.remoteTabTitle(sessions.first { $0.id == id }, shellTitle: session.shellTitle,
                                         fallback: String(localized: "终端"))
    }
}

/// Code 标签页里跑着会话的终端就是一个接着那台 Mac 上那个会话、不在标签树里的远控终端（`RemoteMacWindowModel+Code`）。
/// 程序的起止由那台 Mac 报（`RemoteCodeTabInfo.Run.endedAt`），这边不认。
extension RemoteTerminalPane: CodeTabTerminal {
    func runCodeCommand(_ command: String) { session.typeWhenLineEditorReady(command) }
    var codeCommandHasEnded: Bool { false }
    var codeProgramStatus: ProgramStatusRecord? { client.programReport(for: id) }
}

/// 一台远程 Mac 的窗口：整台接管它的终端，每个一个标签，之后跟着它增减（`RemoteSessionFollower`）。
/// 那台 Mac 报它的 Code 标签页、也认得文件请求时，Code 标签页里跑着的会话不各开标签，开成这扇窗口里的 Code 标签页
/// （`RemoteMacWindowModel+Code`）。
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
    let startTerminal: @MainActor (RemoteTerminalPane) -> Void
    /// 那台 Mac 的 Code 标签页怎么镜像（测试换成假的）。
    let codeHooks: RemoteMacCodeTabHooks
    /// 用户在这扇窗口里关掉的那台 Mac 的 Code 标签页（`RemoteCodeTabInfo.id`）：重新接管之前不再自动开出来，
    /// 里面的会话也不另开终端标签页。
    var closedCodeTabs: Set<UUID> = []
    /// 请那台 Mac 把 Code 标签页里的会话「移到新标签页」之后，等它作为终端标签页开出来时放到前台。
    @ObservationIgnored var frontOnOpen: UUID?

    var panes: [RemoteTerminalPane] { groups.allTabs.map(\.payload) }
    var active: RemoteTerminalPane? { groups.activeTab?.payload }

    init(client: RemoteMacClient, codeHooks: RemoteMacCodeTabHooks = RemoteMacCodeTabHooks(),
         startTerminal: @escaping @MainActor (RemoteTerminalPane) -> Void = { pane in Task { await pane.start() } }) {
        self.client = client
        self.codeHooks = codeHooks
        self.startTerminal = startTerminal
        groups.onTabRemoved = { removed, _ in removed.payload.dispose() }
    }

    /// 连上了：接管它上面的全部终端，第一个放前台。重连后再调不重复开。
    /// 列表本来就按那台 Mac 上的标签顺序发来（老版本 Mac 是打开先后），照着开就是它的顺序。
    /// 那台 Mac 的 Code 标签页里的会话不开标签，开（或接上用户开着的）这扇窗口的 Code 标签页、放进它里面，排在 Mac 上它的位置。
    func takeOver() {
        guard takeover == nil else { return }
        let all = client.listedSessionIDs ?? client.sessions.map(\.id)
        let excluded = codeRunSessionIDs
        let ids = all.filter { !excluded.contains($0) }
        takeover = RemoteTakeoverState(takingOver: ids, listReceived: client.listedSessionIDs != nil)
        closedCodeTabs = []
        let pending = beginCodeTabMirror(listed: Set(all))
        for id in ids { open(id, activate: false) }
        finishCodeTabMirror(pending)
        if let first = ids.first, let at = groups.locateTab(first) {
            groups.activateTab(groupID: at.groupID, index: at.index)
        }
        if client.listedSessionIDs != nil { openFirstShellIfNone(all) }
        if pending != nil, let order = client.sessions.macTabOrder { arrange(by: withCodeTab(order)) }
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
    /// 那台 Mac 的 Code 标签页（`RemoteMacClient.codeTabs`）也跟着它走（`RemoteMacWindowModel+Code`）：先拿掉不再归它的会话、
    /// 再开关终端标签、最后加进新的——同一个会话在同一条连接上不会同时接两次（会互相顶掉）。Mac 上「移到新标签页」的会话
    /// 之后算新的，开成终端标签。
    func follow(_ sessionIDs: [UUID]?, order: [UUID]? = nil) {
        guard let sessionIDs else { return }
        noticeHandReorder()
        guard var takeover else { return }
        let pending = beginCodeTabMirror(listed: Set(sessionIDs))
        let excluded = codeRunSessionIDs
        let update = takeover.update(sessionIDs.filter { !excluded.contains($0) })
        self.takeover = takeover
        if update.firstListIsEmpty { openFirstShellIfNone(sessionIDs) }
        for id in update.gone { close(id) }
        for id in update.fresh { open(id, activate: false) }
        finishCodeTabMirror(pending)
        takeover.noteMacOrder(order.map(withCodeTab), layout: layout)
        self.takeover = takeover
        if let order = takeover.arrangement(order) { arrange(by: withCodeTab(order)) }
        recordLayout()
    }

    /// 各组标签在那台 Mac 的标签顺序里是谁（`orderID(of:)`：终端标签是会话 id，镜像着的 Code 标签页是 Mac 上它的 id），
    /// 按组里的先后。用户自己开的、还没在镜像的 Code 标签页不在里面。
    var layout: [[UUID]] {
        groups.groupIDs.map { groups.groups[$0]?.tabs.compactMap { orderID(of: $0.payload) } ?? [] }
    }

    /// 我们自己挪完标签记一份布局；下次动之前比一比，组里的相对顺序变了就是用户拖过。
    func recordLayout() {
        lastLayout = layout
    }

    private func noticeHandReorder() {
        guard RemoteTabArrangement.reorderedByHand(from: lastLayout, to: layout) else { return }
        takeover?.noteArrangedByHand()
        pushOrderToMac(from: lastLayout)
    }

    /// 用户在这扇窗口里拖过标签：请那台 Mac 照着排。只带相对先后变了的那些组，各组分开发
    ///（不同组之间的先后 Mac 不动，见 `RemoteArrangeSessionsRequest`）。
    private func pushOrderToMac(from previous: [[UUID]]) {
        for group in macOrderPushes(from: previous) { client.arrangeSessionsOnMac(group) }
    }

    /// 要请那台 Mac 照着排的各组（`pushOrderToMac`）：相对先后变了的组，只留会话——Code 标签页不是会话，Mac 不认它的 id。
    func macOrderPushes(from previous: [[UUID]]) -> [[UUID]] {
        let codeTab = codePane?.codeTab?.remote?.macTabID
        return layout.filter { RemoteTabArrangement.reorderedByHand(from: previous, to: [$0]) }
            .map { group in group.filter { $0 != codeTab } }
    }

    /// 标签布局变了（窗口视图观察 `layout` 时调）：用户拖过就马上让那台 Mac 跟着排，不等它下次推列表。
    func layoutChanged() {
        noticeHandReorder()
        recordLayout()
    }

    /// 每个组各排各的，只在组里这些标签原来的位置之间换（`RemoteTabArrangement`）。各组的前台标签和活动组不变，
    /// 正看着的那个不会被切走。
    func arrange(by order: [UUID]) {
        groups.arrangeTabs(by: order) { [weak self] in self?.orderID(of: $0.payload) }
    }

    /// 在那台 Mac 上新开一个本机终端（它那边也会弹出窗口），开成前台标签。返回那台 Mac 上的会话 id。
    @discardableResult
    func openNewShell(directory: String? = nil) async throws -> UUID {
        let id = try await client.openLocalShell(directory: directory)
        noticeHandReorder()
        open(id, activate: true)
        recordLayout()
        return id
    }

    /// 「继续这个会话」（Claude 历史会话）：在那台 Mac 上新开本机终端，开在项目目录里，接上、行编辑器起来之后打进命令。
    /// 命令照样带 `cd`：那台 Mac 开不进这个目录（被删了、没权限）时退回主目录，不能在别的目录里起 Claude Code。
    func resumeAgentSession(directory: String, command: String) async throws {
        let id = try await openNewShell(directory: directory)
        groups.tab(id)?.payload.session.typeWhenLineEditorReady(command)
    }

    /// 打开（或带到前台）一个终端的标签。已有标签且还接着就不重开；接入已结束的换一个新的。
    func open(_ id: UUID, activate: Bool) {
        // 已经镜像在 Code 标签页里：再开一个就是同一个会话在同一条连接上接两次，两边互相顶掉。
        if codePane?.codeTab?.runs.contains(where: { $0.id == id && $0.isMirrored }) == true { return }
        var activate = activate
        if frontOnOpen == id {
            frontOnOpen = nil
            activate = true
        }
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

    /// 关掉本机的标签（只断开，那台 Mac 上照常运行）。关的是镜像着那台 Mac 的 Code 标签页：只停镜像（里面的会话照常跑），
    /// 重新接管之前不再自动开出来。
    @discardableResult
    func close(_ id: UUID) -> Bool {
        guard let at = groups.locateTab(id) else { return false }
        if let macTab = groups.tab(id)?.payload.codeTab?.remote?.macTabID { closedCodeTabs.insert(macTab) }
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
        closedCodeTabs = []
        frontOnOpen = nil
    }
}
