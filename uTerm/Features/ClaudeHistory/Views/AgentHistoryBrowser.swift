import AppKit
import SwiftUI
import UDesignKit

/// 历史会话的内容：左边会话列表（可拖宽），右边选中会话的对话。独立的历史窗口和终端窗口的 Code 模式都是它。
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
        if let transcript = history.transcript {
            // 主对话与点进去的一层层子代理记录都挂着，只露出最里面那层：返回上一层时滚动位置、展开的块都还在。
            let levels = [transcript] + history.subagentStack
            let top = levels.last?.path
            ZStack {
                ForEach(levels, id: \.path) { level in
                    let isTop = level.path == top
                    AgentTranscriptPane(transcript: level,
                                        metadata: history.metadata[level.file.path],
                                        canResume: history.resumeCommand(for: level.file) != nil,
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
        } else {
            RemoteMacStateView(systemImage: "text.bubble", title: String(localized: "选择一个会话"),
                               detail: AgentHistoryText.selectSessionDetail(tools: listedTools))
        }
    }

    private var listedTools: [AgentHistoryTool] {
        history.availableTools.isEmpty ? history.configuredTools : history.availableTools
    }
}

// MARK: - 会话列表

/// 会话列表：顶上搜索框、「＋」新会话、分组菜单、刷新；下面按分组列（组可以折起来），搜索时换成搜索结果。
struct AgentHistorySessionList: View {
    let history: AgentHistoryModel
    var newSession: AgentHistoryNewSession? = nil
    var reveal: AgentHistoryReveal? = nil

    @AppStorage(DefaultsKey.agentHistoryGrouping) private var groupingRaw = AgentHistoryGrouping.default.rawValue
    @AppStorage(DefaultsKey.agentHistoryShownTools) private var shownToolsRaw = ""
    /// 还没定位成功的那一次请求（组还没列出来）：列表有了变化再试。
    @State private var pendingReveal: AgentHistoryReveal?

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
    }

    private var header: some View {
        @Bindable var history = history
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                UDSearchField(text: $history.searchText, placeholder: AgentHistoryText.searchPlaceholder,
                              showsHotkeyChip: false)
                    .onSubmit { history.submitSearch() }
                    .help(AgentHistoryText.searchHelp)
                    .padding(.trailing, 4)
                if let newSession { newSessionButton(newSession) }
                optionsMenu
                Button {
                    Task { await history.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.udPlain)
                .iconButtonHover(cornerRadius: 6)
                .help(String(localized: "刷新"))
                .accessibilityLabel(Text("刷新"))
            }
            if let problem = history.searchProblem {
                Text(AgentHistoryText.searchProblem(problem))
                    .font(.system(size: 11))
                    .foregroundStyle(UD.warning)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: WorkspacePaneHeaderLayout.height)
    }

    /// 「＋」：能新开的工具不止一种时先选工具，只有一种就直接开。
    @ViewBuilder private func newSessionButton(_ newSession: AgentHistoryNewSession) -> some View {
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
            Button(String(localized: "恢复默认")) {
                groupingRaw = AgentHistoryGrouping.default.rawValue
                shownToolsRaw = ""
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
            // 还在列目录，或者读过的那几份都不用列、后面还有没读的：接着等，别急着说「没有」。
            if files.isEmpty && (history.isListing || history.hasMore) {
                RemoteMacProgressView(text: String(localized: "正在读取会话列表…"))
            } else if files.isEmpty {
                RemoteMacStateView(systemImage: "tray", title: String(localized: "没有命令行会话"),
                                   detail: emptyDetail)
            } else {
                list(files)
            }
        }
    }

    private var emptyDetail: String { AgentHistoryText.emptyListDetail(hidden: history.hiddenCount) }

    private func list(_ files: [AgentHistorySessionFile]) -> some View {
        let groups = AgentHistoryListing.groups(files, by: grouping, metadata: history.metadata,
                                                date: { history.liveActivity(of: $0) ?? $0.modifiedAt })
        let showsTool = history.isMultiTool
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(groups) { group in
                        let collapsed = history.collapsedGroups.contains(group.id)
                        if group.kind != .all {
                            AgentHistoryGroupHeader(group: group, collapsed: collapsed) { toggle(group.id) }
                                .id(group.id)
                        }
                        if !collapsed {
                            ForEach(group.files) { file in
                                AgentHistorySessionRow(history: history, file: file, metadata: history.metadata[file.path],
                                                       showsProject: grouping != .project, showsTool: showsTool,
                                                       isSelected: history.selectedFile?.path == file.path)
                                    .onTapGesture { history.select(file) }
                            }
                        }
                    }
                    footer(files)
                }
                .padding(6)
            }
            .onAppear { pendingReveal = reveal }
            .onChange(of: reveal) { _, request in pendingReveal = request }
            .onChange(of: pendingReveal, initial: true) { _, _ in tryReveal(groups, proxy: proxy) }
            .onChange(of: groups.map(\.id)) { _, _ in tryReveal(groups, proxy: proxy) }
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

    private func group(_ session: AgentHistorySearchSession) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if history.isMultiTool { AgentHistoryToolBadge(tool: session.file.tool, size: 14) }
                    Text(AgentHistoryText.sessionTitle(session.file, metadata: session.metadata))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(UD.text)
                        .lineLimit(1)
                }
                AgentSessionTimeText(history: history, file: session.file) { activity in
                    AgentHistoryText.searchSessionDetail(session, showsProject: history.scope == .all, activity: activity)
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

/// 会话一行：（几种工具时）工具标记 + 标题，第二行 时间 · 大小 · 分支 ·（不按项目分组时）项目。
private struct AgentHistorySessionRow: View {
    let history: AgentHistoryModel
    let file: AgentHistorySessionFile
    let metadata: AgentHistorySessionMetadata?
    let showsProject: Bool
    var showsTool = false
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if showsTool {
                AgentHistoryToolBadge(tool: file.tool, size: 15)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(UD.text)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                AgentSessionTimeText(history: history, file: file) { activity in
                    AgentHistoryText.sessionSubtitle(file, metadata: metadata, showsProject: showsProject, activity: activity)
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
            if transcript.subagent == nil {
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
