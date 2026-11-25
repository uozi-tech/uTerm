import SwiftUI
import UDesignKit

/// Code 标签页的尺寸。
enum CodeTabLayout {
    /// 右边至少留这么宽：终端排得下一行像样的命令，对话也不至于一行几个字。
    static let minimumDetailWidth = 380.0
    /// 窄过这个宽度侧栏就不和右边并排：收成一条窄轨，点开时占满整个标签页（右边先让开，选了会话再回来）。
    static let compactWidth = AgentHistoryBrowser.sidebarRange.lowerBound + minimumDetailWidth
    /// 收起时左边那条窄轨的宽度。
    static let railWidth: CGFloat = 36
}

/// 一个 Code 标签页的内容：左边会话侧栏（置顶、分组、筛选、搜索；跑着的会话行上标「运行中」），右边看选中那份记录，
/// 或者那个会话在这个标签页里跑着的终端。SSH 的终端区（`TerminalArea`）和本机终端窗口都用它，各自给终端面板怎么画。
struct CodeTabView: View {
    let code: CodeTabModel
    /// 第一次显示时建文件通道。
    let makeConnection: () -> AgentHistoryConnection
    /// 右边那个终端的面板（SSH 是 `PaneView`，本机是本机终端的面板）。`ended`：程序已经退出、留着最后的画面
    ///（只画终端本身，不要连接状态那几页）。
    let terminal: (any CodeTabTerminal, _ ended: Bool) -> AnyView
    /// 「移到新标签页」；nil = 不出这个按钮。
    var onMoveToTab: ((UUID) -> Void)? = nil
    /// 「结束会话」：宿主先问前台程序（`TerminalCloseGuard.requestEndSession`），再结束。nil = 不出这个按钮。
    var onEndRun: ((UUID) -> Void)? = nil

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(UD.card)
            .task { await code.open(makeConnection) }
    }

    @ViewBuilder private var content: some View {
        if let connection = code.connection {
            switch connection.phase {
            case .connecting:
                RemoteMacProgressView(text: String(localized: "正在连接…"))
            case .failed(let message):
                RemoteMacStateView(systemImage: "exclamationmark.triangle", title: String(localized: "无法读取历史会话"),
                                   detail: message) {
                    UDButton(title: String(localized: "重试")) { Task { await connection.open() } }
                }
            case .ready(let history):
                CodeTabBrowser(code: code, history: history, terminal: terminal, onMoveToTab: onMoveToTab,
                               onEndRun: onEndRun)
            }
        } else {
            RemoteMacProgressView(text: String(localized: "正在连接…"))
        }
    }
}

