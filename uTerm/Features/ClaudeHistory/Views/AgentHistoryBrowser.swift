import AppKit
import SwiftUI
import UAppKitBridge
import UDesignKit
import UniformTypeIdentifiers

/// 在 Code 标签页里跑着的会话（`CodeTabModel.runs`）：不另起一块「正在运行」，列表里有它那份记录的就在那份记录平常的
/// 位置（置顶了在「置顶」，否则在它那一组），行上是它此刻的状态（`CodeRunStatus`）；列表里没有记录的（还没对上记录的
/// 新会话等）放在它那一组的最上面，对不上任何一组的在列表最顶上。规则见 `AgentHistoryRunPlacement`。独立的历史窗口没有。
struct AgentHistoryRunning {
    /// 在 Code 标签页里跑着（或已结束、留着画面）的会话，按起来的先后。
    let rows: () -> [AgentHistoryRunRow]
    let onSelect: (UUID) -> Void
    /// 行上的操作（右键菜单、悬停的 ×）。nil = 没有（只能点一下回到它）。
    var actions: AgentHistoryRunActions? = nil
}

/// 跑着的会话那一行的操作（右键菜单与悬停的 ×）。
struct AgentHistoryRunActions {
    /// 「结束会话」（右键菜单与悬停的 ×）。前台还有程序在跑时先问，由宿主管。
    let end: (UUID) -> Void
    /// 「查看记录」：有记录的会话右边看它的记录。
    let showRecord: (UUID) -> Void
    /// 「返回终端」：右边正看着它的记录时回到它的终端。
    let showTerminal: (UUID) -> Void
    /// 「移到新标签页」；nil = 不出这一项。
    let moveToTab: ((UUID) -> Void)?
}

/// 一个跑着的会话。列表里有它那份记录的，那一行（在置顶或它那一组里）画成跑着的样子；没有的（还没写出记录的新会话）
/// 在列表最顶上，写标题与目录。行上的状态见 `AgentHistoryRunStatus`。
struct AgentHistoryRunRow: Identifiable {
    let id: UUID
    let title: String
    let tool: AgentHistoryTool
    let directory: String
    let isSelected: Bool
    /// 对上的记录；新会话还没对上为 nil。
    let path: String?
    let status: AgentHistoryRunStatus
    /// 右边正看着它的记录（右键菜单里是「返回终端」，否则「查看记录」）。
    var showsRecord = false
    /// 能切到看它的记录（`CodeTabModel.canShowRecord`）：右键菜单里出不出「查看记录」。
    var canShowRecord = false
}

/// 一个跑着的会话此刻的状态（规则见 `CodeRunStatus`）。`read` 在显示它的那一小块视图里调：状态变了只重画那一行，
/// 不让整个列表重算。
struct AgentHistoryRunStatus {
    let read: @MainActor () -> CodeRunStatus
}

/// 历史会话的内容：左边会话列表（可拖宽），右边选中会话的对话。独立的历史窗口用它；Code 标签页另摆（`CodeTabView`），
/// 用的是同样的列表与对话。
struct AgentHistoryBrowser: View {
    let history: AgentHistoryModel
    let onResume: (AgentHistorySessionFile) -> Void
    var newSession: AgentHistoryNewSession? = nil
    var reveal: AgentHistoryReveal? = nil

    @Environment(\.scenePhase) private var scenePhase
    /// 列表的宽度：外面给了就记在外面（Code 模式换主机时不变），没给记在这里。
    @State private var ownWidth: Double
    private let externalWidth: Binding<Double>?
    private var sidebarWidth: Binding<Double> { externalWidth ?? $ownWidth }

    /// 列表的宽度范围；窗口窄时上限再收，给对话留出 `minimumDetailWidth`。
    static let sidebarRange = 220.0...420.0
    static let minimumDetailWidth = 420.0

    init(history: AgentHistoryModel, onResume: @escaping (AgentHistorySessionFile) -> Void,
         newSession: AgentHistoryNewSession? = nil, reveal: AgentHistoryReveal? = nil,
         sidebarWidth: Binding<Double>? = nil) {
        self.history = history
        self.onResume = onResume
        self.newSession = newSession
        self.reveal = reveal
        externalWidth = sidebarWidth
        _ownWidth = State(initialValue: 300)
    }

