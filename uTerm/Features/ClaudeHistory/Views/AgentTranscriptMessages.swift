import SwiftUI
import UDesignKit

/// 历史会话对话记录的正文（两端共用一份）：滚动列表、每一行、工具调用折成的组。样子同 Claude Code Desktop：
/// 你说的话靠右一块气泡、回答直接排、工具调用 / 思考 / 输出都是一行可展开的灰字，不标「你」「Claude」。
///
/// 标题行各端自己画（Mac 是 `AgentTranscriptPane`，iOS 是 `ClaudeTranscriptView`）。两端的差别只有
/// 尺寸与几处交互，放在 `AgentTranscriptStyle`；真正不同的几个小件两端各有一份同名的：
/// `AgentTranscriptMarkdown`（两端的 Markdown 排版不是同一套）、`AgentSubagentEntry`、`AgentNewMessagesPill`，
/// 以及 `agentTranscriptCopyMenu` / `agentHistoryPressStyle` / `agentHistoryScrollChrome` 三个修饰。
struct AgentTranscriptMessages: View {
    let transcript: AgentTranscriptModel
    let onOpenSubagent: (AgentSubagentLink) -> Void

    @State private var expanded: Set<String> = []
    @State private var pendingAnchor: String?

    private let style = AgentTranscriptStyle.platform
    private static var bottomID: String { "agent-transcript-bottom" }

