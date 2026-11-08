import SwiftUI
import SwiftData
import Observation

/// 文件浏览会话标签：一台主机 + 独立 `MobileSFTPController`（独立 SFTP 会话，各自记当前目录）。
/// 引用类型，与 `TermTab` 一样放进工作区里跨标签切换 / 分屏移动保活。
@MainActor
@Observable
final class FileTab: Identifiable {
    let id = UUID()
    let host: ServerProfile
    /// 开标签时的主机名：主机被删（本机 / 同步）后、标签关掉前的那一次渲染用它兜底。
    let hostName: String
    let controller: MobileSFTPController

    /// `controller` 默认新建（未建连）；测试注入已经「连上并列好目录」的假会话控制器。
    init(host: ServerProfile, controller: MobileSFTPController = MobileSFTPController()) {
        self.host = host
        self.hostName = host.name
        self.controller = controller
    }
}

/// 工作区里的一个标签：终端会话或文件浏览（多态，对齐 macOS 工作区里终端 / 文件同条标签）。
enum MWorkTab: Identifiable {
    case terminal(TermTab)
    case files(FileTab)

    var id: UUID {
        switch self {
        case .terminal(let t): return t.id
        case .files(let f): return f.id
        }
    }

    var host: ServerProfile {
        switch self {
        case .terminal(let t): return t.host
        case .files(let f): return f.host
        }
    }

    var kind: MConnectKind {
        switch self {
        case .terminal: return .terminal
        case .files: return .sftp
        }
    }

    var terminal: TermTab? {
        if case .terminal(let t) = self { return t }
        return nil
    }

    /// 标签标题：远控终端跟 Mac 上那枚标签同名，其他终端优先用 shell 设置的标题（OSC 0/2），文件浏览用主机名。
    var title: String {
        switch self {
        case .terminal(let t):
            if let title = t.remote?.macTabTitle { return title }
            return t.controller.shellTitle ?? hostName
        case .files: return hostName
        }
    }

    /// 主机名；主机已被删除（等着被 `closeSessions(ofHost:)` 收掉）时用开标签时的快照，
    /// 不去读已删除模型的属性。
    var hostName: String {
        let snapshot: String
        switch self {
        case .terminal(let t): snapshot = t.hostName
        case .files(let f): snapshot = f.hostName
        }
        return host.isDeleted || host.modelContext == nil ? snapshot : host.name
    }

    /// 关闭后的收尾（连接已关）：收键盘、停 Agent 在途任务。主机被删时整批收标签也要走这一步，
    /// 否则 Agent 的模型流和工具循环还会对着已删除的主机跑命令。
    func disposeSession() {
        guard case .terminal(let t) = self else { return }
        t.controller.resignKeyboard()
        t.agent.dispose()
        t.agentTasks.cancelAll()
    }

    /// 断开这个标签的连接（终端 / SFTP）。
    func shutdown() {
        switch self {
        case .terminal(let t): t.controller.close()
        case .files(let f): f.controller.close()
        }
    }
}

/// 一个分屏格：自己的一条标签条 + 一个前台标签（对齐 macOS `UPaneGroups` 的「组」）。
struct MPane: Identifiable, Equatable {
    let id: UUID
    var tabIDs: [UUID] = []
    var activeID: UUID?

    init(id: UUID = UUID()) { self.id = id }
}

/// 接管 Mac 后要交给工作区屏的变化：`opened` 待建连，`removed` 已摘下、待清理。
struct RemoteTabChanges {
    var opened: [TermTab] = []
    var removed: [MWorkTab] = []
}

private struct RemoteFollow {
    let client: RemoteMacClient
    var follower: RemoteSessionFollower
    /// 用户在手机上拖动排过这台 Mac 的标签：之后 Mac 推来的顺序不再覆盖，直到重新接管。
    var arrangedByHand = false
}

/// 移动端工作区：全部会话标签（终端 / 文件）+ 至多两个分屏格 + 聚焦格。
///
/// 由根视图 `MobileRootView` 持有并注入（高于标签栏 ⇄ 侧栏外壳），size class 翻转、
/// 外壳重建时会话与 SSH 连接都不丢。这里只管「哪个标签在哪一格、谁在前台」，
/// 不碰连接生命周期——建连 / 关闭由 `WorkspaceScreen` 做，`close` 把移除的标签交回去清理。
@MainActor
@Observable
final class MobileWorkspace {
    /// 分屏格数上限。手机与 iPad 上两格已够「终端 + 文件」并排，再多每格都太窄。
    static let maxPanes = 2

