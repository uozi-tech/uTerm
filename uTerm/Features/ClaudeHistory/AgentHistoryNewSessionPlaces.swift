import Foundation
import Observation

/// 新开会话之前选目录：候选目录、主目录缩写、上一次用的工具、手输的路径怎么核对。两端共用（Mac 的 Code 标签页起始页、
/// iOS 的新会话面板），平台只画。
///
/// 候选全是现算的，不为它另存任何东西；只有「上一次用的工具」记在本机偏好里（`DefaultsKey.codeNewSessionTool`）。
nonisolated enum AgentHistoryNewSessionPlaces {
    /// 菜单里最多列几个目录。
    static let limit = 10

    /// 候选目录，按这个顺序、按规整后的路径去重、最多 `limit` 个：
    /// 1. `current`：这个标签页现在的目录（打开它时那个终端的目录，或者上次选的）；
    /// 2. 这台主机上会话记录所在的项目目录（读得到目录的记录才算），哪个项目最近更新过就排前面；
    /// 3. `recent`：本机终端最近待过的目录（只有 Mac 本机给，已经滤掉了不存在的）；
    /// 4. 主目录：总有这一项（名额满了就顶掉最后一个）。
    ///
    /// SSH 主机上的目录不逐个去核对还在不在：到「开始」时不在，终端里的 `cd` 会报错，用户看得见。
    static func candidates(current: String?, files: [AgentHistorySessionFile],
                           metadata: [String: AgentHistorySessionMetadata], recent: [String] = [],
                           home: String?, limit: Int = AgentHistoryNewSessionPlaces.limit) -> [String] {
        let home = home.flatMap { ClaudeProjectPath.normalized($0) }
        var seen: Set<String> = []
        var result: [String] = []
        func add(_ path: String?) {
            guard let path, let normalized = ClaudeProjectPath.normalized(path), seen.insert(normalized).inserted
            else { return }
            result.append(normalized)
        }
        add(current)
        for directory in projectDirectories(files: files, metadata: metadata) { add(directory) }
        for directory in recent { add(directory) }
        guard let home else { return Array(result.prefix(limit)) }
        if result.contains(home) { return Array(result.prefix(limit)) }
        return Array(result.prefix(max(0, limit - 1))) + [home]
    }

    /// 记录所在的项目目录，按那个项目里最近一次更新的先后（新的在前）。
    static func projectDirectories(files: [AgentHistorySessionFile],
                                   metadata: [String: AgentHistorySessionMetadata]) -> [String] {
        var latest: [String: Date] = [:]
        for file in files {
            guard case .directory(let directory) = AgentHistoryListing.projectKey(file, metadata: metadata[file.path])
            else { continue }
            latest[directory] = max(latest[directory] ?? .distantPast, file.modifiedAt)
        }
        return latest.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// 给人看的写法：主目录缩成 `~`。不知道主目录时原样。
    static func displayPath(_ path: String, home: String?) -> String {
        guard let home = home.flatMap({ ClaudeProjectPath.normalized($0) }), home != "/" else { return path }
        return RemoteLocalWorkspaces.displayPath(path, home: home)
    }

    /// 默认用哪种工具：上一次用的那种还能用就用它，否则第一种。
    static func preferredTool(stored: String?, among tools: [AgentHistoryTool]) -> AgentHistoryTool? {
        if let stored, let tool = AgentHistoryTool(rawValue: stored), tools.contains(tool) { return tool }
        return tools.first
    }
}

/// 手输的目录（SSH 主机、配对的 Mac 上没有系统的文件夹面板）：`~` 开头的照那台主机上的主目录展开，再经这个标签页
/// 现成的文件通道核对它存在、是目录。
nonisolated enum AgentHistoryDirectoryInput {
    enum Problem: Error, Equatable, Sendable {
        case empty
        /// 不是 `/` 或 `~` 开头（`~别人` 也不认）。
        case notAbsolute
        /// 要展开 `~` 但不知道主目录。
        case unknownHome
        case missing(String)
        case notDirectory(String)
    }

    /// 输入 → 规整过的绝对路径。不碰主机。
    static func resolve(_ input: String, home: String?) -> Result<String, Problem> {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        if text == "~" || text.hasPrefix("~/") {
            guard let home = home.flatMap({ ClaudeProjectPath.normalized($0) }) else { return .failure(.unknownHome) }
            let rest = text.dropFirst()
            guard let path = ClaudeProjectPath.normalized(home + rest) else { return .failure(.notAbsolute) }
            return .success(path)
        }
        guard let path = ClaudeProjectPath.normalized(text) else { return .failure(.notAbsolute) }
        return .success(path)
    }

    /// 展开后在主机上核对。`stat` 跟着符号链接走（SFTP 的 STAT、远控与辅助程序的文件服务都是）：指向目录的链接也算目录。
    /// 拿不到属性就当不存在（断线也落在这里，提示一样让人知道没选上）；服务端没给类型位时当目录（不拦）。
    static func check(_ input: String, home: String?, provider: any SFTPProviding) async -> Result<String, Problem> {
        var home = home
        if home == nil, input.trimmingCharacters(in: .whitespaces).hasPrefix("~") {
            home = try? await provider.realPath(".")
        }
        let path: String
        switch resolve(input, home: home) {
        case .success(let resolved): path = resolved
        case .failure(let problem): return .failure(problem)
        }
        guard let stat = try? await provider.stat(path) else { return .failure(.missing(path)) }
        switch TerminalLinkTarget.kind(stat) {
        case .directory: return .success(path)
        case .file, .other:
            // 服务端没给权限位时 `kind` 当文件：这时不知道，放行。
            return stat.permissions == nil ? .success(path) : .failure(.notDirectory(path))
        }
    }
}

/// 输入路径那个小面板的状态（Mac 的 SSH 主机、iOS 的「输入路径…」）。
@MainActor
@Observable
final class AgentHistoryPathEntry {
    var text: String {
        didSet { if text != oldValue { problem = nil } }
    }
    private(set) var isChecking = false
    private(set) var problem: AgentHistoryDirectoryInput.Problem?

    init(text: String = "", problem: AgentHistoryDirectoryInput.Problem? = nil) {
        self.text = text
        self.problem = problem
    }

    var message: String? { problem.map(AgentHistoryText.directoryProblem) }

    /// 核对；成功返回展开后的路径，失败留着说明、返回 nil（面板不关）。
    func submit(using connection: AgentHistoryConnection?) async -> String? {
        guard !isChecking else { return nil }
        guard let connection else {
            problem = .unknownHome
            return nil
        }
        isChecking = true
        defer { isChecking = false }
        let input = text
        switch await connection.checkDirectory(input) {
        case .success(let path):
            return path
        case .failure(let failure):
            if text == input { problem = failure }
            return nil
        }
    }
}