    var body: some View {
        GeometryReader { proxy in
            let upper = max(Self.sidebarRange.lowerBound,
                            min(Self.sidebarRange.upperBound, Double(proxy.size.width) - Self.minimumDetailWidth))
            HStack(spacing: 0) {
                AgentHistorySessionList(history: history, newSession: newSession, reveal: reveal, onResume: onResume)
                    .frame(width: min(max(sidebarWidth.wrappedValue, Self.sidebarRange.lowerBound), upper))
                ColumnResizer(width: sidebarWidth, range: Self.sidebarRange.lowerBound...upper, sign: 1)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // 实时跟随只在看得见时查：窗口关了、缩进程序坞 / App 隐藏（场景进了后台）、切走了模式就停，回来马上查一次。
        .onAppear { history.setTranscriptVisible(scenePhase != .background) }
        .onDisappear { history.setTranscriptVisible(false) }
        .onChange(of: scenePhase) { _, phase in history.setTranscriptVisible(phase != .background) }
    }

    @ViewBuilder private var detail: some View {
        if history.transcript != nil {
            AgentHistoryTranscriptStack(history: history, onResume: onResume)
        } else {
            AgentHistorySelectPrompt(history: history)
        }
    }
}

/// 还没选会话时右边的空态。
struct AgentHistorySelectPrompt: View {
    let history: AgentHistoryModel

    var body: some View {
        RemoteMacStateView(systemImage: "text.bubble", title: String(localized: "选择一个会话"),
                           detail: AgentHistoryText.selectSessionDetail(tools: listedTools))
    }

    private var listedTools: [AgentHistoryTool] {
        history.availableTools.isEmpty ? history.configuredTools : history.availableTools
    }
}

/// 选中会话的只读对话：主对话与点进去的一层层子代理记录都挂着，只露出最里面那层（返回上一层时滚动位置、展开的块都还在）。
struct AgentHistoryTranscriptStack: View {
    let history: AgentHistoryModel
    let onResume: (AgentHistorySessionFile) -> Void
    /// 这个会话正在 Code 标签页里跑着：「继续这个会话」的位置换成「返回终端」（`onResume` 回到它的终端）。
    var isRunning: (AgentHistorySessionFile) -> Bool = { _ in false }

    var body: some View {
        if let transcript = history.transcript {
            let levels = [transcript] + history.subagentStack
            let top = levels.last?.path
            ZStack {
                ForEach(levels, id: \.path) { level in
                    let isTop = level.path == top
                    AgentTranscriptPane(transcript: level,
                                        metadata: history.metadata[level.file.path],
                                        canResume: history.resumeCommand(for: level.file) != nil,
                                        isRunning: level.subagent == nil && isRunning(level.file),
                                        onResume: { onResume(level.file) },
                                        onBack: level.subagent == nil ? nil : { history.closeSubagent() },
                                        onOpenSubagent: { history.openSubagent($0) },
                                        onJumpToLatest: { history.jumpToLatest() },
                                        continuation: level.subagent == nil ? history.continuationLink(of: level.file) : nil,
                                        onOpenPart: { history.select($0) })
                        .opacity(isTop ? 1 : 0)
                        .allowsHitTesting(isTop)
                        .accessibilityHidden(!isTop)
                }
            }
            // 换了一份对话（含「跳到最新」把从命中处打开的换成从末尾打开的）就是新的视图：滚动位置、展开的块重来。
            .id(ObjectIdentifier(transcript))
        }
    }
}

// MARK: - 会话列表

/// 会话列表：顶上搜索框、「＋」新会话、分组菜单、刷新；下面按分组列（组可以折起来），搜索时换成搜索结果。
struct AgentHistorySessionList: View {
    let history: AgentHistoryModel
    var newSession: AgentHistoryNewSession? = nil
    var reveal: AgentHistoryReveal? = nil
    /// Code 标签页里跑着的会话：在它那份记录平常的那一行上（没有记录的在最顶上），行上是它此刻的状态。
    var running: AgentHistoryRunning? = nil
    /// 收起侧栏（Code 标签页，放在菜单里）；nil = 菜单里不出这一项。
    var onCollapse: (() -> Void)? = nil
    /// 继续一个会话（行的右键菜单里那一项）；nil = 菜单里不出。
    var onResume: ((AgentHistorySessionFile) -> Void)? = nil

    @AppStorage(DefaultsKey.agentHistoryGrouping) private var groupingRaw = AgentHistoryGrouping.default.rawValue
    @AppStorage(DefaultsKey.agentHistoryShownTools) private var shownToolsRaw = ""
    /// 还没定位成功的那一次请求（组还没列出来）：列表有了变化再试。
    @State private var pendingReveal: AgentHistoryReveal?
    /// 拖动置顶的状态（只在这个列表里认）。
    @State private var pinDrag = AgentHistoryPinDragModel.forList()
    /// 选中的跑着的会话那份记录还没露出来（它那一组收着、还没列到）：列表变了再试，见 `tryRevealRun`。
    @State private var pendingRunReveal: String?
    /// 点了「删除会话…」、等确认的那一份。
    @State private var pendingDelete: AgentHistorySessionFile?
    /// 删不掉时的原因。
    @State private var deleteFailure: String?

    /// 只有一种工具时没有「工具」这种分组：存的是它就按默认的来。
    private var grouping: AgentHistoryGrouping {
        AgentHistoryListPreferences.effectiveGrouping(groupingRaw, isMultiTool: history.isMultiTool)
    }

    private var groupingChoices: [AgentHistoryGrouping] {
        AgentHistoryListPreferences.groupingChoices(isMultiTool: history.isMultiTool)
    }

    @Environment(\.agentHistoryHeaderDivider) private var showsHeaderDivider

    var body: some View {
        VStack(spacing: 0) {
            header
            if showsHeaderDivider { Rectangle().fill(UD.border).frame(height: 1) }
            // 搜索结果盖在列表上，列表一直挂着：清空搜索后选中的会话、滚动位置都还在。
            ZStack {
                content
                    .opacity(history.search == nil ? 1 : 0)
                    .allowsHitTesting(history.search == nil)
                    .accessibilityHidden(history.search != nil)
                if let search = history.search {
                    AgentHistorySearchResults(history: history, search: search)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { history.setShownTools(AgentHistoryListPreferences.decodeTools(shownToolsRaw)) }
        .onChange(of: shownToolsRaw) { _, raw in history.setShownTools(AgentHistoryListPreferences.decodeTools(raw)) }
        // 别的窗口改了置顶：新置顶的那几个先读出来。
        .onChange(of: history.pins?.keys) { _, _ in history.readPinnedMetadata() }
        .alert(AgentHistoryText.deleteConfirmTitle, isPresented: Binding(get: { pendingDelete != nil },
                                                                        set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { file in
            Button(AgentHistoryText.deleteConfirmButton, role: .destructive) { delete(file) }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: { file in
            Text(AgentHistoryText.deleteConfirmMessage(title: AgentHistoryText.sessionTitle(file, metadata: history.metadata[file.path])))
        }
        .alert(AgentHistoryText.deleteFailedTitle, isPresented: Binding(get: { deleteFailure != nil },
                                                                       set: { if !$0 { deleteFailure = nil } })) {
            Button(String(localized: "好")) {}
        } message: {
            Text(verbatim: deleteFailure ?? "")
        }
    }

    private func delete(_ file: AgentHistorySessionFile) {
        Task {
            do {
                try await history.delete(file)
            } catch {
                deleteFailure = FriendlyError.describe(error)
            }
        }
    }

    private var header: some View {
        @Bindable var history = history
        return VStack(alignment: .leading, spacing: 4) {
            // 只留三样：搜索框、「＋」、菜单。刷新、收起侧栏不常用，收进菜单，搜索框拿到这些宽度。
            HStack(spacing: 2) {
                // 不写占位文字（Mac 侧栏窄，放大镜就够说明）；读屏照旧读得出这是什么框。iOS 仍有占位文字。
                UDSearchField(text: $history.searchText, placeholder: "", showsHotkeyChip: false)
                    .accessibilityLabel(Text(AgentHistoryText.searchPlaceholder))
                    .onSubmit { history.submitSearch() }
                    .help(AgentHistoryText.searchHelp)
                    .padding(.trailing, 4)
                if let newSession { newSessionButton(newSession) }
                optionsMenu
            }
            .frame(height: Self.controlRowHeight)
            if let problem = history.searchProblem {
                Text(AgentHistoryText.searchProblem(problem))
                    .font(.system(size: 11))
                    .foregroundStyle(UD.warning)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, Self.headerVerticalPadding)
        .frame(minHeight: Self.headerHeight)
    }

    /// 顶上那一行控件的高度（搜索框的高度）。
    static let controlRowHeight: CGFloat = 32
    static let headerVerticalPadding: CGFloat = 6
    /// 列表顶部那一行的高度（不算分隔线）。Code 标签页右边跑着的会话顶上那一条与它等高，中间的竖线上下贯通。
    static let headerHeight: CGFloat = controlRowHeight + headerVerticalPadding * 2

    /// 「＋」：Code 标签页里叫出右边的起始页（在那里选目录、选工具）；独立的历史窗口里能新开的工具不止一种时先选工具，
    /// 只有一种就直接开。
    @ViewBuilder private func newSessionButton(_ newSession: AgentHistoryNewSession) -> some View {
        if let present = newSession.present {
            Button(action: present) {
                Image(systemName: "plus")
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.udPlain)
            .iconButtonHover(cornerRadius: 6)
            .help(AgentHistoryText.newSession)
            .accessibilityLabel(Text(AgentHistoryText.newSession))
        } else {
            directNewSessionButton(newSession)
        }
    }

    @ViewBuilder private func directNewSessionButton(_ newSession: AgentHistoryNewSession) -> some View {
        let tools = history.newSessionTools(directory: newSession.directory)
        let help = tools.isEmpty && newSession.directory != nil
            ? String(localized: "这台主机上的编码工具都不能在终端里新开会话")
            : AgentHistoryText.newSessionHelp(directory: newSession.directory)
        if tools.count > 1, let directory = newSession.directory {
            Menu {
                Section(AgentHistoryText.newSessionTitle(directory: directory)) {
                    ForEach(tools) { tool in
                        Button(tool.displayName) { start(tool, in: directory, newSession) }
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
            .iconButtonHover(cornerRadius: 6)
            .help(help)
            .accessibilityLabel(Text(AgentHistoryText.newSession))
        } else {
            Button {
                if let tool = tools.first, let directory = newSession.directory { start(tool, in: directory, newSession) }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.udPlain)
            .iconButtonHover(cornerRadius: 6)
            .disabled(tools.isEmpty)
            .help(help)
            .accessibilityLabel(Text(AgentHistoryText.newSession))
        }
    }

    private func start(_ tool: AgentHistoryTool, in directory: String, _ newSession: AgentHistoryNewSession) {
        guard let command = history.newSessionCommand(tool: tool, directory: directory) else { return }
        newSession.start(tool, command, directory)
    }

    /// 分组方式、只看哪几种工具、恢复默认。排序这一轮只有「最近更新」一种，不出。
    /// 分组方式、只看哪几种工具、恢复默认、刷新、收起侧栏。用 uAppKit 的浮层菜单（`UDDropdown` + `UDMenu`），不用系统菜单。
    /// `UDMenu` 只有顶上一个标题：「分组方式」写在那里，「显示」那一段用分隔线隔开。
    private var optionsMenu: some View {
        UDDropdown(anchor: .trailing) { _ in
            Image(systemName: "line.3.horizontal.decrease")
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
                .iconButtonHover(cornerRadius: 6)
        } content: {
            UDMenu(width: 200, head: String(localized: "分组方式", comment: "历史会话列表菜单：按什么分组"),
                   maxHeight: nil, items: optionsMenuItems)
        }
        .fixedSize()
        .help(String(localized: "分组与显示"))
        .accessibilityLabel(Text("分组与显示"))
    }

    private var optionsMenuItems: [UDMenuItem] {
        var items = groupingChoices.map { choice in
            UDMenuItem(label: AgentHistoryText.groupingName(choice), checked: choice == grouping) {
                groupingRaw = choice.rawValue
            }
        }
        if history.isMultiTool {
            items.append(.divider())
            let effective = history.effectiveTools
            for tool in history.availableTools {
                // 只剩这一种勾着时点了不变（`toggling` 不许一种都不勾）。
                items.append(UDMenuItem(label: tool.displayName, checked: effective.contains(tool)) {
                    let next = AgentHistoryListing.toggling(tool, shown: history.shownTools, available: history.availableTools)
                    shownToolsRaw = AgentHistoryListPreferences.encodeTools(next)
                })
            }
        }
        items.append(.divider())
        // 只管分组方式与「显示」，不清置顶。
        items.append(UDMenuItem(label: String(localized: "恢复默认")) {
            groupingRaw = AgentHistoryGrouping.default.rawValue
            shownToolsRaw = ""
        })
        items.append(.divider())
        items.append(UDMenuItem(label: String(localized: "刷新")) { Task { await history.reload() } })
        if let onCollapse {
            items.append(UDMenuItem(label: String(localized: "收起侧栏", comment: "Code 标签页：收起左边的会话列表"),
                                    action: onCollapse))
        }
        return items
    }

    @ViewBuilder private var content: some View {
        switch history.phase {
        case .loading:
            RemoteMacProgressView(text: String(localized: "正在读取会话列表…"))
        case .empty:
            RemoteMacStateView(systemImage: "tray", title: String(localized: "没有历史会话"),
                               detail: AgentHistoryText.noHistoryDetail(tools: history.configuredTools))
        case .failed(let message):
            RemoteMacStateView(systemImage: "exclamationmark.triangle", title: String(localized: "无法读取会话列表"),
                               detail: message) {
                UDButton(title: String(localized: "重试")) { Task { await history.reload() } }
            }
        case .ready:
            let files = history.visibleFiles
            let pinned = history.pinnedFiles
            let runs = running?.rows() ?? []
            // 还在列目录，或者读过的那几份都不用列、后面还有没读的：接着等，别急着说「没有」。
            if files.isEmpty && pinned.isEmpty && runs.isEmpty && (history.isListing || history.hasMore) {
                RemoteMacProgressView(text: String(localized: "正在读取会话列表…"))
            } else if files.isEmpty && pinned.isEmpty && runs.isEmpty {
                RemoteMacStateView(systemImage: "tray", title: String(localized: "没有命令行会话"),
                                   detail: emptyDetail)
            } else {
                list(files, pinned: pinned, runs: runs)
            }
        }
    }

    private var emptyDetail: String { AgentHistoryText.emptyListDetail(hidden: history.hiddenCount) }

    private func list(_ files: [AgentHistorySessionFile], pinned: [AgentHistorySessionFile],
                      runs: [AgentHistoryRunRow]) -> some View {
        let groups = AgentHistoryListing.groups(files, by: grouping, metadata: history.metadata, pinned: pinned,
                                                date: { history.liveActivity(of: $0) ?? $0.modifiedAt })
        // 跑着的会话不另起一块：有记录的在那一行上（置顶或它那一组）；还没有记录行的（刚开的新会话）在它那一组的最上面，
        // 哪一组都对不上的才在列表最顶上。
        let placement = AgentHistoryRunPlacement(runs: runs, path: \.path, directory: \.directory, tool: \.tool,
                                                 groups: groups)
        let selectedRunPath = runs.first(where: \.isSelected)?.path
        // 选中的新会话放在哪一组（它那一组收着就打开）。
        let selectedLeadingGroup = placement.groupID(ofLeading: \.isSelected)
        let pins = history.pins
        return GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(placement.top) { row in
                            unlistedRunRow(row, showsTool: history.isMultiTool, pins: pins)
                        }
                        if pins != nil, pinned.isEmpty {
                            // 落点的锚：零高度，一直在（拖动开始时不插进新的一行）。落点画在它下面、盖住接下来的那一截。
                            // 拖动中、还没有置顶的会话：分组最上面盖一条落点。盖在上面、不占位置：出现消失都不推动列表，
                            // 拖着的落点不跟着跳。拖动的状态只在这条里读（见 `AgentHistoryPinDropStripSlot`）。
                            Color.clear.frame(height: 0)
                                .overlay(alignment: .top) { AgentHistoryPinDropStripSlot(drag: pinDrag) }
                                .zIndex(1)
                        }
                        ForEach(groups) { group in
                            let collapsed = history.collapsedGroups.contains(group.id)
                            if AgentHistoryListing.showsHeader(group, in: groups) {
                                let statuses = collapsed ? placement.runs(in: group).map(\.status) : []
                                AgentHistoryGroupHeader(group: group, collapsed: collapsed,
                                                        runs: { statuses.map { $0.read() } }) {
                                    toggle(group.id)
                                }
                                .id(group.id)
                                .modifier(AgentHistoryPinFrameProbe(drag: pinDrag,
                                                                    slot: group.kind == .pinned ? .pinnedHeader : nil))
                            }
                            if !collapsed {
                                let showsTool = group.mixesTools
                                ForEach(placement.leading(in: group)) { row in
                                    unlistedRunRow(row, showsTool: showsTool || group.files.contains { $0.tool != row.tool },
                                                   pins: pins)
                                }
                                ForEach(group.files) { file in
                                    row(file, in: group, showsTool: showsTool, pins: pins, pinned: pinned,
                                        run: placement.inList[file.path])
                                }
                            }
                        }
                        footer(files)
                    }
                    .padding(6)
                    // 落点在列表的空白处也认（列表短、往下拖出「置顶」时）。
                    .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
                    .contentShape(Rectangle())
                    .coordinateSpace(.named(AgentHistoryPinDragModel.space))
                    .modifier(AgentHistoryPinDropTarget(drag: pinDrag, pins: pins, pinned: pinned,
                                                        pinnedCollapsed: history.collapsedGroups.contains(AgentHistoryGroup.pinnedID)))
                }
                // 展开 / 收起分组时内容高度在变，滚动条一会儿出现一会儿消失，看着像列表在跳；侧栏不显示滚动条（`.never`：接着鼠标时 `.hidden` 仍会显示常驻滚动条）。
                .scrollIndicators(.never)
                .onAppear { pendingReveal = reveal }
                .onChange(of: reveal) { _, request in pendingReveal = request }
                .onChange(of: pendingReveal, initial: true) { _, _ in tryReveal(groups, proxy: proxy) }
                // 选中了一个跑着的会话（侧栏收起时从窄轨展开、重启后还原、新会话对上了记录……）：它那一组收着就打开。
                .onChange(of: selectedRunPath, initial: true) { _, path in
                    pendingRunReveal = path
                    tryRevealRun(groups, proxy: proxy)
                }
                .onChange(of: selectedLeadingGroup, initial: true) { _, id in
                    if let id { history.collapsedGroups.remove(id) }
                }
                .onChange(of: groups.map(\.id)) { _, _ in
                    tryReveal(groups, proxy: proxy)
                    tryRevealRun(groups, proxy: proxy)
                }
            }
        }
    }

    /// 一行会话：点一下选中；Mac 上能拖进 / 拖出「置顶」，右键「置顶」/「取消置顶」（同一件事，菜单好找）。
    /// `run`：这份记录正在 Code 标签页里跑着——行上写它此刻的状态，点一下回到它的终端，右键是跑着的会话那几样操作
    ///（含置顶），悬停出 ×。照样能拖进 / 拖出「置顶」。
    @ViewBuilder
    private func row(_ file: AgentHistorySessionFile, in group: AgentHistoryGroup, showsTool: Bool,
                     pins: AgentHistoryPins?, pinned: [AgentHistorySessionFile], run: AgentHistoryRunRow?) -> some View {
        let key = AgentHistoryPinKey(file)
        let base = AgentHistorySessionRow(history: history, file: file, metadata: history.metadata[file.path],
                                          showsProject: grouping != .project || group.kind == .pinned,
                                          showsTool: showsTool,
                                          isSelected: history.selectedFile?.path == file.path || run?.isSelected == true) {
            if let status = run?.status { AgentHistoryRunStatusTag(status: status) }
        }
            .onTapGesture {
                if let run, let running { running.onSelect(run.id) } else { history.select(file) }
            }
        if let pins {
            let isPinned = group.kind == .pinned
            base
                .modifier(AgentHistoryPinDragRowState(drag: pinDrag, key: key, pinned: isPinned ? pinned : nil))
                .modifier(AgentHistoryPinFrameProbe(drag: pinDrag, slot: isPinned ? .pinnedRow(key) : nil))
                // 不用 `.onDrag`：它没有死区，点一下行时手一抖就起拖、冒出预览，这次点击也被吞掉（同标签页）。
                .dragSource(item: {
                    pinDrag.begin(key)
                    return AgentHistoryPinDragPayload.pasteboardItem()
                }) {
                    AgentHistorySessionRowPreview(history: history, file: file, showsTool: showsTool)
                }
                .modifier(rowMenu(file, pins: pins, run: run))
        } else {
            base.modifier(rowMenu(file, pins: nil, run: run))
        }
    }

    private func rowMenu(_ file: AgentHistorySessionFile, pins: AgentHistoryPins?, run: AgentHistoryRunRow?) -> AgentHistoryRowMenu {
        AgentHistoryRowMenu(file: file, pins: pins, run: run, actions: running?.actions,
                            drag: pins == nil ? nil : pinDrag, history: history, onResume: onResume,
                            onDelete: { pendingDelete = $0 })
    }

    /// 跑着、列表里没有它记录行的会话那一行（列表最顶上，或者它那一组的最上面）。
    private func unlistedRunRow(_ row: AgentHistoryRunRow, showsTool: Bool, pins: AgentHistoryPins?) -> some View {
        AgentHistoryUnlistedRunRow(row: row, showsTool: showsTool)
            .modifier(AgentHistoryRunRowActions(row: row, file: nil, pins: pins, actions: running?.actions))
            .onTapGesture { running?.onSelect(row.id) }
    }

    private func tryRevealRun(_ groups: [AgentHistoryGroup], proxy: ScrollViewProxy) {
        guard let path = pendingRunReveal, let id = AgentHistoryListing.groupID(ofRecord: path, in: groups) else { return }
        pendingRunReveal = nil
        guard history.collapsedGroups.contains(id) else { return }
        history.collapsedGroups.remove(id)
        // 行的 id 就是记录的路径（`AgentHistorySessionFile.id`）。
        Task { @MainActor in proxy.scrollTo(path) }
    }

    /// 定位到终端当前目录那一组：展开它并滚过去。还没列到它就等列表变了再试。
    private func tryReveal(_ groups: [AgentHistoryGroup], proxy: ScrollViewProxy) {
        guard let request = pendingReveal, grouping == .project,
              let id = AgentHistoryListing.groupID(containing: request.directory, in: groups) else { return }
        pendingReveal = nil
        history.collapsedGroups.remove(id)
        Task { @MainActor in proxy.scrollTo(id, anchor: .top) }
    }

    private func toggle(_ id: String) {
        if history.collapsedGroups.contains(id) {
            history.collapsedGroups.remove(id)
        } else {
            history.collapsedGroups.insert(id)
        }
    }

    @ViewBuilder private func footer(_ files: [AgentHistorySessionFile]) -> some View {
        if history.hasMore {
            // 滚到底露出来就再读一批。行数变了它就是一个新视图：窗口高、读完一批它还露着时也会接着读。
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在读取…")
                    .font(UD.caption)
                    .foregroundStyle(UD.text4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .id(files.count)
            .onAppear { history.loadMore() }
        } else if history.hiddenCount > 0 {
            Text(AgentHistoryText.hiddenNote(history.hiddenCount))
                .font(UD.caption)
                .foregroundStyle(UD.text4)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        ForEach(AgentHistoryTool.allCases.filter { history.toolFailures[$0] != nil }) { tool in
            SettingsInlineNote(tone: .warning,
                               text: AgentHistoryText.toolFailure(tool, message: history.toolFailures[tool] ?? ""))
                .padding(.horizontal, 4)
                .padding(.top, 4)
        }
    }
}

/// 组标题：折叠箭头、标题、会话数。点一下折起 / 展开。收起时组里有跑着的会话，会话数前面一个状态点（`CodeRunGroupMark`）。
// MARK: - 运行中

/// 跑着的会话行上的状态（`CodeRunStatus`）：程序报的状态用终端标签页上同一套圆点颜色与文字（`ProgramStatusRecord.tabDot` /
/// `statusLabel`；空闲的圆点是灰的），程序退出了是「已结束」，没报过什么都不画。在自己的 `body` 里读状态：变了只重画这一小块。
struct AgentHistoryRunStatusTag: View {
    let status: AgentHistoryRunStatus

    var body: some View {
        switch status.read() {
        case .unreported:
            EmptyView()
        case .ended:
            tag(dot: UD.text4, text: AgentHistoryText.sessionEnded, textColor: UD.text3, help: AgentHistoryText.sessionEnded)
        case .program(let record):
            // 空闲的圆点是最淡的灰，字用次一级的灰才看得清。
            tag(dot: record.tabDot, text: record.statusLabel, textColor: record.tone == .idle ? UD.text3 : record.tabDot,
                help: record.tabHelp)
        }
    }

    private func tag(dot: Color, text: String, textColor: Color, help: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(verbatim: text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(textColor)
        }
        .fixedSize()
        .help(Text(verbatim: help))
    }
}

/// 跑着、但列表里没有它那份记录的会话那一行（多半是还没写出记录的新会话）：在它那一组的最上面，对不上任何一组时
/// 在列表最顶上（见 `AgentHistoryRunPlacement`）。
/// 标题（新会话就是「新会话」），第二行状态（程序报过的话）+ 目录名。点一下回到它的终端。
private struct AgentHistoryUnlistedRunRow: View {
    let row: AgentHistoryRunRow
    /// 这台主机上不止一种工具：写出是哪种（「新会话」本身看不出来）。
    let showsTool: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(UD.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                AgentHistoryRunStatusTag(status: row.status)
                Text(verbatim: detail)
                    .font(.system(size: 11))
                    .foregroundStyle(UD.text3)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(row.isSelected ? UD.rowSelected : Color.clear))
        .contentShape(Rectangle())
        .help(Text(verbatim: row.directory))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(row.isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var detail: String {
        let place = (row.directory as NSString).lastPathComponent
        return showsTool ? "\(row.tool.displayName) · \(place)" : place
    }
}

/// 跑着的会话那一行的操作：右键菜单（「查看记录」/「返回终端」、「移到新标签页」、有记录的「置顶」、「结束会话」），
/// 悬停时右端一个 ×（结束会话），上下居中。× 盖在行上、不占位置：出现消失这一行的字不挪。
/// 有记录的那一行在置顶或它那一组里，照样能拖进 / 拖出「置顶」；最顶上没有记录的那几行不能置顶。
struct AgentHistoryRunRowActions: ViewModifier {
    let row: AgentHistoryRunRow
    let file: AgentHistorySessionFile?
    let pins: AgentHistoryPins?
    let actions: AgentHistoryRunActions?
    /// 这一行能拖动置顶时那个列表的拖动状态：拖起来的时候不出 ×（这一行淡下去了，× 和它后面不透明的垫底不淡，
    /// 看着是一块方底）。
    var drag: AgentHistoryPinDragModel? = nil

    /// 界面画廊与测试用：建出来的行一开始就当作鼠标悬在上面（悬停拍不到）。App 里始终为 false。
    static var catalogHovered = false

    @State private var hovered = AgentHistoryRunRowActions.catalogHovered

    func body(content: Content) -> some View {
        if let actions {
            content
                .overlay(alignment: .trailing) {
                    if hovered, !isLifted {
                        AgentHistoryRunEndButton(isSelected: row.isSelected) { actions.end(row.id) }
                    }
                }
                .hoverGated { hovered = $0 || Self.catalogHovered }
                .contextMenu { menu(actions) }
        } else {
            content
        }
    }

    private var isLifted: Bool {
        guard let drag, let file else { return false }
        return drag.isLifted(AgentHistoryPinKey(file))
    }

    @ViewBuilder private func menu(_ actions: AgentHistoryRunActions) -> some View {
        if row.canShowRecord {
            if row.showsRecord {
                Button(AgentHistoryText.backToTerminal) { actions.showTerminal(row.id) }
            } else {
                Button(AgentHistoryText.viewRecord) { actions.showRecord(row.id) }
            }
        }
        if let move = actions.moveToTab {
            Button(AgentHistoryText.moveToTab) { move(row.id) }
        }
        if let file, let pins {
            Button(AgentHistoryText.pinAction(isPinned: pins.isPinned(AgentHistoryPinKey(file)))) { pins.toggle(file) }
        }
        Divider()
        Button(AgentHistoryText.endSession, role: .destructive) { actions.end(row.id) }
    }
}

/// 列表里一行记录的右键菜单：在跑的（`run`）是跑着的会话那几样操作（含「置顶」，悬停出 ×），否则是
/// `AgentHistorySessionMenuItem` 那几项（继续、置顶、拷贝会话 ID、删除）。
private struct AgentHistoryRowMenu: ViewModifier {
    let file: AgentHistorySessionFile
    let pins: AgentHistoryPins?
    let run: AgentHistoryRunRow?
    let actions: AgentHistoryRunActions?
    /// 能拖动置顶时这个列表的拖动状态：这一行被拖起来时不出 ×。
    var drag: AgentHistoryPinDragModel? = nil

    let history: AgentHistoryModel
    /// 继续这个会话；nil = 菜单里不出这一项。
    var onResume: ((AgentHistorySessionFile) -> Void)? = nil
    /// 点了「删除会话…」：交给列表去确认。
    var onDelete: (AgentHistorySessionFile) -> Void = { _ in }

    func body(content: Content) -> some View {
        if let run, actions != nil {
            content.modifier(AgentHistoryRunRowActions(row: run, file: file, pins: pins, actions: actions, drag: drag))
        } else {
            let items = AgentHistorySessionMenuItem.items(
                hasRecord: true, canResume: onResume != nil && history.resumeCommand(for: file) != nil,
                canPin: pins != nil, isPinned: pins?.isPinned(file) ?? false, isRunning: false,
                canDelete: history.canDelete(file))
            content.contextMenu {
                ForEach(items, id: \.self) { item in
                    if item.isDestructive, items.count > 1 { Divider() }
                    button(item)
                }
            }
        }
    }

    @ViewBuilder private func button(_ item: AgentHistorySessionMenuItem) -> some View {
        switch item {
        case .resume:
            Button(AgentHistoryText.resumeSession) { onResume?(file) }
        case .pin(let isPinned):
            Button(AgentHistoryText.pinAction(isPinned: isPinned)) { pins?.toggle(file) }
        case .copySessionID:
            Button(AgentHistoryText.copySessionID) { AgentHistoryPasteboard.copy(file.sessionID) }
        case .delete:
            Button(AgentHistoryText.deleteSession, role: .destructive) { onDelete(file) }
        case .endSession:
            EmptyView()
        }
    }
}

/// 跑着的会话那一行悬停时右端的 ×：结束会话，在这一行里上下居中。它后面垫一条整行高、颜色同这一行的底，
/// 把两行字的行尾都盖住（只垫按钮那一小块的话，居中之后上下各露出半截字）；悬在 × 上时按钮那一块再深一点。
struct AgentHistoryRunEndButton: View {
    let isSelected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hovered ? UD.text : UD.text3)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovered ? UD.panelHover : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.udPlain)
        .hoverGated { hovered = $0 }
        .help(AgentHistoryText.endSession)
        .accessibilityLabel(Text(AgentHistoryText.endSession))
        .padding(.horizontal, 5)
        .frame(maxHeight: .infinity)
        .background {
            // 右边两个角同这一行选中底色的圆角（6）。
            let strip = UnevenRoundedRectangle(bottomTrailingRadius: 6, topTrailingRadius: 6)
            strip.fill(UD.card).overlay(strip.fill(isSelected ? UD.rowSelected : Color.clear))
        }
    }
}

// MARK: - 拖动置顶

extension UTType {
    /// 拖动置顶的载荷类型：只是个标记，里面没有任何东西（拖的是哪一个记在进程里的 `AgentHistoryPinDragModel`）。
    /// 只对本进程可见，拖到别的 App、终端、标签条上都不认。需在 `Info.plist` 的 `UTExportedTypeDeclarations` 里登记。
    nonisolated static let utermAgentHistoryPin = UTType(exportedAs: "com.uozi.uterm.agent-history-pin")
}

nonisolated enum AgentHistoryPinDragPayload {
    /// 不带对话内容、标题、路径、会话 ID：一个空的标记（拖动只在本 App 里移动，见 `.dragSource`）。
    static func pasteboardItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setData(Data(), forType: NSPasteboard.PasteboardType(UTType.utermAgentHistoryPin.identifier))
        return item
    }
}

/// 一个列表的拖动置顶状态：拖的是哪一个、此刻落在哪、各行在列表里的位置。
///
/// 拖动（`.dragSource`）没有结束回调：拖到别处松手、按 Esc 取消，`dragging` 都还留着。所以只在拖动正悬在这个列表上
/// （`isOver`，由系统的进出回调维护，会自己复位）时才画被拖的行、落点；落下时还要核对这次拖动确实是从这个列表起的
/// （`active`：最近一次开始拖动的那个列表），别的窗口的列表、上一次没落下的拖动都不算。
@MainActor
@Observable
final class AgentHistoryPinDragModel {
    nonisolated static let space = "agentHistoryPinList"
    /// 最近一次开始拖动的那个列表。
    private static weak var active: AgentHistoryPinDragModel?

    enum Slot: Hashable {
        case strip
        case pinnedHeader
        case pinnedRow(AgentHistoryPinKey)
    }

    private(set) var dragging: AgentHistoryPinKey?
    /// 此刻落在哪；nil = 拖动不在这个列表上。
    private(set) var target: AgentHistoryPinDrop?
    var isOver: Bool { target != nil }
    /// 各个落点相关的行在列表内容里的位置（随布局变，不随滚动变）。不参与观察：只在拖动时读。
    @ObservationIgnored var frames: [Slot: CGRect] = [:]

    /// 界面画廊用：下一个建出来的列表摆成「正拖着 `dragging`、落在 `target`」的样子（拖动中的样子拍不到）。App 里始终为 nil。
    static var catalogPreset: (dragging: AgentHistoryPinKey, target: AgentHistoryPinDrop)?

    static func forList() -> AgentHistoryPinDragModel {
        let model = AgentHistoryPinDragModel()
        if let preset = catalogPreset {
            model.dragging = preset.dragging
            model.target = preset.target
        }
        return model
    }

    func begin(_ key: AgentHistoryPinKey) {
        dragging = key
        target = nil
        Self.active = self
    }

    /// 这一行正被拖着、悬在这个列表上：画成淡的一行。
    func isLifted(_ key: AgentHistoryPinKey) -> Bool { isOver && dragging == key }

    /// 这次拖动是这个列表起的。
    var ownsCurrentDrag: Bool { Self.active === self && dragging != nil }

    func setTarget(_ drop: AgentHistoryPinDrop?) {
        if target != drop { target = drop }
    }

    func end() {
        dragging = nil
        target = nil
        if Self.active === self { Self.active = nil }
    }

    /// 按此刻的位置算落在哪（见 `AgentHistoryPinning.drop`）。
    func drop(at location: CGPoint, pinned: [AgentHistorySessionFile], pinnedCollapsed: Bool) -> AgentHistoryPinDrop {
        guard let dragging else { return .none }
        let keys = pinned.map(AgentHistoryPinKey.init)
        let others = keys.filter { $0 != dragging }
        let bottom: CGFloat?
        if keys.isEmpty {
            bottom = frames[.strip]?.maxY
        } else if !pinnedCollapsed, let last = keys.last, let frame = frames[.pinnedRow(last)] {
            bottom = frame.maxY + 3
        } else {
            bottom = frames[.pinnedHeader]?.maxY
        }
        // 组折起来了、或者行还没排出来：都算在上面（落在组里就排到最后）。
        let mids = others.map { pinnedCollapsed ? -CGFloat.infinity : (frames[.pinnedRow($0)]?.midY ?? -CGFloat.infinity) }
        return AgentHistoryPinning.drop(at: location.y, pinnedBottom: bottom, otherRowMidYs: mids,
                                        draggedIsPinned: keys.contains(dragging))
    }

    /// 插入线画在这一行的上沿：落点是它前面。
    func indicator(before key: AgentHistoryPinKey, pinned: [AgentHistorySessionFile]) -> Bool {
        guard case .pin(let index) = target, key != dragging else { return false }
        let others = pinned.map(AgentHistoryPinKey.init).filter { $0 != dragging }
        return others.firstIndex(of: key) == index
    }

    /// 插入线画在这一行的下沿：落点是组的最后，它是（不算被拖的）最后一行。
    func indicatorAfter(_ key: AgentHistoryPinKey, pinned: [AgentHistorySessionFile]) -> Bool {
        guard case .pin(let index) = target, key != dragging else { return false }
        let others = pinned.map(AgentHistoryPinKey.init).filter { $0 != dragging }
        return index == others.count && others.last == key
    }
}

/// 把一个落点相关的行的位置记进 `AgentHistoryPinDragModel.frames`（列表内容的坐标）。`slot` 为 nil 不记。
private struct AgentHistoryPinFrameProbe: ViewModifier {
    let drag: AgentHistoryPinDragModel
    let slot: AgentHistoryPinDragModel.Slot?

    func body(content: Content) -> some View {
        if let slot {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(AgentHistoryPinDragModel.space)) } action: {
                drag.frames[slot] = $0
            }
        } else {
            content
        }
    }
}

/// 整个列表一个落点：按位置算是进「置顶」（第几个）、拖出去（取消置顶）还是什么都不做。
/// 只认这个列表自己起的拖动（`ownsCurrentDrag`）；文件、标签页、别的列表拖过来的都不接。
private struct AgentHistoryPinDropTarget: ViewModifier {
    let drag: AgentHistoryPinDragModel
    let pins: AgentHistoryPins?
    let pinned: [AgentHistorySessionFile]
    let pinnedCollapsed: Bool

    func body(content: Content) -> some View {
        if let pins {
            content.onDrop(of: [.utermAgentHistoryPin],
                           delegate: Delegate(drag: drag, pins: pins, pinned: pinned, pinnedCollapsed: pinnedCollapsed))
        } else {
            content
        }
    }

    private struct Delegate: DropDelegate {
        let drag: AgentHistoryPinDragModel
        let pins: AgentHistoryPins
        let pinned: [AgentHistorySessionFile]
        let pinnedCollapsed: Bool

        func validateDrop(info: DropInfo) -> Bool {
            drag.ownsCurrentDrag && info.hasItemsConforming(to: [.utermAgentHistoryPin])
        }

        func dropEntered(info: DropInfo) { update(info) }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            DropProposal(operation: update(info) == .none ? .forbidden : .move)
        }

        func dropExited(info: DropInfo) { drag.setTarget(nil) }

        func performDrop(info: DropInfo) -> Bool {
            guard drag.ownsCurrentDrag, let key = drag.dragging else { return false }
            let drop = drag.drop(at: info.location, pinned: pinned, pinnedCollapsed: pinnedCollapsed)
            drag.end()
            switch drop {
            case .pin(let index):
                withAnimation(.easeOut(duration: 0.15)) {
                    pins.place(key, at: index, visible: pinned.map(AgentHistoryPinKey.init))
                }
                return true
            case .unpin:
                withAnimation(.easeOut(duration: 0.15)) { pins.unpin(key) }
                return true
            case .none:
                return false
            }
        }

        @discardableResult
        private func update(_ info: DropInfo) -> AgentHistoryPinDrop {
            guard drag.ownsCurrentDrag else {
                drag.setTarget(nil)
                return .none
            }
            let drop = drag.drop(at: info.location, pinned: pinned, pinnedCollapsed: pinnedCollapsed)
            drag.setTarget(drop)
            return drop
        }
    }
}

/// 落点那一条的位置：拖动悬在列表上时才出来。拖动的状态只在这里和 `AgentHistoryPinDragRowState` 里读——
/// 落点每变一次只重画这几处，不连带整个列表（列表那一层要按上千份记录分组，拖动时每一下都重算就掉帧）。
private struct AgentHistoryPinDropStripSlot: View {
    let drag: AgentHistoryPinDragModel

    var body: some View {
        if drag.isOver {
            AgentHistoryPinDropStrip(isTargeted: drag.target == .pin(index: 0))
                .modifier(AgentHistoryPinFrameProbe(drag: drag, slot: .strip))
        }
    }
}

/// 一行在拖动置顶时的样子：被拖起来的淡下去；在「置顶」里的（`pinned` 不为 nil）落点在它上下沿时画插入线。
private struct AgentHistoryPinDragRowState: ViewModifier {
    let drag: AgentHistoryPinDragModel
    let key: AgentHistoryPinKey
    let pinned: [AgentHistorySessionFile]?

    func body(content: Content) -> some View {
        content
            .opacity(drag.isLifted(key) ? 0.4 : 1)
            .overlay(alignment: .top) {
                if let pinned, drag.indicator(before: key, pinned: pinned) { AgentHistoryPinInsertionLine().offset(y: -2) }
            }
            .overlay(alignment: .bottom) {
                if let pinned, drag.indicatorAfter(key, pinned: pinned) { AgentHistoryPinInsertionLine().offset(y: 2) }
            }
    }
}

/// 还没有置顶的会话、正拖着一个会话时列表顶上那一条：「拖到这里置顶」，拖到上面时高亮。
private struct AgentHistoryPinDropStrip: View {
    let isTargeted: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "pin")
                .font(.system(size: 11, weight: .medium))
            Text(AgentHistoryText.dropToPin)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(isTargeted ? UD.accent : UD.text3)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6).fill(isTargeted ? UD.accentSoft : UD.fillSoft))
        // 盖在列表上（不占位置）：底下垫一层不透明的，免得透出下面那一行的字。
        .background(RoundedRectangle(cornerRadius: 6).fill(UD.card))
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
    }
}