    var body: some View {
        let items = transcript.items
        // 连续的工具调用折成一行；派出了子代理的那次单独一行，入口露在外面。
        let layout = AgentTranscriptLayout(items: items) { transcript.subagentLink(for: $0) == nil }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    AgentTranscriptLoadEarlier(transcript: transcript, loadEarlier: loadEarlier)
                    ForEach(layout.rows) { row in
                        rowView(row.entry, showsTaskLabel: row.startsRun && transcript.subagent != nil)
                            // 换了说话的一方：上面多空一点（代替原来的「你」/「Claude」标签）。
                            .padding(.top, row.hasGapAbove ? 12 : 0)
                            .id(row.id)
                    }
                    AgentTranscriptLoadLater(transcript: transcript)
                    if layout.rows.isEmpty, transcript.reachedStart, transcript.errorMessage == nil {
                        Text("这个会话里没有可显示的消息。")
                            .font(style.font(11))
                            .foregroundStyle(UD.text3)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                    // 跟到底时滚到这里。底部留白由它和上面的间距承担：锚点下面再垫 padding，
                    // `scrollTo(_, anchor: .bottom)` 就永远差这一截（见 `TerminalAgentView`）。
                    Color.clear.frame(height: style.bottomAnchorHeight).id(Self.bottomID)
                }
                // 宽窗口里居中一栏，不铺满。
                .frame(maxWidth: 780)
                .padding(.horizontal, style.columnPadding)
                .padding(.top, style.topPadding)
                .frame(maxWidth: .infinity)
            }
            .agentHistoryScrollChrome()
            // 打开时停在最后一条；内容不满一屏时从顶上排起——只写 `.bottom` 的话短对话会贴着底、上面空一大片。
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .modifier(AgentTranscriptGrowthAnchor(enabled: style.anchorsGrowthToEnd, reachedEnd: transcript.reachedEnd))
            .defaultScrollAnchor(.top, for: .alignment)
            .onChange(of: transcript.prependGeneration) { old, _ in
                // 往前加了一页：留在原来最上面那条（可能和新读进来的调用并成了一组，滚到它所在的那一行）。第一页不用。
                guard old > 0, let anchor = pendingAnchor else { return }
                proxy.scrollTo(layout.rowID(for: anchor), anchor: .top)
            }
            .onChange(of: transcript.focusGeneration) { _, _ in
                // 搜索命中的那一条：在折起来的组里就先展开，再滚到中间（等这一轮布局完）。
                guard let id = transcript.highlightedItemID else { return }
                let rowID = layout.reveal(id, expanding: &expanded)
                Task { @MainActor in proxy.scrollTo(rowID, anchor: .center) }
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

    @ViewBuilder private func rowView(_ entry: AgentTranscriptEntry, showsTaskLabel: Bool) -> some View {
        switch entry {
        case .item(let item):
            AgentTranscriptRow(item: item, showsTaskLabel: showsTaskLabel, subagent: subagentLink(item),
                               onOpenSubagent: onOpenSubagent, isHighlighted: item.id == transcript.highlightedItemID,
                               expanded: $expanded)
        case .tools(let group):
            AgentToolGroupRow(group: group, highlightedID: transcript.highlightedItemID, expanded: $expanded)
        }
    }

    private func subagentLink(_ item: AgentTranscriptItem) -> AgentSubagentLink? {
        guard case .toolCall(let call) = item.kind else { return nil }
        return transcript.subagentLink(for: call)
    }

    private func loadEarlier() {
        pendingAnchor = transcript.firstItemID
        // 要往前看：不再跟着末尾走（内容不满一屏时点「加载更早」也不会被拽回底部）。
        transcript.setFollowsTail(false)
        Task { await transcript.loadEarlier() }
    }
}

/// 两端排版上的差别（同 `HostAvatar` 按平台取默认值）：手机上字大一号、留够点按的高度、没有悬停（展开箭头常显）、
/// 长行横着滚（窄屏折行读不了日志）、只有气泡能长按拷贝（长按别的行会和滚动、选字打架）。
nonisolated struct AgentTranscriptStyle: Sendable {
    /// 比 Mac 大几号。
    var textBump: CGFloat
    /// 对话页标题行的标题。
    var titleSize: CGFloat
    /// 标题行下面的横条前面画图标、只排一行（Mac）；手机上不画图标、字多折两行。
    var bannerShowsIcon: Bool
    var columnPadding: CGFloat
    var topPadding: CGFloat
    var bottomAnchorHeight: CGFloat
    /// 可展开那一行的图标宽与图标后的间距；展开的内容缩进到标题文字下面（两者之和）。
    var iconWidth: CGFloat
    var lineSpacing: CGFloat
    var lineMinHeight: CGFloat?
    /// 展开箭头只在悬停时出现（Mac）；手机上常显。
    var revealsChevronOnHover: Bool
    var bubbleInset: CGFloat
    var bubbleRadius: CGFloat
    var cardRadius: CGFloat
    /// 气泡、展开卡片的底色。
    var surface: Color
    /// 工具结果、命令输出的长行折行（Mac）；手机上横着滚。
    var wrapsLongLines: Bool
    /// 每一行（含工具组）都能右键拷贝（Mac）；手机上只有气泡长按拷贝。
    var copiesEveryRow: Bool
    var noticeLineLimit: Int
    /// 内容变高时（往后读了一页、新消息）读到末尾的就贴着底。手机上一直没设，靠 `AgentTranscriptTailFollow` 补滚。
    var anchorsGrowthToEnd: Bool

    var detailIndent: CGFloat { iconWidth + lineSpacing }

    func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size + textBump, weight: weight)
    }

    func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        UD.mono(size + textBump, weight: weight)
    }

    #if os(macOS)
    static let platform = AgentTranscriptStyle(
        textBump: 0, titleSize: 13, bannerShowsIcon: true, columnPadding: 24, topPadding: 16, bottomAnchorHeight: 4,
        iconWidth: 14, lineSpacing: 7, lineMinHeight: nil, revealsChevronOnHover: true,
        bubbleInset: 64, bubbleRadius: 14, cardRadius: 8, surface: UD.fillSoft,
        wrapsLongLines: true, copiesEveryRow: true, noticeLineLimit: 2, anchorsGrowthToEnd: true)
    #else
    static let platform = AgentTranscriptStyle(
        textBump: 1, titleSize: 14.5, bannerShowsIcon: false, columnPadding: 16, topPadding: 14, bottomAnchorHeight: 2,
        iconWidth: 15, lineSpacing: 8, lineMinHeight: 32, revealsChevronOnHover: false,
        bubbleInset: 40, bubbleRadius: 16, cardRadius: 10, surface: UD.fillFaint,
        wrapsLongLines: false, copiesEveryRow: false, noticeLineLimit: 3, anchorsGrowthToEnd: false)
    #endif
}

/// 内容变高时的锚点：读到末尾就贴着底；从命中处打开、后面还没读完时往后加页不把视口拽到底（不然会一页接一页读下去）。
private struct AgentTranscriptGrowthAnchor: ViewModifier {
    let enabled: Bool
    let reachedEnd: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.defaultScrollAnchor(reachedEnd ? .bottom : .top, for: .sizeChanges)
        } else {
            content
        }
    }
}

extension Binding where Value == Set<String> {
    /// 展开状态：集合里有这个键就是展开的。
    func contains(_ key: String) -> Binding<Bool> {
        Binding<Bool>(get: { wrappedValue.contains(key) },
                      set: { if $0 { wrappedValue.insert(key) } else { wrappedValue.remove(key) } })
    }
}