    private(set) var tabs: [MWorkTab] = []
    private(set) var panes: [MPane]
    /// 接管中的 Mac，以及它的终端列表对账状态。
    private var follows: [RemoteFollow] = []
    private(set) var focusedPaneID: UUID
    /// 第一格占分屏方向的比例（拖动分隔条改它）。
    var splitFraction: CGFloat = 0.5
    /// 用户拖标签到边上选定的分屏方向（`.horizontal` 左右 / `.vertical` 上下）；nil = 按宽度自动。
    /// 这是**偏好**而不是结果：转屏后放不下时 `effectiveAxis` 临时改用另一个方向，
    /// 偏好本身不动，转回来就恢复原样（见 `effectiveAxis(preferred:size:)`）。
    private(set) var splitAxis: Axis?

    /// 左右并排至少要这么宽（每格约 280pt，放得下一屏可用的终端）。
    nonisolated static let sideBySideMinWidth: CGFloat = 560
    /// 上下叠放至少要这么高（每格扣掉标签条与键盘条后仍有终端可看）。
    /// 只在宽度允许并排时才拿它否决叠放，所以竖屏弹出键盘压矮了高度也不会翻成左右。
    nonisolated static let stackedMinHeight: CGFloat = 480

    init() {
        let pane = MPane()
        panes = [pane]
        focusedPaneID = pane.id
    }

    var isEmpty: Bool { tabs.isEmpty }
    var isSplit: Bool { panes.count > 1 }
    var terminalTabs: [TermTab] { tabs.compactMap(\.terminal) }

    var focusedPane: MPane { panes.first { $0.id == focusedPaneID } ?? panes[0] }
    /// 当前活动标签 = 聚焦格的前台标签（键盘、Agent 自动执行都只认它）。
    var activeTab: MWorkTab? { tab(focusedPane.activeID) }

    func tab(_ id: UUID?) -> MWorkTab? {
        guard let id else { return nil }
        return tabs.first { $0.id == id }
    }

    func tabs(in pane: MPane) -> [MWorkTab] { pane.tabIDs.compactMap { tab($0) } }

    func paneIndex(containing tabID: UUID) -> Int? {
        panes.firstIndex { $0.tabIDs.contains(tabID) }
    }

    /// 是否为所在格的前台标签（分屏时两格的前台标签都在屏上）。
    func isFront(_ tabID: UUID) -> Bool {
        guard let i = paneIndex(containing: tabID) else { return false }
        return panes[i].activeID == tabID
    }

    /// 是否为活动标签（聚焦格的前台）。
    func isActive(_ tabID: UUID) -> Bool { focusedPane.activeID == tabID }

    /// 同主机、同类型的已有标签（外部「连接」请求默认复用它而不是再开一个）。
    /// 同主机同类型的已有标签（只看直连的；远控标签接的是 Mac 上的终端，另算）。
    func existing(host: PersistentIdentifier, kind: MConnectKind) -> MWorkTab? {
        tabs.first { $0.kind == kind && $0.host.persistentModelID == host && $0.terminal?.remote == nil }
    }

    /// 已经接入了 Mac 上这个终端的远控标签。
    func existing(remote: MRemoteSource) -> MWorkTab? {
        tabs.first { $0.terminal?.remote == remote }
    }

    /// 接着这台 Mac 上终端的全部标签。
    func remoteTabIDs(of client: RemoteMacClient) -> Set<UUID> {
        Set(terminalTabs.filter { $0.remote?.client === client }.map(\.id))
    }

    /// 接管一台 Mac：每个终端一个标签，开在聚焦格末尾，`focus` 放到前台。之后它新开的终端由 `follow` 接上。
    /// 这里只摆标签：`opened` 由调用方建连，`removed` 由调用方清理。
    func takeOver(_ takeover: MRemoteTakeover) -> RemoteTabChanges {
        follows.removeAll { $0.client === takeover.client }
        follows.append(RemoteFollow(client: takeover.client,
                                    follower: RemoteSessionFollower(takingOver: takeover.sessionIDs)))
        let changes = openRemoteTabs(takeover.client, sessionIDs: takeover.sessionIDs, activate: true)
        arrangeRemoteTabs(of: takeover.client, order: takeover.order)
        if let front = existing(remote: MRemoteSource(client: takeover.client, sessionID: takeover.focus)) {
            activate(front.id)
        }
        return changes
    }

    /// 接管中的 Mac。Mac 上的终端全关了也算，之后新开的还要接上；手动断开才结束（`stopFollowing`）。
    var followedClients: [RemoteMacClient] { follows.map(\.client) }

    func stopFollowing(_ client: RemoteMacClient) {
        follows.removeAll { $0.client === client }
    }