/// 拖进「置顶」时落在哪的那条线。
private struct AgentHistoryPinInsertionLine: View {
    var body: some View {
        Capsule().fill(UD.accent)
            .frame(height: 2)
            .padding(.horizontal, 4)
            .allowsHitTesting(false)
    }
}

// MARK: - 对话

struct AgentTranscriptPane: View {
    let transcript: AgentTranscriptModel
    let metadata: AgentHistorySessionMetadata?
    let canResume: Bool
    /// 这个会话正在 Code 标签页里跑着：按钮是「返回终端」。
    var isRunning = false
    let onResume: () -> Void
    /// 子代理的记录：回到上一层。主对话为 nil。
    var onBack: (() -> Void)? = nil
    var onOpenSubagent: (AgentSubagentLink) -> Void = { _ in }
    /// 从搜索命中处打开的：换回从末尾打开。
    var onJumpToLatest: () -> Void = {}
    /// 这份记录是「接着往下聊」串起来的几份之一：顶上给一条，能翻到之前 / 后来那段（见 `AgentHistoryContinuation`）。
    var continuation: AgentHistoryContinuation.Link? = nil
    var onOpenPart: (AgentHistorySessionFile) -> Void = { _ in }

    @Environment(\.agentHistoryHeaderDivider) private var showsHeaderDivider