// MARK: - 行

/// 对话里的一条（工具调用折成组的不在这里，见 `AgentToolGroupRow`）。
private struct AgentTranscriptRow: View {
    let item: AgentTranscriptItem
    /// 子代理的记录：「用户」那一侧标成「任务」（那是派它的主代理交给它的，不是你说的）。
    let showsTaskLabel: Bool
    /// 这次调用派出的子代理（找得到记录的才有）。
    let subagent: AgentSubagentLink?
    let onOpenSubagent: (AgentSubagentLink) -> Void
    var isHighlighted = false
    @Binding var expanded: Set<String>

    private let style = AgentTranscriptStyle.platform

    var body: some View {
        let isUser = item.role == .user
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            if showsTaskLabel, isUser {
                Text(AgentHistoryText.subagentTask)
                    .font(style.font(11, weight: .semibold))
                    .foregroundStyle(UD.text3)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .modifier(AgentTranscriptHighlight(isOn: isHighlighted))
        .modifier(AgentTranscriptCopyable(enabled: style.copiesEveryRow && item.hasPlainText) { item.plainText })
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .userText(let text):
            AgentUserBubble(copyText: text) {
                AgentTranscriptMarkdown(text: text)
                    .textSelection(.enabled)
            }
        case .assistantText(let text):
            AgentTranscriptMarkdown(text: text)
                .textSelection(.enabled)
        case .command(let command):
            AgentUserBubble(copyText: command) {
                Text(verbatim: command)
                    .font(style.mono(12, weight: .medium))
                    .foregroundStyle(UD.text)
                    .textSelection(.enabled)
            }
        case .commandOutput(let output):
            AgentDisclosureLine(systemImage: "text.alignleft", title: String(localized: "输出"),
                                subtitle: output.firstLine, isOpen: $expanded.contains(AgentTranscriptKey.open(item.id))) {
                AgentDetailCard {
                    AgentClippedBody(id: item.id, text: output, isError: false, expanded: $expanded)
                        .padding(10)
                }
            }
        case .notice(let text):
            Label { Text(verbatim: text) } icon: { Image(systemName: "bell") }
                .font(style.font(11.5))
                .foregroundStyle(UD.text3)
                .lineLimit(style.noticeLineLimit)
        case .thinking(let text):
            AgentDisclosureLine(systemImage: "brain", title: String(localized: "思考"),
                                subtitle: text.firstLine, subtitleIsCode: false,
                                isOpen: $expanded.contains(AgentTranscriptKey.open(item.id))) {
                Text(verbatim: text.text + (text.isClipped ? "\n…" : ""))
                    .font(style.font(12))
                    .italic()
                    .foregroundStyle(UD.text3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(UD.border).frame(width: 2) }
            }
        case .toolCall, .toolResult:
            AgentToolLine(item: item, subagent: subagent, onOpenSubagent: onOpenSubagent, expanded: $expanded)
        case .image:
            Label(String(localized: "图片（不显示）"), systemImage: "photo")
                .font(style.font(11.5))
                .foregroundStyle(UD.text3)
        case .compactSummary(let summary):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Rectangle().fill(UD.border).frame(height: 1)
                    Text("上下文已压缩")
                        .font(style.font(11, weight: .medium))
                        .foregroundStyle(UD.text3)
                        .fixedSize()
                    Rectangle().fill(UD.border).frame(height: 1)
                }
                AgentDisclosureLine(systemImage: "rectangle.compress.vertical", title: String(localized: "压缩摘要"),
                                    subtitle: summary.firstLine, subtitleIsCode: false,
                                    isOpen: $expanded.contains(AgentTranscriptKey.open(item.id))) {
                    AgentDetailCard {
                        AgentClippedBody(id: item.id, text: summary, isError: false, expanded: $expanded)
                            .padding(10)
                    }
                }
            }
            .padding(.vertical, 6)
        case .oversized(let bytes):
            Label(AgentHistoryText.oversized(bytes), systemImage: "exclamationmark.circle")
                .font(style.font(11.5))
                .foregroundStyle(UD.text3)
        case .usage:
            EmptyView()
        }
    }
}

/// 展开状态的键（`expanded` 集合里）。
private enum AgentTranscriptKey {
    static func open(_ id: String) -> String { "\(id).open" }
    static func full(_ id: String) -> String { "\(id).full" }
}