    /// 用户手动断开整台 Mac：不再跟进，返回这台 Mac 的全部标签，由工作区屏关掉并清理。
    func endTakeover(of client: RemoteMacClient) -> Set<UUID> {
        stopFollowing(client)
        return remoteTabIDs(of: client)
    }

    /// 用户亲手关掉这台 Mac 的最后一个标签，等于断开全部，不再跟进。Mac 那边关光的不走这里。
    /// `tab` 是刚从工作区摘下的标签。
    func stopFollowingIfLastTab(_ tab: MWorkTab) {
        guard let client = tab.terminal?.remote?.client, remoteTabIDs(of: client).isEmpty else { return }
        stopFollowing(client)
    }

    /// Mac 的终端列表更新了，手机上的标签跟着它走：
    /// - 没见过的终端在后台开标签，不抢前台。在手机上关掉的不算新的，不会再开回来。
    /// - 列表里出现过、现在没了的终端（在 Mac 上关了、Mac 上的连接断了）关掉标签。之后回来的算新的。
    /// - `order` 是 Mac 上的标签顺序（老版本 Mac 不发，为 nil），这台 Mac 的标签跟着它排（`arrangeRemoteTabs`）。
    /// - `sessionIDs` 为 nil = 这条连接上还没收到列表（刚连上、断开了），不能当成「终端都没了」，什么也不动。
    func follow(_ client: RemoteMacClient, sessionIDs: [UUID]?, order: [UUID]? = nil) -> RemoteTabChanges {
        guard let sessionIDs, let index = follows.firstIndex(where: { $0.client === client }) else {
            return RemoteTabChanges()
        }
        let (gone, fresh) = follows[index].follower.update(sessionIDs)

        var changes = RemoteTabChanges()
        for sessionID in gone {
            guard let tab = existing(remote: MRemoteSource(client: client, sessionID: sessionID)) else { continue }
            close(tab.id)
            changes.removed.append(tab)
        }
        let added = openRemoteTabs(client, sessionIDs: fresh, activate: false)
        changes.opened = added.opened
        changes.removed += added.removed
        arrangeRemoteTabs(of: client, order: order)
        return changes
    }

    /// 这台 Mac 的标签按它上面的顺序排：每一格各排各的，只在这些标签原来占的位置之间换（`RemoteTabArrangement`），
    /// 直连与文件标签、用户挪到另一格的远控标签都留在原处。前台标签和聚焦格不变，正看着的那个不会被切走。
    /// `order` 为 nil（老版本 Mac）时不动。
    /// 用户在手机上亲手排过这台 Mac 的标签（`noteArrangedByHand`）之后也不动，重新接管才恢复。
    func arrangeRemoteTabs(of client: RemoteMacClient, order: [UUID]?) {
        guard let order, follows.first(where: { $0.client === client })?.arrangedByHand != true else { return }
        for index in panes.indices {
            let arranged = RemoteTabArrangement.arranged(panes[index].tabIDs, order: order) { id in
                guard let remote = tab(id)?.terminal?.remote, remote.client === client else { return nil }
                return remote.sessionID
            }
            if arranged != panes[index].tabIDs { panes[index].tabIDs = arranged }
        }
    }

    /// 还接着的标签不动；接入已结束的（被别的设备接管、在 Mac 上断开）换成新标签，不然就是一张死画面。
    private func openRemoteTabs(_ client: RemoteMacClient, sessionIDs: [UUID], activate: Bool) -> RemoteTabChanges {
        var changes = RemoteTabChanges()
        for sessionID in sessionIDs {
            let source = MRemoteSource(client: client, sessionID: sessionID)
            if let current = existing(remote: source) {
                switch current.terminal?.controller.state {
                case .disconnected, .failed:
                    close(current.id)
                    changes.removed.append(current)
                default:
                    continue
                }
            }
            let term = TermTab(host: client.tabHost(for: sessionID), remote: source)
            open(.terminal(term), activate: activate)
            changes.opened.append(term)
        }
        return changes
    }

    // MARK: - 布局

    /// 分屏实际用的方向：偏好放得下就用偏好，放不下换另一个；没偏好时宽够就左右并排。
    /// 两格的先后（左 / 上是第一格）与比例在两个方向间原样对应，转屏来回不会打乱。
    nonisolated static func effectiveAxis(preferred: Axis?, size: CGSize) -> Axis {
        let sideBySide = size.width >= sideBySideMinWidth
        let stacked = size.height >= stackedMinHeight || !sideBySide
        switch preferred {
        case .horizontal?: return sideBySide ? .horizontal : .vertical
        case .vertical?: return stacked ? .vertical : .horizontal
        case nil: return sideBySide ? .horizontal : .vertical
        }
    }

