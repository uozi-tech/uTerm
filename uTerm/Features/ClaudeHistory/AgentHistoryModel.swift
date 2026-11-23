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
    /// 一开始落在终端当前目录对上的项目里（iOS 的历史标签）；false 一直列全部项目（Mac 的列表按项目分组，用不着先挑一个）。
    let followsCurrentProject: Bool

    private(set) var phase: Phase = .loading
    private(set) var projects: [AgentHistoryProject] = []
    /// 终端当前目录对上的项目。
    private(set) var currentProject: AgentHistoryProject?
    private(set) var scope: Scope = .all
    private(set) var isListing = false
    /// 范围里的记录文件，新的在前（还没读过信息的也在里面），已经按「只看哪几种工具」筛过。
    private(set) var files: [AgentHistorySessionFile] = []
    /// 范围里的全部记录文件（没筛过）。
    @ObservationIgnored private var listedFiles: [AgentHistorySessionFile] = []
    /// 这台主机上有记录的工具，按 `AgentHistoryTool.allCases` 的先后。只有一种时界面不出工具标记、「工具」分组和「显示」。
    private(set) var availableTools: [AgentHistoryTool] = []
    /// 「显示」里勾的工具；nil = 全部。实际生效的见 `effectiveTools`。
    private(set) var shownTools: Set<AgentHistoryTool>?
    /// 上一次列项目时读不出来的工具 → 原因（几种工具合在一起时，一种失败不拖累别的）。
    private(set) var toolFailures: [AgentHistoryTool: String] = [:]
    /// 折起来的组（`AgentHistoryGroup.id`）。只在内存里。
    var collapsedGroups: Set<String> = []
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
    /// 看过的会话里读到的最新时间（按路径）：切到别的会话之后，列表那一行还用它。重新列一次就清掉。
    private var seenActivity: [String: Date] = [:]
    /// 打开着的对话多久看一次文件末尾（测试换成不真睡的）。
    @ObservationIgnored let followTiming: AgentTranscriptFollowTiming
    /// 平台说对话现在看不看得见（`setTranscriptVisible`）。
    @ObservationIgnored private var transcriptVisible = false

    /// 搜索的上限（测试换成小的）。
    @ObservationIgnored let searchLimits: AgentHistorySearchLimits
    /// 这台主机能不能跑命令（标成只许 SFTP 的主机不能）：不能就不搜，直接说明。
    let allowsSearch: Bool

    isolated deinit {
        searchTask?.cancel()
    }

    init(source: any AgentHistorySource, preferredDirectory: String?,
         followTiming: AgentTranscriptFollowTiming = .standard,
         searchLimits: AgentHistorySearchLimits = .standard, allowsSearch: Bool = true,
         followsCurrentProject: Bool = true) {
        self.source = source
        self.preferredDirectory = preferredDirectory
        self.followsCurrentProject = followsCurrentProject
        self.followTiming = followTiming
        self.searchLimits = searchLimits
        self.allowsSearch = allowsSearch
    }

    /// 列表里显示的：已经读过的那一段里要列出来的。
    var visibleFiles: [AgentHistorySessionFile] {
        files.prefix(resolvedCount).filter { metadata[$0.path]?.isListed ?? true }
    }

    /// 读过信息、不列出来的（桌面版等）有几个。
    var hiddenCount: Int {
        files.reduce(0) { $0 + ((metadata[$1.path]?.isListed == false) ? 1 : 0) }
    }

    // MARK: - 几种工具

    /// 合在一起的数据源拆开（不是合成的就是它自己）。
    var parts: [any AgentHistorySource] {
        (source as? AgentHistoryCompositeSource)?.sources ?? [source]
    }

    /// 建了数据源的工具（不管这台主机上有没有记录）。
    var configuredTools: [AgentHistoryTool] { parts.map(\.tool) }

    /// 某种工具的数据源；没有为 nil。
    func source(for tool: AgentHistoryTool) -> (any AgentHistorySource)? {
        parts.first { $0.tool == tool }
    }

    var isMultiTool: Bool { availableTools.count > 1 }

    /// 实际生效的「只看哪几种」（见 `AgentHistoryListing.effectiveTools`）。
    var effectiveTools: Set<AgentHistoryTool> {
        AgentHistoryListing.effectiveTools(shown: shownTools, available: availableTools)
    }

    /// 改「显示」里勾的工具：列表就地重筛（读过的信息都在，不重读），选中的会话被筛掉了就取消选中，有搜索就重搜。
    func setShownTools(_ tools: Set<AgentHistoryTool>?) {
        guard tools != shownTools else { return }
        shownTools = tools
        applyToolFilter()
        if let selectedFile, !files.contains(where: { $0.path == selectedFile.path }) { select(nil) }
        if let query = search?.query, !isListing, phase == .ready { startSearch(query) }
    }

    private func passesToolFilter(_ file: AgentHistorySessionFile) -> Bool {
        !isMultiTool || effectiveTools.contains(file.tool)
    }

    private func applyToolFilter() {
        let filtered = listedFiles.filter(passesToolFilter)
        guard filtered.map(\.path) != files.map(\.path) else { return }
        files = filtered
        queued.removeAll()
        resolvedCount = 0
        advanceResolved()
        targetRows = max(targetRows, pageRows)
        fill()
    }

    /// 搜索时不参与的工具：范围里有它的会话，但它的记录没法在主机上搜。
    var searchExcludedTools: [AgentHistoryTool] {
        let present = Set(files.map(\.tool))
        return AgentHistoryTool.allCases.filter { tool in
            present.contains(tool) && !(source(for: tool)?.supportsSearch ?? false)
        }
    }

    /// 终端当前目录落在哪个项目里：几种工具各问各的数据源（Claude Code 要按目录名换算），取离得最近的那个。
    private func findProject(containing directory: String, among found: [AgentHistoryProject]) async -> AgentHistoryProject? {
        var best: AgentHistoryProject?
        for part in parts {
            let mine = found.filter { $0.tool == part.tool }
            guard !mine.isEmpty, let hit = await part.project(containing: directory, among: mine) else { continue }
            if (hit.directory?.count ?? 0) > (best?.directory?.count ?? -1) { best = hit }
        }
        return best
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
            toolFailures = await (source as? AgentHistoryCompositeSource)?.failures ?? [:]
            let present = Set(found.map(\.tool))
            availableTools = AgentHistoryTool.allCases.filter(present.contains)
            guard !found.isEmpty else {
                phase = .empty
                files = []
                listedFiles = []
                if let query = search?.query { startSearch(query) }
                return
            }
            if let preferredDirectory {
                currentProject = await findProject(containing: preferredDirectory, among: found)
            }
            let nextScope: Scope
            switch scope {
            case .project(let old):
                nextScope = found.first(where: { $0.id == old.id && $0.tool == old.tool }).map { project in
                    var project = project
                    project.directory = old.directory
                    return .project(project)
                } ?? currentProject.map(Scope.project) ?? .all
            case .all:
                nextScope = (files.isEmpty && followsCurrentProject ? currentProject.map(Scope.project) : nil) ?? .all
            }
            phase = .ready
            await setScope(nextScope)
        } catch {
            phase = .failed(error.localizedDescription)
            failWaitingSearch()
        }
    }

    /// 等着列表列完的搜索：列不出来就跟着失败。
    private func failWaitingSearch() {
        if search?.phase == .waiting { search?.phase = .failed(AgentHistoryText.searchListFailed) }
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
                failWaitingSearch()
                return
            }
        case .all:
            listed = await source.allSessions(in: projects)
        }
        guard generation == listGeneration else { return }
        listedFiles = listed
        files = listed.filter(passesToolFilter)
        // 列表里的修改时间是刚列的了，之前记的不再需要（正开着的那份照样从对话里取）。
        seenActivity.removeAll()
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
        if let selectedFile, !files.contains(where: { $0.path == selectedFile.path }) {
            select(nil)
        }
        // 范围跟着项目选择器走：有搜索就在新的范围里重搜（列完了，不用等上面的 `defer`）。
        isListing = false
        if let query = search?.query { startSearch(query) }
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
        open(file, at: nil)
    }

    /// 列表里这个会话那一行该用的更新的时间：正开着的取对话已加载内容里最新那条的（实时跟随时跟着变），看过又切走的
    /// 取切走时记下的。不比列表里记的修改时间新就是 nil（那一行照旧用修改时间）。
    func liveActivity(of file: AgentHistorySessionFile) -> Date? {
        var latest = seenActivity[file.path]
        if selectedFile?.path == file.path, let open = transcript?.lastActivity, latest.map({ open > $0 }) ?? true {
            latest = open
        }
        guard let latest, latest > file.modifiedAt else { return nil }
        return latest
    }

    /// 要换掉正开着的对话了：记下在它里面读到的最新时间。
    private func rememberActivity() {
        guard let transcript, let seen = transcript.lastActivity else { return }
        let path = transcript.file.path
        seenActivity[path] = max(seen, seenActivity[path] ?? seen)
    }

    /// 打开一份对话：`hit` 为 nil 从末尾打开，否则从命中那一行打开并高亮它。
    private func open(_ file: AgentHistorySessionFile?, at hit: AgentHistorySearchHit?) {
        rememberActivity()
        selectedFile = file
        stopFollowingAll()
        subagentStack = []
        guard let file else {
            transcript = nil
            return
        }
        let pager = hit.map { source.transcript(for: file, around: $0.anchor) } ?? source.transcript(for: file)
        let model = AgentTranscriptModel(file: file, pager: pager, source: source, target: .session(file),
                                         followTiming: followTiming, opensAt: hit?.itemID)
        transcript = model
        updateFollowing()
        Task { await model.loadEarlier() }
    }

    /// 点了一条命中：打开那份对话并停在那一条上。已经开着、那一条也已经读进来了就只是滚过去。
    func openHit(_ hit: AgentHistorySearchHit, in session: AgentHistorySearchSession) {
        if metadata[session.file.path] == nil {
            metadata[session.file.path] = session.metadata
            metadataKeys[session.file.path] = session.file.cacheKey
        }
        if selectedFile?.path == session.file.path, let transcript, transcript.items.contains(where: { $0.id == hit.itemID }) {
            if !subagentStack.isEmpty {
                for level in subagentStack { level.setFollowing(false) }
                subagentStack = []
                updateFollowing()
            }
            transcript.focus(on: hit.itemID)
            return
        }
        open(session.file, at: hit)
    }

    /// 从命中处打开的对话换回普通的从末尾打开（「跳到最新」）。
    func jumpToLatest() {
        guard let file = selectedFile else { return }
        open(file, at: nil)
    }

    // MARK: - 搜索

    /// 一次搜索的状态。有它时列表区显示搜索结果。
    struct Search: Equatable {
        enum Phase: Equatable {
            /// 范围里的会话还在列，列完马上搜。
            case waiting
            case searching
            case finished
            /// 用户点了取消。
            case stopped
            case failed(String)
        }

        let query: AgentHistorySearchQuery
        var phase: Phase
        var sessions: [AgentHistorySearchSession] = []
        var searched = 0
        var total = 0
        /// 命中到了上限，后面没再找。
        var truncated = false

        var hitCount: Int { sessions.reduce(0) { $0 + $1.hits.count } }
        var isRunning: Bool { phase == .waiting || phase == .searching }
    }

    /// 搜索框里的字（界面绑定）。改了（和搜着的不一样了）或者清空，就丢掉在途的搜索与结果，回到列表。
    /// 只在内存里：不存「最近搜索」。
    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            searchProblem = nil
            if let search, searchText.trimmingCharacters(in: .whitespacesAndNewlines) != search.query.text {
                cancelSearch()
                self.search = nil
            }
        }
    }
    private(set) var search: Search?
    /// 按回车时搜索词不合规矩（太短、太长、有控制字符）。
    private(set) var searchProblem: AgentHistorySearchQuery.Problem?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = 0

    /// 按回车：搜。每次搜索都是主机上的命令，所以不随着打字搜。
    func submitSearch() {
        switch AgentHistorySearchQuery.validate(searchText) {
        case .failure(let problem):
            cancelSearch()
            search = nil
            searchProblem = problem
        case .success(let query):
            searchProblem = nil
            startSearch(query)
        }
    }

    /// 停下在途的搜索，已经出来的结果留着。
    func stopSearch() {
        guard let current = search, current.isRunning else { return }
        cancelSearch()
        search?.phase = .stopped
    }

    /// 清空搜索框：回到原来的列表（选中的会话、滚动位置都还在）。
    func clearSearch() {
        searchText = ""
        cancelSearch()
        search = nil
        searchProblem = nil
    }

    private func cancelSearch() {
        searchGeneration += 1
        searchTask?.cancel()
        searchTask = nil
    }

    private func startSearch(_ query: AgentHistorySearchQuery) {
        cancelSearch()
        guard allowsSearch else {
            search = Search(query: query, phase: .failed(AgentHistoryText.searchCannotExecute))
            return
        }
        // 范围里的会话还没列完：等 `setScope` 列完再来。
        guard !isListing, phase != .loading else {
            search = Search(query: query, phase: .waiting)
            return
        }
        // 范围里的会话全是不能搜的工具的：不发命令，直接说明。
        let excluded = searchExcludedTools
        if !files.isEmpty, Set(files.map(\.tool)).isSubset(of: excluded) {
            search = Search(query: query, phase: .failed(AgentHistoryText.searchUnsupported(excluded)))
            return
        }
        search = Search(query: query, phase: .searching, total: files.count)
        let generation = searchGeneration
        let files = self.files
        let source = self.source
        let limits = searchLimits
        searchTask = Task { [weak self] in
            do {
                try await source.search(query, in: files, limits: limits) { [weak self] event in
                    await self?.apply(event, generation: generation)
                }
            } catch {
                self?.searchFailed(error, generation: generation)
            }
        }
    }

    private func apply(_ event: AgentHistorySearchEvent, generation: Int) {
        guard generation == searchGeneration, var current = search else { return }
        switch event {
        case .progress(let searched, let total):
            current.searched = searched
            current.total = total
        case .session(let session):
            // 几种工具同时搜，各路报来的先后穿插：按会话的新旧插进去（同一种工具本来就是新的先报，顺序不变）。
            let index = current.sessions.firstIndex { $0.file.modifiedAt < session.file.modifiedAt }
            current.sessions.insert(session, at: index ?? current.sessions.endIndex)
        case .finished(let truncated):
            current.truncated = truncated
            current.phase = .finished
            searchTask = nil
        }
        search = current
    }

    private func searchFailed(_ error: any Error, generation: Int) {
        guard generation == searchGeneration, search != nil else { return }
        searchTask = nil
        if error is CancellationError { return }
        search?.phase = .failed(AgentHistoryText.searchFailure(error))
    }

    // MARK: - 实时跟随

    /// 平台告诉它对话现在看不看得见：Mac 是窗口开着且没缩到程序坞，iOS 是标签在前台且 App 不在后台。
    /// 看得见时只有正在显示的那一层（`displayedTranscript`）盯着文件末尾，别的层都停。
    func setTranscriptVisible(_ visible: Bool) {
        guard visible != transcriptVisible else { return }
        transcriptVisible = visible
        updateFollowing()
    }

    private func updateFollowing() {
        let top = displayedTranscript
        for level in [transcript].compactMap({ $0 }) + subagentStack {
            level.setFollowing(transcriptVisible && level === top)
        }
    }

    private func stopFollowingAll() {
        transcript?.setFollowing(false)
        for level in subagentStack { level.setFollowing(false) }
    }

    /// 正在显示的那一层：点进了子代理就是最里面那份，否则是主对话。
    var displayedTranscript: AgentTranscriptModel? { subagentStack.last ?? transcript }

    /// 从正在显示的那一层点进它派出的一个子代理。只读，没有「继续这个会话」。
    func openSubagent(_ link: AgentSubagentLink) {
        guard let parent = displayedTranscript else { return }
        let model = AgentTranscriptModel(file: parent.file, pager: source.subagentTranscript(for: link.file),
                                         source: source, target: .subagent(link.file), subagent: link,
                                         followTiming: followTiming)
        subagentStack.append(model)
        updateFollowing()
        Task { await model.loadEarlier() }
    }

    /// 返回上一层（最里面那份子代理记录关掉，内容随之丢掉）。
    func closeSubagent() {
        guard !subagentStack.isEmpty else { return }
        subagentStack.removeLast().setFollowing(false)
        updateFollowing()
    }

    /// 在终端里继续选中的会话要敲的命令。目录用记录里对得上项目的那个，对不上用终端当前目录对上的项目目录。
    func resumeCommand(for file: AgentHistorySessionFile) -> (command: String, directory: String)? {
        let info = metadata[file.path]
        let directory = info?.resumeDirectory ?? file.project.directory
            ?? (currentProject?.id == file.project.id && currentProject?.tool == file.tool ? currentProject?.directory : nil)
        guard let directory, let source = source(for: file.tool),
              let command = source.resumeCommand(sessionID: file.sessionID, directory: directory) else {
            return nil
        }
        return (command, directory)
    }

    /// 在 `directory` 里新开一个某种工具的会话要敲的命令；那种工具不在终端里用、或者目录不合法为 nil。
    func newSessionCommand(tool: AgentHistoryTool, directory: String) -> String? {
        source(for: tool)?.newSessionCommand(directory: directory)
    }

    /// 「＋」新会话能选的工具：这台主机上有记录的（一种都没有就是建了数据源的那几种），能在终端里新开的。
    func newSessionTools(directory: String?) -> [AgentHistoryTool] {
        guard let directory else { return [] }
        let candidates = availableTools.isEmpty ? configuredTools : availableTools
        return candidates.filter { newSessionCommand(tool: $0, directory: directory) != nil }
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
/// 实时跟随：看得见（`setFollowing(true)`）且末尾已经读过时，每 `followTiming.interval` 看一次文件末尾，新写进来的条目
/// 接在后面（按 ID 去重，新来的工具结果挂回前面的调用）；文件变短就整份从末尾重读。读失败不报错，安静地退避。
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
    /// 每次在末尾接上了新条目就 +1，界面据此决定跟着滚到底，还是提示「有新消息」。
    private(set) var appendGeneration = 0
    /// 最近一段时间里文件在变（`followTiming.activeWindow` 内读到过新内容）：标题处的「正在更新」。
    private(set) var isUpdating = false
    /// 末尾来了新条目，而用户正往上翻着、没跟到底：底部的「有新消息」。
    private(set) var hasNewBelow = false
    /// 后面已经读到文件末尾了。从末尾打开的一开始就是；从搜索命中处打开的，往后一页页读（`loadLater`）到末尾才是，
    /// 这之后才接上实时跟随。
    private(set) var reachedEnd: Bool
    /// 是不是从搜索命中处打开的（「跳到最新」只对它有意义）。
    let opensAtHit: Bool
    private(set) var isLoadingLater = false
    private(set) var laterErrorMessage: String?
    /// 每次往后加了一页就 +1。
    private(set) var laterGeneration = 0
    /// 高亮的那一条（搜索命中的）。
    private(set) var highlightedItemID: String?
    /// 要界面滚到高亮那一条时 +1。
    private(set) var focusGeneration = 0
    /// 已加载内容里最新一条的时间（顶栏第二行的「最后活动」）。第一页、实时跟随接上的、往后翻的都算，往前翻旧页不会把它
    /// 改旧；跟随接上的条目没带时间戳就记成读到它的那一刻。还不知道为 nil（界面退回会话信息里的时间）。
    private(set) var lastActivity: Date?

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
    /// 会话还开着时，调用来了、子代理的记录可能晚一点才写出来：标记要重新列 `subagents/`（有间隔）。
    @ObservationIgnored private var subagentIndexStale = false
    @ObservationIgnored private var lastSubagentListing: ContinuousClock.Instant?

    // 实时跟随
    @ObservationIgnored let followTiming: AgentTranscriptFollowTiming
    @ObservationIgnored private var followTask: Task<Void, Never>?
    @ObservationIgnored private var isFollowReading = false
    @ObservationIgnored private var followFailures = 0
    @ObservationIgnored private var lastGrowth: ContinuousClock.Instant?
    /// 出现过的全部条目 ID（含挂到调用上的工具结果）：往后读到的和已有的重了就不再加。
    @ObservationIgnored private var seenIDs: Set<String> = []
    /// 文件被换掉、整份重读时 +1：在途的读拿到的是旧文件的东西，丢掉。
    @ObservationIgnored private var contentEpoch = 0
    /// 界面报的：用户是不是停在底部（跟着新内容走）。
    @ObservationIgnored private(set) var followsTail = true

    /// `opensAt`：从这一条（搜索命中）所在的行打开，`pager` 也要是从那一行读的（`transcript(for:around:)`）。
    init(file: AgentHistorySessionFile, pager: any AgentTranscriptPaging, source: (any AgentHistorySource)? = nil,
         target: AgentTranscriptTarget? = nil, subagent: AgentSubagentLink? = nil,
         followTiming: AgentTranscriptFollowTiming = .standard, opensAt itemID: String? = nil) {
        self.file = file
        self.pager = pager
        self.source = source
        self.target = target ?? .session(file)
        self.subagent = subagent
        self.followTiming = followTiming
        opensAtHit = itemID != nil
        reachedEnd = itemID == nil
        highlightedItemID = itemID
        // 停在命中那里，不跟着末尾走。
        followsTail = itemID == nil
    }

    isolated deinit {
        followTask?.cancel()
    }

    /// 在一份历史里唯一：界面拿它当视图身份（主对话与子代理一层一层的不能混）。
    var path: String { target.path }

    /// 已经加载的部分里最早的一条（往前加一页后滚回它）。
    var firstItemID: String? { items.first?.id }

    func loadEarlier() async {
        guard !isLoading, !reachedStart else { return }
        isLoading = true
        errorMessage = nil
        let epoch = contentEpoch
        do {
            let page = try await pager.loadPrevious()
            guard epoch == contentEpoch else {
                // 读的时候文件被换掉了：这一页是旧的，丢掉，按新文件重新从末尾读。
                isLoading = false
                await loadEarlier()
                return
            }
            seenIDs.formUnion(page.items.map(\.id))
            let isFirstPage = items.isEmpty
            if isFirstPage { noteActivity(page.items, arrivedNow: false) }
            items = AgentTranscriptAssembler.attachResults(page.items + items)
            reachedStart = page.reachedStart
            prependGeneration += 1
            // 从命中处打开的第一页回来了：滚到那一条。
            if isFirstPage, let highlightedItemID, items.contains(where: { $0.id == highlightedItemID }) {
                focusGeneration += 1
            }
            resolveSubagents()
        } catch {
            if epoch == contentEpoch { errorMessage = error.localizedDescription }
        }
        isLoading = false
    }

    /// 从命中处打开的：再往后读一页（滚到底或点「加载更晚的消息」）。读到文件末尾之后实时跟随接上。
    func loadLater() async {
        guard !reachedEnd, !isLoadingLater, !isLoading else { return }
        isLoadingLater = true
        laterErrorMessage = nil
        defer { isLoadingLater = false }
        let epoch = contentEpoch
        do {
            let growth = try await pager.loadNext()
            guard epoch == contentEpoch else { return }
            switch growth {
            case .unchanged:
                reachedEnd = true
            case .appended(let new, let hasMore):
                let fresh = new.filter { !seenIDs.contains($0.id) }
                seenIDs.formUnion(fresh.map(\.id))
                noteActivity(fresh, arrivedNow: false)
                if !fresh.isEmpty { items = AgentTranscriptAssembler.attachResults(items + fresh) }
                reachedEnd = !hasMore
                laterGeneration += 1
                if fresh.contains(where: { if case .toolCall(let call) = $0.kind { return call.spawn != nil } else { return false } }) {
                    subagentIndexStale = true
                }
                resolveSubagents()
            case .replaced:
                reachedEnd = true
                highlightedItemID = nil
                isLoadingLater = false
                await reloadFromEnd()
            }
        } catch {
            if epoch == contentEpoch { laterErrorMessage = error.localizedDescription }
        }
    }

    /// 新读到的条目里最新的时间戳；只往新里改。`arrivedNow`（实时跟随接上的）且没有时间戳时取此刻。
    private func noteActivity(_ new: [AgentTranscriptItem], arrivedNow: Bool) {
        guard !new.isEmpty else { return }
        guard let candidate = new.compactMap(\.timestamp).max() ?? (arrivedNow ? followTiming.date() : nil) else { return }
        if lastActivity.map({ candidate > $0 }) ?? true { lastActivity = candidate }
    }

    /// 高亮这一条并让界面滚过去（它已经读进来了）。
    func focus(on itemID: String) {
        highlightedItemID = itemID
        focusGeneration += 1
    }

    // MARK: - 实时跟随

    /// 看得见就开始盯着文件末尾（马上看一次，之后按节奏），看不见就停。
    func setFollowing(_ active: Bool) {
        if active {
            guard followTask == nil else { return }
            let timing = followTiming
            followTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let delay = await self?.followOnce() else { return }
                    do { try await timing.sleep(delay) } catch { return }
                }
            }
        } else {
            followTask?.cancel()
            followTask = nil
        }
    }

    var isFollowing: Bool { followTask != nil }

    /// 看一次文件末尾，返回隔多久再看。末尾还没读过（第一页没回来）时什么都不做。测试与画廊直接调。
    @discardableResult
    func followOnce() async -> Duration {
        // 从命中处打开、后面还没读到末尾：不跟（后面的由用户一页页往后读，不自动一口气读到末尾）。
        guard !isFollowReading, reachedEnd else { return followTiming.interval }
        isFollowReading = true
        defer { isFollowReading = false }
        let epoch = contentEpoch
        var next = followTiming.interval
        do {
            let growth = try await pager.loadNewer()
            followFailures = 0
            if epoch == contentEpoch {
                switch growth {
                case .unchanged:
                    break
                case .appended(let new, let hasMore):
                    lastGrowth = followTiming.now()
                    append(new)
                    if hasMore { next = .zero }
                case .replaced:
                    lastGrowth = followTiming.now()
                    await reloadFromEnd()
                }
            }
        } catch {
            // 断线之类：不弹错，拉长间隔，恢复后接着跟。
            followFailures += 1
            next = followTiming.delay(afterFailures: followFailures)
        }
        refreshUpdating()
        if subagentIndexStale, isUpdating, !pendingSpawns.isEmpty { resolveSubagents() }
        return next
    }

    /// 连续读失败了几次（测试看退避）。
    var consecutiveFollowFailures: Int { followFailures }

    private func refreshUpdating() {
        let updating = lastGrowth.map { followTiming.now() - $0 < followTiming.activeWindow } ?? false
        if updating != isUpdating { isUpdating = updating }
    }

    private func append(_ new: [AgentTranscriptItem]) {
        let fresh = new.filter { !seenIDs.contains($0.id) }
        guard !fresh.isEmpty else { return }
        seenIDs.formUnion(fresh.map(\.id))
        noteActivity(fresh, arrivedNow: true)
        items = AgentTranscriptAssembler.attachResults(items + fresh)
        appendGeneration += 1
        if !followsTail { hasNewBelow = true }
        let spawnsChanged = fresh.contains { item in
            switch item.kind {
            case .toolCall(let call): return call.spawn != nil
            case .toolResult(let result): return result.spawnedAgentID != nil
            default: return false
            }
        }
        if spawnsChanged { subagentIndexStale = true }
        resolveSubagents()
    }

    /// 文件变短了 / 换掉了：清空，整份从末尾重读。
    private func reloadFromEnd() async {
        contentEpoch += 1
        items = []
        reachedStart = false
        // 文件换掉了：命中处的位置不再作数，从末尾重读。
        reachedEnd = true
        highlightedItemID = nil
        lastActivity = nil
        errorMessage = nil
        seenIDs = []
        subagentLinks = [:]
        subagentIndex = nil
        subagentIndexStale = false
        infoRead = []
        fileByToolUse = [:]
        hasNewBelow = false
        await loadEarlier()
        appendGeneration += 1
    }

    /// 界面报：用户停在底部（跟着走），还是往上翻了。回到底部时「有新消息」消掉。
    func setFollowsTail(_ follows: Bool) {
        followsTail = follows
        if follows, hasNewBelow { hasNewBelow = false }
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
        let epoch = contentEpoch
        let now = followTiming.now()
        let relists = subagentIndexStale
            && lastSubagentListing.map { now - $0 >= followTiming.subagentRelist } ?? true
        if subagentIndex == nil || relists {
            guard let listed = try? await source.subagents(of: target), epoch == contentEpoch else { return }
            subagentIndex = listed
            lastSubagentListing = now
            subagentIndexStale = false
        }
        guard let index = subagentIndex, !index.isEmpty else {
            // 还没有记录（会话开着时可能马上就有）：之后有间隔地再列。
            subagentIndexStale = true
            return
        }
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
            guard epoch == contentEpoch else { return }
            for (file, info) in infos {
                infoRead.insert(file.path)
                guard let info, let toolUseID = info.toolUseID else { continue }
                fileByToolUse[toolUseID] = (file, info)
                if let request = waiting.removeValue(forKey: toolUseID) {
                    link(toolUseID, file: file, request: request, info: info)
                }
            }
        }
        // 还有对不上的：记录也许还没写出来，之后有间隔地再列。
        if !waiting.isEmpty { subagentIndexStale = true }
    }

    private func link(_ toolUseID: String, file: AgentSubagentFile, request: AgentSpawnRequest, info: AgentSubagentInfo?) {
        subagentLinks[toolUseID] = AgentSubagentLink(file: file, agentType: request.agentType ?? info?.agentType,
                                                     description: request.description ?? info?.description)
    }
}
