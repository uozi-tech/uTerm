import SwiftUI
import UDesignKit

/// 历史会话左边列表里两端共用的几块：会话一行、分组标题、搜索结果。列表本身（拖动置顶、跑着的会话、选中后去哪）
/// 两端各写（Mac 是 `AgentHistorySessionList`，iOS 是 `ClaudeHistoryList`）。
///
/// 两端的差别只在尺寸，放在 `AgentHistoryListStyle`；真正不同的几个小件两端各有一份同名的：
/// `AgentHistoryStateView`（空状态）、`AgentHistoryWarningNote`（警示一句），以及 `agentHistoryPressStyle` / `agentHistoryScrollChrome` 两个修饰。

/// 两端排版上的差别（同 `HostAvatar` 按平台取默认值）：手机上字大、行高（行尾不画进入的箭头，同 Claude Code Desktop）。
nonisolated struct AgentHistoryListStyle: Sendable {
    var titleSize: CGFloat
    /// 会话一行（只有一行名字）的最小高度。
    var rowMinHeight: CGFloat
    /// 组里不止一种工具时名字前面那个工具标记的大小。
    var toolBadgeSize: CGFloat
    var detailSize: CGFloat
    var roleSize: CGFloat
    var snippetSize: CGFloat
    var noteSize: CGFloat
    var rowPadding: EdgeInsets
    var hitRowPadding: EdgeInsets
    var rowRadius: CGFloat
    var hitRowMinHeight: CGFloat?
    var headerSize: CGFloat
    var headerChevronSize: CGFloat
    var headerHeight: CGFloat
    var headerPadding: CGFloat
    /// 按工具分组时组标题前画那种工具的标记。
    var headerShowsToolBadge: Bool
    var searchSpacing: CGFloat
    var searchPadding: CGFloat
    /// 停止搜索的按钮留够点按的高度。
    var stopButtonMinHeight: CGFloat?
    var hidesScrollIndicators: Bool
    /// 列表底部那几句（正在读取、隐藏了几份）。
    var footerPadding: EdgeInsets
    /// 侧栏最底下账号额度那一行。Mac 上列表一直伸到卡片的圆角底边下面、最底下几点被卡片盖住，上边多留 2pt
    /// 它在看得见的那一截里才居中（画廊量的：额度行上下各 10pt）。
    var accountLimitsPadding: EdgeInsets {
        #if os(macOS)
        EdgeInsets(top: footerPadding.top + 2, leading: footerPadding.leading,
                   bottom: max(0, footerPadding.bottom - 2), trailing: footerPadding.trailing)
        #else
        footerPadding
        #endif
    }

    #if os(macOS)
    static let platform = AgentHistoryListStyle(
        titleSize: 13, rowMinHeight: 30, toolBadgeSize: 14, detailSize: 11, roleSize: 10.5, snippetSize: 12, noteSize: 11,
        rowPadding: EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10),
        hitRowPadding: EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10),
        rowRadius: 6, hitRowMinHeight: nil,
        headerSize: 11.5, headerChevronSize: 9, headerHeight: 26, headerPadding: 8, headerShowsToolBadge: false,
        searchSpacing: 10, searchPadding: 6, stopButtonMinHeight: nil, hidesScrollIndicators: true,
        footerPadding: EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
    #else
    static let platform = AgentHistoryListStyle(
        titleSize: 15, rowMinHeight: 44, toolBadgeSize: 16, detailSize: 12.5, roleSize: 11.5, snippetSize: 14, noteSize: 12.5,
        rowPadding: EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12),
        hitRowPadding: EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12),
        rowRadius: 10, hitRowMinHeight: 44,
        headerSize: 13.5, headerChevronSize: 11, headerHeight: 40, headerPadding: 10, headerShowsToolBadge: true,
        searchSpacing: 12, searchPadding: 8, stopButtonMinHeight: 44, hidesScrollIndicators: false,
        footerPadding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
    #endif
}

