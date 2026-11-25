import AppKit
import SwiftUI
import UAppKitBridge
import UDesignKit
import UniformTypeIdentifiers

/// 在 Code 标签页里跑着的会话（`CodeTabModel.runs`）：列表里对应的行标成「运行中」；列表里没有行的（还没对上记录的
/// 新会话）放在列表最顶上。不另起一组「正在运行」：一个会话只出现一次。独立的历史窗口没有。
struct AgentHistoryRunning {
    /// 在 Code 标签页里跑着（或已结束、留着画面）的会话，按起来的先后。列表把它们都放在最顶上，置顶与下面的分组里
    /// 不再出现（一个会话只出现一次）；结束、拿掉之后回到它的记录平常的位置。
    let rows: () -> [AgentHistoryRunRow]
    let onSelect: (UUID) -> Void
    /// 行上的操作（右键菜单、悬停的 ×）。nil = 没有（只能点一下回到它）。
    var actions: AgentHistoryRunActions? = nil
}

/// 顶上跑着的会话那一行的操作，同终端顶上「⋯」菜单里的那几样。
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

/// 列表最顶上的一行：一个跑着的会话。有记录、列表里有那份记录的，画成那份记录平常的样子；没有的（还没写出记录的新会话）
/// 写标题与目录。行上的状态见 `AgentHistoryRunStatus`。
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
}

/// 一个跑着的会话此刻的状态：程序经 OSC 7501 报的（同终端标签页上的圆点与文字），没报过就是「运行中」，程序退出了
/// 是「已结束」（优先）。`read` 在显示它的那一小块视图里调：状态变了只重画那一行，不让整个列表重算。
struct AgentHistoryRunStatus {
    enum Phase: Equatable {
        case running
        case ended
        case program(ProgramStatusRecord)
    }

