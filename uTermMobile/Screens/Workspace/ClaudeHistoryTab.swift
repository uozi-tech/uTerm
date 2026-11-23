import UDesignKit
import SwiftUI
import SwiftData
import Observation
import UIKit

/// 「Claude 历史会话」标签：一台主机（或一台配对过的 Mac）上 Claude Code 在命令行里的会话，只读。
/// 连接、列表、翻页都在两端共用的 `AgentHistoryConnection` / `AgentHistoryModel` 里，这里只是标签与画面。
///
/// 内容只在内存里：不落盘、不进 iCloud、不进标签归档（`MobileTerminalTabArchive` 只管终端），重启不恢复。
/// 一台主机（一台 Mac）至多一个，再开就带到前台。
@MainActor
@Observable
final class ClaudeHistoryTab: Identifiable {
    let id = UUID()
    /// 直连的主机；配对的 Mac 是不入库的临时主机（`RemoteMacClient.filesTabHost`），只用来显示名字。
    let host: ServerProfile
    let hostName: String
    /// 读的是这台配对过的 Mac（远控链路），不是 SSH 主机。
    let remoteMac: RemoteMacClient?
    let connection: AgentHistoryConnection

    init(host: ServerProfile, connection: AgentHistoryConnection, remoteMac: RemoteMacClient? = nil) {
        self.host = host
        self.hostName = host.name
        self.remoteMac = remoteMac
        self.connection = connection
    }

    /// 已保存的主机（经 SFTP，与同主机的终端共用一条 SSH 连接）。`directory` 是终端当前目录，先列它所在的项目。
    convenience init(server host: ServerProfile, directory: String?, container: ModelContainer) {
        self.init(host: host, connection: AgentHistoryConnection(
            preferredDirectory: directory, allowsCommands: { !host.sftpOnly },
            connect: AgentHistoryAccess.server(host, container: container)))
    }

    /// 配对过的 Mac：读它上面的 `~/.claude`。远控协议里没有终端的当前目录，列全部项目。
    convenience init(pairedMac client: RemoteMacClient) {
        self.init(host: client.filesTabHost,
                  connection: AgentHistoryConnection(preferredDirectory: nil, connect: AgentHistoryAccess.pairedMac(client)),
                  remoteMac: client)
    }

    /// 能不能「继续这个会话」：要在那台主机上开终端。仅 SFTP 的主机开不了；配对的 Mac 要认得「新建本机终端」。
    var canResume: Bool {
        if let remoteMac { return remoteMac.supportsLocalShell }
        return !host.sftpOnly
    }

    func start() {
        Task { await connection.open() }
    }

    func close() {
        connection.close()
    }
}

/// 历史标签的主体：连接中 / 失败 / 会话列表与对话。
struct ClaudeHistorySessionBody: View {
    let tab: ClaudeHistoryTab
    /// 标签在前台、工作区没收起：打开着的对话才盯着文件末尾（实时跟随）。
    var isActive = true
    /// 在终端里继续选中的会话（命令由共享的 `ClaudeResumeCommand` 生成）。
    var onResume: (_ command: String, _ directory: String) -> Void