/// 空状态用的图标（两端的图标出处不同，`AgentHistoryStateView` 各自对应）。
enum AgentHistoryStateIcon {
    case warning, search
    /// 没有会话。
    case empty
    /// 还没选会话（右边的空态）。
    case conversation
}

/// 选中的行：底色。两端同一个。用中性的灰（`UD.fillSoft`），不用跟着强调色的 `rowSelected`（同 Claude Code Desktop）；
/// 比悬停的那一档（`rowHover`）深一点，看得出选中。
struct AgentHistoryRowBackground: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: AgentHistoryListStyle.platform.rowRadius, style: .continuous)
                .fill(isSelected ? AgentHistoryRowBackground.selected : Color.clear))
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    static var selected: Color { UD.fillSoft }
}

// MARK: - 会话一行

/// 列表一行的样子（同 Claude Code Desktop 的侧栏）：只有一行名字；组里不止一种工具时前面一个小工具标记。
/// 跑着的会话照 `AgentHistoryRunIndicator` 在右端标：运行中一个灰色的呼吸灯，等人处理时一个黄点，出错时一个警示图标
/// （Mac 上悬停时右端由 × 盖住）。会话行、还没对上记录的跑着的会话那一行都用它。
struct AgentHistoryTitleRow<Trailing: View>: View {
    let title: String
    var tool: AgentHistoryTool? = nil
    let isSelected: Bool
    var indicator: AgentHistoryRunIndicator = .none
    /// 不占行、读屏要念的那些（时间、大小、分支、目录），排在状态后面。
    var detail: String? = nil
    /// 原地改名时名字换成的输入框（`AgentHistoryRenaming`）。
    var editor: AgentHistoryTitleEditor? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        let style = AgentHistoryListStyle.platform
        HStack(spacing: 8) {
            if let tool { AgentHistoryToolBadge(tool: tool, size: style.toolBadgeSize) }
            if let editor {
                AgentHistoryTitleField(editor: editor).id(editor.id)
            } else {
                AgentHistoryRowTitle(title: title)
            }
            AgentHistoryRunMark(indicator: indicator)
            trailing()
        }
        .padding(style.rowPadding)
        .frame(minHeight: style.rowMinHeight)
        .modifier(AgentHistoryRowBackground(isSelected: isSelected))
        .accessibilityValue(Text(verbatim: [indicator.label, detail].compactMap { $0 }.joined(separator: " · ")))
    }
}

extension AgentHistoryTitleRow where Trailing == EmptyView {
    init(title: String, tool: AgentHistoryTool? = nil, isSelected: Bool, indicator: AgentHistoryRunIndicator = .none,
         detail: String? = nil, editor: AgentHistoryTitleEditor? = nil) {
        self.init(title: title, tool: tool, isSelected: isSelected, indicator: indicator, detail: detail, editor: editor) {
            EmptyView()
        }
    }
}

/// 一行的名字：一行，长了截断。
struct AgentHistoryRowTitle: View {
    let title: String

    var body: some View {
        Text(verbatim: title)
            .font(.system(size: AgentHistoryListStyle.platform.titleSize))
            .foregroundStyle(UD.text)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 行右端的标记：运行中一个灰色的呼吸灯，等人处理一个黄点，出错一个警示图标，别的什么都不画。说明放进悬停提示与读屏。
/// 呼吸灯是 uAppKit 的 `UDBreathingDot`（Core Animation 插值，不用 SwiftUI 的常驻动画；减弱动态效果时常亮）。
struct AgentHistoryRunMark: View {
    let indicator: AgentHistoryRunIndicator

    var body: some View {
        switch indicator {
        case .none:
            EmptyView()
        case .working:
            UDBreathingDot(color: UD.text3, size: 7, dimOpacity: 0.25, duration: 1.1)
                .padding(.horizontal, 3)
                .help(Text(verbatim: indicator.label ?? ""))
                .accessibilityHidden(true)
        case .needsInput(let record):
            AgentHistoryRunDot(color: UD.warning, label: record.statusLabel, help: record.tabHelp)
        case .error(let record):
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: AgentHistoryListStyle.platform.titleSize - 1))
                .foregroundStyle(UD.text3)
                .help(Text(verbatim: record.tabHelp))
                .accessibilityLabel(Text(verbatim: record.statusLabel))
        }
    }
}