    var body: some View {
        VStack(spacing: 0) {
            header
            if showsHeaderDivider { Rectangle().fill(UD.border).frame(height: 1) }
            if transcript.opensAtHit, !transcript.reachedEnd {
                hitBanner
                Rectangle().fill(UD.border).frame(height: 1)
            }
            if let continuation {
                continuationBanner(continuation)
                Rectangle().fill(UD.border).frame(height: 1)
            }
            AgentTranscriptMessages(transcript: transcript, onOpenSubagent: onOpenSubagent) { loadEarlier in
                top(loadEarlier)
            } bottom: {
                bottom
            }
        }
    }

    /// 「接着往下聊」串起来的另一段：顶上说一句，给按钮翻过去。
    private func continuationBanner(_ link: AgentHistoryContinuation.Link) -> some View {
        let target: AgentHistorySessionFile
        switch link {
        case .previous(let file), .next(let file): target = file
        }
        return HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(UD.text3)
            Text(AgentHistoryText.continuationNotice(link))
                .font(.system(size: 11.5))
                .foregroundStyle(UD.text2)
                .lineLimit(1)
            Spacer(minLength: 8)
            UDButton(title: AgentHistoryText.continuationAction(link), style: .secondary,
                     systemImage: { if case .previous = link { return "arrow.up" } else { return "arrow.down" } }(),
                     action: { onOpenPart(target) })
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(UD.fillSoft)
    }