/// 搜索命中的那一条：底色加左边一道线，画在边界外，不挤动排版。
private struct AgentTranscriptHighlight: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        content
            .background {
                if isOn {
                    RoundedRectangle(cornerRadius: AgentTranscriptStyle.platform.cardRadius, style: .continuous)
                        .fill(UD.accentSoft)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1.5).fill(UD.accent).frame(width: 3)
                        }
                        .padding(.horizontal, -8)
                        .padding(.vertical, -5)
                }
            }
            .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// 能拷贝这一条的文字。文字在点的时候才拼（工具组的结果加起来可能有几百 KB，不能每次重画都拼一遍）。
private struct AgentTranscriptCopyable: ViewModifier {
    let enabled: Bool
    let text: () -> String

    func body(content: Content) -> some View {
        if enabled {
            content.agentTranscriptCopyMenu(text)
        } else {
            content
        }
    }
}

/// 你说的话：靠右、宽度贴着内容的一块。左边至少空出一截，长消息也看得出是哪一方。
private struct AgentUserBubble<Content: View>: View {
    let copyText: String
    @ViewBuilder let content: () -> Content

    private let style = AgentTranscriptStyle.platform

    var body: some View {
        // 长消息不量贴身宽度（量一遍要排成一整行，反正会撑满）。`utf8.count` 不用逐字数。
        AgentHuggingWidth(hugs: copyText.utf8.count <= 1_500) {
            content()
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: style.bubbleRadius, style: .continuous).fill(style.surface))
                // 每一行都能拷贝的那一端，行上已经有了。
                .modifier(AgentTranscriptCopyable(enabled: !style.copiesEveryRow) { copyText })
        }
        .padding(.leading, style.bubbleInset)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// 可展开的一行灰字：图标、标题、一行摘要、（出错）、展开箭头。工具调用、思考、命令输出都用它。
private struct AgentDisclosureLine<Detail: View>: View {
    let systemImage: String
    let title: String
    var subtitle: String = ""
    /// 摘要是命令、路径这类：用等宽字。
    var subtitleIsCode = true
    var isError = false
    var isExpandable = true
    /// 展开后摘要就在下面：标题行上不再重复（工具组的名字列表下面没有，照留）。
    var keepsSubtitleWhenOpen = false
    @Binding var isOpen: Bool
    @ViewBuilder let detail: () -> Detail

    @State private var hovering = false
    private let style = AgentTranscriptStyle.platform

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                guard isExpandable else { return }
                withAnimation(.easeOut(duration: 0.15)) { isOpen.toggle() }
            } label: {
                header
            }
            .agentHistoryPressStyle()
            .onHover { hovering = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isExpandable ? .isButton : [])
            if isOpen, isExpandable {
                detail()
                    .padding(.leading, style.detailIndent)
            }
        }
    }

    private var header: some View {
        HStack(spacing: style.lineSpacing) {
            Image(systemName: systemImage)
                .font(style.font(11))
                .foregroundStyle(UD.text3)
                .frame(width: style.iconWidth)
            Text(verbatim: title)
                .font(style.font(12.5, weight: .medium))
                .foregroundStyle(UD.text2)
                .fixedSize()
            if !subtitle.isEmpty, keepsSubtitleWhenOpen || !isOpen {
                Text(verbatim: subtitle)
                    .font(subtitleIsCode ? style.mono(11.5) : style.font(12))
                    .foregroundStyle(UD.text3)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if isError {
                Text(AgentHistoryText.toolFailed)
                    .font(style.font(10.5, weight: .medium))
                    .foregroundStyle(UD.danger)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(UD.danger.opacity(0.12)))
                    .fixedSize()
            }
            if isExpandable {
                Image(systemName: "chevron.right")
                    .font(style.font(9, weight: .semibold))
                    .foregroundStyle(UD.text4)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .opacity(!style.revealsChevronOnHover || hovering || isOpen ? 1 : 0)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: style.lineMinHeight)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(hovering && isExpandable && style.revealsChevronOnHover ? UD.panelHover : .clear))
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
    }
}

/// 展开后的灰底卡片。
private struct AgentDetailCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        let style = AgentTranscriptStyle.platform
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: style.cardRadius, style: .continuous).fill(style.surface))
    }
}

/// 一次工具调用（或找不到调用的一份结果）：一行，展开是调用的参数和结果。
private struct AgentToolLine: View {
    let item: AgentTranscriptItem
    var subagent: AgentSubagentLink? = nil
    var onOpenSubagent: (AgentSubagentLink) -> Void = { _ in }
    @Binding var expanded: Set<String>

    private let style = AgentTranscriptStyle.platform

