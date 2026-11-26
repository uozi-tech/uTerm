import SwiftUI
import UDesignKit

/// 历史会话里两端共用的几块：对话页顶上的横条、加载控件、标题块、拷贝菜单项；列表的读取 / 空 / 失败状态与列表底部。
/// 两端的标题行、列表本身仍各写（布局不同：手机上放不下要折两行、留 44pt 点按）。
///
/// 两端各有一份同名的小件（控件出处不同）：`AgentHistoryActionButton`、`AgentHistorySpinner`、`AgentHistoryProgressView`、
/// `AgentHistoryStateView`、`AgentHistoryWarningNote`。

/// 横条、加载控件上按钮的图标（两端的图标出处不同，`AgentHistoryActionButton` 各自对应）。
enum AgentHistoryActionIcon {
    case up, down, toLatest, retry
}

extension AgentHistoryContinuation.Link {
    /// 要翻过去的那一份。
    var file: AgentHistorySessionFile {
        switch self {
        case .previous(let file), .next(let file): return file
        }
    }

    var isPrevious: Bool {
        if case .previous = self { return true }
        return false
    }
}

// MARK: - 对话页

/// 标题行下面的横条：从命中处打开（后面还没读到末尾）、「接着往下聊」串起来的另一段。各带一条分隔线。
struct AgentTranscriptBanners: View {
    let transcript: AgentTranscriptModel
    let continuation: AgentHistoryContinuation.Link?
    /// 从搜索命中处打开的：换回从末尾打开。
    let onJumpToLatest: () -> Void
    let onOpenPart: (AgentHistorySessionFile) -> Void

    var body: some View {
        if transcript.opensAtHit, !transcript.reachedEnd {
            AgentTranscriptBanner(systemImage: "text.magnifyingglass", text: AgentHistoryText.openedAtHit,
                                  actionTitle: AgentHistoryText.jumpToLatest, actionIcon: .toLatest,
                                  action: onJumpToLatest)
            Rectangle().fill(UD.border).frame(height: 1)
        }
        if let continuation {
            AgentTranscriptBanner(systemImage: "arrow.triangle.branch",
                                  text: AgentHistoryText.continuationNotice(continuation),
                                  actionTitle: AgentHistoryText.continuationAction(continuation),
                                  actionIcon: continuation.isPrevious ? .up : .down) { onOpenPart(continuation.file) }
            Rectangle().fill(UD.border).frame(height: 1)
        }
    }
}

/// 一条横条：说一句，右边一个按钮。Mac 前面带图标、一行；手机上字多折两行。
private struct AgentTranscriptBanner: View {
    let systemImage: String
    let text: String
    let actionTitle: String
    let actionIcon: AgentHistoryActionIcon
    let action: () -> Void

