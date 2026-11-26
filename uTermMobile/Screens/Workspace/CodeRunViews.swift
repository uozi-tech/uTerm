import UDesignKit
import SwiftUI

/// Code 标签页详情里一个跑着的会话：顶上一条标题行，下面是它的活终端（连接中时是格内的连接中页）。
///
/// 不在看它时整块移到屏外而不是透明：终端是 `UIViewRepresentable`，会无视 ZStack 顺序和透明度盖在别的 SwiftUI 上面。
/// 连接中页也不能叠在终端上面（同一个原因）：连接中时终端移到屏外、连接中页占它的位置（同工作区的格内连接中页）。
struct CodeRunPane: View {
    let code: CodeTabRuns
    let run: CodeRunBoard<TermTab>.Run
    /// 详情此刻露着的就是它的终端。
    let shown: Bool
    /// 露着、标签在前台、工作区没收起。
    let isActive: Bool
    /// 窄屏：标题行左边有返回列表。
    let showsBack: Bool

    var body: some View {
        let cover = code.tab.runCovers[run.id]
        VStack(spacing: 0) {
            // 标题行下面不画横线（同 Mac 的 Code 标签页）。
            CodeRunHeader(code: code, run: run, showsBack: showsBack)
            ZStack {
                TerminalSessionBody(tab: run.terminal, isActive: isActive && cover == nil,
                                    isFocused: code.isFocused && shown && cover == nil,
                                    onInteract: code.onInteract,
                                    // 镜像那台 Mac 的会话：连不上时的「关闭」只回到列表，不去结束 Mac 上的会话。
                                    onClose: { run.isMirrored ? code.tab.backToList() : code.tab.endRun(run.id) },
                                    // 断开就是程序退出了（命令后面接着 `exit`），重新连只会开一个空 shell：不给。
                                    offersReconnect: false,
                                    onRetry: { code.tab.retryRun(run.id) })
                    .offset(x: cover == nil ? 0 : -100_000)
                if let cover, shown {
                    ConnectingCoverView(request: cover,
                                        onFinish: { code.tab.finishCover(run.id) },
                                        onCancel: { code.tab.endRun(run.id) },
                                        onRetry: { code.tab.retryRun(run.id) },
                                        fillsScreen: false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: cover == nil)
        }
        .offset(x: shown ? 0 : -100_000)
        .allowsHitTesting(shown)
        .accessibilityHidden(!shown)
    }
}

/// 跑着的会话的标题行，一行：返回（窄屏）· 工具标记 · 标题与状态（各一行）…… 更多（⋯）。
/// 「查看记录」「移到新标签页」「结束会话」都收在「更多」里，窄的格子（iPhone、Duo 分屏 330pt）也不折行。
/// 程序已经退出、终端留着最后的画面时（没有对话记录、或者很快就退出），第二行是「会话已结束」，右边换成「重新开始」与
/// 「回到记录」（有记录时）或「关闭」。
struct CodeRunHeader: View {
    let code: CodeTabRuns
    let run: CodeRunBoard<TermTab>.Run
    let showsBack: Bool

    /// 对上的记录列表里会列出来（有对话可回去看）。
    private var hasRecord: Bool {
        guard let path = run.sessionPath else { return false }
        return code.tab.connection.history?.metadata[path]?.isListed ?? true
    }

    var body: some View {
        HStack(spacing: 8) {
            if showsBack {
                Button { code.tab.backToList() } label: {
                    MIcon(name: "back", size: 17, color: M.text2, weight: .semibold)
                        .frame(width: M.minTarget, height: M.minTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MPressStyle())
                .accessibilityLabel(Text("返回会话列表"))
            }
            AgentHistoryToolBadge(tool: run.tool, size: 18)
                .padding(.leading, showsBack ? 0 : 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(code.tab.title(of: run))
                    .font(M.sans(14.5, weight: .semibold)).foregroundStyle(M.text)
                    .lineLimit(1)
                Text(verbatim: CodeRunText.state(of: run, controller: run.terminal.controller))
                    .font(M.sans(11.5)).foregroundStyle(run.isRunning ? M.text3 : M.warning)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.trailing, 6)
        .frame(minHeight: 52)
    }

    @ViewBuilder private var trailing: some View {
        if run.isRunning {
            MMenu {
                // 详情露着终端时才有这条标题行，所以这里只有「查看记录」；看记录时回终端的按钮在记录的标题行上。
                // 记录列表里还没列到的没有这一项（切不过去）。
                if code.tab.canShowRecord(run) {
                    Button { code.tab.setShowsTerminal(run.id, false) } label: {
                        Label(AgentHistoryText.viewRecord, systemImage: "clock")
                    }
                }
                // 镜像那台 Mac 的会话请 Mac 挪（Mac 要认得 `codeTabAction`，见 `ClaudeHistoryTab+MacActions`）。
                if let move = code.onMoveToTab, code.canMoveToTab(run) {
                    Button { move(run.id) } label: {
                        Label(AgentHistoryText.moveToTab, systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .disabled(code.tab.macActionInFlight)
                }
                Button(role: .destructive) { code.tab.endRun(run.id) } label: {
                    Label(AgentHistoryText.endSession, systemImage: "xmark.circle")
                }
            } label: {
                MIcon(name: "ellipsis", size: 16, color: M.text2, weight: .semibold)
                    .frame(width: M.minTarget, height: M.minTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("更多"))
        } else {
            HStack(spacing: 6) {
                // 镜像那台 Mac 的会话请 Mac 重新开始；老 Mac 不认得 `codeTabAction`，不给。
                if code.canRestart(run) {
                    MBtn(title: AgentHistoryText.restartSession, icon: "refresh", kind: .tinted, height: 34) {
                        code.restart(run.id)
                    }
                    .fixedSize()
                    .disabled(run.isMirrored && code.tab.macActionInFlight)
                }
                MBtn(title: hasRecord ? String(localized: "回到记录") : AgentHistoryText.closeEndedSession,
                     icon: hasRecord ? "clock" : "x", kind: .tinted, height: 34) {
                    code.tab.endRun(run.id)
                }
                .fixedSize()
            }
            .padding(.trailing, 4)
        }
    }
}

/// 跑着、但列表里没有它那份记录的会话那一行（多半是还没写出记录的新会话）：在它那一组的最上面，对不上任何一组时
/// 在列表最顶上（见 `AgentHistoryRunPlacement`）。
/// 标题（新会话就是「新会话」），第二行程序报的状态 + 目录名（连接中、已退出时换成那句状态）。点一下回到它的终端。
struct CodeUnlistedRunRow: View {
    let code: CodeTabRuns
    let run: CodeRunBoard<TermTab>.Run
    /// 这台主机上不止一种工具：写出是哪种（「新会话」本身看不出来）。
    let showsTool: Bool
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            VStack(alignment: .leading, spacing: 4) {
                Text(code.tab.title(of: run))
                    .font(M.sans(15, weight: .medium)).foregroundStyle(M.text)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    let state = CodeRunText.listDetail(of: run, controller: run.terminal.controller)
                    if !run.isRunning || state.isConnected { CodeRunStatusMark(run: run) }
                    Text(verbatim: showsTool ? "\(run.tool.displayName) · \(state.text)" : state.text)
                        .font(M.sans(12.5)).foregroundStyle(run.isRunning ? M.text3 : M.warning)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MIcon(name: "chev", size: 12, color: M.text4, weight: .semibold)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: MRadius.md, style: .continuous)
            .fill(selected ? M.rowSelected : Color.clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 列表行上一个跑着的会话的状态（规则见 `CodeRunStatus`，同 Mac 的 `AgentHistoryRunStatusTag`）：程序报的状态用终端标签上
/// 同一套颜色与文字（`statusLabel`，颜色同标签圆点；空闲是灰的），程序退出了是「已结束」，没报过什么都不画。
/// 在自己的 `body` 里读状态：变了只重画这一小块。
struct CodeRunStatusMark: View {
    let run: CodeRunBoard<TermTab>.Run
    @Environment(\.mAccent) private var accent

    var body: some View {
        switch CodeRunStatus.of(isEnded: !run.isRunning, report: run.terminal.programReport) {
        case .unreported:
            EmptyView()
        case .ended:
            mark(color: M.text4, text: AgentHistoryText.sessionEnded, textColor: M.text3)
        case .program(let status):
            let color = WorkspaceTabChip.color(for: status.tone, accent: accent)
            mark(color: color, text: status.statusLabel, textColor: status.tone == .idle ? M.text3 : color)
        }
    }

    private func mark(color: Color, text: String, textColor: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(verbatim: text)
                .font(M.sans(11.5, weight: .medium)).foregroundStyle(textColor)
        }
        .fixedSize()
    }
}

/// 跑着的会话的状态那一行。
enum CodeRunText {
    /// 列表顶上那一行的小字：连着时是目录名（前面另有程序报的状态，见 `CodeRunStatusMark`），否则是状态（正在连接、已退出……）。
    @MainActor
    static func listDetail(of run: CodeRunBoard<TermTab>.Run,
                           controller: MobileTerminalController) -> (text: String, isConnected: Bool) {
        if run.isRunning, controller.state == .connected, !controller.isReconnecting {
            return ((run.directory as NSString).lastPathComponent, true)
        }
        return (state(of: run, controller: controller), false)
    }

    @MainActor
    static func state(of run: CodeRunBoard<TermTab>.Run, controller: MobileTerminalController) -> String {
        if !run.isRunning { return AgentHistoryText.sessionEndedBanner }
        let place = (run.directory as NSString).lastPathComponent
        switch controller.state {
        case .idle, .connecting: return String(localized: "正在连接…")
        case .failed: return String(localized: "连接失败")
        case .disconnected: return String(localized: "已断开")
        case .connected:
            if controller.isReconnecting { return String(localized: "正在重新连接…") }
            // 程序报了状态（运行中、等待确认、空闲……）就写它，同侧栏那一行（`CodeRunStatus`）；没报过只写目录：
            // 不能写「运行中」，那是程序报来的「正在干活」，没报过的多半正停在输入框等人。
            if let status = run.terminal.programReport { return "\(status.statusLabel) · \(place)" }
            return place
        }
    }
}
