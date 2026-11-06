import UDesignKit
import SwiftUI
import SwiftData

/// 会话工作区：终端与文件浏览同在一条标签条里（多态标签），可拆成两格并排分屏。
/// 由根视图常驻挂载、全屏盖住标签栏（`store.showWorkspace` 控制展开 / 收起）；
/// 「返回」只是收起回到主机列表，会话不断，主机页的「会话 N」再展开。
///
/// 连接流程不变：主机列表 / 命令面板 / 「+」都走 `store.requestConnect`，连接中页盖在上面，
/// 这里消费 `store.openTarget` 建会话、开标签，并把控制器回填给连接中页观察。
struct WorkspaceScreen: View {
    @Environment(\.mChrome) private var chrome
    @Environment(MobileStore.self) private var store
    @Environment(HostKeyChallengeRelay.self) private var relay
    @Environment(MobileWorkspace.self) private var workspace
    @Environment(RemoteMacDirectory.self) private var remoteMacs: RemoteMacDirectory?
    @Environment(\.modelContext) private var context
    @Environment(\.mAccent) private var accent
    @Query(sort: [SortDescriptor(\ServerProfile.sortOrder)]) private var hosts: [ServerProfile]

    /// 新建会话抽屉要开的类型（「+」菜单选的）。
    @State private var newKind: MConnectKind?
    @State private var dragging = false
    /// 正被拖着的标签（拖拽开始时由标签条报上来）。投放端直接读它，不去异步解包载荷。
    @State private var draggingTabID: UUID?
    /// 拖拽悬停处松手的结果，驱动投放高亮。
    @State private var dropTarget: MDropTarget?
    /// 新建抽屉里已选了主机、连接中页还没盖上来的那一小段（抽屉收起后 0.3s 才发起连接）。
    /// 期间 UIKit 会把抽屉弹出前的第一响应者（旧标签的终端）恢复回来，必须算作「没人拥有键盘」。
    @State private var awaitingConnect = false
    /// 关标签前的确认流程（弹窗挂在对应标签上，见 `WorkspaceTabChip`）。
    @State private var closeFlow = MTabCloseFlow()

    private var visible: Bool { store.showWorkspace }