    /// 从命中处打开、后面还没读到末尾：顶上说一句，给「跳到最新」。
    private var hitBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(UD.text3)
            Text(AgentHistoryText.openedAtHit)
                .font(.system(size: 11.5))
                .foregroundStyle(UD.text2)
                .lineLimit(1)
            Spacer(minLength: 8)
            UDButton(title: AgentHistoryText.jumpToLatest, style: .secondary, systemImage: "arrow.down.to.line",
                     action: onJumpToLatest)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(UD.fillSoft)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.udPlain)
                .iconButtonHover(cornerRadius: 6)
                .help(AgentHistoryText.backToParent)
                .accessibilityLabel(Text(AgentHistoryText.backToParent))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(titleLine)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(UD.text)
                        .lineLimit(1)
                    if transcript.isUpdating { AgentUpdatingBadge() }
                }
                AgentTranscriptDetailText(transcript: transcript, metadata: metadata)
                    .font(.system(size: 11))
                    .foregroundStyle(UD.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Menu {
                if transcript.subagent == nil {
                    Button(String(localized: "拷贝会话 ID")) { AgentHistoryPasteboard.copy(transcript.file.sessionID) }
                }
                Button(String(localized: "拷贝已加载的对话")) { AgentHistoryPasteboard.copy(transcript.plainText) }
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28, height: 26)
            .help(String(localized: "拷贝"))
            // 子代理的记录只读：不能单独继续。
            if transcript.subagent == nil, isRunning {
                UDButton(title: AgentHistoryText.backToTerminal, systemImage: "terminal", action: onResume)
                    .help(String(localized: "这个会话正在这个标签页里运行，回到它的终端",
                                 comment: "Code 标签页：看记录时回到正在跑的那个终端"))
            } else if transcript.subagent == nil {
                UDButton(title: String(localized: "继续这个会话"), systemImage: "play.fill", action: onResume)
                    .disabled(!canResume)
                    .help(AgentHistoryText.resumeHelp(transcript.file.tool, canResume: canResume))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }

    private var titleLine: String {
        transcript.subagent.map(AgentHistoryText.subagentTitle) ?? AgentHistoryText.transcriptTitle(metadata)
    }

    /// 列表最顶上：出错重试、读取中、「加载更早的消息」。
    @ViewBuilder private func top(_ loadEarlier: @escaping () -> Void) -> some View {
        if let error = transcript.errorMessage {
            HStack(spacing: 8) {
                SettingsInlineNote(tone: .warning, text: error)
                UDButton(title: String(localized: "重试"), style: .secondary) { loadEarlier() }
            }
        } else if transcript.isLoading {
            HStack {
                Spacer()
                UDIndeterminateBar().frame(width: 120)
                Spacer()
            }
            .padding(.vertical, 8)
        } else if !transcript.reachedStart {
            HStack {
                Spacer()
                UDButton(title: String(localized: "加载更早的消息"), style: .secondary, systemImage: "arrow.up") {
                    loadEarlier()
                }
                Spacer()
            }
        }
    }

    /// 从命中处打开的：后面还有，「加载更晚的消息」（滚到底也会读，见 `AgentTranscriptTailFollow`）。
    @ViewBuilder private var bottom: some View {
        if !transcript.reachedEnd {
            HStack(spacing: 8) {
                Spacer()
                if let error = transcript.laterErrorMessage {
                    SettingsInlineNote(tone: .warning, text: error)
                }
                if transcript.isLoadingLater {
                    UDIndeterminateBar().frame(width: 120).padding(.vertical, 8)
                } else {
                    UDButton(title: AgentHistoryText.loadLater, style: .secondary, systemImage: "arrow.down") {
                        Task { await transcript.loadLater() }
                    }
                }
                Spacer()
            }
        }
    }
}