    let read: @MainActor () -> Phase
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
                AgentHistorySessionList(history: history, newSession: newSession, reveal: reveal)
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
                                        onJumpToLatest: { history.jumpToLatest() })
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
    /// Code 标签页里跑着的会话：列表里对应的行标成「运行中」，列表里没有行的放在最顶上。
    var running: AgentHistoryRunning? = nil
    /// 收起侧栏（Code 标签页，放在菜单里）；nil = 菜单里不出这一项。
    var onCollapse: (() -> Void)? = nil

    @AppStorage(DefaultsKey.agentHistoryGrouping) private var groupingRaw = AgentHistoryGrouping.default.rawValue
    @AppStorage(DefaultsKey.agentHistoryShownTools) private var shownToolsRaw = ""
    /// 还没定位成功的那一次请求（组还没列出来）：列表有了变化再试。
    @State private var pendingReveal: AgentHistoryReveal?
    /// 拖动置顶的状态（只在这个列表里认）。
    @State private var pinDrag = AgentHistoryPinDragModel.forList()

    /// 只有一种工具时没有「工具」这种分组：存的是它就按默认的来。
    private var grouping: AgentHistoryGrouping {
        AgentHistoryListPreferences.effectiveGrouping(groupingRaw, isMultiTool: history.isMultiTool)
    }

    private var groupingChoices: [AgentHistoryGrouping] {
        AgentHistoryListPreferences.groupingChoices(isMultiTool: history.isMultiTool)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(UD.border).frame(height: 1)
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
    private var optionsMenu: some View {
        Menu {
            Picker(selection: Binding(get: { grouping }, set: { groupingRaw = $0.rawValue })) {
                ForEach(groupingChoices) { choice in
                    Text(AgentHistoryText.groupingName(choice)).tag(choice)
                }
            } label: {
                Text("分组方式", comment: "历史会话列表菜单：按什么分组")
            }
            .pickerStyle(.inline)
            if history.isMultiTool {
                Section(String(localized: "显示", comment: "历史会话列表菜单：只看哪几种编码工具")) {
                    let effective = history.effectiveTools
                    ForEach(history.availableTools) { tool in
                        Toggle(tool.displayName, isOn: Binding(
                            get: { effective.contains(tool) },
                            set: { _ in
                                let next = AgentHistoryListing.toggling(tool, shown: history.shownTools,
                                                                        available: history.availableTools)
                                shownToolsRaw = AgentHistoryListPreferences.encodeTools(next)
                            }))
                        .disabled(effective == [tool])
                    }
                }
            }
            Divider()
            // 只管分组方式与「显示」，不清置顶。
            Button(String(localized: "恢复默认")) {
                groupingRaw = AgentHistoryGrouping.default.rawValue
                shownToolsRaw = ""
            }
            Divider()
            Button(String(localized: "刷新")) { Task { await history.reload() } }
            if let onCollapse {
                Button(String(localized: "收起侧栏", comment: "Code 标签页：收起左边的会话列表"), action: onCollapse)
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 26, height: 26)
        .contentShape(Rectangle())
        .iconButtonHover(cornerRadius: 6)
        .help(String(localized: "分组与显示"))
        .accessibilityLabel(Text("分组与显示"))
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

    private func list(_ allFiles: [AgentHistorySessionFile], pinned allPinned: [AgentHistorySessionFile],
                      runs: [AgentHistoryRunRow]) -> some View {
        // 跑着的都在最顶上，下面（置顶、分组）不再出现。
        let runPaths = Set(runs.compactMap(\.path))
        let (files, pinned) = AgentHistoryListing.excludingRunning(allFiles, pinned: allPinned, running: runPaths)
        let byPath = Dictionary((allFiles + allPinned).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let groups = AgentHistoryListing.groups(files, by: grouping, metadata: history.metadata, pinned: pinned,
                                                date: { history.liveActivity(of: $0) ?? $0.modifiedAt })
        let pins = history.pins
        // 拖动中、还没有置顶的会话：分组最上面盖一条落点。盖在上面、不占位置：出现消失都不推动列表，拖着的落点不跟着跳。
        let showsDropStrip = pins != nil && pinned.isEmpty && pinDrag.isOver
        return GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(runs) { row in
                            let file = row.path.flatMap { byPath[$0] }
                            runRow(row, file: file)
                                .modifier(AgentHistoryRunRowActions(row: row, file: file, pins: pins,
                                                                    actions: running?.actions))
                                .onTapGesture { running?.onSelect(row.id) }
                        }
                        if !runs.isEmpty, !groups.isEmpty {
                            Rectangle().fill(UD.border).frame(height: 1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }
                        if pins != nil, pinned.isEmpty {
                            // 落点的锚：零高度，一直在（拖动开始时不插进新的一行）。落点画在它下面、盖住接下来的那一截。
                            Color.clear.frame(height: 0)
                                .overlay(alignment: .top) {
                                    if showsDropStrip {
                                        AgentHistoryPinDropStrip(isTargeted: pinDrag.target == .pin(index: 0))
                                            .modifier(AgentHistoryPinFrameProbe(drag: pinDrag, slot: .strip))
                                    }
                                }
                                .zIndex(1)
                        }
                        ForEach(groups) { group in
                            let collapsed = history.collapsedGroups.contains(group.id)
                            if AgentHistoryListing.showsHeader(group, in: groups) {
                                AgentHistoryGroupHeader(group: group, collapsed: collapsed) { toggle(group.id) }
                                    .id(group.id)
                                    .modifier(AgentHistoryPinFrameProbe(drag: pinDrag,
                                                                        slot: group.kind == .pinned ? .pinnedHeader : nil))
                            }
                            if !collapsed {
                                let showsTool = group.mixesTools
                                ForEach(group.files) { file in
                                    row(file, in: group, showsTool: showsTool, pins: pins, pinned: pinned)
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
                .onChange(of: groups.map(\.id)) { _, _ in tryReveal(groups, proxy: proxy) }
            }
        }
    }

    /// 顶上一个跑着的会话：列表里有它那份记录的画成记录平常的那一行，没有的写标题与目录。行上的状态是它此刻的状态。
    @ViewBuilder
    private func runRow(_ row: AgentHistoryRunRow, file: AgentHistorySessionFile?) -> some View {
        if let file {
            AgentHistorySessionRow(history: history, file: file, metadata: history.metadata[file.path],
                                   showsProject: true, showsTool: history.isMultiTool, isSelected: row.isSelected,
                                   runStatus: row.status)
        } else {
            AgentHistoryUnlistedRunRow(row: row, showsTool: history.isMultiTool)
        }
    }

    /// 一行会话：点一下选中；Mac 上能拖进 / 拖出「置顶」，右键「置顶」/「取消置顶」（同一件事，菜单好找）。
    @ViewBuilder
    private func row(_ file: AgentHistorySessionFile, in group: AgentHistoryGroup, showsTool: Bool,
                     pins: AgentHistoryPins?, pinned: [AgentHistorySessionFile]) -> some View {
        let key = AgentHistoryPinKey(file)
        let base = AgentHistorySessionRow(history: history, file: file, metadata: history.metadata[file.path],
                                          showsProject: grouping != .project || group.kind == .pinned,
                                          showsTool: showsTool,
                                          isSelected: history.selectedFile?.path == file.path)
            .onTapGesture { history.select(file) }
        if let pins {
            let isPinned = group.kind == .pinned
            base
                .opacity(pinDrag.isOver && pinDrag.dragging == key ? 0.4 : 1)
                .overlay(alignment: .top) {
                    if isPinned, pinDrag.indicator(before: key, pinned: pinned) { AgentHistoryPinInsertionLine().offset(y: -2) }
                }
                .overlay(alignment: .bottom) {
                    if isPinned, pinDrag.indicatorAfter(key, pinned: pinned) { AgentHistoryPinInsertionLine().offset(y: 2) }
                }
                .modifier(AgentHistoryPinFrameProbe(drag: pinDrag, slot: isPinned ? .pinnedRow(key) : nil))
                .onDrag {
                    pinDrag.begin(key)
                    return AgentHistoryPinDragPayload.itemProvider()
                } preview: {
                    AgentHistorySessionRowPreview(history: history, file: file, showsTool: showsTool)
                }
                .contextMenu {
                    Button(AgentHistoryText.pinAction(isPinned: pins.isPinned(key))) { pins.toggle(file) }
                }
        } else {
            base
        }
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

/// 组标题：折叠箭头、标题、会话数。点一下折起 / 展开。
private struct AgentHistoryGroupHeader: View {
    let group: AgentHistoryGroup
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(UD.text4)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 10)
                Text(AgentHistoryText.groupTitle(group))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(UD.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(verbatim: "\(group.files.count)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(UD.text4)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.udPlain)
        .padding(.top, 4)
        .help(AgentHistoryText.groupHelp(group).map { Text(verbatim: $0) } ?? Text(verbatim: ""))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(AgentHistoryText.groupAccessibility(group, collapsed: collapsed)))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - 运行中

/// 「运行中」小标记：绿点 + 字。
struct AgentHistoryRunningTag: View {
    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(UD.success).frame(width: 6, height: 6)
            Text("运行中")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(UD.success)
        }
        .fixedSize()
    }
}

/// 跑着的会话行上的状态：程序报的状态用终端标签页上同一套圆点颜色与文字（`ProgramStatusRecord.tabDot` /
/// `statusLabel`），没报过是「运行中」，程序退出了是「已结束」。在自己的 `body` 里读状态：变了只重画这一小块。
struct AgentHistoryRunStatusTag: View {
    let status: AgentHistoryRunStatus

    var body: some View {
        let phase = status.read()
        HStack(spacing: 3) {
            Circle().fill(color(phase)).frame(width: 6, height: 6)
            Text(verbatim: label(phase))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(phase == .ended ? UD.text3 : color(phase))
        }
        .fixedSize()
        .help(Text(verbatim: help(phase)))
    }

    private func color(_ phase: AgentHistoryRunStatus.Phase) -> Color {
        switch phase {
        case .running: UD.success
        case .ended: UD.text4
        case .program(let record): record.tabDot
        }
    }

    private func label(_ phase: AgentHistoryRunStatus.Phase) -> String {
        switch phase {
        case .running: String(localized: "运行中")
        case .ended: AgentHistoryText.sessionEnded
        case .program(let record): record.statusLabel
        }
    }

    private func help(_ phase: AgentHistoryRunStatus.Phase) -> String {
        switch phase {
        case .running: String(localized: "运行中")
        case .ended: AgentHistoryText.sessionEnded
        case .program(let record): record.tabHelp
        }
    }
}

/// 列表最顶上那一行（`AgentHistoryRunRow`）：标题（新会话就是「新会话」），第二行「运行中」+ 目录名。点一下回到它的终端。
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

/// 顶上跑着的会话那一行的操作：右键菜单（「查看记录」/「返回终端」、「移到新标签页」、有记录的「置顶」、「结束会话」），
/// 悬停时右上角一个 ×（结束会话）。× 盖在行上、不占位置：出现消失这一行的字不挪。这几行不能拖（跑着的不进「置顶」那一套拖动）。
struct AgentHistoryRunRowActions: ViewModifier {
    let row: AgentHistoryRunRow
    let file: AgentHistorySessionFile?
    let pins: AgentHistoryPins?
    let actions: AgentHistoryRunActions?

    /// 界面画廊与测试用：建出来的行一开始就当作鼠标悬在上面（悬停拍不到）。App 里始终为 false。
    static var catalogHovered = false

    @State private var hovered = AgentHistoryRunRowActions.catalogHovered

    func body(content: Content) -> some View {
        if let actions {
            content
                .overlay(alignment: .topTrailing) {
                    if hovered {
                        AgentHistoryRunEndButton(isSelected: row.isSelected) { actions.end(row.id) }
                            .padding(.top, 5)
                            .padding(.trailing, 5)
                    }
                }
                .hoverGated { hovered = $0 || Self.catalogHovered }
                .contextMenu { menu(actions) }
        } else {
            content
        }
    }

    @ViewBuilder private func menu(_ actions: AgentHistoryRunActions) -> some View {
        if row.path != nil {
            if row.showsRecord {
                Button(String(localized: "返回终端")) { actions.showTerminal(row.id) }
            } else {
                Button(String(localized: "查看记录", comment: "Code 标签页：看这个正在跑的会话的对话记录")) {
                    actions.showRecord(row.id)
                }
            }
        }
        if let move = actions.moveToTab {
            Button(String(localized: "移到新标签页", comment: "Code 标签页：把这个会话的终端开成普通的终端标签页")) {
                move(row.id)
            }
        }
        if let file, let pins {
            Button(AgentHistoryText.pinAction(isPinned: pins.isPinned(AgentHistoryPinKey(file)))) { pins.toggle(file) }
        }
        Divider()
        Button(AgentHistoryText.endSession, role: .destructive) { actions.end(row.id) }
    }
}

/// 跑着的会话那一行悬停时右上角的 ×：结束会话。底色同这一行（盖住下面的字），悬在它上面时再深一点。
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
                .background {
                    RoundedRectangle(cornerRadius: 5).fill(UD.card)
                        .overlay(RoundedRectangle(cornerRadius: 5).fill(isSelected ? UD.rowSelected : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 5).fill(hovered ? UD.panelHover : Color.clear))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.udPlain)
        .hoverGated { hovered = $0 }
        .help(AgentHistoryText.endSession)
        .accessibilityLabel(Text(AgentHistoryText.endSession))
    }
}

// MARK: - 拖动置顶

extension UTType {
    /// 拖动置顶的载荷类型：只是个标记，里面没有任何东西（拖的是哪一个记在进程里的 `AgentHistoryPinDragModel`）。
    /// 只对本进程可见，拖到别的 App、终端、标签条上都不认。需在 `Info.plist` 的 `UTExportedTypeDeclarations` 里登记。
    nonisolated static let utermAgentHistoryPin = UTType(exportedAs: "com.uozi.uterm.agent-history-pin")
}

nonisolated enum AgentHistoryPinDragPayload {
    /// 不带对话内容、标题、路径、会话 ID：一个空的标记。
    static func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.utermAgentHistoryPin.identifier,
                                            visibility: .ownProcess) { completion in
            completion(Data(), nil)
            return nil
        }
        return provider
    }
}

/// 一个列表的拖动置顶状态：拖的是哪一个、此刻落在哪、各行在列表里的位置。
///
/// `.onDrag` 没有结束回调：拖到别处松手、按 Esc 取消，`dragging` 都还留着。所以只在拖动正悬在这个列表上
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
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(isTargeted ? UD.accent : UD.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
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

// MARK: - 搜索结果

/// 列表区的搜索结果：按会话分组（最近的在前），每组下面是命中的摘要行，点一条打开那份对话并停在那里。
struct AgentHistorySearchResults: View {
    let history: AgentHistoryModel
    let search: AgentHistoryModel.Search

    var body: some View {
        if search.sessions.isEmpty, !search.isRunning {
            VStack(spacing: 0) {
                excludedNote
                unsearchedNote
                emptyState
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    status
                    excludedNote
                    unsearchedNote
                    ForEach(search.sessions) { session in
                        group(session)
                    }
                    footer
                }
                .padding(6)
            }
            .scrollIndicators(.never)
        }
    }

    /// 有的工具的会话没参与搜索（记录的格式没法在主机上搜）：结果上方说一句。
    @ViewBuilder private var excludedNote: some View {
        let excluded = history.searchExcludedTools
        if !excluded.isEmpty, search.phase != .failed(AgentHistoryText.searchUnsupported(excluded)) {
            note(AgentHistoryText.searchUnsupported(excluded))
        }
    }

    /// 压缩过的记录没搜（主机上没有解压的工具）：也说一句，免得以为搜全了。
    @ViewBuilder private var unsearchedNote: some View {
        if search.unsearched > 0 { note(AgentHistoryText.searchSkippedCompressed(search.unsearched)) }
    }

    @ViewBuilder private var emptyState: some View {
        switch search.phase {
        case .failed(let message):
            RemoteMacStateView(systemImage: "exclamationmark.triangle", title: String(localized: "无法搜索"), detail: message) {
                UDButton(title: String(localized: "重试")) { history.submitSearch() }
            }
        case .stopped:
            RemoteMacStateView(systemImage: "magnifyingglass", title: AgentHistoryText.searchStopped(search),
                               detail: AgentHistoryText.searchNoResultsDetail) {
                UDButton(title: String(localized: "重试")) { history.submitSearch() }
            }
        default:
            RemoteMacStateView(systemImage: "magnifyingglass", title: AgentHistoryText.searchNoResults(search.query),
                               detail: AgentHistoryText.searchNoResultsDetail)
        }
    }

    /// 顶上：正在搜（进度 + 停止）。
    @ViewBuilder private var status: some View {
        if search.isRunning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(AgentHistoryText.searchProgress(search))
                    .font(UD.caption)
                    .foregroundStyle(UD.text3)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(AgentHistoryText.stopSearch) { history.stopSearch() }
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }

    /// 末尾：到了上限 / 停了 / 出错。
    @ViewBuilder private var footer: some View {
        if search.truncated {
            note(AgentHistoryText.searchTruncated(search.hitCount))
        } else if search.phase == .stopped {
            note(AgentHistoryText.searchStopped(search))
        } else if case .failed(let message) = search.phase {
            SettingsInlineNote(tone: .warning, text: message)
                .padding(.horizontal, 4)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(UD.caption)
            .foregroundStyle(UD.text4)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }

    /// 结果里不止一种工具：每个会话的第二行最前面写工具名（同列表的行）。
    private var showsTool: Bool { AgentHistoryListing.mixesTools(search.sessions.map(\.file)) }

    private func group(_ session: AgentHistorySearchSession) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AgentHistoryText.sessionTitle(session.file, metadata: session.metadata))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(UD.text)
                    .lineLimit(1)
                AgentSessionTimeText(history: history, file: session.file) { activity in
                    AgentHistoryText.searchSessionDetail(session, showsProject: history.scope == .all,
                                                         showsTool: showsTool, activity: activity)
                }
                .font(.system(size: 11))
                .foregroundStyle(UD.text3)
                .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.top, 2)
            .padding(.bottom, 2)
            ForEach(session.hits) { hit in
                AgentHistorySearchHitRow(hit: hit, tool: session.file.tool, isSelected: isOpen(hit, in: session))
                    .onTapGesture { history.openHit(hit, in: session) }
            }
            if session.hasMoreHits {
                note(AgentHistoryText.sessionMoreHits(session.hits.count))
            }
        }
    }

    private func isOpen(_ hit: AgentHistorySearchHit, in session: AgentHistorySearchSession) -> Bool {
        history.selectedFile?.path == session.file.path && history.transcript?.highlightedItemID == hit.itemID
    }
}

