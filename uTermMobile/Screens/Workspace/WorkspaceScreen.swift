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
    @Environment(MobileStore.self) private var store
    @Environment(HostKeyChallengeRelay.self) private var relay
    @Environment(MobileWorkspace.self) private var workspace
    @Environment(\.modelContext) private var context
    @Environment(\.mAccent) private var accent
    @Query(sort: [SortDescriptor(\ServerProfile.sortOrder)]) private var hosts: [ServerProfile]

    /// 新建会话抽屉要开的类型（「+」菜单选的）。
    @State private var newKind: MConnectKind?
    @State private var dragging = false

    private var visible: Bool { store.showWorkspace }

    /// 宽度够两格各放下一屏可用的终端（约 80 列 9pt 字）时左右并排，否则上下叠放。
    static let sideBySideMinWidth: CGFloat = 560

    var body: some View {
        ZStack {
            // 只在连接请求刚到、标签还没开出来的一瞬为空（连接中页正盖着），什么也不画。
            if !(workspace.isEmpty && !workspace.isSplit) { panesView }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: store.openTarget) { _, t in consume(t) }
        .onAppear { consume(store.openTarget) }
        .onChange(of: workspace.activeTab?.id) { _, _ in syncKeyboard() }
        .onChange(of: workspace.focusedPaneID) { _, _ in syncKeyboard() }
        // 收起回主机列表（会话不断）时收起键盘，否则键盘会残留在标签页之上；展开时重新聚焦。
        .onChange(of: store.showWorkspace) { _, shown in
            if shown { syncKeyboard() } else { resignAll() }
        }
        // 连接中页撤下（连接完成）后再弹键盘——建连期刻意不弹（见 SwiftTermView.autoFocus）。
        .onChange(of: store.connecting?.id) { _, id in
            if id == nil { syncKeyboard() }
        }
        // 连接中页取消：移除对应会话标签（控制器已由 store 关闭）。
        .onChange(of: store.teardownTabID) { _, id in
            guard let id else { return }
            if let removed = workspace.close(id) { dispose(removed) }
            if workspace.isEmpty { store.showWorkspace = false }
            store.teardownTabID = nil
        }
        .sheet(item: $newKind) { kind in newTabSheet(kind) }
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

    private func closeTab(_ id: UUID) {
        guard let removed = workspace.close(id) else { return }
        switch removed {
        case .terminal(let t): t.controller.close()
        case .files(let f): f.controller.close()
        }
        dispose(removed)
        // 关掉最后一个会话就没有可看的了：收回主机列表。
        if workspace.isEmpty { store.showWorkspace = false }
    }

    /// 关闭后的视图侧清理（连接已关）：收键盘、停 Agent 在途任务。
    private func dispose(_ tab: MWorkTab) {
        guard case .terminal(let t) = tab else { return }
        t.controller.resignKeyboard()
        t.agent.dispose()
        t.agentTasks.cancelAll()
    }

    /// 「+」：先把焦点给发起的那一格（新标签开在聚焦格），再开抽屉选主机。
    private func requestNew(_ kind: MConnectKind, in pane: MPane) {
        workspace.focus(pane: pane.id)
        newKind = kind
    }

    private func toggleSplit() {
        withAnimation(.easeInOut(duration: 0.22)) {
            if workspace.isSplit { workspace.unsplit() } else { workspace.split() }
        }
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

    /// 键盘只归活动标签：终端模式的终端接管第一响应者；文件浏览 / Agent 没有终端去接管，
    /// 主动全局收起旧键盘，否则击键会落到另一格或已切走的终端里。
    private func syncKeyboard() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // 连接中页期间不要弹键盘——键盘窗口恒在最上，会盖住中转页的取消按钮。
            guard store.connecting == nil, store.showWorkspace else { return }
            if let term = workspace.activeTab?.terminal, term.mode == .terminal {
                term.controller.focusKeyboard()
            } else {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                to: nil, from: nil, for: nil)
            }
        }
    }

    private func resignAll() {
        for term in workspace.terminalTabs { term.controller.resignKeyboard() }
    }

    // MARK: - 分屏

    private var panesView: some View {
        GeometryReader { geo in
            let horizontal = geo.size.width >= Self.sideBySideMinWidth
            let length = horizontal ? geo.size.width : geo.size.height
            let split = workspace.isSplit
            let firstLength = split ? (length * workspace.splitFraction).rounded() : length
            ZStack(alignment: .topLeading) {
                ForEach(Array(workspace.panes.enumerated()), id: \.element.id) { index, pane in
                    let start = index == 0 ? 0 : firstLength + 1
                    let extent = index == 0 ? firstLength : length - firstLength - 1
                    paneView(pane, showsBack: index == 0,
                             splitState: index == workspace.panes.count - 1 ? split : nil)
                        .frame(width: horizontal ? extent : geo.size.width,
                               height: horizontal ? geo.size.height : extent)
                        .overlay {
                            // 焦点框（对齐 macOS `PaneFocusRing`）：只在分屏时画，只画聚焦格。
                            if split && pane.id == workspace.focusedPaneID {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(accent, lineWidth: 1.5)
                                    .allowsHitTesting(false)
                            }
                        }
                        .offset(x: horizontal ? start : 0, y: horizontal ? 0 : start)
                }
                if split {
                    divider(horizontal: horizontal, length: length, crossLength: horizontal ? geo.size.height : geo.size.width)
                        .offset(x: horizontal ? firstLength - Self.dividerHitWidth / 2 : 0,
                                y: horizontal ? 0 : firstLength - Self.dividerHitWidth / 2)
                }
            }
            .coordinateSpace(.named("workspace-split"))
        }
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

    private func paneView(_ pane: MPane, showsBack: Bool, splitState: Bool?) -> some View {
        let paneTabs = workspace.tabs(in: pane)
        let focused = pane.id == workspace.focusedPaneID
        return VStack(spacing: 0) {
            WorkspaceTabStrip(
                tabs: paneTabs, activeID: pane.activeID,
                paneFocused: focused || !workspace.isSplit,
                showsBack: showsBack, splitState: splitState,
                onSelect: { workspace.activate($0) },
                onClose: closeTab,
                onNew: { requestNew($0, in: pane) },
                onBack: { store.showWorkspace = false },
                onAgent: { toggleAgent(in: pane) },
                onToggleSplit: toggleSplit,
                onMoveToOtherPane: { id in
                    withAnimation(.easeInOut(duration: 0.22)) { workspace.moveToOtherPane(id) }
                })
            ZStack {
                ForEach(paneTabs) { tab in
                    let front = tab.id == pane.activeID
                    tabBody(tab, front: front, focused: front && focused)
                        .opacity(front ? 1 : 0)
                        .allowsHitTesting(front)
                }
                if paneTabs.isEmpty { emptyPane(pane) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(M.surface)
        .contentShape(Rectangle())
        // 点到格里任何地方都把焦点给它（终端的 UIKit 视图另由 onInteract 报告）。
        .simultaneousGesture(TapGesture().onEnded { workspace.focus(pane: pane.id) })
    }

    @ViewBuilder
    private func tabBody(_ tab: MWorkTab, front: Bool, focused: Bool) -> some View {
        switch tab {
        case .terminal(let term):
            // 收起时所有终端都不在屏上：降刷新节拍，Agent 也不自动执行。
            TerminalSessionBody(tab: term, isActive: front && visible, isFocused: focused,
                                onInteract: { workspace.activate(term.id) },
                                onClose: { closeTab(term.id) })
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
        return NavigationStack {
            ScrollView {
                MCardList {
                    if candidates.isEmpty {
                        Text("没有可连接的主机").font(M.sans(14)).foregroundStyle(M.text3)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        ForEach(candidates) { host in
                            // 新建会话也走连接中页（强制新开一个，即便已有同主机同类型的标签）。
                            hostRow(host, kind: kind) {
                                newKind = nil
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    store.requestConnect(host, kind: kind, allowDuplicate: true)
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
                    .clipShape(RoundedRectangle(cornerRadius: 10))
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
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(MPressStyle())
    }
}

extension MConnectKind: Identifiable {
    var id: Self { self }
}