/// 黄点（等人处理）：列表一行右端、收起的组标题上。说明放进悬停提示与读屏。
struct AgentHistoryRunDot: View {
    let color: Color
    let label: String
    var help: String? = nil

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .padding(.horizontal, 3)
            .help(Text(verbatim: help ?? label))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: label))
    }
}

/// 会话一行：只有名字（`AgentHistoryTitleRow`）。时间、大小、分支、项目不占列表的地方，悬停提示与读屏里有。
/// `status`：在 Code 标签页里跑着时它此刻的状态（两端的状态对象不同，各自给）。在这一行的 `body` 里读：
/// 状态变了只重画这一行。
struct AgentHistorySessionRow: View {
    let history: AgentHistoryModel
    let file: AgentHistorySessionFile
    let metadata: AgentHistorySessionMetadata?
    /// 组里不止一种工具：名字前面一个工具标记。
    var showsTool = false
    let isSelected: Bool
    var status: () -> CodeRunStatus = { .unreported }
    /// 原地改名（右键「重命名…」）：列表的 `AgentHistoryRenaming`；这一行在改名或正写回时才有用。
    var renaming: AgentHistoryRenaming? = nil

    var body: some View {
        let activity = history.liveActivity(of: file)
        let rename = renaming?.state(of: file, in: history)
        let title: String = if case .saving(let title) = rename { title } else {
            AgentHistoryText.sessionTitle(file, metadata: metadata)
        }
        let editor: AgentHistoryTitleEditor? = if case .editing(let editor) = rename { editor } else { nil }
        // 悬停提示与读屏里的「几分钟前」到点重算（数据没变也会过时），同各处的时间（`AgentSessionTimeText`）。
        TimelineView(AgentSessionTimeSchedule(interval: AgentSessionTimeText.refreshInterval)) { _ in
            AgentHistoryTitleRow(title: title, tool: showsTool ? file.tool : nil, isSelected: isSelected,
                                 indicator: AgentHistoryRunIndicator(status()),
                                 detail: AgentHistoryText.sessionSubtitle(file, metadata: metadata, showsProject: true,
                                                                          activity: activity),
                                 editor: editor)
                .help(Text(verbatim: AgentHistoryText.sessionRowHelp(file, metadata: metadata, activity: activity)))
        }
    }
}

// MARK: - 分组标题

/// 组标题：折叠箭头、标题、会话数。点一下折起 / 展开。项目组的标题是目录名（不翻译），完整路径给悬停与读屏。
struct AgentHistoryGroupHeader: View {
    let group: AgentHistoryGroup
    let collapsed: Bool
    /// 组里跑着的会话此刻的状态（收起时才给）。在这里读：状态变了只重画组标题。
    var runs: () -> [CodeRunStatus] = { [] }
    let toggle: () -> Void

