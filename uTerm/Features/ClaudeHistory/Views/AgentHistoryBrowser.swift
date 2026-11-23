import AppKit
import SwiftUI
import UDesignKit

/// 历史会话窗口的内容：左边会话列表，右边选中会话的对话。
struct AgentHistoryBrowser: View {
    let history: AgentHistoryModel
    let onResume: (AgentHistorySessionFile) -> Void

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        HStack(spacing: 0) {
            AgentHistorySessionList(history: history)
                .frame(width: 300)
            Rectangle().fill(UD.border).frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 实时跟随只在看得见时查：窗口关了、缩进程序坞 / App 隐藏（场景进了后台）就停，回来马上查一次。
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
                                        onOpenSubagent: { history.openSubagent($0) })
                        .opacity(isTop ? 1 : 0)
                        .allowsHitTesting(isTop)
                        .accessibilityHidden(!isTop)
                }
            }
            .id(transcript.file.path)
        } else {
            RemoteMacStateView(systemImage: "text.bubble", title: String(localized: "选择一个会话"),
                               detail: String(localized: "左边列的是在命令行里用 Claude Code 的会话，内容只读。"))
        }
    }
}

// MARK: - 会话列表

struct AgentHistorySessionList: View {
    let history: AgentHistoryModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(UD.border).frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Menu {
                if let current = history.currentProject {
                    Button(AgentHistoryText.currentProjectItem(current)) {
                        Task { await history.setScope(.project(current)) }
                    }
                }
                Button(String(localized: "全部项目")) { Task { await history.setScope(.all) } }
                let others = history.projects.filter { $0.id != history.currentProject?.id }.prefix(40)
                if !others.isEmpty {
                    Section(String(localized: "其他项目")) {
                        ForEach(Array(others)) { project in
                            Button(AgentHistoryText.projectName(project)) {
                                Task { await history.setScope(.project(project)) }
                            }
                        }
                    }
                }
            } label: {
                Text(scopeTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .help(String(localized: "切换项目"))
            Spacer(minLength: 0)
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
        .padding(.horizontal, 10)
        .frame(height: 40)
    }

    private var scopeTitle: String { AgentHistoryText.scopeTitle(history.scope) }

    @ViewBuilder private var content: some View {
        switch history.phase {
        case .loading:
            RemoteMacProgressView(text: String(localized: "正在读取会话列表…"))
        case .empty:
            RemoteMacStateView(systemImage: "tray", title: String(localized: "没有历史会话"),
                               detail: AgentHistoryText.noHistoryDetail)
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(files) { file in
                    AgentHistorySessionRow(file: file, metadata: history.metadata[file.path],
                                           showsProject: history.scope == .all,
                                           isSelected: history.selectedFile?.path == file.path)
                        .onTapGesture { history.select(file) }
                }
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
            }
            .padding(6)
        }
    }
}

private struct AgentHistorySessionRow: View {
    let file: AgentHistorySessionFile
    let metadata: AgentHistorySessionMetadata?
    let showsProject: Bool
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(UD.text)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(UD.text3)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? UD.rowSelected : Color.clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var title: String { AgentHistoryText.sessionTitle(file, metadata: metadata) }

    private var subtitle: String {
        AgentHistoryText.sessionSubtitle(file, metadata: metadata, showsProject: showsProject)
    }
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

    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(UD.border).frame(height: 1)
            messages
        }
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
                Text(detailLine)
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
                    .help(canResume
                          ? String(localized: "在这台主机上新开一个终端标签页，执行 claude --resume")
                          : String(localized: "不知道这个会话的工作目录，无法继续"))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }

    private var titleLine: String {
        transcript.subagent.map(AgentHistoryText.subagentTitle) ?? AgentHistoryText.transcriptTitle(metadata)
    }

    private var detailLine: String {
        transcript.subagent.map(AgentHistoryText.subagentDetail)
            ?? AgentHistoryText.transcriptDetail(transcript.file, metadata: metadata)
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
                                           subagent: subagentLink(item), onOpenSubagent: onOpenSubagent,
                                           expanded: $expanded)
                            .id(item.id)
                    }
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
            .defaultScrollAnchor(.bottom)
            .onChange(of: transcript.prependGeneration) { old, _ in
                // 往前加了一页：留在原来最上面那条，不跳到别处。第一页不用（默认停在底部）。
                guard old > 0, let anchor = pendingAnchor else { return }
                proxy.scrollTo(anchor, anchor: .top)
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
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(UD.accent))
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
    /// 这次调用派出的子代理（找得到记录的才有）。
    let subagent: AgentSubagentLink?
    let onOpenSubagent: (AgentSubagentLink) -> Void
    @Binding var expanded: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsRole {
                Text(AgentHistoryText.roleLabel(item.role, inSubagent: inSubagent))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(UD.text3)
                    .padding(.top, 6)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