/// 列表 + 右边。宽的时候并排（侧栏可拖宽、可收起），窄的时候侧栏收成一条窄轨，点开时占满、右边让开。
///
/// 窄的时候不让侧栏盖在右边上面：右边可能是终端（引擎自己画的图层），叠在上面的 SwiftUI 内容压不住它；
/// 也不并排挤窄右边：终端会跟着重排。占满再回来，终端的尺寸不变。
private struct CodeTabBrowser: View {
    let code: CodeTabModel
    let history: AgentHistoryModel
    let terminal: (any CodeTabTerminal, _ ended: Bool) -> AnyView
    let onMoveToTab: ((UUID) -> Void)?
    let onEndRun: ((UUID) -> Void)?

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { proxy in
            let width = Double(proxy.size.width)
            let compact = width < CodeTabLayout.compactWidth
            let inline = !compact && !code.sidebarHidden
            let upper = max(AgentHistoryBrowser.sidebarRange.lowerBound,
                            min(AgentHistoryBrowser.sidebarRange.upperBound, width - CodeTabLayout.minimumDetailWidth))
            HStack(spacing: 0) {
                if compact && code.sidebarOverlayShown {
                    sessionList(onCollapse: { code.sidebarOverlayShown = false })
                        .frame(maxWidth: .infinity)
                } else if inline {
                    sessionList(onCollapse: { code.sidebarHidden = true })
                        .frame(width: min(max(code.sidebarWidth, AgentHistoryBrowser.sidebarRange.lowerBound), upper))
                    ColumnResizer(width: Binding(get: { code.sidebarWidth }, set: { code.sidebarWidth = $0 }),
                                  range: AgentHistoryBrowser.sidebarRange.lowerBound...upper, sign: 1)
                } else {
                    CodeTabRail(runningCount: code.runningCount) {
                        if compact { code.sidebarOverlayShown = true } else { code.sidebarHidden = false }
                    }
                    Rectangle().fill(UD.border).frame(width: 1)
                }
                if !(compact && code.sidebarOverlayShown) {
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onChange(of: compact) { _, isCompact in if !isCompact { code.sidebarOverlayShown = false } }
        }
        .onAppear { updateTranscriptVisibility() }
        .onDisappear { history.setTranscriptVisible(false) }
        .onChange(of: code.detail) { _, _ in updateTranscriptVisibility() }
        .onChange(of: scenePhase) { _, _ in updateTranscriptVisibility() }
        .onChange(of: code.sidebarOverlayShown) { _, _ in updateTranscriptVisibility() }
        // 用户点了列表里的一行：不再看那个没对上记录的新会话；盖着的侧栏收回去。
        .onChange(of: history.selectedFile?.path) { _, _ in
            code.historySelectionChanged()
            code.sidebarOverlayShown = false
        }
    }

    /// 实时跟随只在看得见记录时查：右边是终端、侧栏占满了、标签页切走了、App 进了后台都停。
    private func updateTranscriptVisibility() {
        history.setTranscriptVisible(code.detail == .transcript && !code.sidebarOverlayShown && scenePhase != .background)
    }

    private func sessionList(onCollapse: @escaping () -> Void) -> some View {
        AgentHistorySessionList(
            history: history,
            // 「＋」不直接开：右边换成起始页，在那里选目录和工具。
            newSession: AgentHistoryNewSession(presenting: { code.showNewSessionPage() }),
            reveal: code.reveal,
            running: AgentHistoryRunning(rows: {
                let selected = code.displayedRun?.id
                let showsRecord = code.detail == .transcript
                return code.runs.map { run in
                    let terminal = run.terminal
                    let ended = run.isEnded
                    return AgentHistoryRunRow(
                        id: run.id, title: code.title(of: run), tool: run.tool, directory: run.directory,
                        isSelected: run.id == selected, path: run.path,
                        status: AgentHistoryRunStatus {
                            if ended { return .ended }
                            return terminal.codeProgramStatus.map { .program($0) } ?? .running
                        },
                        showsRecord: showsRecord && run.id == selected)
                }
            }, onSelect: { id in
                code.selectRun(id)
                code.sidebarOverlayShown = false
            }, actions: onEndRun.map { end in
                AgentHistoryRunActions(
                    end: end,
                    showRecord: { id in
                        code.showRecord(of: id)
                        code.sidebarOverlayShown = false
                    },
                    showTerminal: { id in
                        code.selectRun(id)
                        code.sidebarOverlayShown = false
                    },
                    moveToTab: onMoveToTab)
            }),
            onCollapse: onCollapse)
    }

    // MARK: 右边

    @ViewBuilder private var detail: some View {
        switch code.detail {
        case .empty:
            // 什么都没选（刚打开、点了「＋」、跑着的会话结束了）：起始页。
            CodeTabNewSessionPage(code: code, history: history)
        case .transcript:
            // 看着一个仍在跑的会话的记录：不另加一条，记录标题行上「继续这个会话」换成「返回终端」。
            AgentHistoryTranscriptStack(history: history, onResume: { file in code.resume(file) },
                                        isRunning: { code.run(for: $0.path) != nil })
        case .terminal(let id):
            if let run = code.runs.first(where: { $0.id == id }) {
                VStack(spacing: 0) {
                    runHeader(run)
                    if run.isEnded { CodeTabEndedBanner(code: code, runID: run.id) }
                    terminal(run.terminal, run.isEnded)
                        // 每个会话一个面板：换会话就是换一个终端，不复用同一个视图。
                        .id(run.id)
                }
            }
        }
    }

    /// 跑着的会话的终端顶上那一条：工具标记、标题，右端一个「⋯」菜单（查看记录、移到新标签页、结束会话）。
    /// 右边显示着终端本身就说明在跑，不再写「运行中」。与侧栏顶部那一行等高，中间的竖线上下贯通。
    private func runHeader(_ run: CodeTabModel.Run) -> some View {
        let title = code.title(of: run)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                AgentHistoryToolBadge(tool: run.tool, size: 15)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(UD.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                runMenu(run)
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: AgentHistorySessionList.headerHeight)
            Rectangle().fill(UD.border).frame(height: 1)
        }
    }