    var body: some View {
        let style = AgentHistoryListStyle.platform
        let mark = CodeRunGroupMark(runs())
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: style.headerChevronSize, weight: .semibold))
                    .foregroundStyle(UD.text4)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: style.headerChevronSize + 2)
                if style.headerShowsToolBadge, case .tool(let tool) = group.kind {
                    AgentHistoryToolBadge(tool: tool, size: 16)
                }
                Text(AgentHistoryText.groupTitle(group))
                    .font(.system(size: style.headerSize, weight: .semibold))
                    .foregroundStyle(UD.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                // 同一行上的规则：只有组里有人等着处理时才画黄点（`CodeRunGroupMark.waitingRecord`）。
                if let mark, let waiting = mark.waitingRecord {
                    AgentHistoryRunDot(color: UD.warning, label: waiting.statusLabel,
                                       help: AgentHistoryText.groupRunsNote(mark))
                }
                Text(verbatim: "\(group.files.count)")
                    .font(.system(size: style.headerSize - 0.5))
                    .monospacedDigit()
                    .foregroundStyle(UD.text4)
            }
            .padding(.horizontal, style.headerPadding)
            .frame(minHeight: style.headerHeight)
            .contentShape(Rectangle())
        }
        .agentHistoryPressStyle()
        .padding(.top, 4)
        .help(AgentHistoryText.groupHelp(group).map { Text(verbatim: $0) } ?? Text(verbatim: ""))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(AgentHistoryText.groupAccessibility(group, collapsed: collapsed, runs: mark)))
        .accessibilityHint(Text(verbatim: AgentHistoryText.groupHelp(group) ?? ""))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - 搜索结果

/// 列表区的搜索结果：按会话分组（最近的在前），每组下面是命中的摘要行，点一条打开那份对话并停在那里。
struct AgentHistorySearchResults: View {
    let history: AgentHistoryModel
    let search: AgentHistoryModel.Search
    /// 点开了一条命中（那份记录已经选上）：窄屏的手机上进到对话。
    var onOpened: (AgentHistorySessionFile) -> Void = { _ in }

    private let style = AgentHistoryListStyle.platform

    var body: some View {
        if search.sessions.isEmpty, !search.isRunning {
            VStack(spacing: 0) {
                excludedNote
                unsearchedNote
                emptyState
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: style.searchSpacing) {
                    status
                    excludedNote
                    unsearchedNote
                    ForEach(search.sessions) { session in
                        group(session)
                    }
                    footer
                }
                .padding(style.searchPadding)
            }
            .scrollIndicators(style.hidesScrollIndicators ? .never : .automatic)
            .agentHistoryScrollChrome()
        }
    }

    /// 有的工具的会话没参与搜索（记录的格式没法在主机上搜）：结果上方说一句。全都不能搜时失败页已经说了，不重复。
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
            AgentHistoryStateView(icon: .warning, title: String(localized: "无法搜索"), detail: message,
                                  actionTitle: String(localized: "重试")) { history.submitSearch() }
        case .stopped:
            AgentHistoryStateView(icon: .search, title: AgentHistoryText.searchStopped(search),
                                  detail: AgentHistoryText.searchNoResultsDetail,
                                  actionTitle: String(localized: "重试")) { history.submitSearch() }
        default:
            AgentHistoryStateView(icon: .search, title: AgentHistoryText.searchNoResults(search.query),
                                  detail: AgentHistoryText.searchNoResultsDetail)
        }
    }

    /// 顶上：正在搜（进度 + 停止）。
    @ViewBuilder private var status: some View {
        if search.isRunning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(AgentHistoryText.searchProgress(search))
                    .font(.system(size: style.noteSize))
                    .foregroundStyle(UD.text3)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button(AgentHistoryText.stopSearch) { history.stopSearch() }
                    .agentHistoryPressStyle()
                    .font(.system(size: style.noteSize + 0.5, weight: .medium))
                    .foregroundStyle(UD.accent)
                    .frame(minHeight: style.stopButtonMinHeight)
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
            AgentHistoryWarningNote(text: message)
        }
    }

    /// 结果旁的说明。text3 而不是 text4：「哪种工具不参与搜索」这类说明要读得清（text4 压在浅色底上太淡）。
    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: style.noteSize))
            .foregroundStyle(UD.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, style.hitRowPadding.leading)
            .padding(.vertical, 4)
    }

    /// 结果里不止一种工具：每个会话的第二行最前面写工具名（同列表的行）。
    private var showsTool: Bool { AgentHistoryListing.mixesTools(search.sessions.map(\.file)) }

    private func group(_ session: AgentHistorySearchSession) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AgentHistoryText.sessionTitle(session.file, metadata: session.metadata))
                    .font(.system(size: style.titleSize, weight: .semibold))
                    .foregroundStyle(UD.text)
                    .lineLimit(1)
                AgentSessionTimeText(history: history, file: session.file) { activity in
                    AgentHistoryText.searchSessionDetail(session, showsProject: history.scope == .all,
                                                         showsTool: showsTool, activity: activity)
                }
                .font(.system(size: style.detailSize))
                .foregroundStyle(UD.text3)
                .lineLimit(1)
            }
            .padding(.horizontal, style.hitRowPadding.leading)
            .padding(.vertical, 2)
            ForEach(session.hits) { hit in
                Button {
                    history.openHit(hit, in: session)
                    onOpened(session.file)
                } label: {
                    AgentHistorySearchHitRow(hit: hit, tool: session.file.tool, isSelected: isOpen(hit, in: session))
                }
                .agentHistoryPressStyle()
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
    /// 回答的一方叫什么（Codex 的回答不标「Claude」）。
    let tool: AgentHistoryTool
    let isSelected: Bool

    var body: some View {
        let style = AgentHistoryListStyle.platform
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AgentHistoryText.roleLabel(hit.role, tool: tool))
                    .font(.system(size: style.roleSize, weight: .semibold))
                    .foregroundStyle(UD.text4)
                Text(AgentHistorySnippetText.attributed(hit.snippet, match: UD.accent))
                    .font(.system(size: style.snippetSize))
                    .foregroundStyle(UD.text2)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(style.hitRowPadding)
        .frame(minHeight: style.hitRowMinHeight)
        .modifier(AgentHistoryRowBackground(isSelected: isSelected))
    }
}

