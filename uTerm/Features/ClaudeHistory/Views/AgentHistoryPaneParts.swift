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
                if let reading = transcript.latestUsage {
                    AgentTranscriptUsageBadge(usage: reading.usage, at: reading.at)
                }
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

/// 标题旁的用量：最后一次回答时的上下文（知道窗口多大画一圈占了几成）。点开是明细：模型、上下文、最后一次输出，
/// 记录里有账号额度的（Codex）再列各个时间窗用了几成、几时重置。
private struct AgentTranscriptUsageBadge: View {
    let usage: AgentTurnUsage
    let at: Date?

    @State private var showsDetail = false

    var body: some View {
        let style = AgentTranscriptStyle.platform
        Button { showsDetail.toggle() } label: {
            let level = usage.contextFraction.map { AgentUsageLevel.of(percent: $0 * 100) } ?? .normal
            HStack(spacing: 4) {
                if let fraction = usage.contextFraction {
                    AgentUsageRing(fraction: fraction)
                } else {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .font(style.font(9.5))
                }
                Text(AgentHistoryText.usageBadge(usage))
                    .font(style.font(10.5, weight: .medium))
                    .monospacedDigit()
            }
            .foregroundStyle(level == .normal ? UD.text3 : level.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(UD.fillSoft))
            .fixedSize()
            .contentShape(Capsule())
        }
        .agentHistoryPressStyle()
        .help(AgentHistoryText.usageTitle)
        .popover(isPresented: $showsDetail) {
            AgentUsageDetail(usage: usage, at: at)
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel(Text(AgentHistoryText.usageBadge(usage)))
    }
}

/// 用了几成的小圆环（标题旁的上下文、侧栏底部那一行）。底环中性，进度弧的颜色按程度（`AgentUsageLevel`）。
struct AgentUsageRing: View {
    let fraction: Double
    var level: AgentUsageLevel? = nil
    var size: CGFloat = 9
    var lineWidth: CGFloat = 1.5

    var body: some View {
        let level = level ?? AgentUsageLevel.of(percent: fraction * 100)
        ZStack {
            Circle().stroke(UD.fillSoft, lineWidth: lineWidth)
            Circle().trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(level.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
        .frame(width: size, height: size)
    }
}

private struct AgentUsageDetail: View {
    let usage: AgentTurnUsage
    let at: Date?

    var body: some View {
        let style = AgentTranscriptStyle.platform
        VStack(alignment: .leading, spacing: 8) {
            Text(AgentHistoryText.usageTitle)
                .font(style.font(12, weight: .semibold))
                .foregroundStyle(UD.text)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                if let model = usage.model {
                    row(AgentHistoryText.usageModel, model)
                }
                row(AgentHistoryText.usageContext, AgentHistoryText.usageContextValue(usage))
                row(AgentHistoryText.usageOutput, AgentHistoryText.tokenCount(usage.outputTokens))
            }
            if usage.contextWindow == nil {
                Text(AgentHistoryText.usageNoWindow)
                    .font(style.font(10.5))
                    .foregroundStyle(UD.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let limits = usage.rateLimits {
                Divider()
                Text(AgentHistoryText.usageRateLimits)
                    .font(style.font(11, weight: .semibold))
                    .foregroundStyle(UD.text2)
                ForEach(Array(limits.windows.enumerated()), id: \.offset) { _, window in
                    AgentRateLimitRow(window: window)
                }
                if let plan = limits.plan {
                    Text(AgentHistoryText.rateLimitPlan(plan))
                        .font(style.font(10.5))
                        .foregroundStyle(UD.text3)
                }
            }
            if let at {
                Text(AgentHistoryText.usageAsOf(at))
                    .font(style.font(10.5))
                    .foregroundStyle(UD.text4)
            }
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        let style = AgentTranscriptStyle.platform
        return GridRow {
            Text(label)
                .font(style.font(11))
                .foregroundStyle(UD.text3)
            Text(verbatim: value)
                .font(style.font(11))
                .foregroundStyle(UD.text)
                .monospacedDigit()
                .textSelection(.enabled)
        }
    }
}

/// 额度的一个时间窗：名字、用了几成（一根条）、几时重置。
struct AgentRateLimitRow: View {
    let window: AgentRateLimits.Window

    var body: some View {
        let style = AgentTranscriptStyle.platform
        let level = AgentUsageLevel.of(window)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(AgentHistoryText.rateLimitWindow(window))
                    .font(style.font(11))
                    .foregroundStyle(UD.text2)
                Spacer(minLength: 8)
                Text(AgentHistoryText.rateLimitUsed(window.usedPercent))
                    .font(style.font(11))
                    .foregroundStyle(level == .normal ? UD.text : level.color)
                    .monospacedDigit()
            }
            AgentRateLimitBar(usedPercent: window.usedPercent, level: level)
                .frame(height: 4)
            if window.didReset {
                Text(AgentHistoryText.rateLimitDidReset)
                    .font(style.font(10.5))
                    .foregroundStyle(UD.text3)
            } else if let resets = window.resetsAt {
                Text(AgentHistoryText.rateLimitResets(resets))
                    .font(style.font(10.5))
                    .foregroundStyle(UD.text3)
            }
        }
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
                    .agentHistoryBottomBar { AgentHistoryAccountLimits(history: history) }
            }
        }
    }
}

/// 侧栏最底下一行：每种工具的账号额度（最紧的三个时间窗，`AgentAccountLimits.compact`，如 5 小时、每周、Fable），最后是正在看的
/// 会话的上下文。每一项是小圆环（颜色按程度蓝 / 黄 / 红）+ 名字 + 用了几成，字不上色；用了多少 / 窗口多大、几时重置
/// 放在悬停和点开里，不常驻。只有一种工具有额度时不放工具图标。放不下时去掉名字。露着时每分钟重读一次状态栏的数据。
private struct AgentHistoryAccountLimits: View {
    let history: AgentHistoryModel
    @Environment(\.agentHistoryHidesAccountLimits) private var hidden
    @State private var showsDetail = false

