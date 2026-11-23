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
            CodeRunHeader(code: code, run: run, showsBack: showsBack)
            Rectangle().fill(M.divider).frame(height: 1)
            ZStack {
                TerminalSessionBody(tab: run.terminal, isActive: isActive && cover == nil,
                                    isFocused: code.isFocused && shown && cover == nil,
                                    onInteract: code.onInteract,
                                    onClose: { code.tab.endRun(run.id) },
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
/// 程序已经退出（很快就退出、留着给人看输出的那种）时右边换成「回到记录」或「关闭」。
struct CodeRunHeader: View {
    let code: CodeTabRuns
    let run: CodeRunBoard<TermTab>.Run
    let showsBack: Bool

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
                // 详情露着终端时才有这条标题行，所以这里是「查看记录」；看记录时回终端的按钮在记录的标题行上。
                if run.sessionPath != nil {
                    Button { code.tab.setShowsTerminal(run.id, !run.showsTerminal) } label: {
                        Label(run.showsTerminal ? String(localized: "查看记录") : String(localized: "返回终端"),
                              systemImage: run.showsTerminal ? "clock" : "terminal")
                    }
                }
                if let move = code.onMoveToTab {
                    Button { move(run.id) } label: {
                        Label("移到新标签页", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
                Button(role: .destructive) { code.tab.endRun(run.id) } label: {
                    Label("结束会话", systemImage: "xmark.circle")
                }
            } label: {
                MIcon(name: "ellipsis", size: 16, color: M.text2, weight: .semibold)
                    .frame(width: M.minTarget, height: M.minTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("更多"))
        } else {
            MBtn(title: run.sessionPath == nil ? String(localized: "关闭") : String(localized: "回到记录"),
                 icon: run.sessionPath == nil ? "x" : "clock", kind: .tinted, height: 34) {
                code.tab.endRun(run.id)
            }
            .fixedSize()
            .padding(.trailing, 4)
        }
    }
}

/// 列表顶上一组「正在运行」：在这个标签页里继续着的会话（含还没有记录的新会话），一眼看到有几个在跑，点一行回到它的终端。
struct CodeRunningSection: View {
    let code: CodeTabRuns

    /// 多过这几个就在这一块里滚，别把下面的列表挤没了。
    private static let visibleRows = 3

    var body: some View {
        let runs = code.board.runs
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Circle().fill(M.success).frame(width: 7, height: 7)
                Text("正在运行", comment: "Code 标签页列表顶上：在这个标签页里继续着的会话")
                    .font(M.sans(13.5, weight: .semibold)).foregroundStyle(M.text2)
                Spacer(minLength: 6)
                Text(verbatim: "\(runs.count)")
                    .font(M.mono(12)).foregroundStyle(M.text4)
            }
            .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 4)
            .accessibilityElement(children: .combine)
            if runs.count > Self.visibleRows {
                ScrollView { rows(runs) }
                    .frame(height: CGFloat(Self.visibleRows) * 60)
                    .mKeepsScrollContentInSafeArea()
            } else {
                rows(runs)
            }
        }
        .padding(.bottom, 6)
    }

    private func rows(_ runs: [CodeRunBoard<TermTab>.Run]) -> some View {
        VStack(spacing: 2) {
            ForEach(runs) { run in
                Button { code.tab.focusRun(run.id) } label: {
                    row(run, selected: code.board.focusedID == run.id && run.showsTerminal)
                }
                .buttonStyle(MPressStyle())
            }
        }
        .padding(.horizontal, 8)
    }

    private func row(_ run: CodeRunBoard<TermTab>.Run, selected: Bool) -> some View {
        HStack(spacing: 9) {
            AgentHistoryToolBadge(tool: run.tool, size: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(code.tab.title(of: run))
                    .font(M.sans(15, weight: .medium)).foregroundStyle(M.text)
                    .lineLimit(1)
                Text(verbatim: CodeRunText.state(of: run, controller: run.terminal.controller))
                    .font(M.sans(12.5)).foregroundStyle(run.isRunning ? M.text3 : M.warning)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MIcon(name: "chev", size: 12, color: M.text4, weight: .semibold)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(minHeight: M.minTarget)
        .background(RoundedRectangle(cornerRadius: MRadius.md, style: .continuous)
            .fill(selected ? M.rowSelected : Color.clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 列表行上的「运行中」：这份记录正在 Code 标签页里继续着。
struct CodeRunningMark: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(M.success).frame(width: 6, height: 6)
            Text("运行中", comment: "Code 标签页：这个会话正在标签页里继续着")
                .font(M.sans(11.5, weight: .medium)).foregroundStyle(M.success)
        }
        .fixedSize()
    }
}

/// 跑着的会话的状态那一行。
enum CodeRunText {
    @MainActor
    static func state(of run: CodeRunBoard<TermTab>.Run, controller: MobileTerminalController) -> String {
        if !run.isRunning { return String(localized: "程序已退出") }
        let place = (run.directory as NSString).lastPathComponent
        switch controller.state {
        case .idle, .connecting: return String(localized: "正在连接…")
        case .failed: return String(localized: "连接失败")
        case .disconnected: return String(localized: "已断开")
        case .connected:
            if controller.isReconnecting { return String(localized: "正在重新连接…") }
            return String(localized: "运行中 · \(place)", comment: "Code 标签页：会话正在跑，后面是工作目录的名字")
        }
    }
}