// MARK: - 行的菜单

/// 列表一行的菜单内容，两端共用（Mac 右键、iOS 长按；怎么弹出来由各端的 `agentHistoryRowMenu`）。
/// 条目与顺序见 `AgentHistorySessionMenuItem`；Mac 上跑着的会话另有的几样（查看记录 / 返回终端、移到新标签页）
/// 由 `extras` 放在最前面。
struct AgentHistoryRowMenuContent<Extras: View>: View {
    let items: [AgentHistorySessionMenuItem]
    /// 这一行的记录；还没对上记录的新会话为 nil（只有「结束会话」）。
    let file: AgentHistorySessionFile?
    /// 这一行显示的名字（「拷贝会话名」）。
    let title: String
    let pins: AgentHistoryPins?
    var onResume: ((AgentHistorySessionFile) -> Void)? = nil
    var onRename: (AgentHistorySessionFile) -> Void = { _ in }
    var onDelete: (AgentHistorySessionFile) -> Void = { _ in }
    var onEnd: () -> Void = {}
    @ViewBuilder var extras: () -> Extras

    var body: some View {
        extras()
        ForEach(items, id: \.self) { item in
            if item.isDestructive, items.count > 1 { Divider() }
            button(item)
        }
    }

    @ViewBuilder private func button(_ item: AgentHistorySessionMenuItem) -> some View {
        switch item {
        case .resume:
            Button { if let file { onResume?(file) } } label: {
                Label(AgentHistoryText.resumeSession, systemImage: "play")
            }
        case .pin(let isPinned):
            Button {
                if let pins, let file { withAnimation(.easeOut(duration: 0.2)) { pins.toggle(file) } }
            } label: {
                Label(AgentHistoryText.pinAction(isPinned: isPinned), systemImage: isPinned ? "pin.slash" : "pin")
            }
        case .rename:
            Button { if let file { onRename(file) } } label: {
                Label(AgentHistoryText.renameSession, systemImage: "pencil")
            }
        case .copyTitle:
            Button { AgentHistoryPasteboard.copy(title) } label: {
                Label(AgentHistoryText.copySessionTitle, systemImage: "textformat")
            }
        case .copySessionID:
            Button { if let file { AgentHistoryPasteboard.copy(file.sessionID) } } label: {
                Label(AgentHistoryText.copySessionID, systemImage: "doc.on.doc")
            }
        case .delete:
            Button(role: .destructive) { if let file { onDelete(file) } } label: {
                Label(AgentHistoryText.deleteSession, systemImage: "trash")
            }
        case .endSession:
            Button(role: .destructive, action: onEnd) {
                Label(AgentHistoryText.endSession, systemImage: "xmark.circle")
            }
        }
    }
}