    var body: some View {
        let rows = hidden ? [] : history.accountLimits()
        // 标题旁那个标记滚不到、或者右边露着终端时也看得到上下文。
        let context = hidden ? nil : history.currentContextUsage
        let style = AgentHistoryListStyle.platform
        // 上面不画分割线：贴在列表底部的条（`agentHistoryBottomBar`），列表从它下面滚过时系统做滚动边缘效果，
        // 没东西在下面时它和列表是同一块底（同 Apple 的做法、也同「填充即边界」）。
        VStack(spacing: 0) {
            if !rows.isEmpty || context != nil {
                #if os(macOS)
                // Mac：只一行——额度里最紧的那一个（带名字）+ 上下文；悬停这一行看全部，点开看明细。
                macLine(rows, context: context)
                    .font(.system(size: style.noteSize))
                    .padding(style.accountLimitsPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                #else
                // 一行放得下就一行；放不下额度一行、上下文一行（都带名字）；再放不下才去掉名字。
                ViewThatFits(in: .horizontal) {
                    items(rows, context: context, labeled: true)
                    stacked(rows, context: context, labeled: true)
                    items(rows, context: context, labeled: false)
                    stacked(rows, context: context, labeled: false)
                }
                .font(.system(size: style.noteSize))
                .padding(style.accountLimitsPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                #endif
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await history.refreshStatusLines()
                await history.refreshContextUsage()
            }
        }
    }

    #if os(macOS)
    private func macLine(_ rows: [AgentAccountLimits], context: AgentTurnUsage?) -> some View {
        // 几种工具里用得最多的那个时间窗。
        let tightest = rows.compactMap { row in row.headline.map { (row: row, window: $0) } }
            .max { $0.window.usedPercent < $1.window.usedPercent }
        return Button { showsDetail.toggle() } label: {
            ViewThatFits(in: .horizontal) {
                macItems(tightest, showsTool: rows.count > 1, context: context, labeled: true)
                macItems(tightest, showsTool: rows.count > 1, context: context, labeled: false)
            }
            .contentShape(Rectangle())
        }
        .agentHistoryPressStyle()
        .help(AgentHistoryText.accountLimitsSummary(rows, context: context))
        .popover(isPresented: $showsDetail) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows, id: \.tool) { row in
                    AgentAccountLimitsDetail(row: row)
                }
            }
        }
        .disabled(rows.isEmpty)
    }