/// 标题旁的「正在更新」：这份对话最近还在变（会话开着）。
private struct AgentUpdatingBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(UD.success).frame(width: 6, height: 6)
            Text(AgentHistoryText.updating)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(UD.success)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(UD.success.opacity(0.12)))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// 往上翻着时末尾来了新内容：底部的「有新消息」，点了跳到底。
struct AgentNewMessagesPill: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 10.5, weight: .semibold))
                Text(AgentHistoryText.newMessages)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(UD.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            // 浮层的底色（浅色下是白的），不用强调色整块铺：它盖在对话上，只是个提示。
            .background(Capsule().fill(UD.overlay))
            .overlay(Capsule().strokeBorder(UD.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.udPlain)
    }
}

/// 记录里的一段 Markdown：第一次排版就是解析好的样子。
///
/// 不用 `StreamingMarkdownView`：它在 `onAppear` 里才解析，没出现过的行懒栈都按空文档量高（几乎是 0），
/// 整份对话量出来只有实际的五分之一（120 条：4957 vs 22751pt）。往回翻时一行行出现、一行行长到真实高度，
/// 文档高度在滚动中一次变几百点，视口里的内容跟着往前跳几百点、或者整屏换到别处，滚动条滑块也跟着跳
/// （`ClaudeTranscriptScrollProbeTests`）。记录里的文字是落定的，这里在 body 里同步取解析结果，第一次量高就是对的；
/// 解析过的进缓存，回收后再出现不重解析。
struct AgentTranscriptMarkdown: View {
    let text: String

