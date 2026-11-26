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
    /// 终端里的程序请求预览的文件（只读，见 `FilePreviewTab`）。
    case preview(FilePreviewTab)
    /// 一台主机上编码工具（Claude Code、Codex 等）的历史会话（只读，见 `ClaudeHistoryTab`）。
    case history(ClaudeHistoryTab)

    var id: UUID {
        switch self {
        case .terminal(let t): return t.id
        case .files(let f): return f.id
        case .preview(let p): return p.id
        case .history(let h): return h.id
        }
    }

    var host: ServerProfile {
        switch self {
        case .terminal(let t): return t.host
        case .files(let f): return f.host
        case .preview(let p): return p.host
        case .history(let h): return h.host
        }
    }

    /// 预览、历史标签也算文件一类（读的是文件）；「打开主机」复用已有标签时不认它们（`existing(host:kind:)`）。
    var kind: MConnectKind {
        switch self {
        case .terminal: return .terminal
        case .files, .preview, .history: return .sftp
        }
    }

    var terminal: TermTab? {
        if case .terminal(let t) = self { return t }
        return nil
    }

    var preview: FilePreviewTab? {
        if case .preview(let p) = self { return p }
        return nil
    }

    var history: ClaudeHistoryTab? {
        if case .history(let h) = self { return h }
        return nil
    }

    /// 标签标题：远控终端以 Mac 上那枚标签的名字为准（`RemoteSessionInfo.remoteTabTitle`，Mac 控 Mac 同一规则），
    /// 其他终端优先用 shell 设置的标题（OSC 0/2），文件浏览用主机名。
    var title: String {
        switch self {
        case .terminal(let t):
            if let remote = t.remote {
                return RemoteSessionInfo.remoteTabTitle(remote.sessionInfo, shellTitle: t.controller.shellTitle,
                                                        fallback: hostName)
            }
            return t.controller.shellTitle ?? hostName
        case .files, .history: return hostName
        case .preview(let p): return p.title
        }
    }

    /// 主机名；主机已被删除（等着被 `closeSessions(ofHost:)` 收掉）时用开标签时的快照，
    /// 不去读已删除模型的属性。
    var hostName: String {
        let snapshot: String
        switch self {
        case .terminal(let t): snapshot = t.hostName
        case .files(let f): snapshot = f.hostName
        case .preview(let p): snapshot = p.hostName
        case .history(let h): snapshot = h.hostName
        }
        return host.isDeleted || host.modelContext == nil ? snapshot : host.name
    }

    /// 关闭后的收尾（连接已关）：收键盘、停 Agent 在途任务。主机被删时整批收标签也要走这一步，
    /// 否则 Agent 的模型流和工具循环还会对着已删除的主机跑命令。Code 标签页里的会话在 `shutdown`（`close`）里
    /// 已经一个个收过了。
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
        case .preview(let p): p.controller.close()
        // Code 标签页：里面跑着的会话一起结束。
        case .history(let h): h.close()
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
    /// 列表对账与「用户亲手排过」（两端共用的 `RemoteTakeoverState`）。
    var state: RemoteTakeoverState
    /// 用户在手机上关掉的 Mac Code 标签页（`RemoteCodeTabInfo.id`）：重新接管之前不再自动开出来，里面的会话也不另开终端标签页。
    var closedCodeTabs: Set<UUID> = []
}