/// 一条命中：谁说的 + 前后文，命中的字加粗着色。
private struct AgentHistorySearchHitRow: View {
    let hit: AgentHistorySearchHit
    let tool: AgentHistoryTool
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(AgentHistoryText.roleLabel(hit.role, tool: tool))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(UD.text4)
            Text(AgentHistorySnippetText.attributed(hit.snippet, match: UD.accent))
                .font(.system(size: 12))
                .foregroundStyle(UD.text2)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? UD.rowSelected : Color.clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 会话一行：标题，第二行（组里不止一种工具时）工具名 · 时间 · 大小 · 分支 ·（不按项目分组时）项目。
/// 行前不画工具标记：一组里只有一种工具时它是噪音，混着的时候第二行的字说得清。
private struct AgentHistorySessionRow: View {
    let history: AgentHistoryModel
    let file: AgentHistorySessionFile
    let metadata: AgentHistorySessionMetadata?
    let showsProject: Bool
    /// 组里不止一种工具：第二行最前面写工具名。
    var showsTool = false
    let isSelected: Bool
    /// 在 Code 标签页里跑着（`AgentHistoryRunning`）：第二行前面是它此刻的状态。
    var runStatus: AgentHistoryRunStatus? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(UD.text)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                if let runStatus { AgentHistoryRunStatusTag(status: runStatus) }
                AgentSessionTimeText(history: history, file: file) { activity in
                    AgentHistoryText.sessionSubtitle(file, metadata: metadata, showsProject: showsProject,
                                                     showsTool: showsTool, activity: activity)
                }
                .font(.system(size: 11))
                .foregroundStyle(UD.text3)
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? UD.rowSelected : Color.clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var title: String { AgentHistoryText.sessionTitle(file, metadata: metadata) }
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

    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(UD.border).frame(height: 1)
            if transcript.opensAtHit, !transcript.reachedEnd {
                hitBanner
                Rectangle().fill(UD.border).frame(height: 1)
            }
            messages
        }
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
                UDButton(title: String(localized: "返回终端"), systemImage: "terminal", action: onResume)
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