    var body: some View {
        MarkdownBlocks(document: MarkdownDocumentCache.transcript.document(for: text), style: .chat)
    }
}

/// 派子代理的调用下面的入口：点进去看那个子代理自己的记录。
struct AgentSubagentEntry: View {
    let link: AgentSubagentLink
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(UD.accent)
                Text(AgentHistoryText.subagentEntry)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(UD.accent)
                let detail = AgentHistoryText.subagentEntryDetail(link)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(UD.text4)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(UD.text4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(UD.accentSoft))
            .contentShape(Rectangle())
        }
        .buttonStyle(.udPlain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - 共用视图的平台一层（iOS 在 `ClaudeHistoryTab.swift` 里有同名的一份，见 `AgentTranscriptMessages`、`AgentHistoryListViews`）

/// 空状态。
struct AgentHistoryStateView: View {
    let icon: AgentHistoryStateIcon
    let title: String
    let detail: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        RemoteMacStateView(systemImage: icon == .warning ? "exclamationmark.triangle" : "magnifyingglass",
                           title: title, detail: detail) {
            if let actionTitle, let action { UDButton(title: actionTitle, action: action) }
        }
    }
}

/// 列表、搜索结果里的一句警示（搜索出错）。
struct AgentHistoryWarningNote: View {
    let text: String