/// 镜像 Mac 的 Code 标签页时第一步做完、等第二步加进来的会话（见 `follow`）。
private struct PendingCodeRuns {
    let tab: ClaudeHistoryTab
    let info: RemoteCodeTabInfo
    let added: [RemoteCodeTabInfo.Run]
    /// 刚开出来：照 Mac 那边看着的选一次。
    let adoptsSelection: Bool
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
    /// 每一格的键盘意愿，按格 id 记（见 `keyboardIntent(forPane:)`）。
    @ObservationIgnored private var keyboardIntents: [UUID: MTerminalKeyboardIntent] = [:]
    /// 开出来时要放到前台的 Mac 会话（手机上请 Mac 把 Code 标签页里的会话「移到新标签页」：Mac 推来新的列表之后它才成了
    /// 终端标签页，见 `bringToFront(remote:)`）。开出来就清掉。
    @ObservationIgnored private var frontOnOpen: MRemoteSource?
    /// 终端里的程序请求预览一个文件（`TerminalFilePreview`）：工作区屏建预览标签（它有建 SFTP 会话要的容器）。
    @ObservationIgnored var onFilePreviewRequest: ((TermTab, String) -> Void)?

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

    /// 全部活终端连同它所在的格：终端标签页，加上 Code 标签页里跑着的会话（`ClaudeHistoryTab.runs`）。
    /// 键盘归属、实时活动、归档按它算，Code 标签页里的会话照终端标签页那样算。
    var allTerminals: [(term: TermTab, paneID: UUID)] {
        var result: [(TermTab, UUID)] = []
        for pane in panes {
            for tab in tabs(in: pane) {
                switch tab {
                case .terminal(let term): result.append((term, pane.id))
                case .history(let code): result += code.runTerminals.map { ($0, pane.id) }
                case .files, .preview: break
                }
            }
        }
        return result
    }

