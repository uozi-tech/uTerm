import Foundation
@testable import uTerm

/// 内存里的假数据源，`tool` 可指定：在测试和界面画廊里看几种工具混排。内容全是手写的。
///
/// 项目放在 `/fake/<工具>/<记录目录名>`，会话文件是 `<项目>/<会话 ID>.jsonl`（只是个路径，不读文件）。
actor AgentHistoryFakeSource: AgentHistorySource {
    struct Session {
        var id: String
        /// 记录目录的名字（Claude Code 是工作目录换出来的那个）。
        var projectID: String
        /// 数据源放在项目上的真实工作目录（Codex 这类直接有；Claude Code 没有，为 nil）。
        var projectDirectory: String?
        /// 会话信息里「该在哪个目录继续」。
        var resumeDirectory: String?
        var title: String?
        var modifiedAt: Date
        var size: UInt64 = 18 * 1024
        var branch: String? = "main"
        var isListed = true
        var items: [AgentTranscriptItem] = []
        /// 搜索时报的命中。
        var hits: [AgentHistorySearchHit] = []
    }

    nonisolated let tool: AgentHistoryTool
    nonisolated let supportsSearch: Bool
    /// 能不能在终端里继续 / 新开（不能的工具数据源返回 nil）。
    nonisolated let resumable: Bool
    nonisolated let startsSessions: Bool

    private let sessionList: [Session]
    private var projectsError: (any Error)?
    private var searchError: (any Error)?
    /// 搜索时交给它的会话（按调用的先后）。
    private(set) var searchedPaths: [[String]] = []
    private(set) var metadataReads = 0

    init(tool: AgentHistoryTool, sessions: [Session], supportsSearch: Bool = true, resumable: Bool = true,
         startsSessions: Bool = true, projectsError: (any Error)? = nil, searchError: (any Error)? = nil) {
        self.tool = tool
        sessionList = sessions
        self.supportsSearch = supportsSearch
        self.resumable = resumable
        self.startsSessions = startsSessions
        self.projectsError = projectsError
        self.searchError = searchError
    }

    nonisolated func projectPath(_ id: String) -> String { "/fake/\(tool.rawValue)/\(id)" }
    nonisolated func sessionPath(_ session: Session) -> String { projectPath(session.projectID) + "/\(session.id).jsonl" }

    func setProjectsError(_ error: (any Error)?) { projectsError = error }

    private func makeProject(_ id: String) -> AgentHistoryProject {
        let members = sessionList.filter { $0.projectID == id }
        return AgentHistoryProject(id: id, path: projectPath(id), modifiedAt: members.map(\.modifiedAt).max(),
                                   directory: members.first?.projectDirectory, tool: tool)
    }

    func projects() async throws -> [AgentHistoryProject] {
        if let projectsError { throw projectsError }
        var seen: Set<String> = []
        return sessionList.map(\.projectID).filter { seen.insert($0).inserted }.map(makeProject)
            .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    func project(containing directory: String, among projects: [AgentHistoryProject]) -> AgentHistoryProject? {
        for candidate in ClaudeProjectPath.lineage(of: directory) {
            if let hit = projects.first(where: { $0.directory == candidate }) { return hit }
        }
        return nil
    }

    private func file(_ session: Session) -> AgentHistorySessionFile {
        AgentHistorySessionFile(sessionID: session.id, project: makeProject(session.projectID), path: sessionPath(session),
                                size: session.size, modifiedAt: session.modifiedAt)
    }

    func sessions(in project: AgentHistoryProject) async throws -> [AgentHistorySessionFile] {
        sessionList.filter { $0.projectID == project.id }.map(file).sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func allSessions(in projects: [AgentHistoryProject]) async -> [AgentHistorySessionFile] {
        let ids = Set(projects.map(\.id))
        return sessionList.filter { ids.contains($0.projectID) }.map(file).sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private func session(at path: String) -> Session? {
        sessionList.first { sessionPath($0) == path }
    }

    func metadata(for file: AgentHistorySessionFile) async throws -> AgentHistorySessionMetadata {
        metadataReads += 1
        guard let session = session(at: file.path) else { throw AgentHistoryFakeError.missing }
        return AgentHistorySessionMetadata(title: session.title, isListed: session.isListed,
                                           lastDirectory: session.resumeDirectory, resumeDirectory: session.resumeDirectory,
                                           gitBranch: session.branch, lastActivity: session.modifiedAt)
    }

    nonisolated func transcript(for file: AgentHistorySessionFile) -> any AgentTranscriptPaging {
        AgentHistoryFakePager(source: self, path: file.path)
    }

    nonisolated func transcript(for file: AgentHistorySessionFile, around anchor: AgentTranscriptAnchor) -> any AgentTranscriptPaging {
        AgentHistoryFakePager(source: self, path: file.path)
    }

    func items(at path: String) -> [AgentTranscriptItem] { session(at: path)?.items ?? [] }

    func search(_ query: AgentHistorySearchQuery, in files: [AgentHistorySessionFile], limits: AgentHistorySearchLimits,
                // 测试 target 没开 Approachable Concurrency，协议里的类型（App 里默认 nonsending）要写明。
                onEvent: nonisolated(nonsending) @escaping @Sendable (AgentHistorySearchEvent) async -> Void) async throws {
        searchedPaths.append(files.map(\.path))
        if let searchError { throw searchError }
        var total = 0
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            await onEvent(.progress(searched: index + 1, total: files.count))
            guard let session = session(at: file.path), !session.hits.isEmpty else { continue }
            let shown = Array(session.hits.prefix(limits.hitsPerSession))
            let metadata = try await metadata(for: file)
            await onEvent(.session(AgentHistorySearchSession(file: file, metadata: metadata, hits: shown,
                                                             hasMoreHits: session.hits.count > shown.count)))
            total += shown.count
            if total >= limits.totalHits {
                await onEvent(.finished(truncated: true))
                return
            }
        }
        await onEvent(.finished(truncated: false))
    }

    nonisolated func subagentTranscript(for subagent: AgentSubagentFile) -> any AgentTranscriptPaging {
        AgentHistoryFakePager(source: self, path: subagent.path)
    }

    func subagents(of target: AgentTranscriptTarget) async throws -> [AgentSubagentFile] { [] }

    func info(of subagent: AgentSubagentFile) async -> AgentSubagentInfo? { nil }

    nonisolated func resumeCommand(sessionID: String, directory: String) -> String? {
        guard resumable, directory.hasPrefix("/") else { return nil }
        return "cd -- '\(directory)' && \(tool.rawValue) resume \(sessionID)"
    }

    nonisolated func newSessionCommand(directory: String) -> String? {
        guard startsSessions, directory.hasPrefix("/") else { return nil }
        return "cd -- '\(directory)' && \(tool.rawValue)"
    }

    // MARK: 手写的条目

    static func turn(_ id: String, ask: String, answer: String, at date: Date) -> [AgentTranscriptItem] {
        [AgentTranscriptItem(id: "\(id).u", kind: .userText(ask), timestamp: date.addingTimeInterval(-60)),
         AgentTranscriptItem(id: "\(id).a", kind: .assistantText(answer), timestamp: date)]
    }

    static func hit(_ id: String, before: String, match: String, after: String, role: AgentTranscriptItem.Role = .user) -> AgentHistorySearchHit {
        AgentHistorySearchHit(itemID: id, role: role, snippet: AgentHistorySnippet(before: before, match: match, after: after),
                              timestamp: nil, anchor: AgentTranscriptAnchor(lineOffset: 0, lineLength: 1))
    }
}

nonisolated enum AgentHistoryFakeError: Error, LocalizedError {
    case missing
    case offline

    var errorDescription: String? {
        switch self {
        case .missing: return "没有这份记录"
        case .offline: return "连接已断开"
        }
    }
}

/// 一页就读完的假对话。
actor AgentHistoryFakePager: AgentTranscriptPaging {
    let source: AgentHistoryFakeSource
    let path: String
    private var done = false

    init(source: AgentHistoryFakeSource, path: String) {
        self.source = source
        self.path = path
    }

    func loadPrevious() async throws -> (items: [AgentTranscriptItem], reachedStart: Bool) {
        guard !done else { return ([], true) }
        done = true
        return (await source.items(at: path), true)
    }

    func loadNewer() async throws -> AgentTranscriptGrowth { .unchanged }
}