    var body: some View {
        Group {
            switch tab.connection.phase {
            case .connecting:
                ClaudeHistoryProgress(text: String(localized: "正在连接…"))
            case .failed(let message):
                ClaudeHistoryState(icon: "warn", title: String(localized: "无法读取历史会话"), message: message,
                                   actionTitle: String(localized: "重试")) {
                    Task { await tab.connection.open() }
                }
            case .ready(let history):
                ClaudeHistoryBrowser(history: history, canResume: tab.canResume, isActive: isActive) { file in
                    guard let plan = history.resumeCommand(for: file) else { return }
                    onResume(plan.command, plan.directory)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(M.surface, ignoresSafeAreaEdges: .mSessionBody)
    }
}

/// 列表与对话。宽的格子（iPad、展开的 Duo 横屏）左右并排；窄的先是列表，点一条进到对话，左上角返回列表。
/// 对话里点进子代理的记录再一层层往里进，左上角一层层返回。
struct ClaudeHistoryBrowser: View {
    let history: AgentHistoryModel
    let canResume: Bool
    var isActive = true
    let onResume: (AgentHistorySessionFile) -> Void

    @Environment(\.scenePhase) private var scenePhase

    /// 宽过这么多才左右并排：列表 300pt，对话至少还要 400pt 才读得下去。
    nonisolated static let sideBySideMinWidth: CGFloat = 700

    var body: some View {
        GeometryReader { geo in
            if geo.size.width >= Self.sideBySideMinWidth {
                HStack(spacing: 0) {
                    ClaudeHistoryList(history: history)
                        .frame(width: 300)
                    Rectangle().fill(M.divider).frame(width: 1)
                    detail(showsBack: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if history.transcript != nil {
                detail(showsBack: true)
            } else {
                ClaudeHistoryList(history: history)
            }
        }
        // 实时跟随只在看得见时查：标签不在前台、工作区收起、App 进了后台就停（省电），回来马上查一次。
        .onChange(of: isActive && scenePhase != .background, initial: true) { _, visible in
            history.setTranscriptVisible(visible)
        }
        .onDisappear { history.setTranscriptVisible(false) }
    }

    @ViewBuilder private func detail(showsBack: Bool) -> some View {
        if let transcript = history.transcript {
            // 主对话与点进去的一层层子代理记录都挂着，只露出最里面那层：返回时滚动位置、展开的块都还在。
            let levels = [transcript] + history.subagentStack
            let top = levels.last?.path
            ZStack {
                ForEach(levels, id: \.path) { level in
                    let isTop = level.path == top
                    ClaudeTranscriptView(transcript: level,
                                         metadata: history.metadata[level.file.path],
                                         canResume: canResume && history.resumeCommand(for: level.file) != nil,
                                         onBack: back(for: level, showsBack: showsBack),
                                         onResume: { onResume(level.file) },
                                         onOpenSubagent: { history.openSubagent($0) },
                                         onJumpToLatest: { history.jumpToLatest() })
                        .opacity(isTop ? 1 : 0)
                        .allowsHitTesting(isTop)
                        .accessibilityHidden(!isTop)
                }
            }
            // 换了一份对话（含「跳到最新」）就是新的视图。
            .id(ObjectIdentifier(transcript))
        } else {
            ClaudeHistoryState(icon: "clock", title: String(localized: "选择一个会话"),
                               message: String(localized: "左边列的是在命令行里用 Claude Code 的会话，内容只读。"))
        }
    }

    /// 子代理的记录回上一层；主对话在窄屏回列表，宽屏没有返回。
    private func back(for level: AgentTranscriptModel, showsBack: Bool) -> (() -> Void)? {
        if level.subagent != nil { return { history.closeSubagent() } }
        return showsBack ? { history.select(nil) } : nil
    }
}

// MARK: - 会话列表

private struct ClaudeHistoryList: View {
    let history: AgentHistoryModel

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            Rectangle().fill(M.divider).frame(height: 1)
            // 搜索结果盖在列表上，列表一直挂着：清空搜索后选中的会话、滚动位置都还在。
            ZStack {
                content
                    .opacity(history.search == nil ? 1 : 0)
                    .allowsHitTesting(history.search == nil)
                    .accessibilityHidden(history.search != nil)
                if let search = history.search {
                    ClaudeHistorySearchResults(history: history, search: search)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var searchBar: some View {
        @Bindable var history = history
        return VStack(alignment: .leading, spacing: 4) {
            MSearchField(text: $history.searchText, placeholder: AgentHistoryText.searchPlaceholder)
                .submitLabel(.search)
                .onSubmit { history.submitSearch() }
            if let problem = history.searchProblem {
                Text(AgentHistoryText.searchProblem(problem))
                    .font(M.sans(12.5)).foregroundStyle(M.warning)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var header: some View {
        HStack(spacing: 6) {
            MMenu {
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
                HStack(spacing: 4) {
                    Text(AgentHistoryText.scopeTitle(history.scope))
                        .font(M.sans(14, weight: .semibold)).foregroundStyle(M.text)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(M.text3)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: M.minTarget)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("切换项目"))
            Spacer(minLength: 0)
            Button { Task { await history.reload() } } label: {
                MIcon(name: "refresh", size: 15, color: M.text2)
                    .frame(width: M.minTarget, height: M.minTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MPressStyle())
            .accessibilityLabel(Text("刷新"))
        }
    }

    @ViewBuilder private var content: some View {
        switch history.phase {
        case .loading:
            ClaudeHistoryProgress(text: String(localized: "正在读取会话列表…"))
        case .empty:
            ClaudeHistoryState(icon: "clock", title: String(localized: "没有历史会话"),
                               message: AgentHistoryText.noHistoryDetail)
        case .failed(let message):
            ClaudeHistoryState(icon: "warn", title: String(localized: "无法读取会话列表"), message: message,
                               actionTitle: String(localized: "重试")) {
                Task { await history.reload() }
            }
        case .ready:
            let files = history.visibleFiles
            // 还在列目录，或者读过的那几份都不用列、后面还有没读的：接着等，别急着说「没有」。
            if files.isEmpty && (history.isListing || history.hasMore) {
                ClaudeHistoryProgress(text: String(localized: "正在读取会话列表…"))
            } else if files.isEmpty {
                ClaudeHistoryState(icon: "clock", title: String(localized: "没有命令行会话"),
                                   message: AgentHistoryText.emptyListDetail(hidden: history.hiddenCount))
            } else {
                list(files)
            }
        }
    }

    private func list(_ files: [AgentHistorySessionFile]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(files) { file in
                    Button { history.select(file) } label: {
                        ClaudeHistoryRow(history: history, file: file, metadata: history.metadata[file.path],
                                         showsProject: history.scope == .all,
                                         isSelected: history.selectedFile?.path == file.path)
                    }
                    .buttonStyle(MPressStyle())
                }
                if history.hasMore {
                    // 滚到底露出来就再读一批（同 Mac：行数变了它就是一个新视图，格子高、读完一批还露着时也会接着读）。
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在读取…").font(M.sans(12.5)).foregroundStyle(M.text4)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .id(files.count)
                    .onAppear { history.loadMore() }
                } else if history.hiddenCount > 0 {
                    Text(AgentHistoryText.hiddenNote(history.hiddenCount))
                        .font(M.sans(12.5)).foregroundStyle(M.text4)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                }
            }
            .padding(8)
        }
        .mKeepsScrollContentInSafeArea()
    }
}

// MARK: - 搜索结果

/// 同 Mac：按会话分组（最近的在前），每组下面是命中的摘要行；点一条打开那份对话并停在那里（窄屏进到对话，返回回到结果）。
private struct ClaudeHistorySearchResults: View {
    let history: AgentHistoryModel
    let search: AgentHistoryModel.Search

    var body: some View {
        if search.sessions.isEmpty, !search.isRunning {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    status
                    ForEach(search.sessions) { session in
                        group(session)
                    }
                    footer
                }
                .padding(8)
            }
            .mKeepsScrollContentInSafeArea()
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch search.phase {
        case .failed(let message):
            ClaudeHistoryState(icon: "warn", title: String(localized: "无法搜索"), message: message,
                               actionTitle: String(localized: "重试")) { history.submitSearch() }
        case .stopped:
            ClaudeHistoryState(icon: "search", title: AgentHistoryText.searchStopped(search),
                               message: AgentHistoryText.searchNoResultsDetail,
                               actionTitle: String(localized: "重试")) { history.submitSearch() }
        default:
            ClaudeHistoryState(icon: "search", title: AgentHistoryText.searchNoResults(search.query),
                               message: AgentHistoryText.searchNoResultsDetail)
        }
    }

    @ViewBuilder private var status: some View {
        if search.isRunning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(AgentHistoryText.searchProgress(search))
                    .font(M.sans(12.5)).foregroundStyle(M.text3)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button(AgentHistoryText.stopSearch) { history.stopSearch() }
                    .font(M.sans(13.5, weight: .medium))
                    .frame(minHeight: M.minTarget)
            }
            .padding(.horizontal, 6)
        }
    }

    @ViewBuilder private var footer: some View {
        if search.truncated {
            note(AgentHistoryText.searchTruncated(search.hitCount))
        } else if search.phase == .stopped {
            note(AgentHistoryText.searchStopped(search))
        } else if case .failed(let message) = search.phase {
            Text(verbatim: message).font(M.sans(12.5)).foregroundStyle(M.warning)
                .padding(.horizontal, 12)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(M.sans(12.5)).foregroundStyle(M.text4)
            .padding(.horizontal, 12).padding(.vertical, 4)
    }

    private func group(_ session: AgentHistorySearchSession) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 3) {
                Text(AgentHistoryText.sessionTitle(session.file, metadata: session.metadata))
                    .font(M.sans(15, weight: .semibold)).foregroundStyle(M.text)
                    .lineLimit(1)
                AgentSessionTimeText(history: history, file: session.file) { activity in
                    AgentHistoryText.searchSessionDetail(session, showsProject: history.scope == .all, activity: activity)
                }
                .font(M.sans(12.5)).foregroundStyle(M.text3)
                .lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.bottom, 2)
            ForEach(session.hits) { hit in
                Button { history.openHit(hit, in: session) } label: {
                    ClaudeHistorySearchHitRow(hit: hit, isSelected: isOpen(hit, in: session))
                }
                .buttonStyle(MPressStyle())
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

private struct ClaudeHistorySearchHitRow: View {
    let hit: AgentHistorySearchHit
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(AgentHistoryText.roleLabel(hit.role))
                    .font(M.sans(11.5, weight: .semibold)).foregroundStyle(M.text4)
                Text(AgentHistorySnippetText.attributed(hit.snippet, match: M.accent))
                    .font(M.sans(14)).foregroundStyle(M.text2)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MIcon(name: "chev", size: 12, color: M.text4, weight: .semibold)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(minHeight: M.minTarget)
        .background(RoundedRectangle(cornerRadius: MRadius.md, style: .continuous)
            .fill(isSelected ? M.rowSelected : Color.clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct ClaudeHistoryRow: View {
    let history: AgentHistoryModel
    let file: AgentHistorySessionFile
    let metadata: AgentHistorySessionMetadata?
    let showsProject: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(AgentHistoryText.sessionTitle(file, metadata: metadata))
                    .font(M.sans(15, weight: .medium)).foregroundStyle(M.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                AgentSessionTimeText(history: history, file: file) { activity in
                    AgentHistoryText.sessionSubtitle(file, metadata: metadata, showsProject: showsProject, activity: activity)
                }
                .font(M.sans(12.5)).foregroundStyle(M.text3)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MIcon(name: "chev", size: 12, color: M.text4, weight: .semibold)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: MRadius.md, style: .continuous)
            .fill(isSelected ? M.rowSelected : Color.clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - 对话

private struct ClaudeTranscriptView: View {
    let transcript: AgentTranscriptModel
    let metadata: AgentHistorySessionMetadata?
    let canResume: Bool
    /// 窄屏：回到列表；子代理的记录：回上一层。宽屏的主对话没有（列表一直在左边）。
    let onBack: (() -> Void)?
    let onResume: () -> Void
    let onOpenSubagent: (AgentSubagentLink) -> Void
    /// 从搜索命中处打开的：换回从末尾打开。
    var onJumpToLatest: () -> Void = {}

    @State private var expanded: Set<String> = []
    @State private var pendingAnchor: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(M.divider).frame(height: 1)
            if transcript.opensAtHit, !transcript.reachedEnd {
                hitBanner
                Rectangle().fill(M.divider).frame(height: 1)
            }
            messages
        }
    }

    /// 从命中处打开、后面还没读到末尾：顶上说一句，给「跳到最新」。同 Mac。
    private var hitBanner: some View {
        HStack(spacing: 8) {
            Text(AgentHistoryText.openedAtHit)
                .font(M.sans(12.5)).foregroundStyle(M.text2)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            MBtn(title: AgentHistoryText.jumpToLatest, icon: "download", kind: .secondary, height: 32,
                 action: onJumpToLatest)
                .fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(M.fillFaint)
    }

    /// 放得下就一行（返回 · 标题 · 拷贝 · 继续）；窄的格子（Duo 分屏 330pt、iPhone 竖屏）标题一行、按钮另起一行，
    /// 不然标题只剩两三个字。
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                backButton
                titleBlock
                actions
            }
            // 子代理的记录只有拷贝一个按钮，窄的格子里也放得下一行。
            .frame(minWidth: transcript.subagent == nil ? 460 : 0, minHeight: 52)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    backButton
                    titleBlock
                }
                .frame(minHeight: 48)
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    actions
                }
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder private var backButton: some View {
        if let onBack {
            Button(action: onBack) {
                MIcon(name: "back", size: 17, color: M.text2, weight: .semibold)
                    .frame(width: M.minTarget, height: M.minTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MPressStyle())
            .accessibilityLabel(Text(transcript.subagent == nil ? String(localized: "返回会话列表")
                                                                 : AgentHistoryText.backToParent))
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(transcript.subagent.map(AgentHistoryText.subagentTitle) ?? AgentHistoryText.transcriptTitle(metadata))
                    .font(M.sans(14.5, weight: .semibold)).foregroundStyle(M.text)
                    .lineLimit(1)
                if transcript.isUpdating { ClaudeUpdatingBadge() }
            }
            AgentTranscriptDetailText(transcript: transcript, metadata: metadata)
                .font(M.sans(11.5)).foregroundStyle(M.text3)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.leading, onBack == nil ? 14 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            MMenu {
                if transcript.subagent == nil {
                    Button { UIPasteboard.general.string = transcript.file.sessionID } label: {
                        Label("拷贝会话 ID", systemImage: "number")
                    }
                }
                Button { UIPasteboard.general.string = transcript.plainText } label: {
                    Label("拷贝已加载的对话", systemImage: "doc.on.doc")
                }
            } label: {
                MIcon(name: "copy", size: 15, color: M.text2)
                    .frame(width: 40, height: M.minTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("拷贝"))
            // 子代理的记录只读：不能单独继续。
            if transcript.subagent == nil {
                MBtn(title: String(localized: "继续这个会话"), icon: "run", kind: .tinted, height: 34,
                     disabled: !canResume, action: onResume)
                    .fixedSize()
                    .padding(.trailing, 10)
            } else {
                Spacer().frame(width: 4)
            }
        }
    }

    private var messages: some View {
        let items = transcript.items
        let runStarts = AgentTranscriptRuns.starts(items)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    top
                    ForEach(items) { item in
                        ClaudeTranscriptRow(item: item, showsRole: runStarts.contains(item.id), inSubagent: transcript.subagent != nil,
                                            subagent: subagentLink(item), onOpenSubagent: onOpenSubagent,
                                            isHighlighted: item.id == transcript.highlightedItemID,
                                            expanded: $expanded)
                            .id(item.id)
                    }
                    bottom
                    if items.isEmpty, transcript.reachedStart, transcript.errorMessage == nil {
                        Text("这个会话里没有可显示的消息。")
                            .font(M.sans(13)).foregroundStyle(M.text3)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                    // 跟到底时滚到这里。底部留白由它和上面的间距承担（同原来的 14pt），锚点下面不再垫 padding。
                    Color.clear.frame(height: 2).id(Self.bottomID)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
            }
            .mKeepsScrollContentInSafeArea()
            // 打开时停在最后一条（从末尾读起）；内容不满一屏时从顶上排起——只写 `.bottom` 的话短对话会贴着底、上面空一大片。
            .defaultScrollAnchor(.bottom, for: .initialOffset)
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
                    ClaudeNewMessagesPill {
                        transcript.setFollowsTail(true)
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    }
                    .padding(.bottom, 12)
                    .transition(.opacity)
                }
            }
        }
    }

    private static let bottomID = "claude-transcript-bottom"

    @ViewBuilder private var top: some View {
        if let error = transcript.errorMessage {
            VStack(spacing: 8) {
                Text(verbatim: error).font(M.sans(13)).foregroundStyle(M.warning)
                    .multilineTextAlignment(.center)
                MBtn(title: String(localized: "重试"), icon: "refresh", kind: .secondary, height: 34) { loadEarlier() }
                    .fixedSize()
            }
            .frame(maxWidth: .infinity)
        } else if transcript.isLoading {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8)
        } else if !transcript.reachedStart {
            MBtn(title: String(localized: "加载更早的消息"), icon: "upload", kind: .secondary, height: 34) { loadEarlier() }
                .fixedSize()
                .frame(maxWidth: .infinity)
        }
    }

    /// 从命中处打开的：后面还有，「加载更晚的消息」（滚到底也会读，见 `AgentTranscriptTailFollow`）。
    @ViewBuilder private var bottom: some View {
        if !transcript.reachedEnd {
            VStack(spacing: 8) {
                if let error = transcript.laterErrorMessage {
                    Text(verbatim: error).font(M.sans(13)).foregroundStyle(M.warning)
                        .multilineTextAlignment(.center)
                }
                if transcript.isLoadingLater {
                    ProgressView().padding(.vertical, 8)
                } else {
                    MBtn(title: AgentHistoryText.loadLater, icon: "download", kind: .secondary, height: 34) {
                        Task { await transcript.loadLater() }
                    }
                    .fixedSize()
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func loadEarlier() {
        pendingAnchor = transcript.firstItemID
        // 要往前看：不再跟着末尾走。
        transcript.setFollowsTail(false)
        Task { await transcript.loadEarlier() }
    }

    private func subagentLink(_ item: AgentTranscriptItem) -> AgentSubagentLink? {
        guard case .toolCall(let call) = item.kind else { return nil }
        return transcript.subagentLink(for: call)
    }
}

private struct ClaudeTranscriptRow: View {
    let item: AgentTranscriptItem
    let showsRole: Bool
    /// 子代理的记录：「用户」那一侧标成「任务」。
    var inSubagent = false
    /// 这次调用派出的子代理（找得到记录的才有）。
    let subagent: AgentSubagentLink?
    let onOpenSubagent: (AgentSubagentLink) -> Void
    /// 搜索命中的那一条：整条带底色和左边一道线（画在边界外，不挤动排版）。同 Mac。
    var isHighlighted = false
    @Binding var expanded: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if showsRole {
                Text(AgentHistoryText.roleLabel(item.role, inSubagent: inSubagent))
                    .font(M.sans(12, weight: .semibold)).foregroundStyle(M.text3)
                    .padding(.top, 6)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: MRadius.md, style: .continuous)
                    .fill(M.accent.opacity(0.12))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5).fill(M.accent).frame(width: 3)
                    }
                    .padding(.horizontal, -8)
                    .padding(.vertical, -5)
            }
        }
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .userText(let text):
            MStreamingMarkdown(text: text, isStreaming: false)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: MRadius.md, style: .continuous).fill(M.fillFaint))
                .modifier(CopyMenu(text: item.plainText))
        case .assistantText(let text):
            MStreamingMarkdown(text: text, isStreaming: false)
                .textSelection(.enabled)
        case .command(let command):
            Text(verbatim: command)
                .font(M.mono(13, weight: .medium)).foregroundStyle(M.text)
                .textSelection(.enabled)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: MRadius.sm, style: .continuous).fill(M.fillFaint))
        case .commandOutput(let output):
            ClaudeClippedBlock(id: item.id, label: String(localized: "输出"), text: output, isError: false,
                               expanded: $expanded)
        case .notice(let text):
            Label { Text(verbatim: text) } icon: { Image(systemName: "bell") }
                .font(M.sans(12.5)).foregroundStyle(M.text3)
                .lineLimit(3)
        case .thinking(let text):
            DisclosureGroup(isExpanded: binding("\(item.id).thinking")) {
                Text(verbatim: text.text + (text.isClipped ? "\n…" : ""))
                    .font(M.sans(13)).italic().foregroundStyle(M.text3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } label: {
                Label(String(localized: "思考"), systemImage: "brain")
                    .font(M.sans(12.5, weight: .medium)).foregroundStyle(M.text3)
            }
            .tint(M.text3)
        case .toolCall(let call):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 11)).foregroundStyle(M.text3)
                    Text(verbatim: call.name)
                        .font(M.mono(12.5, weight: .semibold)).foregroundStyle(M.text2)
                    Text(verbatim: call.summary)
                        .font(M.mono(12.5)).foregroundStyle(M.text3)
                        .lineLimit(1).truncationMode(.tail)
                }
                if let subagent {
                    ClaudeSubagentEntry(link: subagent) { onOpenSubagent(subagent) }
                        .padding(.leading, 18)
                }
                if let result = call.result {
                    ClaudeClippedBlock(id: item.id, label: AgentHistoryText.resultLabel(result), text: result.content,
                                       isError: result.isError, expanded: $expanded)
                        .padding(.leading, 18)
                }
            }
        case .toolResult(let result):
            ClaudeClippedBlock(id: item.id, label: AgentHistoryText.resultLabel(result), text: result.content,
                               isError: result.isError, expanded: $expanded)
        case .image:
            Label(String(localized: "图片（不显示）"), systemImage: "photo")
                .font(M.sans(12.5)).foregroundStyle(M.text3)
        case .compactSummary(let summary):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Rectangle().fill(M.divider).frame(height: 1)
                    Text("上下文已压缩")
                        .font(M.sans(12, weight: .medium)).foregroundStyle(M.text3)
                        .fixedSize()
                    Rectangle().fill(M.divider).frame(height: 1)
                }
                ClaudeClippedBlock(id: item.id, label: String(localized: "压缩摘要"), text: summary, isError: false,
                                   expanded: $expanded)
            }
            .padding(.vertical, 6)
        case .oversized(let bytes):
            Label(AgentHistoryText.oversized(bytes), systemImage: "exclamationmark.circle")
                .font(M.sans(12.5)).foregroundStyle(M.text3)
        }
    }

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(key) },
                set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } })
    }
}