    /// 带到前台：终端标签页直接切过去；Code 标签页里的会话切到那个标签页、详情换成它的终端（深链接、通知用）。
    /// 找不到返回 false。
    @discardableResult
    func revealTerminal(_ id: UUID) -> Bool {
        if tab(id) != nil {
            activate(id)
            return true
        }
        for code in tabs.compactMap(\.history) {
            guard let run = code.runs.runs.first(where: { $0.terminal.id == id }) else { continue }
            activate(code.id)
            code.focusRun(run.id)
            return true
        }
        return false
    }

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
        tabs.first {
            $0.kind == kind && $0.host.persistentModelID == host && $0.terminal?.remote == nil && $0.preview == nil
                && $0.history == nil
        }
    }

    /// 已经接入了 Mac 上这个终端的远控标签。
    func existing(remote: MRemoteSource) -> MWorkTab? {
        tabs.first { $0.terminal?.remote == remote }
    }

    /// 接着 Mac 上这个终端的终端与它所在的标签：远控终端标签页，或者镜像着那台 Mac 的 Code 标签页里的会话。
    func remoteTerminal(_ source: MRemoteSource) -> (tabID: UUID, term: TermTab)? {
        if let tab = existing(remote: source), let term = tab.terminal { return (tab.id, term) }
        if let code = existingHistory(remoteMac: source.client), let term = code.mirroredTerminal(session: source.sessionID) {
            return (code.id, term)
        }
        return nil
    }

    /// 把接着 Mac 上这个会话的终端标签页放到前台；还没开出来（Mac 推来的列表还没到）就等它开出来时放（`openRemoteTabs`）。
    func bringToFront(remote source: MRemoteSource) {
        if let tab = existing(remote: source) {
            frontOnOpen = nil
            activate(tab.id)
        } else {
            frontOnOpen = source
        }
    }

    /// 镜像着这台 Mac 的 Code 标签页的那个标签页。
    func mirroredCodeTab(of client: RemoteMacClient) -> ClaudeHistoryTab? {
        existingHistory(remoteMac: client).flatMap { $0.mirroredMacTabID != nil ? $0 : nil }
    }

    /// 这台 Mac 的文件标签（一台 Mac 至多一个）。
    func existing(remoteFiles client: RemoteMacClient) -> MWorkTab? {
        tabs.first {
            if case .files(let files) = $0 { return files.controller.remoteMac === client }
            return false
        }
    }

    /// 接着这台 Mac 的全部标签：它上面的终端，加上它的文件标签与历史会话标签。
    func remoteTabIDs(of client: RemoteMacClient) -> Set<UUID> {
        var ids = Set(terminalTabs.filter { $0.remote?.client === client }.map(\.id))
        if let files = existing(remoteFiles: client) { ids.insert(files.id) }
        if let history = existingHistory(remoteMac: client) { ids.insert(history.id) }
        return ids
    }

    /// 直连这台主机的历史会话标签（一台主机至多一个）。
    func existingHistory(host: PersistentIdentifier) -> ClaudeHistoryTab? {
        tabs.lazy.compactMap(\.history).first { $0.remoteMac == nil && $0.host.persistentModelID == host }
    }

    /// 这台 Mac 的历史会话标签（一台 Mac 至多一个）。
    func existingHistory(remoteMac client: RemoteMacClient) -> ClaudeHistoryTab? {
        tabs.lazy.compactMap(\.history).first { $0.remoteMac === client }
    }

    /// 打开历史会话标签：同一台主机（同一台 Mac）已经有了就带到前台、返回已有的那个，没有就开在聚焦格并开始读。
    @discardableResult
    func openHistory(_ history: ClaudeHistoryTab) -> ClaudeHistoryTab {
        let existing = history.remoteMac.map { existingHistory(remoteMac: $0) }
            ?? existingHistory(host: history.host.persistentModelID)
        if let existing {
            activate(existing.id)
            return existing
        }
        open(.history(history))
        history.start()
        return history
    }

    /// 终端标签长按「历史会话」：切到 / 新开这台主机（远控标签是那台 Mac）的 Code 标签页，开在聚焦格；直连主机定位到
    /// 终端当前目录那一组（已经开着的再定位一次，可能已经滚走、折起来了）。不能读历史会话的标签（体验主机、老版本的 Mac）返回 nil。
    @discardableResult
    func showCode(for term: TermTab, container: ModelContainer) -> ClaudeHistoryTab? {
        guard term.offersClaudeHistory else { return nil }
        if let remote = term.remote { return openHistory(ClaudeHistoryTab(pairedMac: remote.client)) }
        let directory = term.claudeHistoryDirectory
        let fresh = ClaudeHistoryTab(server: term.host, directory: directory, container: container)
        let opened = openHistory(fresh)
        if opened !== fresh { opened.reveal(directory: directory) }
        return opened
    }

    /// 接管一台 Mac：每个终端一个标签，开在聚焦格末尾，`focus` 放到前台。之后它新开的终端由 `follow` 接上。
    /// 这里只摆标签：`opened` 由调用方建连，`removed` 由调用方清理。
    ///
    /// Mac 报了它的 Code 标签页（63 号消息）时，里面跑着的会话不各开终端标签页，而是开（或接上已有的）这台 Mac 的 Code 标签页、
    /// 放进它里面；`focus` 是其中一个时切到 Code 标签页、详情换成它。
    func takeOver(_ takeover: MRemoteTakeover) -> RemoteTabChanges {
        let client = takeover.client
        follows.removeAll { $0.client === client }
        let excluded = client.codeRunSessionIDs
        let sessionIDs = takeover.sessionIDs.filter { !excluded.contains($0) }
        follows.append(RemoteFollow(client: client, state: RemoteTakeoverState(takingOver: sessionIDs)))
        var changes = RemoteTabChanges()
        let listed = Set(takeover.sessionIDs).union(client.listedSessionIDs ?? [])
        let pending = beginCodeTabMirror(client, listed: listed, changes: &changes)
        let opened = openRemoteTabs(client, sessionIDs: sessionIDs, activate: true)
        changes.opened += opened.opened
        changes.removed += opened.removed
        finishCodeTabMirror(pending, client: client, changes: &changes)
        arrangeRemoteTabs(of: client, order: takeover.order)
        if let front = remoteTerminal(MRemoteSource(client: client, sessionID: takeover.focus)) {
            activate(front.tabID)
            tab(front.tabID)?.history?.selectMirroredRun(takeover.focus)
            // 「继续这个会话」：新开的那个终端接上之后打进命令。
            if let command = takeover.focusCommand { front.term.controller.typeWhenLineEditorReady(command) }
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
        let mirroring = tab.history.flatMap { $0.mirroredMacTabID != nil ? $0.remoteMac : nil }
        guard let client = tab.terminal?.remote?.client ?? mirroring, remoteTabIDs(of: client).isEmpty else { return }
        stopFollowing(client)
    }

    /// 用户在手机上关掉了镜像 Mac Code 标签页的那个标签页：只断开镜像（Mac 上的会话照旧），重新接管之前不再自动开出来。
    /// Mac 那边关掉、跟着收掉的不走这里。`tab` 是刚从工作区摘下的标签。
    func noteClosedByUser(_ tab: MWorkTab) {
        guard let code = tab.history, let macTab = code.mirroredMacTabID, let client = code.remoteMac,
              let index = follows.firstIndex(where: { $0.client === client }) else { return }
        follows[index].closedCodeTabs.insert(macTab)
    }

    /// Mac 的终端列表更新了，手机上的标签跟着它走：
    /// - 没见过的终端在后台开标签，不抢前台。在手机上关掉的不算新的，不会再开回来。
    /// - 列表里出现过、现在没了的终端（在 Mac 上关了、Mac 上的连接断了）关掉标签。之后回来的算新的。
    /// - `order` 是 Mac 上的标签顺序（老版本 Mac 不发，为 nil），这台 Mac 的标签跟着它排（`arrangeRemoteTabs`）。
    /// - `sessionIDs` 为 nil = 这条连接上还没收到列表（刚连上、断开了），不能当成「终端都没了」，什么也不动。
    /// - Mac 报了它的 Code 标签页（`RemoteMacClient.codeTabs`）：里面跑着的会话不当终端标签页，由这台 Mac 的 Code 标签页
    ///   镜像（`ClaudeHistoryTab+Mirror`）；Mac 上挪出 Code 标签页的会话之后算新的，开成终端标签页。
    ///   先拿掉不再归 Code 标签页的、再开关终端标签页、最后加进新的：同一个会话在同一条连接上不会同时接两次。
    func follow(_ client: RemoteMacClient, sessionIDs: [UUID]?, order: [UUID]? = nil) -> RemoteTabChanges {
        guard let sessionIDs, let index = follows.firstIndex(where: { $0.client === client }) else {
            return RemoteTabChanges()
        }
        var changes = RemoteTabChanges()
        let pending = beginCodeTabMirror(client, listed: Set(sessionIDs), changes: &changes)
        let excluded = client.codeRunSessionIDs
        let update = follows[index].state.update(sessionIDs.filter { !excluded.contains($0) })
        let (gone, fresh) = (update.gone, update.fresh)

        for sessionID in gone {
            guard let tab = existing(remote: MRemoteSource(client: client, sessionID: sessionID)) else { continue }
            close(tab.id)
            changes.removed.append(tab)
        }
        let added = openRemoteTabs(client, sessionIDs: fresh, activate: false)
        changes.opened += added.opened
        changes.removed += added.removed
        finishCodeTabMirror(pending, client: client, changes: &changes)
        if let index = follows.firstIndex(where: { $0.client === client }) {
            follows[index].state.noteMacOrder(order.map { withCodeTab($0, of: client) }, layout: remoteLayout(of: client))
        }
        arrangeRemoteTabs(of: client, order: order)
        return changes
    }

    // MARK: - 镜像 Mac 的 Code 标签页

    /// 第一步：Mac 上的 Code 标签页（`RemoteCodeTabInfo`，取 `mirrored()` 那一个）要镜像就确保有这台 Mac 的 Code 标签页
    /// （有用户自己开的就接上它，没有就在后台开一个）；拿掉不再归它的会话、其余照 Mac 改。Mac 上没有了：镜像开出来的关掉，
    /// 用户自己开的留着、只停镜像。用户在手机上关过的不再开。还没收到 Mac 的 Code 标签页（老 Mac、刚连上）什么都不动。
    private func beginCodeTabMirror(_ client: RemoteMacClient, listed: Set<UUID>,
                                    changes: inout RemoteTabChanges) -> PendingCodeRuns? {
        guard let index = follows.firstIndex(where: { $0.client === client }), let tabs = client.codeTabs else { return nil }
        let existing = existingHistory(remoteMac: client)
        guard let info = tabs.mirrored(), !follows[index].closedCodeTabs.contains(info.id) else {
            if let existing, existing.mirroredMacTabID != nil {
                if existing.opensForMirror, tabs.mirrored() == nil {
                    close(existing.id)
                    changes.removed.append(.history(existing))
                } else {
                    existing.stopMirroring()
                }
            }
            return nil
        }
        let code: ClaudeHistoryTab
        let isNew: Bool
        if let existing {
            code = existing
            isNew = false
        } else {
            code = ClaudeHistoryTab(pairedMac: client)
            code.opensForMirror = true
            // 开在这台 Mac 的标签所在的那一格（还没有就是聚焦格），不抢前台。
            let ids = remoteTabIDs(of: client)
            open(.history(code), in: panes.first { pane in pane.tabIDs.contains(where: ids.contains) }?.id, activate: false)
            code.start()
            isNew = true
        }
        code.mirroredMacTabID = info.id
        let plan = code.mirrorPlan(info, listed: listed)
        code.removeMirroredRuns(plan.removed)
        code.applyMirrorUpdates(plan.updated)
        return PendingCodeRuns(tab: code, info: info, added: plan.added, adoptsSelection: isNew)
    }

    /// 第二步：加进 Mac 上新出现的会话（它们的终端交给工作区屏去连）；刚开出来的照 Mac 那边看着的选一次。
    private func finishCodeTabMirror(_ pending: PendingCodeRuns?, client: RemoteMacClient, changes: inout RemoteTabChanges) {
        guard let pending else { return }
        changes.opened += pending.tab.addMirroredRuns(pending.added, client: client)
        if pending.adoptsSelection { pending.tab.adoptMacSelection(of: pending.info) }
    }

    /// Mac 的标签顺序里插进 Code 标签页（按它报的 `slot`），镜像着它的那个标签页跟着排。没镜像、没报位置时原样。
    private func withCodeTab(_ order: [UUID], of client: RemoteMacClient) -> [UUID] {
        guard let info = client.codeTabs?.mirrored(), info.slot != nil,
              mirroredCodeTab(of: client)?.mirroredMacTabID == info.id else { return order }
        return order.insertingCodeTabs([(info.id, info.slot)])
    }

    /// 这个标签在 Mac 的标签顺序里是谁：远控终端标签是它接着的会话，镜像着这台 Mac 的 Code 标签页是 Mac 上那个 Code 标签页。
    private func remoteOrderID(of id: UUID, client: RemoteMacClient) -> UUID? {
        guard let tab = tab(id) else { return nil }
        if let remote = tab.terminal?.remote, remote.client === client { return remote.sessionID }
        if let code = tab.history, code.remoteMac === client { return code.mirroredMacTabID }
        return nil
    }

    /// 这台 Mac 的标签按它上面的顺序排：每一格各排各的，只在这些标签原来占的位置之间换（`RemoteTabArrangement`），
    /// 直连与文件标签、用户挪到另一格的远控标签都留在原处。前台标签和聚焦格不变，正看着的那个不会被切走。
    /// `order` 为 nil（老版本 Mac）时不动。
    /// 用户在手机上亲手排过这台 Mac 的标签（`noteArrangedByHand`）之后也不动，重新接管才恢复。
    func arrangeRemoteTabs(of client: RemoteMacClient, order: [UUID]?) {
        guard let order = follows.first(where: { $0.client === client })?.state.arrangement(order) else { return }
        let full = withCodeTab(order, of: client)
        for index in panes.indices {
            let arranged = RemoteTabArrangement.arranged(panes[index].tabIDs, order: full) { id in
                remoteOrderID(of: id, client: client)
            }
            if arranged != panes[index].tabIDs { panes[index].tabIDs = arranged }
        }
    }

    /// 每一格里这台 Mac 的标签（会话 id、镜像的 Code 标签页是 Mac 上它的 id，按格里的先后）。
    private func remoteLayout(of client: RemoteMacClient) -> [[UUID]] {
        panes.map { pane in pane.tabIDs.compactMap { remoteOrderID(of: $0, client: client) } }
    }

    /// 还接着的标签不动；接入已结束的（被别的设备接管、在 Mac 上断开）换成新标签，不然就是一张死画面。
    private func openRemoteTabs(_ client: RemoteMacClient, sessionIDs: [UUID], activate: Bool) -> RemoteTabChanges {
        var changes = RemoteTabChanges()
        for sessionID in sessionIDs {
            let source = MRemoteSource(client: client, sessionID: sessionID)
            // 已经镜像在这台 Mac 的 Code 标签页里：再开一个就是同一个会话在同一条连接上接两次，两边互相顶掉。
            if existingHistory(remoteMac: client)?.mirroredTerminal(session: sessionID) != nil { continue }
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
            let front = frontOnOpen == source
            if front { frontOnOpen = nil }
            open(.terminal(term), activate: activate || front)
            changes.opened.append(term)
        }
        return changes
    }

    // MARK: - 键盘

    /// 这一格的键盘意愿：用户在这一格里收起过键盘没有。格里的终端标签共用一份——切标签时键盘该在就在、
    /// 该收着就收着，终端不用因为键盘升降改尺寸（每改一次，里面的程序就整屏重画一遍）。分屏的两格各记各的。
    func keyboardIntent(forPane id: UUID) -> MTerminalKeyboardIntent {
        if let intent = keyboardIntents[id] { return intent }
        let intent = MTerminalKeyboardIntent()
        keyboardIntents[id] = intent
        return intent
    }

    /// 把键盘交给 `owner`（nil = 谁都不该拿），返回键盘是不是已经在它手上。
    ///
    /// 键盘正在别的终端标签上时，先让新归属者接手、再收回其他标签的归属：第一响应者直接换主，键盘不经过
    /// 「收起 → 再弹出」（中间那一下会让新旧两个终端各改一次尺寸、各重画一遍）。新归属者接不了（它那一格的键盘
    /// 是收着的、没连上、视图还没进窗口）就和以前一样：别的标签当场收键盘，之后由调用方再聚焦一次。
    @discardableResult
    func handKeyboard(to owner: TermTab?) -> Bool {
        let placed = allTerminals
        let terminals = placed.map(\.term)
        for (term, paneID) in placed {
            term.controller.keyboardIntent = keyboardIntent(forPane: paneID)
        }
        if let owner, terminals.contains(where: { $0 !== owner && $0.controller.keyboardShown }) {
            owner.controller.ownsKeyboard = true
            owner.controller.focusKeyboard()
        }
        for term in terminals { term.controller.ownsKeyboard = term === owner }
        return owner?.controller.keyboardShown ?? false
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
    /// 除非那一格还没有前台标签。`typing`：终端连上、行编辑器起来之后打进这行命令（「继续这个会话」）。
    func open(_ tab: MWorkTab, in paneID: UUID? = nil, activate: Bool = true, typing command: String? = nil) {
        if let command { tab.terminal?.controller.typeWhenLineEditorReady(command) }
        if let term = tab.terminal, term.remote == nil {
            term.controller.onFilePreviewRequest = { [weak self, weak term] path in
                guard let self, let term else { return }
                self.onFilePreviewRequest?(term, path)
            }
        }
        tabs.append(tab)
        let i = panes.firstIndex { $0.id == (paneID ?? focusedPaneID) } ?? 0
        panes[i].tabIDs.append(tab.id)
        guard activate || panes[i].activeID == nil else { return }
        panes[i].activeID = tab.id
        focusedPaneID = panes[i].id
        // 新开到前台的终端默认弹键盘（用户是来打字的），哪怕这一格之前收起过。
        if tab.terminal != nil { keyboardIntent(forPane: panes[i].id).collapsed = false }
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

    /// 同主机的预览标签（一台主机至多一个）。
    func existingPreview(host: PersistentIdentifier) -> FilePreviewTab? {
        tabs.lazy.compactMap(\.preview).first { $0.host.persistentModelID == host }
    }

    /// 把预览标签放到 `term` 旁边，键盘焦点留在终端那一格（用户还在和终端里的程序对话）。
    ///
    /// 已分屏：放进终端不在的那一格；没分屏：拆出第二格放它。已经开着（换了内容的那个）：带到它那一格的前台，
    /// 它要是和终端挤在同一格，挪到另一格。
    func placePreview(_ preview: FilePreviewTab, beside term: TermTab) {
        let focused = focusedPaneID
        let termPane = paneIndex(containing: term.id)
        if let at = paneIndex(containing: preview.id) {
            if at == termPane, let other = otherPane(than: at) ?? splitOff() {
                move(preview.id, from: at, to: other)
            }
        } else {
            let target = termPane.flatMap { otherPane(than: $0) ?? splitOff() } ?? 0
            tabs.append(.preview(preview))
            panes[target].tabIDs.append(preview.id)
        }
        if let at = paneIndex(containing: preview.id) { panes[at].activeID = preview.id }
        if panes.contains(where: { $0.id == focused }) { focusedPaneID = focused }
    }

    private func otherPane(than index: Int) -> Int? {
        panes.indices.first { $0 != index }
    }

    /// 拆出一个空的第二格（不改聚焦）；已经两格了返回 nil。
    private func splitOff() -> Int? {
        guard panes.count < Self.maxPanes else { return nil }
        panes.append(MPane())
        return panes.count - 1
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
        keyboardIntents = keyboardIntents.filter { $0.key == merged.id }
    }

    /// 用户亲手把这个标签排到了某个位置：它若是远控标签，这台 Mac 推来的顺序从此不再覆盖手机上的排法，
    /// 直到重新接管（`takeOver` 换一份新的跟进状态）或 Mac 的顺序和手机上的对上（`noteMacOrder`）。
    /// 同时请 Mac 照它所在那一格的先后排（支持的 Mac 排完推回新顺序，手机随之重新跟着 Mac）。
    func noteArrangedByHand(_ tabID: UUID) {
        let mirroring = tab(tabID)?.history.flatMap { $0.mirroredMacTabID != nil ? $0.remoteMac : nil }
        guard let client = tab(tabID)?.terminal?.remote?.client ?? mirroring,
              let index = follows.firstIndex(where: { $0.client === client }) else { return }
        follows[index].state.noteArrangedByHand()
        guard let pane = paneIndex(containing: tabID) else { return }
        // 只交会话：Code 标签页不是会话，Mac 排的时候也不认它。
        let codeTab = mirroredCodeTab(of: client)?.mirroredMacTabID
        client.arrangeSessionsOnMac(remoteLayout(of: client)[pane].filter { $0 != codeTab })
    }

    /// 这台 Mac 的标签是否被用户亲手排过。
    func isArrangedByHand(_ client: RemoteMacClient) -> Bool {
        follows.first { $0.client === client }?.state.arrangedByHand ?? false
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
        keyboardIntents[removedID] = nil
        if !isSplit { splitAxis = nil }
        if focusedPaneID == removedID { focusedPaneID = panes[0].id }
    }
}
