import Foundation
import Observation

/// 历史会话窗口的状态：会话列表（当前项目或全部项目）、选中的会话、它的对话。两端共用，平台只画。
///
/// 列表里每一行的标题与来源要读文件末尾一小块，**滚到哪行读哪行**（`rowAppeared`），读过的按
/// （路径、大小、修改时间）缓存在数据源里。来源不是命令行的（桌面版等）读到之后从列表里拿掉。
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
    private(set) var selectedFile: AgentHistorySessionFile?
    private(set) var transcript: AgentTranscriptModel?

    /// 同时读几份记录的末尾。
    @ObservationIgnored private let metadataConcurrency = 4
    /// 一行露出来时顺带把后面几行也读了，往下滚时不用等。
    @ObservationIgnored private let prefetchCount = 12
    @ObservationIgnored private var queued: [AgentHistorySessionFile] = []
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var failed: Set<String> = []
    @ObservationIgnored private var listGeneration = 0

    init(source: any AgentHistorySource, preferredDirectory: String?) {
        self.source = source
        self.preferredDirectory = preferredDirectory
    }

    /// 列表里显示的：读过信息、要列出来的，以及还没读到的（显示成占位行）。
    var visibleFiles: [AgentHistorySessionFile] {
        files.filter { metadata[$0.path]?.isListed ?? true }
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
        if let selectedFile, !listed.contains(where: { $0.path == selectedFile.path }) {
            select(nil)
        }
    }

    /// 一行露出来了：读它和后面几行的信息。
    func rowAppeared(_ file: AgentHistorySessionFile) {
        let visible = visibleFiles
        guard let index = visible.firstIndex(where: { $0.path == file.path }) else { return }
        for candidate in visible[index..<min(visible.count, index + prefetchCount)] {
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
        if let result {
            metadata[file.path] = result
        } else {
            // 读不了的（文件刚被删、没权限）照样列着，标题显示文件名。不反复重试。
            failed.insert(file.path)
            metadata[file.path] = AgentHistorySessionMetadata(title: nil, isListed: true, lastDirectory: nil,
                                                              resumeDirectory: file.project.directory,
                                                              gitBranch: nil, lastActivity: nil)
        }
        pump()
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