    private func macItems(_ tightest: (row: AgentAccountLimits, window: AgentRateLimits.Window)?, showsTool: Bool,
                          context: AgentTurnUsage?, labeled: Bool) -> some View {
        let style = AgentHistoryListStyle.platform
        return HStack(spacing: 12) {
            if let tightest {
                HStack(spacing: 5) {
                    if showsTool { AgentHistoryToolBadge(tool: tightest.row.tool, size: style.toolBadgeSize - 2) }
                    AgentUsageItem(fraction: tightest.window.usedPercent / 100, level: AgentUsageLevel.of(tightest.window),
                                   label: labeled ? AgentHistoryText.rateLimitShortName(tightest.window) : nil,
                                   value: "\(Int(tightest.window.usedPercent.rounded()))%")
                }
            }
            if let context {
                AgentUsageItem(fraction: context.contextFraction,
                               level: context.contextFraction.map { AgentUsageLevel.of(percent: $0 * 100) } ?? .normal,
                               label: labeled ? AgentHistoryText.usageContext : nil,
                               value: context.contextFraction.map { "\(Int(($0 * 100).rounded()))%" }
                                   ?? AgentHistoryText.tokenCount(context.contextTokens))
            }
        }
        .fixedSize()
    }
    #endif

    private func items(_ rows: [AgentAccountLimits], context: AgentTurnUsage?, labeled: Bool) -> some View {
        HStack(spacing: 12) {
            ForEach(rows, id: \.tool) { row in
                group(row, showsTool: rows.count > 1, labeled: labeled)
            }
            if let context { AgentContextUsageItem(usage: context, labeled: labeled) }
        }
        .fixedSize()
    }

    /// 每种工具一行、上下文一行。
    private func stacked(_ rows: [AgentAccountLimits], context: AgentTurnUsage?, labeled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.tool) { row in
                HStack(spacing: 12) { group(row, showsTool: rows.count > 1, labeled: labeled) }
            }
            if let context { AgentContextUsageItem(usage: context, labeled: labeled) }
        }
        .fixedSize()
    }

    /// 一种工具的那几项：几种工具都有额度时前面放工具图标分开它们。点开是这种工具的全部额度。
    private func group(_ row: AgentAccountLimits, showsTool: Bool, labeled: Bool) -> some View {
        AgentAccountLimitsGroup(row: row, showsTool: showsTool, labeled: labeled)
    }
}

private struct AgentAccountLimitsGroup: View {
    let row: AgentAccountLimits
    let showsTool: Bool
    let labeled: Bool

    @State private var showsDetail = false