/// 派子代理的调用下面的入口：点进去看那个子代理自己的记录。同 Mac。
private struct ClaudeSubagentEntry: View {
    let link: AgentSubagentLink
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(M.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AgentHistoryText.subagentEntry)
                        .font(M.sans(13.5, weight: .medium)).foregroundStyle(M.accent)
                    let detail = AgentHistoryText.subagentEntryDetail(link)
                    if !detail.isEmpty {
                        Text(verbatim: detail)
                            .font(M.sans(11.5)).foregroundStyle(M.text3)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                MIcon(name: "chev", size: 11, color: M.text4, weight: .semibold)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(minHeight: M.minTarget)
            .background(RoundedRectangle(cornerRadius: MRadius.md, style: .continuous).fill(M.fillFaint))
            .contentShape(Rectangle())
        }
        .buttonStyle(MPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// 标题旁的「正在更新」：这份对话最近还在变（会话开着）。同 Mac。
private struct ClaudeUpdatingBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(M.success).frame(width: 6, height: 6)
            Text(AgentHistoryText.updating)
                .font(M.sans(11, weight: .medium)).foregroundStyle(M.success)
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(M.success.opacity(0.12)))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// 往上翻着时末尾来了新内容：底部的「有新消息」，点了跳到底。同 Mac。
private struct ClaudeNewMessagesPill: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down").font(.system(size: 12, weight: .semibold))
                Text(AgentHistoryText.newMessages).font(M.sans(13.5, weight: .medium))
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(Capsule().fill(M.accent))
            .shadow(color: .black.opacity(0.18), radius: 5, y: 1)
            .contentShape(Capsule())
        }
        .buttonStyle(MPressStyle())
    }
}