    var body: some View {
        SettingsInlineNote(tone: .warning, text: text)
            .padding(.horizontal, 4)
    }
}

/// 组标题上组里跑着的会话的状态点：同行上状态的圆点颜色（`AgentHistoryRunStatusTag`）；都没报过状态是灰的。
struct AgentHistoryRunMarkDot: View {
    let mark: CodeRunGroupMark

    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
    }

    private var color: Color {
        if case .program(let record) = mark.status { return record.tabDot }
        return UD.text4
    }
}

extension View {
    /// 右键「拷贝文字」。文字点了才取。
    func agentTranscriptCopyMenu(_ text: @escaping () -> String) -> some View {
        contextMenu {
            Button(String(localized: "拷贝文字")) { AgentHistoryPasteboard.copy(text()) }
        }
    }

    /// 行、可展开那一行的按钮：不带按下的效果（悬停、选中的底色由行自己画）。
    func agentHistoryPressStyle() -> some View {
        buttonStyle(.udPlain)
    }

    func agentHistoryScrollChrome() -> some View { self }
}

/// 拖动置顶时跟着光标的那一行：不透明、带阴影的卡片（不然字直接叠在别的行上，两行重影读不清）。
struct AgentHistorySessionRowPreview: View {
    let history: AgentHistoryModel
    let file: AgentHistorySessionFile
    var showsTool = false

    var body: some View {
        AgentHistorySessionRow(history: history, file: file, metadata: history.metadata[file.path],
                               showsProject: false, showsTool: showsTool, isSelected: false)
            .frame(width: AgentHistoryPinDragPreview.width, alignment: .leading)
            .modifier(AgentHistoryPinDragPreview())
    }
}

/// 拖动置顶时跟着光标的那张卡片：不透明的底、细描边、阴影（同 Mac 列表里拖起来的行）。
struct AgentHistoryPinDragPreview: ViewModifier {
    static let width: CGFloat = 260

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(UD.card))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(UD.border))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .padding(10)
    }
}

extension EnvironmentValues {
    /// 会话列表、对话记录顶上那一行下面画不画横线。Code 标签页里不画（侧栏与右边的标题行连成一片）；
    /// 独立的历史会话窗口照旧画。
    @Entry var agentHistoryHeaderDivider = true
}