    /// 「⋯」：「查看记录」/「返回终端」（看当前显示的是哪个）、「移到新标签页」、「结束会话」。没对上记录的新会话没有记录可看。
    @ViewBuilder private func runMenu(_ run: CodeTabModel.Run) -> some View {
        let showsRecord = code.detail == .transcript
        if run.path != nil || onMoveToTab != nil || onEndRun != nil {
            Menu {
                if run.path != nil {
                    Button(showsRecord ? String(localized: "返回终端") : Self.viewRecord) {
                        code.setShowsTranscript(!showsRecord, for: run.id)
                    }
                }
                if let onMoveToTab {
                    Button(Self.moveToTab) { onMoveToTab(run.id) }
                }
                if let onEndRun {
                    Divider()
                    Button(AgentHistoryText.endSession, role: .destructive) { onEndRun(run.id) }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
            .iconButtonHover(cornerRadius: 6)
            .help(String(localized: "更多"))
            .accessibilityLabel(Text("更多"))
        }
    }

    private static var viewRecord: String {
        String(localized: "查看记录", comment: "Code 标签页：看这个正在跑的会话的对话记录")
    }

    private static var moveToTab: String {
        String(localized: "移到新标签页", comment: "Code 标签页：把这个会话的终端开成普通的终端标签页")
    }
}

/// 程序已经退出、没有对话记录可看的会话：右边终端顶上一条「会话已结束」，带「重新开始」「关闭」。下面是终端最后的画面。
/// 不自己跳走：用户看完了再决定。
struct CodeTabEndedBanner: View {
    let code: CodeTabModel
    let runID: UUID

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(UD.text3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(AgentHistoryText.sessionEndedBanner)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(UD.text)
                    Text(AgentHistoryText.sessionEndedDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(UD.text3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                UDButton(title: AgentHistoryText.restartSession, systemImage: "arrow.clockwise") {
                    code.restart(runID)
                }
                UDButton(title: AgentHistoryText.closeEndedSession, style: .secondary) {
                    code.dismissEnded(runID)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(UD.fillSoft)
            Rectangle().fill(UD.border).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(AgentHistoryText.sessionEndedBanner))
    }
}

/// 侧栏收起时左边那条窄轨：展开按钮；有会话在跑时下面一个绿点带个数，一眼看得到。
private struct CodeTabRail: View {
    let runningCount: Int
    let expand: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Button(action: expand) {
                Image(systemName: "sidebar.left")
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.udPlain)
            .iconButtonHover(cornerRadius: 6)
            .help(String(localized: "展开侧栏", comment: "Code 标签页：展开左边的会话列表"))
            .accessibilityLabel(Text("展开侧栏", comment: "Code 标签页：展开左边的会话列表"))
            .frame(height: AgentHistorySessionList.headerHeight)
            if runningCount > 0 {
                Button(action: expand) {
                    VStack(spacing: 3) {
                        Circle().fill(UD.success).frame(width: 7, height: 7)
                        Text(verbatim: "\(runningCount)")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(UD.success)
                    }
                    .frame(width: 26, height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.udPlain)
                .help(String(localized: "\(runningCount) 个会话正在运行", comment: "Code 标签页收起的侧栏上：在跑的会话个数"))
            }
            Spacer(minLength: 0)
        }
        .frame(width: CodeTabLayout.railWidth)
        .frame(maxHeight: .infinity)
    }
}