/// 长按拷贝一段消息的文字（文字选择在手机上不好拖到整段）。
private struct CopyMenu: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        content.mContextMenu(preview: RoundedRectangle(cornerRadius: MRadius.md, style: .continuous)) {
            Button { UIPasteboard.general.string = text } label: {
                Label("拷贝文字", systemImage: "doc.on.doc")
            }
        }
    }
}

/// 折叠的长文字（工具结果、命令输出、压缩摘要）：默认收起；展开先给前几行，再点才给全部（仍有上限）。同 Mac。
private struct ClaudeClippedBlock: View {
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
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(verbatim: showsAll ? text.text : preview)
                        .font(M.mono(12)).foregroundStyle(isError ? M.danger : M.text2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(8)
                }
                .background(RoundedRectangle(cornerRadius: MRadius.sm, style: .continuous).fill(M.fillFaint))
                if !showsAll, preview.count < text.text.count {
                    Button(AgentHistoryText.showAll(text.text.count)) { expanded.insert(fullKey) }
                        .font(M.sans(12.5))
                }
                if text.isClipped, showsAll || preview.count >= text.text.count {
                    Text(AgentHistoryText.clippedNote(text))
                        .font(M.sans(12)).foregroundStyle(M.text4)
                }
            }
            .padding(.top, 4)
        } label: {
            Text(label)
                .font(M.sans(12.5, weight: .medium)).foregroundStyle(isError ? M.danger : M.text3)
        }
        .tint(M.text3)
    }

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(key) },
                set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } })
    }
}

// MARK: - 状态

private struct ClaudeHistoryProgress: View {
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(text).font(M.sans(13.5)).foregroundStyle(M.text3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ClaudeHistoryState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            MIcon(name: icon, size: 30, color: M.text4, weight: .light)
                .frame(width: 64, height: 64)
                .background(M.fillFaint)
                .clipShape(Circle())
            Text(title).font(M.sans(16, weight: .semibold)).foregroundStyle(M.text)
            Text(message).font(M.sans(13.5)).foregroundStyle(M.text3)
                .multilineTextAlignment(.center).lineSpacing(2)
                .frame(maxWidth: 320)
            if let actionTitle, let action {
                MBtn(title: actionTitle, icon: "refresh", kind: .tinted, height: 40, action: action)
                    .fixedSize()
                    .padding(.top, 4)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