    /// 这块尺寸下能当投放区的边：放不下的方向不给（否则松手后的样子和高亮对不上）。
    nonisolated static func dockableEdges(size: CGSize) -> [Edge] {
        var edges: [Edge] = []
        if effectiveAxis(preferred: .horizontal, size: size) == .horizontal { edges += [.leading, .trailing] }
        if effectiveAxis(preferred: .vertical, size: size) == .vertical { edges += [.top, .bottom] }
        return edges
    }

    // MARK: - 操作

    /// 把新标签放进 `paneID`（缺省聚焦格）末尾，设为前台并聚焦该格。`activate` 为 false 时留在后台，
    /// 除非那一格还没有前台标签。
    func open(_ tab: MWorkTab, in paneID: UUID? = nil, activate: Bool = true) {
        tabs.append(tab)
        let i = panes.firstIndex { $0.id == (paneID ?? focusedPaneID) } ?? 0
        panes[i].tabIDs.append(tab.id)
        guard activate || panes[i].activeID == nil else { return }
        panes[i].activeID = tab.id
        focusedPaneID = panes[i].id
    }

    /// 切到某个标签：设为所在格的前台，并聚焦该格。
    func activate(_ tabID: UUID) {
        guard let i = paneIndex(containing: tabID) else { return }
        panes[i].activeID = tabID
        focusedPaneID = panes[i].id
    }

    func focus(pane id: UUID) {
        guard panes.contains(where: { $0.id == id }) else { return }
        focusedPaneID = id
    }

    /// 移除一个标签，返回它供调用方关连接 / 收键盘。前台标签被关时前台落到右邻（没有就左邻），
    /// 对齐 macOS 标签条；分屏时某格关空了就收起那一格。
    @discardableResult
    func close(_ tabID: UUID) -> MWorkTab? {
        guard let i = paneIndex(containing: tabID),
              let removed = tab(tabID) else { return nil }
        tabs.removeAll { $0.id == tabID }
        let pos = panes[i].tabIDs.firstIndex(of: tabID) ?? 0
        panes[i].tabIDs.remove(at: pos)
        if panes[i].activeID == tabID {
            let ids = panes[i].tabIDs
            panes[i].activeID = ids.isEmpty ? nil : ids[min(pos, ids.count - 1)]
        }
        if panes[i].tabIDs.isEmpty && isSplit { removePane(at: i) }
        return removed
    }

    /// 移除某台主机的全部标签并断开连接，返回被移除的标签 id。
    ///
    /// 主机被删时调用（本机删除前，或 LAN / CloudKit 同步删掉以后）：标签强持着
    /// `ServerProfile`，主机没了以后再读 `host.name` 之类会撞上已删除的模型。
    @discardableResult
    func closeSessions(ofHost host: PersistentIdentifier) -> [UUID] {
        let doomed = tabs.filter { $0.host.persistentModelID == host }
        for tab in doomed {
            close(tab.id)
            tab.shutdown()
            tab.disposeSession()
        }
        return doomed.map(\.id)
    }

    /// 拆出第二格并聚焦它。当前格有两个以上标签时把前台标签移过去（常见的「拖到右边」）；
    /// 只有一个标签时新格留空，由调用方给它开新标签。已分屏时什么也不做。
    func split() {
        guard panes.count < Self.maxPanes else { return }
        let source = panes.firstIndex { $0.id == focusedPaneID } ?? 0
        panes.append(MPane())
        let target = panes.count - 1
        if panes[source].tabIDs.count > 1, let moving = panes[source].activeID {
            move(moving, from: source, to: target)
        }
        focusedPaneID = panes[target].id
    }

    /// 取消分屏：所有标签并回第一格，聚焦格的前台标签仍在前台。
    func unsplit() {
        guard isSplit else { return }
        splitAxis = nil
        let keepActive = focusedPane.activeID ?? panes[0].activeID
        var merged = panes[0]
        for pane in panes.dropFirst() { merged.tabIDs.append(contentsOf: pane.tabIDs) }
        merged.activeID = keepActive
        panes = [merged]
        focusedPaneID = merged.id
    }

    /// 用户亲手把这个标签排到了某个位置：它若是远控标签，这台 Mac 推来的顺序从此不再覆盖手机上的排法，
    /// 直到重新接管（`takeOver` 换一份新的跟进状态）。
    func noteArrangedByHand(_ tabID: UUID) {
        guard let client = tab(tabID)?.terminal?.remote?.client,
              let index = follows.firstIndex(where: { $0.client === client }) else { return }
        follows[index].arrangedByHand = true
    }