    var body: some View {
        let style = AgentTranscriptStyle.platform
        HStack(spacing: 8) {
            if style.bannerShowsIcon {
                Image(systemName: systemImage)
                    .font(style.font(11))
                    .foregroundStyle(UD.text3)
            }
            Text(text)
                .font(style.font(11.5))
                .foregroundStyle(UD.text2)
                .lineLimit(style.bannerShowsIcon ? 1 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            AgentHistoryActionButton(title: actionTitle, icon: actionIcon, action: action)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(style.surface)
    }
}

/// 标题行里的标题块：标题（子代理的记录是它的任务）、「正在更新」、目录 · 分支 · 时间。
struct AgentTranscriptTitleBlock: View {
    let transcript: AgentTranscriptModel
    let metadata: AgentHistorySessionMetadata?

    var body: some View {
        let style = AgentTranscriptStyle.platform
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(transcript.subagent.map(AgentHistoryText.subagentTitle) ?? AgentHistoryText.transcriptTitle(metadata))
                    .font(.system(size: style.titleSize, weight: .semibold))
                    .foregroundStyle(UD.text)
                    .lineLimit(1)
                if transcript.isUpdating { AgentUpdatingBadge() }
            }
            AgentTranscriptDetailText(transcript: transcript, metadata: metadata)
                .font(style.font(11))
                .foregroundStyle(UD.text3)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

/// 标题旁的「正在更新」：这份对话最近还在变（会话开着）。
private struct AgentUpdatingBadge: View {
    var body: some View {
        let style = AgentTranscriptStyle.platform
        HStack(spacing: 4) {
            Circle().fill(UD.success).frame(width: 6, height: 6)
            Text(AgentHistoryText.updating)
                .font(style.font(10.5, weight: .medium))
                .foregroundStyle(UD.success)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(UD.success.opacity(0.12)))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// 标题行「拷贝」菜单里的几项（菜单本身两端各画：Mac 是图标按钮的 `Menu`，手机是 `MMenu`）。
struct AgentTranscriptCopyItems: View {
    let transcript: AgentTranscriptModel

    var body: some View {
        if transcript.subagent == nil {
            Button { AgentHistoryPasteboard.copy(transcript.file.sessionID) } label: {
                Label("拷贝会话 ID", systemImage: "number")
            }
        }
        Button { AgentHistoryPasteboard.copy(transcript.plainText) } label: {
            Label("拷贝已加载的对话", systemImage: "doc.on.doc")
        }
    }
}

/// 对话列表最顶上：出错重试、读取中、「加载更早的消息」。
struct AgentTranscriptLoadEarlier: View {
    let transcript: AgentTranscriptModel
    let loadEarlier: () -> Void

    var body: some View {
        if let error = transcript.errorMessage {
            HStack(spacing: 8) {
                AgentHistoryWarningNote(text: error)
                AgentHistoryActionButton(title: String(localized: "重试"), icon: .retry, action: loadEarlier)
            }
        } else if transcript.isLoading {
            AgentHistorySpinner()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        } else if !transcript.reachedStart {
            AgentHistoryActionButton(title: String(localized: "加载更早的消息"), icon: .up, action: loadEarlier)
                .frame(maxWidth: .infinity)
        }
    }
}

/// 从命中处打开的：后面还有，「加载更晚的消息」（滚到底也会读，见 `AgentTranscriptTailFollow`）。
struct AgentTranscriptLoadLater: View {
    let transcript: AgentTranscriptModel

    var body: some View {
        if !transcript.reachedEnd {
            VStack(spacing: 8) {
                if let error = transcript.laterErrorMessage {
                    AgentHistoryWarningNote(text: error)
                }
                if transcript.isLoadingLater {
                    AgentHistorySpinner().padding(.vertical, 8)
                } else {
                    AgentHistoryActionButton(title: AgentHistoryText.loadLater, icon: .down) {
                        Task { await transcript.loadLater() }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - 列表

/// 会话列表区：读取中、没有记录、读不出来，有会话时交给各端的列表（`list`）。
struct AgentHistoryListContent<List: View>: View {
    let history: AgentHistoryModel
    /// 有跑着的会话（列表里会有它们那几行，不能说「没有」）。
    let hasRuns: Bool
    @ViewBuilder let list: () -> List

    var body: some View {
        switch history.phase {
        case .loading:
            AgentHistoryProgressView(text: String(localized: "正在读取会话列表…"))
        case .empty:
            AgentHistoryStateView(icon: .empty, title: String(localized: "没有历史会话"),
                                  detail: AgentHistoryText.noHistoryDetail(tools: history.configuredTools))
        case .failed(let message):
            AgentHistoryStateView(icon: .warning, title: String(localized: "无法读取会话列表"), detail: message,
                                  actionTitle: String(localized: "重试")) { Task { await history.reload() } }
        case .ready:
            let isEmpty = history.visibleFiles.isEmpty && history.pinnedFiles.isEmpty && !hasRuns
            // 还在列目录，或者读过的那几份都不用列、后面还有没读的：接着等，别急着说「没有」。
            if isEmpty, history.isListing || history.hasMore {
                AgentHistoryProgressView(text: String(localized: "正在读取会话列表…"))
            } else if isEmpty {
                AgentHistoryStateView(icon: .empty, title: String(localized: "没有命令行会话"),
                                      detail: AgentHistoryText.emptyListDetail(hidden: history.hiddenCount))
            } else {
                list()
            }
        }
    }
}

/// 列表底部：滚到底露出来就再读一批；读完了说一句隐藏了几份；某种工具的记录读不出来（别的照常列着）。
struct AgentHistoryListFooter: View {
    let history: AgentHistoryModel
    /// 已经列出的份数：变了它就是一个新视图，格子高、读完一批它还露着时也会接着读（上一批没读够时 `loadMore`
    /// 自己不起作用，不会一露出来就一路读下去）。
    let listedCount: Int

    var body: some View {
        let style = AgentHistoryListStyle.platform
        if history.hasMore {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在读取…")
                    .font(.system(size: style.noteSize))
                    .foregroundStyle(UD.text4)
            }
            .padding(style.footerPadding)
            .id(listedCount)
            .onAppear { history.loadMore() }
        } else if history.hiddenCount > 0 {
            Text(AgentHistoryText.hiddenNote(history.hiddenCount))
                .font(.system(size: style.noteSize))
                .foregroundStyle(UD.text4)
                .padding(style.footerPadding)
        }
        ForEach(AgentHistoryTool.allCases.filter { history.toolFailures[$0] != nil }) { tool in
            AgentHistoryWarningNote(text: AgentHistoryText.toolFailure(tool, message: history.toolFailures[tool] ?? ""))
        }
    }
}