    private var messages: some View {
        let items = transcript.items
        let runStarts = AgentTranscriptRuns.starts(items)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    top
                    ForEach(items) { item in
                        AgentTranscriptRow(item: item, showsRole: runStarts.contains(item.id), inSubagent: transcript.subagent != nil,
                                           tool: transcript.file.tool,
                                           subagent: subagentLink(item), onOpenSubagent: onOpenSubagent,
                                           isHighlighted: item.id == transcript.highlightedItemID,
                                           expanded: $expanded)
                            .id(item.id)
                    }
                    bottom
                    if items.isEmpty, transcript.reachedStart, transcript.errorMessage == nil {
                        Text("这个会话里没有可显示的消息。")
                            .font(UD.caption)
                            .foregroundStyle(UD.text3)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                    // 跟到底时滚到这里。底部留白由它和上面的间距承担（同原来的 14pt）：锚点下面再垫 padding，
                    // `scrollTo(_, anchor: .bottom)` 就永远差这一截（见 `TerminalAgentView`）。
                    Color.clear.frame(height: 4).id(Self.bottomID)
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
            }
            // 打开时停在最后一条；内容不满一屏时从顶上排起——只写 `.bottom` 的话短对话会贴着底、上面空一大片。
            // 从命中处打开、后面还没读到末尾时，往后加页不把视口拽到底（不然会一页接一页读下去）。
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(transcript.reachedEnd ? .bottom : .top, for: .sizeChanges)
            .defaultScrollAnchor(.top, for: .alignment)
            .onChange(of: transcript.prependGeneration) { old, _ in
                // 往前加了一页：留在原来最上面那条，不跳到别处。第一页不用（默认停在底部）。
                guard old > 0, let anchor = pendingAnchor else { return }
                proxy.scrollTo(anchor, anchor: .top)
            }
            .onChange(of: transcript.focusGeneration) { _, _ in
                // 搜索命中的那一条：滚到中间（等这一轮布局完）。
                guard let id = transcript.highlightedItemID else { return }
                Task { @MainActor in proxy.scrollTo(id, anchor: .center) }
            }
            .modifier(AgentTranscriptTailFollow(transcript: transcript, proxy: proxy, bottomID: Self.bottomID))
            .overlay(alignment: .bottom) {
                if transcript.hasNewBelow {
                    AgentNewMessagesPill {
                        transcript.setFollowsTail(true)
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    }
                    .padding(.bottom, 12)
                    .transition(.opacity)
                }
            }
        }
    }

    private static let bottomID = "agent-transcript-bottom"

    @State private var pendingAnchor: String?

    private func subagentLink(_ item: AgentTranscriptItem) -> AgentSubagentLink? {
        guard case .toolCall(let call) = item.kind else { return nil }
        return transcript.subagentLink(for: call)
    }

    @ViewBuilder private var top: some View {
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

    private func loadEarlier() {
        pendingAnchor = transcript.firstItemID
        // 要往前看：不再跟着末尾走（内容不满一屏时点「加载更早」也不会被拽回底部）。
        transcript.setFollowsTail(false)
        Task { await transcript.loadEarlier() }
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
private struct AgentNewMessagesPill: View {
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

enum AgentHistoryPasteboard {
    static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }
}

private struct AgentTranscriptRow: View {
    let item: AgentTranscriptItem
    let showsRole: Bool
    /// 子代理的记录：「用户」那一侧标成「任务」。
    var inSubagent = false
    /// 回答的一方叫什么。
    var tool: AgentHistoryTool = .claude
    /// 这次调用派出的子代理（找得到记录的才有）。
    let subagent: AgentSubagentLink?
    let onOpenSubagent: (AgentSubagentLink) -> Void
    /// 搜索命中的那一条：整条带底色和左边一道线（画在边界外，不挤动排版）。
    var isHighlighted = false
    @Binding var expanded: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsRole {
                Text(AgentHistoryText.roleLabel(item.role, inSubagent: inSubagent, tool: tool))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(UD.text3)
                    .padding(.top, 6)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 8)
                    .fill(UD.accentSoft)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5).fill(UD.accent).frame(width: 3)
                    }
                    .padding(.horizontal, -8)
                    .padding(.vertical, -5)
            }
        }
        .contextMenu {
            let text = item.plainText
            if !text.isEmpty {
                Button(String(localized: "拷贝文字")) { AgentHistoryPasteboard.copy(text) }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .userText(let text):
            StreamingMarkdownView(text: text, isStreaming: false)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(UD.fillSoft))
        case .assistantText(let text):
            StreamingMarkdownView(text: text, isStreaming: false)
                .textSelection(.enabled)
        case .command(let command):
            Text(command)
                .font(UD.mono(12, weight: .medium))
                .foregroundStyle(UD.text)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(UD.fillSoft))
        case .commandOutput(let output):
            AgentClippedBlock(id: item.id, label: String(localized: "输出"), text: output, isError: false,
                              expanded: $expanded)
        case .notice(let text):
            Label(text, systemImage: "bell")
                .font(.system(size: 11.5))
                .foregroundStyle(UD.text3)
                .lineLimit(2)
        case .thinking(let text):
            DisclosureGroup(isExpanded: binding("\(item.id).thinking")) {
                Text(text.text + (text.isClipped ? "\n…" : ""))
                    .font(.system(size: 12))
                    .italic()
                    .foregroundStyle(UD.text3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } label: {
                Label(String(localized: "思考"), systemImage: "brain")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(UD.text3)
            }
        case .toolCall(let call):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 10.5))
                        .foregroundStyle(UD.text3)
                    Text(call.name)
                        .font(UD.mono(11.5, weight: .semibold))
                        .foregroundStyle(UD.text2)
                    Text(call.summary)
                        .font(UD.mono(11.5))
                        .foregroundStyle(UD.text3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
                if let subagent {
                    AgentSubagentEntry(link: subagent) { onOpenSubagent(subagent) }
                        .padding(.leading, 18)
                }
                if let result = call.result {
                    AgentClippedBlock(id: item.id, label: AgentHistoryText.resultLabel(result), text: result.content,
                                      isError: result.isError, expanded: $expanded)
                        .padding(.leading, 18)
                }
            }
        case .toolResult(let result):
            AgentClippedBlock(id: item.id, label: AgentHistoryText.resultLabel(result), text: result.content,
                              isError: result.isError, expanded: $expanded)
        case .image:
            Label(String(localized: "图片（不显示）"), systemImage: "photo")
                .font(.system(size: 11.5))
                .foregroundStyle(UD.text3)
        case .compactSummary(let summary):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Rectangle().fill(UD.border).frame(height: 1)
                    Text("上下文已压缩")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(UD.text3)
                        .fixedSize()
                    Rectangle().fill(UD.border).frame(height: 1)
                }
                AgentClippedBlock(id: item.id, label: String(localized: "压缩摘要"), text: summary, isError: false,
                                  expanded: $expanded)
            }
            .padding(.vertical, 6)
        case .oversized(let bytes):
            Label(AgentHistoryText.oversized(bytes),
                  systemImage: "exclamationmark.circle")
                .font(.system(size: 11.5))
                .foregroundStyle(UD.text3)
        }
    }

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(key) },
                set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } })
    }
}

