import Foundation
import Observation

/// 历史会话窗口的状态：会话列表（当前项目或全部项目）、选中的会话、它的对话。两端共用，平台只画。
///
/// 列表里每一行的标题与来源要读文件末尾一小块，**读到了才知道这一行要不要列**（桌面版起的不列）。所以列表只显示
/// 从头数起已经读过的那一段，一批一批往后读（`loadMore`，列表滚到底时由界面调）：行只会往后加，不会先占位再消失——
/// 慢的主机上、藏起来的比列出来的多时，占位行一批批消失很难看。读过的按（路径、大小、修改时间）缓存在数据源里。
///
/// 对话内容只在内存里，关窗口就没了：不落盘、不进 iCloud、不进偏好设置。
@MainActor
@Observable
final class AgentHistoryModel {
    enum Phase: Equatable {
        case loading
        /// 这台主机上没有记录目录。
        case empty
        case failed(String)
        case ready
    }

    enum Scope: Equatable {
        case project(AgentHistoryProject)
        case all
    }

    let source: any AgentHistorySource
    /// 打开时终端所在的目录；拿不到为 nil（退到全部项目）。
    let preferredDirectory: String?

    private(set) var phase: Phase = .loading
    private(set) var projects: [AgentHistoryProject] = []
    /// 终端当前目录对上的项目。
    private(set) var currentProject: AgentHistoryProject?
    private(set) var scope: Scope = .all
    private(set) var isListing = false
    /// 范围里的全部记录文件，新的在前（还没读过信息的也在里面）。
    private(set) var files: [AgentHistorySessionFile] = []
    private(set) var metadata: [String: AgentHistorySessionMetadata] = [:]
    /// `files` 从头数起，信息已经读到的有几份。列表只显示这一段。
    private(set) var resolvedCount = 0
    private(set) var selectedFile: AgentHistorySessionFile?
    /// 选中会话的主对话。
    private(set) var transcript: AgentTranscriptModel?
    /// 从主对话一层层点进去的子代理记录，最里面的在最后。
    private(set) var subagentStack: [AgentTranscriptModel] = []

    /// 同时读几份记录的末尾。
    @ObservationIgnored private let metadataConcurrency = 4
    /// 排在已读那一段后面、提前读的份数。
    @ObservationIgnored private let lookahead = 12
    /// 一批要让列表多出几行（窗口再高一屏也放不下这么多）。
    @ObservationIgnored private let pageRows = 24
    /// 读到列表有这么多行为止。
    @ObservationIgnored private var targetRows = 0
    /// 每份信息是照哪个（路径、大小、修改时间）读的：刷新后文件变了就重读。
    @ObservationIgnored private var metadataKeys: [String: AgentHistorySessionFile.CacheKey] = [:]
    @ObservationIgnored private var queued: [AgentHistorySessionFile] = []
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var failed: Set<String> = []
    @ObservationIgnored private var listGeneration = 0

    init(source: any AgentHistorySource, preferredDirectory: String?) {
        self.source = source
        self.preferredDirectory = preferredDirectory
    }

    /// 列表里显示的：已经读过的那一段里要列出来的。
    var visibleFiles: [AgentHistorySessionFile] {
        files.prefix(resolvedCount).filter { metadata[$0.path]?.isListed ?? true }
    }

    /// 读过信息、不列出来的（桌面版等）有几个。
    var hiddenCount: Int {
        files.reduce(0) { $0 + ((metadata[$1.path]?.isListed == false) ? 1 : 0) }
    }

    func start() async {
        guard phase == .loading, projects.isEmpty else { return }
        await reload()
    }

