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
    private(set) var transcript: AgentTranscriptModel?

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
        guard let file else {
            transcript = nil
            return
        }
        let model = AgentTranscriptModel(file: file, pager: source.transcript(for: file))
        transcript = model
        Task { await model.loadEarlier() }
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

/// 一份对话：从末尾开始，往上翻一页读一页。
@MainActor
@Observable
final class AgentTranscriptModel {
    let file: AgentHistorySessionFile
    private(set) var items: [AgentTranscriptItem] = []
    private(set) var reachedStart = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// 每次往前加了一页就 +1，界面据此把滚动位置留在原来那条上。
    private(set) var prependGeneration = 0

    @ObservationIgnored private let pager: any AgentTranscriptPaging

    init(file: AgentHistorySessionFile, pager: any AgentTranscriptPaging) {
        self.file = file
        self.pager = pager
    }

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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 已加载部分的纯文字（拷贝对话用）。
    var plainText: String {
        items.map(\.plainText).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