    /// 这台 Mac 的标签是否被用户亲手排过。
    func isArrangedByHand(_ client: RemoteMacClient) -> Bool {
        follows.first { $0.client === client }?.arrangedByHand ?? false
    }

    /// 在所在格里把标签挪到第 `index` 位（拖动排序）。前台标签与聚焦格不变，越界时夹到两端。
    func reorder(_ tabID: UUID, to index: Int) {
        guard let pane = paneIndex(containing: tabID),
              let from = panes[pane].tabIDs.firstIndex(of: tabID) else { return }
        var ids = panes[pane].tabIDs
        ids.remove(at: from)
        ids.insert(tabID, at: min(max(index, 0), ids.count))
        if ids != panes[pane].tabIDs { panes[pane].tabIDs = ids }
    }

    /// 拖到另一格的标签条上松手：并进那一格的第 `index` 位，成为那一格的前台并聚焦。原格空了就收起。
    func move(_ tabID: UUID, toPane paneID: UUID, at index: Int) {
        guard let source = paneIndex(containing: tabID),
              let target = panes.firstIndex(where: { $0.id == paneID }),
              source != target else { return }
        move(tabID, from: source, to: target)
        reorder(tabID, to: index)
        focusedPaneID = panes[target].id
        if panes[source].tabIDs.isEmpty { removePane(at: source) }
    }

    /// 把标签挪到另一格（没分屏就先拆出一格）。挪走后原格空了会收起，等同取消分屏。
    func moveToOtherPane(_ tabID: UUID) {
        guard let source = paneIndex(containing: tabID) else { return }
        if !isSplit { panes.append(MPane()) }
        let target = source == 0 ? 1 : 0
        move(tabID, from: source, to: target)
        focusedPaneID = panes[target].id
        if panes[source].tabIDs.isEmpty { removePane(at: source) }
    }

    /// 拖到另一格中间：并进那一格。原格空了就收起。
    func move(_ tabID: UUID, toPane paneID: UUID) {
        guard let source = paneIndex(containing: tabID),
              let target = panes.firstIndex(where: { $0.id == paneID }),
              source != target else { return }
        move(tabID, from: source, to: target)
        focusedPaneID = panes[target].id
        if panes[source].tabIDs.isEmpty { removePane(at: source) }
    }

    /// 能不能把标签拖到边上：要么它所在格还有别的标签（拆出新格），要么已经分屏（换位）。
    func canDock(_ tabID: UUID) -> Bool {
        guard let i = paneIndex(containing: tabID) else { return false }
        return panes[i].tabIDs.count > 1 || isSplit
    }

    /// 拖到工作区某条边上松手：让这个标签所在的格停到那一边。
    /// - 它所在格还有别的标签：没分屏就拆出新格放它；已分屏（两格封顶）就并进另一格。
    /// - 它独占一格（只能是已分屏）：整格换到那一边，即「左右 ⇄ 上下」「左 ⇄ 右」自由换位。
    /// 方向记成偏好（`splitAxis`），转屏时由 `effectiveAxis` 兜底。
    func dock(_ tabID: UUID, to edge: Edge) {
        guard let source = paneIndex(containing: tabID), canDock(tabID) else { return }
        var target = source
        if panes[source].tabIDs.count > 1 {
            if !isSplit { panes.append(MPane()) }
            target = source == 0 ? 1 : 0
            move(tabID, from: source, to: target)
        }
        let wantsFirst = edge == .leading || edge == .top
        if (target == 0) != wantsFirst {
            panes.swapAt(0, 1)
            splitFraction = 1 - splitFraction
            target = 1 - target
        }
        splitAxis = edge == .leading || edge == .trailing ? .horizontal : .vertical
        focusedPaneID = panes[target].id
    }

    private func move(_ tabID: UUID, from source: Int, to target: Int) {
        guard let pos = panes[source].tabIDs.firstIndex(of: tabID) else { return }
        panes[source].tabIDs.remove(at: pos)
        if panes[source].activeID == tabID {
            let ids = panes[source].tabIDs
            panes[source].activeID = ids.isEmpty ? nil : ids[min(pos, ids.count - 1)]
        }
        panes[target].tabIDs.append(tabID)
        panes[target].activeID = tabID
    }

    private func removePane(at index: Int) {
        let removedID = panes[index].id
        panes.remove(at: index)
        if !isSplit { splitAxis = nil }
        if focusedPaneID == removedID { focusedPaneID = panes[0].id }
    }
}