    var body: some View {
        let isOpen = $expanded.contains(AgentTranscriptKey.open(item.id))
        VStack(alignment: .leading, spacing: 4) {
            switch item.kind {
            case .toolCall(let call):
                AgentDisclosureLine(systemImage: AgentToolSymbol.systemImage(for: call.name), title: call.name,
                                    subtitle: call.summary, isError: call.result?.isError == true,
                                    isExpandable: call.result != nil || !call.summary.isEmpty, isOpen: isOpen) {
                    AgentDetailCard {
                        if !call.summary.isEmpty {
                            Text(verbatim: call.summary)
                                .font(style.mono(11.5))
                                .foregroundStyle(UD.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                        if let result = call.result {
                            if !call.summary.isEmpty { Rectangle().fill(UD.border).frame(height: 1) }
                            resultBody(result)
                        }
                    }
                }
                if let subagent {
                    AgentSubagentEntry(link: subagent) { onOpenSubagent(subagent) }
                        .padding(.leading, style.detailIndent)
                }
            case .toolResult(let result):
                AgentDisclosureLine(systemImage: "arrow.turn.down.right", title: String(localized: "结果"),
                                    subtitle: result.content.firstLine, isError: result.isError, isOpen: isOpen) {
                    AgentDetailCard { resultBody(result) }
                }
            default:
                EmptyView()
            }
        }
    }

    private func resultBody(_ result: AgentToolResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentClippedBody(id: item.id, text: result.content, isError: result.isError, expanded: $expanded)
            if result.imageCount > 0 {
                Label(AgentHistoryText.resultImages(result.imageCount), systemImage: "photo")
                    .font(style.font(11))
                    .foregroundStyle(UD.text3)
            }
        }
        .padding(10)
    }
}

/// 连续几次工具调用：折成一行「N 次工具调用 · Bash、Read」，展开是每一次各一行。
private struct AgentToolGroupRow: View {
    let group: AgentToolGroup
    let highlightedID: String?
    @Binding var expanded: Set<String>

    var body: some View {
        AgentDisclosureLine(systemImage: "square.stack.3d.up", title: AgentHistoryText.toolGroupTitle(group.items.count),
                            subtitle: group.names.joined(separator: String(localized: "、", comment: "并列项之间的分隔符")),
                            subtitleIsCode: false, isError: group.hasError, keepsSubtitleWhenOpen: true,
                            isOpen: $expanded.contains(group.expansionKey)) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(group.items) { item in
                    AgentToolLine(item: item, expanded: $expanded)
                        .modifier(AgentTranscriptHighlight(isOn: item.id == highlightedID))
                }
            }
            .padding(.leading, 10)
            .overlay(alignment: .leading) { Rectangle().fill(UD.border).frame(width: 1) }
        }
        .modifier(AgentTranscriptCopyable(enabled: AgentTranscriptStyle.platform.copiesEveryRow) {
            group.items.map(\.plainText).filter { !$0.isEmpty }.joined(separator: "\n\n")
        })
    }
}

/// 长文字（工具结果、命令输出、压缩摘要）展开后的内容：先给前几行，再点才给全部（仍有上限）。
private struct AgentClippedBody: View {
    let id: String
    let text: AgentClippedText
    let isError: Bool
    @Binding var expanded: Set<String>

    private let style = AgentTranscriptStyle.platform

    var body: some View {
        let fullKey = AgentTranscriptKey.full(id)
        let showsAll = expanded.contains(fullKey)
        let preview = text.preview(lines: AgentTranscriptLimits.previewLines,
                                   characters: AgentTranscriptLimits.previewCharacters)
        VStack(alignment: .leading, spacing: 6) {
            textView(showsAll ? text.text : preview)
            if !showsAll, preview.count < text.text.count {
                Button(AgentHistoryText.showAll(text.text.count)) { expanded.insert(fullKey) }
                    .buttonStyle(.udPlain)
                    .font(style.font(11))
                    .foregroundStyle(UD.accent)
            }
            if text.isClipped, showsAll || preview.count >= text.text.count {
                Text(AgentHistoryText.clippedNote(text))
                    .font(style.font(11))
                    .foregroundStyle(UD.text4)
            }
        }
    }

    @ViewBuilder private func textView(_ string: String) -> some View {
        let body = Text(verbatim: string)
            .font(style.mono(11))
            .foregroundStyle(isError ? UD.danger : UD.text2)
            .textSelection(.enabled)
        if style.wrapsLongLines {
            body.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                body.fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}