extension AgentHistoryRowMenuContent where Extras == EmptyView {
    init(items: [AgentHistorySessionMenuItem], file: AgentHistorySessionFile?, title: String, pins: AgentHistoryPins?,
         onResume: ((AgentHistorySessionFile) -> Void)? = nil, onRename: @escaping (AgentHistorySessionFile) -> Void = { _ in },
         onDelete: @escaping (AgentHistorySessionFile) -> Void = { _ in }, onEnd: @escaping () -> Void = {}) {
        self.init(items: items, file: file, title: title, pins: pins, onResume: onResume, onRename: onRename,
                  onDelete: onDelete, onEnd: onEnd) { EmptyView() }
    }
}

// MARK: - 删除

/// 「删除会话…」的确认框和删不掉时的提示，两端共用。`file` 非 nil 时弹出确认。
struct AgentHistoryDeletePrompt: ViewModifier {
    let history: AgentHistoryModel
    @Binding var file: AgentHistorySessionFile?
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .alert(AgentHistoryText.deleteConfirmTitle, isPresented: Binding(get: { file != nil },
                                                                            set: { if !$0 { file = nil } }),
                   presenting: file) { target in
                Button(AgentHistoryText.deleteConfirmButton, role: .destructive) { delete(target) }
                Button(String(localized: "取消"), role: .cancel) {}
            } message: { target in
                Text(AgentHistoryText.deleteConfirmMessage(
                    title: AgentHistoryText.sessionTitle(target, metadata: history.metadata[target.path])))
            }
            .alert(AgentHistoryText.deleteFailedTitle, isPresented: Binding(get: { failure != nil },
                                                                           set: { if !$0 { failure = nil } })) {
                Button(String(localized: "好")) {}
            } message: {
                Text(verbatim: failure ?? "")
            }
    }

    private func delete(_ target: AgentHistorySessionFile) {
        Task {
            do {
                try await history.delete(target)
            } catch {
                failure = FriendlyError.describe(error)
            }
        }
    }
}

// MARK: - 重命名

/// 右键「重命名…」：那一行的名字原地换成输入框（同 Claude Code Desktop，不弹窗）。回车或点到别处写回，Esc 不改；
/// 名字没变、清空了也不改。写回的那一会儿行上已经是新名字，写不回去时退回原来的名字、提示原因。两端共用，列表各持一个，
/// 行照 `state(of:in:)` 画（`AgentHistorySessionRow.renaming`），失败的提示由 `AgentHistoryRenameFailureAlert` 弹。
@MainActor @Observable
final class AgentHistoryRenaming {
    enum RowState: Equatable {
        case editing(AgentHistoryTitleEditor)
        case saving(String)
    }

    /// 正在改名的那一行。一次只有一行。
    private(set) var editing: AgentHistorySessionFile?
    /// 正在写回的：记录路径 → 新名字。
    private var saving: [String: String] = [:]
    /// 写不回去的原因（弹提示）。
    var failure: String?

    func start(_ file: AgentHistorySessionFile) {
        editing = file
    }

    func state(of file: AgentHistorySessionFile, in history: AgentHistoryModel) -> RowState? {
        if editing?.path == file.path {
            let initial = AgentHistoryText.sessionTitle(file, metadata: history.metadata[file.path])
            return .editing(AgentHistoryTitleEditor(
                id: file.path, initial: initial,
                commit: { [weak self] title in self?.commit(file, title: title, initial: initial, history: history) },
                cancel: { [weak self] in self?.finishEditing(file) }))
        }
        return saving[file.path].map(RowState.saving)
    }