    /// 重新列项目与会话。读过的信息按缓存键复用（文件没变就不再读）。
    func reload() async {
        phase = .loading
        do {
            let found = try await source.projects()
            projects = found
            guard !found.isEmpty else {
                phase = .empty
                files = []
                return
            }
            if let preferredDirectory {
                currentProject = await source.project(containing: preferredDirectory, among: found)
            }
            let nextScope: Scope
            switch scope {
            case .project(let old):
                nextScope = found.first(where: { $0.id == old.id }).map { project in
                    var project = project
                    project.directory = old.directory
                    return .project(project)
                } ?? currentProject.map(Scope.project) ?? .all
            case .all:
                nextScope = (files.isEmpty ? currentProject.map(Scope.project) : nil) ?? .all
            }
            phase = .ready
            await setScope(nextScope)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// 切到某个项目或全部项目。
    func setScope(_ newScope: Scope) async {
        scope = newScope
        listGeneration += 1
        let generation = listGeneration
        queued.removeAll()
        isListing = true
        defer { if generation == listGeneration { isListing = false } }
        let listed: [AgentHistorySessionFile]
        switch newScope {
        case .project(let project):
            do {
                listed = try await source.sessions(in: project)
            } catch {
                guard generation == listGeneration else { return }
                phase = .failed(error.localizedDescription)
                return
            }
        case .all:
            listed = await source.allSessions(in: projects)
        }
        guard generation == listGeneration else { return }
        files = listed
        failed.removeAll()
        // 文件变过的（大小或修改时间不一样了）信息作废，重读。
        for file in listed where metadataKeys[file.path] != nil && metadataKeys[file.path] != file.cacheKey {
            metadata[file.path] = nil
            metadataKeys[file.path] = nil
        }
        resolvedCount = 0
        advanceResolved()
        targetRows = pageRows
        fill()
        if let selectedFile, !listed.contains(where: { $0.path == selectedFile.path }) {
            select(nil)
        }
    }

    /// 后面还有没读的记录（列表底下画「正在读取」）。
    var hasMore: Bool { resolvedCount < files.count }

    /// 再往后读一批：读到列表多出一批行，或者读完为止。列表滚到底时调。
    ///
    /// 上一批还没读够时不起作用：行是一份一份冒出来的，列表还短的时候底下那行一直露着、每多一行就又调一次，
    /// 不挡的话目标跟着行数往上涨，一路读下去停不住。
    func loadMore() {
        let shown = visibleFiles.count
        guard hasMore, shown >= targetRows else { return }
        targetRows = shown + pageRows
        fill()
    }

    private func advanceResolved() {
        while resolvedCount < files.count, metadata[files[resolvedCount].path] != nil {
            resolvedCount += 1
        }
    }

    /// 行数还没到目标就接着读：已读那一段后面的 `lookahead` 份排上队。
    private func fill() {
        guard hasMore, visibleFiles.count < targetRows else { return }
        for candidate in files[resolvedCount..<min(files.count, resolvedCount + lookahead)] {
            enqueue(candidate)
        }
        pump()
    }

    private func enqueue(_ file: AgentHistorySessionFile) {
        guard metadata[file.path] == nil, !inFlight.contains(file.path), !failed.contains(file.path),
              !queued.contains(where: { $0.path == file.path }) else { return }
        queued.append(file)
    }

    private func pump() {
        while inFlight.count < metadataConcurrency, !queued.isEmpty {
            let file = queued.removeFirst()
            inFlight.insert(file.path)
            Task { [source] in
                let result = try? await source.metadata(for: file)
                self.finished(file, result)
            }
        }
    }

    private func finished(_ file: AgentHistorySessionFile, _ result: AgentHistorySessionMetadata?) {
        inFlight.remove(file.path)
        // 读的时候文件又变了（中途刷新过）：这份信息是旧的，丢掉重读。
        if let current = files.first(where: { $0.path == file.path }), current.cacheKey != file.cacheKey {
            pump()
            fill()
            return
        }
        metadataKeys[file.path] = file.cacheKey
        if let result {
            metadata[file.path] = result
        } else {
            // 读不了的（文件刚被删、没权限）照样列着，标题显示文件名。不反复重试。
            failed.insert(file.path)
            metadata[file.path] = AgentHistorySessionMetadata(title: nil, isListed: true, lastDirectory: nil,
                                                              resumeDirectory: file.project.directory,
                                                              gitBranch: nil, lastActivity: nil)
        }
        advanceResolved()
        pump()
        fill()
    }

    func select(_ file: AgentHistorySessionFile?) {
        guard file?.path != selectedFile?.path else { return }
        selectedFile = file
        subagentStack = []
        guard let file else {
            transcript = nil
            return
        }
        let model = AgentTranscriptModel(file: file, pager: source.transcript(for: file), source: source,
                                         target: .session(file))
        transcript = model
        Task { await model.loadEarlier() }
    }

    /// 正在显示的那一层：点进了子代理就是最里面那份，否则是主对话。
    var displayedTranscript: AgentTranscriptModel? { subagentStack.last ?? transcript }

    /// 从正在显示的那一层点进它派出的一个子代理。只读，没有「继续这个会话」。
    func openSubagent(_ link: AgentSubagentLink) {
        guard let parent = displayedTranscript else { return }
        let model = AgentTranscriptModel(file: parent.file, pager: source.subagentTranscript(for: link.file),
                                         source: source, target: .subagent(link.file), subagent: link)
        subagentStack.append(model)
        Task { await model.loadEarlier() }
    }

    /// 返回上一层（最里面那份子代理记录关掉，内容随之丢掉）。
    func closeSubagent() {
        guard !subagentStack.isEmpty else { return }
        subagentStack.removeLast()
    }

    /// 在终端里继续选中的会话要敲的命令。目录用记录里对得上项目的那个，对不上用终端当前目录对上的项目目录。
    func resumeCommand(for file: AgentHistorySessionFile) -> (command: String, directory: String)? {
        let info = metadata[file.path]
        let directory = info?.resumeDirectory ?? file.project.directory
            ?? (currentProject?.id == file.project.id ? currentProject?.directory : nil)
        guard let directory, let command = source.resumeCommand(sessionID: file.sessionID, directory: directory) else {
            return nil
        }
        return (command, directory)
    }
}

/// 对话里一次派子代理的调用对上的那份记录。
nonisolated struct AgentSubagentLink: Equatable, Sendable {
    let file: AgentSubagentFile
    var agentType: String?
    var description: String?
}

/// 一份对话：从末尾开始，往上翻一页读一页。主对话与子代理的记录都是它（`subagent` 不为 nil 的是后者）。
///
/// 派子代理的调用要对上它的记录（`subagentLinks`）：读到了派子代理的调用才去列 `subagents(of:)`（懒，列表阶段不碰）；
/// 先按调用结果里报的子代理 ID 对，对不上的（结果还没读到、太大没解析、老版本没报）再读子代理附带的信息文件，
/// 一次最多读 `infoConcurrency` 份、对上了就停，不会一口气把几百份都读了。对不上的不给入口，不报错。
@MainActor
@Observable
final class AgentTranscriptModel {
    let file: AgentHistorySessionFile
    /// 这是哪一份记录。
    let target: AgentTranscriptTarget
    /// 子代理的记录：是从哪次调用点进来的。主对话为 nil。
    let subagent: AgentSubagentLink?
    private(set) var items: [AgentTranscriptItem] = []
    private(set) var reachedStart = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// 每次往前加了一页就 +1，界面据此把滚动位置留在原来那条上。
    private(set) var prependGeneration = 0
    /// 派子代理的调用（按 `toolUseID`）→ 它的记录。对不上的没有。
    private(set) var subagentLinks: [String: AgentSubagentLink] = [:]

    /// 同时读几份子代理的信息文件。
    nonisolated static let infoConcurrency = 4

    @ObservationIgnored private let pager: any AgentTranscriptPaging
    @ObservationIgnored private let source: (any AgentHistorySource)?
    /// 列过的子代理记录；nil = 还没列过。
    @ObservationIgnored private var subagentIndex: [AgentSubagentFile]?
    /// 读过信息文件的（按路径），和读到的「调用 → 记录」。
    @ObservationIgnored private var infoRead: Set<String> = []
    @ObservationIgnored private var fileByToolUse: [String: (file: AgentSubagentFile, info: AgentSubagentInfo)] = [:]
    @ObservationIgnored private var isResolving = false
    @ObservationIgnored private var resolvesAgain = false

    init(file: AgentHistorySessionFile, pager: any AgentTranscriptPaging, source: (any AgentHistorySource)? = nil,
         target: AgentTranscriptTarget? = nil, subagent: AgentSubagentLink? = nil) {
        self.file = file
        self.pager = pager
        self.source = source
        self.target = target ?? .session(file)
        self.subagent = subagent
    }

    /// 在一份历史里唯一：界面拿它当视图身份（主对话与子代理一层一层的不能混）。
    var path: String { target.path }

    /// 已经加载的部分里最早的一条（往前加一页后滚回它）。
    var firstItemID: String? { items.first?.id }

    func loadEarlier() async {
        guard !isLoading, !reachedStart else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let page = try await pager.loadPrevious()
            items = AgentTranscriptAssembler.attachResults(page.items + items)
            reachedStart = page.reachedStart
            prependGeneration += 1
            resolveSubagents()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 已加载部分的纯文字（拷贝对话用）。
    var plainText: String {
        items.map(\.plainText).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// 这次调用派出的子代理的记录；没派、或者找不到记录为 nil。
    func subagentLink(for call: AgentToolCall) -> AgentSubagentLink? {
        guard call.spawn != nil, let id = call.toolUseID else { return nil }
        return subagentLinks[id]
    }

    // MARK: - 子代理

    /// 已加载的条目里还没对上记录的派子代理调用。
    private var pendingSpawns: [(toolUseID: String, agentID: String?, request: AgentSpawnRequest)] {
        items.compactMap { item in
            guard case .toolCall(let call) = item.kind, let request = call.spawn, let id = call.toolUseID,
                  subagentLinks[id] == nil else { return nil }
            return (id, call.result?.spawnedAgentID, request)
        }
    }

    /// 给新读到的派子代理调用找记录。正在找时再叫一次就等这一轮完了再来一轮。
    func resolveSubagents() {
        guard source != nil else { return }
        guard !isResolving else {
            resolvesAgain = true
            return
        }
        guard !pendingSpawns.isEmpty else { return }
        isResolving = true
        Task {
            repeat {
                resolvesAgain = false
                await resolveOnce()
            } while resolvesAgain
            isResolving = false
        }
    }

    private func resolveOnce() async {
        guard let source, !pendingSpawns.isEmpty else { return }
        if subagentIndex == nil {
            guard let listed = try? await source.subagents(of: target) else { return }
            subagentIndex = listed
        }
        guard let index = subagentIndex, !index.isEmpty else { return }
        let byAgentID = Dictionary(index.map { ($0.agentID, $0) }, uniquingKeysWith: { first, _ in first })
        var unresolved: [(toolUseID: String, request: AgentSpawnRequest)] = []
        for spawn in pendingSpawns {
            if let agentID = spawn.agentID, let file = byAgentID[agentID] {
                link(spawn.toolUseID, file: file, request: spawn.request, info: nil)
            } else if let known = fileByToolUse[spawn.toolUseID] {
                link(spawn.toolUseID, file: known.file, request: spawn.request, info: known.info)
            } else {
                unresolved.append((spawn.toolUseID, spawn.request))
            }
        }
        guard !unresolved.isEmpty else { return }

        // 靠信息文件对：新的先读（还开着的会话里，没报结果的多半是刚派出去的那几个），一批一批读，对上了就停。
        let linked = Set(subagentLinks.values.map(\.file.path))
        var candidates = index.filter { $0.hasInfo && !infoRead.contains($0.path) && !linked.contains($0.path) }
        var waiting = Dictionary(unresolved.map { ($0.toolUseID, $0.request) }, uniquingKeysWith: { first, _ in first })
        while !waiting.isEmpty, !candidates.isEmpty {
            let batch = Array(candidates.prefix(Self.infoConcurrency))
            candidates.removeFirst(batch.count)
            let infos = await withTaskGroup(of: (AgentSubagentFile, AgentSubagentInfo?).self) { group in
                for file in batch { group.addTask { (file, await source.info(of: file)) } }
                var results: [(AgentSubagentFile, AgentSubagentInfo?)] = []
                for await result in group { results.append(result) }
                return results
            }
            for (file, info) in infos {
                infoRead.insert(file.path)
                guard let info, let toolUseID = info.toolUseID else { continue }
                fileByToolUse[toolUseID] = (file, info)
                if let request = waiting.removeValue(forKey: toolUseID) {
                    link(toolUseID, file: file, request: request, info: info)
                }
            }
        }
    }

    private func link(_ toolUseID: String, file: AgentSubagentFile, request: AgentSpawnRequest, info: AgentSubagentInfo?) {
        subagentLinks[toolUseID] = AgentSubagentLink(file: file, agentType: request.agentType ?? info?.agentType,
                                                     description: request.description ?? info?.description)
    }
}