    var body: some View {
        ZStack {
            // 只在连接请求刚到、标签还没开出来的一瞬为空（连接中页正盖着），什么也不画。
            if !(workspace.isEmpty && !workspace.isSplit) { panesView }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Duo 展开竖屏：状态栏只占顶行右端，整条顶行却都是安全区——工作区伸进顶行，
        // 贴顶的标签条与状态栏同一行（标签条自己让出状态栏，见 mAvoidsStatusBar）。
        .ignoresSafeArea(.container, edges: chrome.statusRowHeight != nil ? .top : [])
        // Duo 折叠 / 展开横屏：状态栏在右侧一列的顶部，下面空着——Agent / 分屏开关放到那里。
        .overlay(alignment: .topTrailing) {
            if let column = chrome.statusColumn, !(workspace.isEmpty && !workspace.isSplit) {
                WorkspaceSideControls(
                    // 远控标签没有 Agent（同标签条，见 WorkspaceTabStrip）。
                    agentOn: focusedFrontTerminal.flatMap { $0.remote == nil ? $0.mode == .agent : nil },
                    isSplit: workspace.isSplit,
                    onAgent: { toggleAgent(in: workspace.focusedPane) },
                    onToggleSplit: toggleSplit)
                    .frame(width: column.width)
                    .padding(.top, column.statusBottom)
                    .offset(x: column.width)
            }
        }
        .onChange(of: store.openTarget) { _, t in consume(t) }
        .onChange(of: store.remoteTakeover) { _, t in consume(t) }
        .onChange(of: followedSessionIDs) { _, _ in followRemoteSessions() }
        .task(id: workspace.followedClients.map(ObjectIdentifier.init)) { await keepFollowedMacsConnected() }
        .onAppear {
            consume(store.openTarget)
            consume(store.remoteTakeover)
        }
        .onChange(of: workspace.activeTab?.id) { _, _ in syncKeyboard() }
        .onChange(of: workspace.focusedPaneID) { _, _ in syncKeyboard() }
        // 收起回主机列表（会话不断）时收起键盘，否则键盘会残留在标签页之上；展开时重新聚焦。
        .onChange(of: store.showWorkspace) { _, _ in syncKeyboard() }
        // 连接中页盖上即收回所有键盘归属；撤下（连接完成）后再弹——建连期刻意不弹。
        .onChange(of: store.connecting?.id) { _, _ in syncKeyboard() }
        .onChange(of: newKind) { _, _ in syncKeyboard() }
        .onChange(of: awaitingConnect) { _, _ in syncKeyboard() }
        // 连接中页取消、断开整台 Mac：关掉并移除这些标签。
        .onChange(of: store.teardownTabIDs) { _, ids in
            guard !ids.isEmpty else { return }
            for id in ids {
                guard let removed = workspace.close(id) else { continue }
                removed.shutdown()
                dispose(removed)
                workspace.stopFollowingIfLastTab(removed)
            }
            if workspace.isEmpty { store.showWorkspace = false }
            store.teardownTabIDs = []
        }
        // 主机被同步删掉（LAN 覆盖 / 别的设备经 CloudKit 删除）：收掉它的会话标签。
        // 本机在主机页删除时 HostsScreen 会先收，这里兜的是同步路径。
        .onChange(of: Set(hosts.map(\.persistentModelID))) { _, live in
            // 跳过远控标签：它挂的是不入库的临时主机，本来就不在列表里，不是被删了。
            // 不能按 modelContext 判：被同步删掉的主机 modelContext 也会变 nil，那正是要收掉的。
            let orphaned = Set(workspace.tabs.filter { $0.terminal?.remote == nil }.map { $0.host.persistentModelID })
                .subtracting(live)
            guard !orphaned.isEmpty else { return }
            for host in orphaned {
                let closed = workspace.closeSessions(ofHost: host)
                if let req = store.connecting, let tabID = req.tabID, closed.contains(tabID) {
                    store.connecting = nil
                }
            }
            syncKeyboard()
            if workspace.isEmpty { store.showWorkspace = false }
        }
        .sheet(item: $newKind) { kind in newTabSheet(kind).mSheetContentMargins() }
    }

    // MARK: - 打开 / 关闭

    /// 外部「打开主机」请求（来自主机列表 / 详情 / 命令面板 / 「+」）：
    /// 默认聚焦同主机同类型的已有标签，`allowDuplicate` 时总是新开一个，开在聚焦格里。
    private func consume(_ target: MOpenTarget?) {
        guard let target else { return }
        store.openTarget = nil
        guard let host = hosts.first(where: { $0.persistentModelID == target.hostID }),
              !(target.kind == .terminal && host.sftpOnly) else {
            // 找不到主机 / 仅 SFTP 却要终端：撤下正在等待绑定的连接中页，避免空转卡死。
            if let req = store.connecting, req.tabID == nil, req.host.persistentModelID == target.hostID {
                store.cancelConnect()
            }
            return
        }
        if !(store.connecting?.allowDuplicate ?? false),
           let existing = workspace.existing(host: target.hostID, kind: target.kind) {
            workspace.activate(existing.id)
            bindConnecting(existing)   // 已有会话（多半已连）：让连接中页据其状态立即收尾
            return
        }
        let tab: MWorkTab
        switch target.kind {
        case .terminal:
            let term = TermTab(host: host)
            term.controller.start(profile: host, container: context.container, relay: relay)
            tab = .terminal(term)
        case .sftp:
            let files = FileTab(host: host)
            files.controller.start(profile: host, container: context.container, relay: relay)
            tab = .files(files)
        }
        workspace.open(tab)
        bindConnecting(tab)
    }

    /// 接管 Mac：把它上面的全部终端开成标签并建连，连接中页跟踪放到前台的那个。
    private func consume(_ takeover: MRemoteTakeover?) {
        guard let takeover else { return }
        store.remoteTakeover = nil
        let changes = workspace.takeOver(takeover)
        apply(changes)
        guard let req = store.connecting else { return }
        let focus = MRemoteSource(client: takeover.client, sessionID: takeover.focus)
        let front = workspace.existing(remote: focus)
        req.tabID = front?.id
        req.terminal = front?.terminal?.controller
        req.companionTabIDs = changes.opened.map(\.id).filter { $0 != front?.id }
    }

    /// 接管中的 Mac 的终端列表。nil = 这条连接上还没收到，不能当成「终端都没了」。
    private var followedSessionIDs: [[UUID]?] {
        workspace.followedClients.map(\.listedSessionIDs)
    }

    /// Mac 上开关了终端：手机上的标签跟着开关。
    private func followRemoteSessions() {
        for client in workspace.followedClients {
            apply(workspace.follow(client, sessionIDs: client.listedSessionIDs))
        }
    }

    /// 终端全关时没有标签，也就没有后端负责重连：由这里连回去，才收得到之后新开的终端。
    private func keepFollowedMacsConnected() async {
        guard !workspace.followedClients.isEmpty else { return }
        while !Task.isCancelled {
            for client in workspace.followedClients where client.canAutoReconnect {
                await client.connect()
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func apply(_ changes: RemoteTabChanges) {
        changes.removed.forEach(finishClosing)
        for term in changes.opened {
            term.controller.start(profile: term.host, container: context.container, relay: relay)
        }
        // 最后一个会话没了就没有可看的了：收回主机列表。
        if workspace.isEmpty { store.showWorkspace = false }
    }

    /// 若此次开标签由连接中页发起，把控制器回填给请求，供连接中页观察真实状态并推进阶段。
    private func bindConnecting(_ tab: MWorkTab) {
        guard let req = store.connecting, req.kind == tab.kind, req.tabID == nil,
              req.host.persistentModelID == tab.host.persistentModelID else { return }
        req.tabID = tab.id
        switch tab {
        case .terminal(let t): req.terminal = t.controller
        case .files(let f): req.sftp = f.controller
        }
    }

    /// 用户要关一个标签：要不要先问由 `MTabCloseFlow` 裁决。
    private func requestClose(_ id: UUID) {
        guard let tab = workspace.tab(id) else { return }
        closeFlow.request(tab, close: closeTab)
    }

    private func confirmClose(_ id: UUID, alsoOnMac: Bool) {
        if alsoOnMac, let remote = workspace.tabs.first(where: { $0.id == id })?.terminal?.remote {
            remote.client.closeSessionOnMac(remote.sessionID)
        }
        closeTab(id)
    }

    private func closeTab(_ id: UUID) {
        guard let removed = workspace.close(id) else { return }
        finishClosing(removed)
        workspace.stopFollowingIfLastTab(removed)
        // 关掉最后一个会话就没有可看的了：收回主机列表。
        if workspace.isEmpty { store.showWorkspace = false }
    }

    /// 标签已从工作区摘下：断连接，撤掉跟它绑定的连接中页，清理视图侧。
    private func finishClosing(_ tab: MWorkTab) {
        tab.shutdown()
        // 分屏时连接中页只盖这一格，标签条仍可点：用户直接关掉正在建连的标签时，
        // 那张连接中页随标签消失、再没人调 onFinish。不在这里撤掉请求的话，
        // `requestConnect` 会吞掉之后所有连接、`keyboardOwner` 恒为 nil（谁都打不了字）。
        if let req = store.connecting, req.tabID == tab.id { store.connecting = nil }
        dispose(tab)
    }

    /// 关闭后的视图侧清理（连接已关）：收键盘、停 Agent 在途任务。
    private func dispose(_ tab: MWorkTab) {
        tab.disposeSession()
    }

    /// 「+」：先把焦点给发起的那一格（新标签开在聚焦格），再开抽屉选主机。
    private func requestNew(_ kind: MConnectKind, in pane: MPane) {
        workspace.focus(pane: pane.id)
        newKind = kind
    }

    /// 改分屏布局不带动画：动画期间终端的宽度逐帧变化，每一帧都是一次重排 + 一次 PTY resize，
    /// 一次点击实测让网格变了 11 次（98 列一路到 55 列），全屏程序跟着反复重绘，整屏闪烁。
    private func toggleSplit() {
        if workspace.isSplit { workspace.unsplit() } else { workspace.split() }
    }

    /// 切换当前终端标签的「终端 ⇄ Agent」模式（对齐 macOS 终端窗口的分段开关）。
    private func toggleAgent(in pane: MPane) {
        guard let term = workspace.tab(pane.activeID)?.terminal else { return }
        workspace.focus(pane: pane.id)
        withAnimation(.easeInOut(duration: 0.16)) {
            term.mode = term.mode == .agent ? .terminal : .agent
        }
        syncKeyboard()
    }

    // MARK: - 键盘

    /// 此刻该拿键盘的终端标签：聚焦格的前台标签、终端模式，且上面没有连接中页 / 新建抽屉。
    /// 连接中页期间一个都没有——键盘窗口恒在最上，会盖住中转页的取消按钮。
    private var keyboardOwner: TermTab? {
        guard store.connecting == nil, store.showWorkspace, newKind == nil, !awaitingConnect,
              let term = workspace.activeTab?.terminal, term.mode == .terminal else { return nil }
        return term
    }

    /// 键盘只归一个标签：先把归属逐会话下发（立即生效，丢了归属的终端当场收键盘、
    /// 也拒绝 UIKit 的自动恢复），再在布局落定后让归属者聚焦——它没连上时 `focusKeyboard`
    /// 什么也不做。没有归属者（文件浏览 / Agent / 连接中）就全局收起，否则击键会落到另一格。
    private func syncKeyboard() {
        let owner = keyboardOwner
        for term in workspace.terminalTabs { term.controller.ownsKeyboard = term === owner }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // 连接中页 / 收起态不做全局收起：上面可能叠着要输入的弹层；终端已按归属各自收了。
            guard store.connecting == nil, store.showWorkspace else { return }
            if let owner = keyboardOwner {
                owner.controller.focusKeyboard()
            } else {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                to: nil, from: nil, for: nil)
            }
        }
    }

    // MARK: - 分屏

    private var panesView: some View {
        GeometryReader { geo in
            let layout = WorkspaceSplitGeometry(size: geo.size, paneCount: workspace.panes.count,
                                                preferredAxis: workspace.splitAxis,
                                                fraction: workspace.splitFraction)
            let horizontal = layout.axis == .horizontal
            let split = workspace.isSplit
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(workspace.panes.enumerated()), id: \.element.id) { index, pane in
                        let rect = layout.rects[min(index, layout.rects.count - 1)]
                        paneView(pane, showsBack: index == 0,
                                 splitState: index == workspace.panes.count - 1 ? split : nil)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .overlayPreferenceValue(WorkspacePaneBodySlots.self) { slots in
                    tabBodies(in: slots)
                }
                if split {
                    divider(horizontal: horizontal, length: layout.length,
                            crossLength: horizontal ? geo.size.height : geo.size.width)
                        .offset(x: horizontal ? layout.firstLength - Self.dividerHitWidth / 2 : 0,
                                y: horizontal ? 0 : layout.firstLength - Self.dividerHitWidth / 2)
                }
                if let dropTarget {
                    let rect = layout.highlightRect(for: dropTarget, panes: workspace.panes)
                    WorkspaceDropHighlight(target: dropTarget)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: dropTarget)
            .coordinateSpace(.named("workspace-split"))
            .onDrop(of: [.utermTabID], delegate: WorkspaceDropDelegate(
                resolve: { point in
                    guard let id = draggingTabID else { return nil }
                    // 标签条贴顶时会撑到状态行高度（Duo 竖屏，见 mAvoidsStatusBar），按较高的算。
                    let strip = max(WorkspaceTabStrip.height, chrome.statusRowHeight ?? 0)
                    return layout.target(at: point, tabID: id, in: workspace, stripHeight: strip)
                },
                onHover: { target in
                    if dropTarget != target { dropTarget = target }
                },
                onDrop: { target in
                    guard let id = draggingTabID else { return }
                    draggingTabID = nil
                    switch target {
                    case .edge(let edge): workspace.dock(id, to: edge)
                    case .pane(let paneID): workspace.move(id, toPane: paneID)
                    }
                }))
        }
        .environment(\.mTerminalHoldsFontSize, dragging)
        .background(M.surface)
    }

    private static let dividerHitWidth: CGFloat = 24

    /// 两格之间的分隔条：1pt `divider` 线，中间一枚把手；拖动时线与把手转 accent
    ///（对齐 macOS `UPaneSplitter`）。命中区 24pt，比线宽得多，手指好抓。
    private func divider(horizontal: Bool, length: CGFloat, crossLength: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(dragging ? accent : M.divider)
                .frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1)
            Capsule().fill(dragging ? accent : M.text4)
                .frame(width: horizontal ? 4 : 36, height: horizontal ? 36 : 4)
        }
        .frame(width: horizontal ? Self.dividerHitWidth : crossLength,
               height: horizontal ? crossLength : Self.dividerHitWidth)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("workspace-split"))
                .onChanged { value in
                    dragging = true
                    let position = horizontal ? value.location.x : value.location.y
                    workspace.splitFraction = min(max(position / max(length, 1), 0.25), 0.75)
                }
                .onEnded { _ in dragging = false })
        .accessibilityLabel(Text("分屏分隔条"))
        .accessibilityAdjustableAction { direction in
            let step: CGFloat = direction == .increment ? 0.05 : -0.05
            workspace.splitFraction = min(max(workspace.splitFraction + step, 0.25), 0.75)
        }
    }

    // MARK: - 一格

    private var focusedFrontTerminal: TermTab? {
        workspace.tab(workspace.focusedPane.activeID)?.terminal
    }

    private func paneView(_ pane: MPane, showsBack: Bool, splitState: Bool?) -> some View {
        let paneTabs = workspace.tabs(in: pane)
        let focused = pane.id == workspace.focusedPaneID
        return VStack(spacing: 0) {
            WorkspaceTabStrip(
                tabs: paneTabs, activeID: pane.activeID,
                paneFocused: focused || !workspace.isSplit,
                showsBack: showsBack, splitState: splitState,
                onSelect: { workspace.activate($0) },
                onClose: requestClose,
                onNew: { requestNew($0, in: pane) },
                onBack: { store.showWorkspace = false },
                onAgent: { toggleAgent(in: pane) },
                onToggleSplit: toggleSplit,
                onMoveToOtherPane: { workspace.moveToOtherPane($0) },
                showsTrailingControls: chrome.statusColumn == nil,
                onDragTab: { draggingTabID = $0 },
                closePrompt: Binding(get: { closeFlow.pending }, set: { closeFlow.pending = $0 }),
                onConfirmClose: confirmClose)
            // 标签主体不在这里，见 `tabBodies`；这里只留位置。
            Group {
                if paneTabs.isEmpty { emptyPane(pane) } else { Color.clear }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .anchorPreference(key: WorkspacePaneBodySlots.self, value: .bounds) { [pane.id: $0] }
        }
        .background(M.surface)
        .contentShape(Rectangle())
        // 点到格里任何地方都把焦点给它（终端的 UIKit 视图另由 onInteract 报告）。
        .simultaneousGesture(TapGesture().onEnded { workspace.focus(pane: pane.id) })
    }

    /// 所有标签主体都挂在同一个 `ForEach` 下，只按所在格摆位置。标签换格时视图身份不变：
    /// 按格分开挂的话换格等于新建，SwiftUI 之后再也不更新新终端的 frame（布局算得对，
    /// UIKit 宿主却停在换格那一刻的尺寸），转屏、拖分隔条后终端就盖到别的格上。
    private func tabBodies(in slots: [UUID: Anchor<CGRect>]) -> some View {
        GeometryReader { proxy in
            ForEach(workspace.tabs) { tab in
                let pane = workspace.paneIndex(containing: tab.id).map { workspace.panes[$0] }
                let slot = pane.flatMap { slots[$0.id] }.map { proxy[$0] } ?? .zero
                let front = pane?.activeID == tab.id
                coveredTabBody(tab, front: front, focused: front && pane?.id == workspace.focusedPaneID)
                    .frame(width: slot.width, height: slot.height)
                    .contentShape(Rectangle())
                    // 点到格里任何地方都把焦点给它（终端的 UIKit 视图另由 onInteract 报告）。
                    .simultaneousGesture(TapGesture().onEnded {
                        if let pane { workspace.focus(pane: pane.id) }
                    })
                    .opacity(front ? 1 : 0)
                    .allowsHitTesting(front)
                    // 用真实布局位置而不是 offset：正文底色要按实际位置判断是否贴着安全区。
                    .padding(.leading, slot.minX)
                    .padding(.top, slot.minY)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    /// 正在为这个标签建连、且连接中页只盖这个标签（分屏时在工作区里新开的）时，返回该请求。
    private func paneCover(for tab: MWorkTab) -> MConnectRequest? {
        guard let req = store.connecting, req.tabID == tab.id,
              req.showsInPane(workspace, workspaceVisible: store.showWorkspace) else { return nil }
        return req
    }

    /// 标签主体；建连中（格内连接中页）时主体移到屏外、连接中页顶上。
    /// 不能把连接中页叠在终端上面：SwiftTerm 的 UIView 会无视 ZStack 顺序盖住上面的 SwiftUI
    ///（见 TerminalSessionBody 的 Agent 层）。主体仍挂着，建连期 shell 首屏的字节照收。
    @ViewBuilder
    private func coveredTabBody(_ tab: MWorkTab, front: Bool, focused: Bool) -> some View {
        let cover = paneCover(for: tab)
        ZStack {
            tabBody(tab, front: front, focused: focused && cover == nil)
                .offset(x: cover == nil ? 0 : -100_000)
            if let cover {
                ConnectingCoverView(request: cover,
                                    onFinish: { store.finishConnect() },
                                    onCancel: { store.cancelConnect() },
                                    onRetry: { store.retryConnect() },
                                    fillsScreen: false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.22), value: cover?.id)
    }

    @ViewBuilder
    private func tabBody(_ tab: MWorkTab, front: Bool, focused: Bool) -> some View {
        switch tab {
        case .terminal(let term):
            // 收起时所有终端都不在屏上：降刷新节拍，Agent 也不自动执行。
            TerminalSessionBody(tab: term, isActive: front && visible, isFocused: focused,
                                onInteract: { workspace.activate(term.id) },
                                onClose: { requestClose(term.id) })
        case .files(let files):
            FilesSessionBody(tab: files, onClose: { closeTab(files.id) })
        }
    }

    /// 刚拆出、还没开标签的空格。
    private func emptyPane(_ pane: MPane) -> some View {
        VStack(spacing: 14) {
            MIcon(name: "split", size: 30, color: M.text4, weight: .light)
            Text("在这一侧打开").font(M.sans(14, weight: .semibold)).foregroundStyle(M.text2)
            HStack(spacing: 10) {
                MBtn(title: "新建终端", icon: "term", kind: .tinted, height: 40) {
                    requestNew(.terminal, in: pane)
                }.fixedSize()
                MBtn(title: "浏览文件", icon: "folder", kind: .secondary, height: 40) {
                    requestNew(.sftp, in: pane)
                }.fixedSize()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 新建会话

    private func newTabSheet(_ kind: MConnectKind) -> some View {
        let candidates = kind == .terminal ? hosts.filter { !$0.sftpOnly } : hosts
        // Mac 的本机终端只有终端能开；文件浏览没有对应的远控通道。
        let macs = kind == .terminal ? remoteMacs : nil
        return NavigationStack {
            ScrollView {
                MCardList {
                    if let macs {
                        MacTerminalRows(directory: macs) { client, sessionID in
                            awaitingConnect = true
                            newKind = nil
                            // 同主机行：等抽屉收起再盖连接中页。
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                store.takeOver(client, focus: sessionID)
                                awaitingConnect = false
                            }
                        }
                    }
                    if candidates.isEmpty {
                        if macs?.pairedMacs.isEmpty ?? true {
                            Text("没有可连接的主机").font(M.sans(14)).foregroundStyle(M.text3)
                                .frame(maxWidth: .infinity).padding(.top, 40)
                        }
                    } else {
                        ForEach(candidates) { host in
                            // 新建会话也走连接中页（强制新开一个，即便已有同主机同类型的标签）。
                            hostRow(host, kind: kind) {
                                awaitingConnect = true
                                newKind = nil
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    store.requestConnect(host, kind: kind, allowDuplicate: true)
                                    awaitingConnect = false
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(M.canvas)
            .navigationTitle(kind == .terminal ? "新建终端" : "浏览文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { newKind = nil } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func hostRow(_ host: ServerProfile, kind: MConnectKind,
                         open: @escaping () -> Void) -> some View {
        let tint = kind == .terminal ? accent : M.folder2
        return Button(action: open) {
            HStack(spacing: 12) {
                MIcon(name: kind == .terminal ? "server" : "folder", size: 18, color: tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: MRadius.md))
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name).font(M.sans(15.5, weight: .semibold)).foregroundStyle(M.text)
                    Text(host.displayEndpoint).font(M.mono(12)).foregroundStyle(M.text3)
                }
                Spacer()
                MIcon(name: kind == .terminal ? "run" : "chev", size: 14,
                      color: kind == .terminal ? accent : M.text4, weight: .semibold)
            }
            .padding(14)
            .background(M.card)
            .clipShape(RoundedRectangle(cornerRadius: MRadius.card))
        }
        .buttonStyle(MPressStyle())
    }
}

extension MConnectKind: Identifiable {
    var id: Self { self }
}

/// 每一格里标签主体该占的区域（标签条高度随状态栏变化，只有格自己知道）。
private struct WorkspacePaneBodySlots: PreferenceKey {
    static let defaultValue: [UUID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}