/// 派子代理的调用下面的入口：点进去看那个子代理自己的记录。
private struct AgentSubagentEntry: View {
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

/// 折叠的长文字（工具结果、命令输出、压缩摘要）：默认收起；展开先给前几行，再点才给全部（仍有上限）。
private struct AgentClippedBlock: View {
    let id: String
    let label: String
    let text: AgentClippedText
    let isError: Bool
    @Binding var expanded: Set<String>

    private var openKey: String { "\(id).open" }
    private var fullKey: String { "\(id).full" }

    var body: some View {
        DisclosureGroup(isExpanded: binding(openKey)) {
            VStack(alignment: .leading, spacing: 6) {
                let showsAll = expanded.contains(fullKey)
                let preview = text.preview(lines: AgentTranscriptLimits.previewLines,
                                           characters: AgentTranscriptLimits.previewCharacters)
                Text(showsAll ? text.text : preview)
                    .font(UD.mono(11))
                    .foregroundStyle(isError ? UD.danger : UD.text2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(UD.fillSoft))
                if !showsAll, preview.count < text.text.count {
                    Button(AgentHistoryText.showAll(text.text.count)) { expanded.insert(fullKey) }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
                if text.isClipped, showsAll || preview.count >= text.text.count {
                    Text(AgentHistoryText.clippedNote(text))
                        .font(.system(size: 11))
                        .foregroundStyle(UD.text4)
                }
            }
            .padding(.top, 4)
        } label: {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(isError ? UD.danger : UD.text3)
        }
    }

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(key) },
                set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } })
    }
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