    private func finishEditing(_ file: AgentHistorySessionFile) {
        if editing?.path == file.path { editing = nil }
    }

    private func commit(_ file: AgentHistorySessionFile, title: String, initial: String, history: AgentHistoryModel) {
        guard editing?.path == file.path else { return }
        finishEditing(file)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != initial else { return }
        saving[file.path] = trimmed
        Task {
            defer { saving[file.path] = nil }
            do {
                try await history.rename(file, to: trimmed)
            } catch {
                failure = FriendlyError.describe(error)
            }
        }
    }
}

/// 原地改名的输入框收到的东西：一开始的名字、回车 / 点到别处时交回的新名字、Esc。
struct AgentHistoryTitleEditor: Equatable {
    /// 哪一行（记录路径）：换一行改名时输入框重来。
    let id: String
    let initial: String
    let commit: (String) -> Void
    let cancel: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.initial == rhs.initial }
}

/// 行上原地改名的输入框：样子同名字（同样的字号、没有边框），出现时就有焦点（Mac 上全选着原来的名字）。
struct AgentHistoryTitleField: View {
    let editor: AgentHistoryTitleEditor
    @State private var text: String
    @State private var finished = false
    @FocusState private var focused: Bool

    init(editor: AgentHistoryTitleEditor) {
        self.editor = editor
        _text = State(initialValue: editor.initial)
    }

    var body: some View {
        TextField(AgentHistoryText.renameTitle, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: AgentHistoryListStyle.platform.titleSize))
            .foregroundStyle(UD.text)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .focused($focused)
            // 等挂进窗口再要焦点：`onAppear` 里要的那一下常落空（右键菜单收起时也还在把焦点交回原处）。
            .task {
                await Task.yield()
                focused = true
            }
            .onSubmit { finish { editor.commit(text) } }
            .onKeyPress(.escape) {
                finish { editor.cancel() }
                return .handled
            }
            // 点到别处（失去焦点）也写回，同访达里改文件名。
            .onChange(of: focused) { _, now in
                if !now { finish { editor.commit(text) } }
            }
    }

    private func finish(_ action: () -> Void) {
        guard !finished else { return }
        finished = true
        action()
    }
}

/// 写不回去时的提示（`AgentHistoryRenaming.failure`）。
struct AgentHistoryRenameFailureAlert: ViewModifier {
    let renaming: AgentHistoryRenaming

    func body(content: Content) -> some View {
        content.alert(AgentHistoryText.renameFailedTitle,
                      isPresented: Binding(get: { renaming.failure != nil }, set: { if !$0 { renaming.failure = nil } })) {
            Button(String(localized: "好")) {}
        } message: {
            Text(verbatim: renaming.failure ?? "")
        }
    }
}

// MARK: - 主机上正在运行的会话

/// 列表露着时隔几秒读一次主机上在跑的会话（`AgentHistoryModel.setLiveSessionsVisible`）：出现时开始、消失时停，
/// App 进了后台也停，回来马上读一次。两端的列表各挂一个（Mac 的 `AgentHistorySessionList`、iOS 的 `ClaudeHistoryList`）。
/// `active`：平台另外知道的「列表其实不在屏上」（iOS 窄屏上详情盖着列表、标签不在前台）。
struct AgentHistoryLiveSessionsPolling: ViewModifier {
    let history: AgentHistoryModel
    var active = true

    @Environment(\.scenePhase) private var scenePhase

    private var visible: Bool { active && scenePhase != .background }

    func body(content: Content) -> some View {
        content
            .onAppear { history.setLiveSessionsVisible(visible) }
            .onDisappear { history.setLiveSessionsVisible(false) }
            .onChange(of: visible) { _, visible in history.setLiveSessionsVisible(visible) }
    }
}