    var body: some View {
        let style = AgentHistoryListStyle.platform
        Button { showsDetail.toggle() } label: {
            HStack(spacing: 12) {
                if showsTool {
                    AgentHistoryToolBadge(tool: row.tool, size: style.toolBadgeSize - 2)
                        .padding(.trailing, -6)
                }
                ForEach(Array(row.compact.enumerated()), id: \.offset) { _, window in
                    AgentUsageItem(fraction: window.usedPercent / 100, level: AgentUsageLevel.of(window),
                                   label: labeled ? AgentHistoryText.rateLimitShortName(window) : nil,
                                   value: "\(Int(window.usedPercent.rounded()))%")
                        .help(AgentHistoryText.rateLimitHelp(window, tool: row.tool))
                }
            }
            .contentShape(Rectangle())
        }
        .agentHistoryPressStyle()
        .popover(isPresented: $showsDetail) {
            AgentAccountLimitsDetail(row: row)
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// 侧栏底部最后一项：正在看的会话的上下文。知道窗口多大画圆环写百分比，不知道只写用了多少。
private struct AgentContextUsageItem: View {
    let usage: AgentTurnUsage
    let labeled: Bool

    var body: some View {
        AgentUsageItem(fraction: usage.contextFraction,
                       level: usage.contextFraction.map { AgentUsageLevel.of(percent: $0 * 100) } ?? .normal,
                       label: labeled ? AgentHistoryText.usageContext : nil,
                       value: usage.contextFraction.map { "\(Int(($0 * 100).rounded()))%" }
                           ?? AgentHistoryText.tokenCount(usage.contextTokens))
            .help(AgentHistoryText.usageContext + " · " + AgentHistoryText.usageContextValue(usage))
    }
}

/// 一项：小圆环、名字、数字。圆环按程度上色，字不上色。
private struct AgentUsageItem: View {
    let fraction: Double?
    let level: AgentUsageLevel
    let label: String?
    let value: String

    var body: some View {
        let style = AgentHistoryListStyle.platform
        HStack(spacing: 5) {
            if let fraction {
                AgentUsageRing(fraction: fraction, level: level, size: style.noteSize + 2, lineWidth: 2)
            }
            if let label {
                Text(label)
                    .lineLimit(1)
                    .foregroundStyle(UD.text3)
            }
            Text(verbatim: value)
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(UD.text2)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 一种工具的额度明细（侧栏底部、iOS 状态栏那一列点开的都是它）。
struct AgentAccountLimitsDetail: View {
    let row: AgentAccountLimits

    var body: some View {
        let style = AgentTranscriptStyle.platform
        VStack(alignment: .leading, spacing: 8) {
            Text(AgentHistoryText.accountLimitsTitle(row.tool))
                .font(style.font(12, weight: .semibold))
                .foregroundStyle(UD.text)
            ForEach(Array(row.windows.enumerated()), id: \.offset) { _, window in
                AgentRateLimitRow(window: window)
            }
            if let plan = row.limits.plan {
                Text(AgentHistoryText.rateLimitPlan(plan))
                    .font(style.font(10.5))
                    .foregroundStyle(UD.text3)
            }
            if let at = row.at {
                Text(AgentHistoryText.usageAsOf(at))
                    .font(style.font(10.5))
                    .foregroundStyle(UD.text4)
            }
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
    }
}

/// 额度用了几成的一根细条，颜色按程度（`AgentUsageLevel`）。
struct AgentRateLimitBar: View {
    let usedPercent: Double
    let level: AgentUsageLevel

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(UD.fillSoft)
                Capsule().fill(level.color)
                    .frame(width: proxy.size.width * min(1, max(0, usedPercent / 100)))
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

private struct AgentHistoryHidesAccountLimitsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 侧栏底部不列账号额度：平台把它放到了别处（iPhone Duo 横握时放进状态栏那一列，`WorkspaceSideAccountLimits`）。
    /// 列表照旧每分钟重读一次状态栏的数据。
    var agentHistoryHidesAccountLimits: Bool {
        get { self[AgentHistoryHidesAccountLimitsKey.self] }
        set { self[AgentHistoryHidesAccountLimitsKey.self] = newValue }
    }
}

extension AgentUsageLevel {
    /// 蓝（强调色）、黄、红。
    var color: Color {
        switch self {
        case .normal: return UD.accent
        case .warning: return UD.warning
        case .critical: return UD.danger
        }
    }
}

private extension View {
    /// 贴在会话列表底部的条（账号额度、上下文），不画常驻的分割线。Mac 上铺一层不透明的底（同列表的卡片色）、列表在它
    /// 上面截止：Mac 的柔和边缘效果几乎是透明的，后面会话的标题会从这一行后面透出来（实机反馈）。iOS 26 起用
    /// `safeAreaBar`，列表滚到它下面时系统做柔和的滚动边缘效果；iOS 26 以前退回 `safeAreaInset`（同样不画线）。
    @ViewBuilder
    func agentHistoryBottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        #if os(macOS)
        safeAreaInset(edge: .bottom, spacing: 0) { bar().background(UD.card) }
        #else
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .bottom, spacing: 0, content: bar)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0, content: bar)
        }
        #endif
    }
}
