import Foundation

/// 历史会话界面上的文字：列表的一行、对话的标题行、空态。两端共用，平台只管怎么画。
enum AgentHistoryText {
    /// 项目的名字：知道工作目录就用目录名，否则用记录目录的名字（`-Users-a-proj`，换不回原路径）。
    static func projectName(_ project: AgentHistoryProject) -> String {
        if let directory = project.directory { return (directory as NSString).lastPathComponent }
        return project.id
    }

    static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }

    /// 范围选择器上的字。
    static func scopeTitle(_ scope: AgentHistoryModel.Scope) -> String {
        switch scope {
        case .project(let project): return projectName(project)
        case .all: return String(localized: "全部项目")
        }
    }

    static func currentProjectItem(_ project: AgentHistoryProject) -> String {
        String(localized: "当前项目（\(projectName(project))）")
    }

    /// 列表一行的标题。读不到标题时用会话 ID 的前 8 位。
    static func sessionTitle(_ file: AgentHistorySessionFile, metadata: AgentHistorySessionMetadata?) -> String {
        if let title = metadata?.title { return title }
        return String(localized: "（无标题）\(String(file.sessionID.prefix(8)))")
    }

    /// 列表一行的第二行：多久以前 · 大小 · 分支 ·（全部项目时）项目。
    static func sessionSubtitle(_ file: AgentHistorySessionFile, metadata: AgentHistorySessionMetadata?,
                                showsProject: Bool) -> String {
        var parts = [relative(file.modifiedAt), file.size.formatted(.byteCount(style: .file))]
        if let branch = metadata?.gitBranch { parts.append(branch) }
        if showsProject {
            parts.append(metadata?.lastDirectory.map { ($0 as NSString).lastPathComponent } ?? projectName(file.project))
        }
        return parts.joined(separator: " · ")
    }

    /// 对话顶上的那一行：目录 · 分支 · 最后活动。`lastActivity` 是已加载内容里最新那条的时间（实时跟随时跟着变），
    /// 没有就用会话信息里的最后活动、再没有用文件的修改时间。
    static func transcriptDetail(_ file: AgentHistorySessionFile, metadata: AgentHistorySessionMetadata?,
                                 lastActivity: Date? = nil) -> String {
        var parts: [String] = []
        if let directory = metadata?.resumeDirectory ?? metadata?.lastDirectory { parts.append(directory) }
        if let branch = metadata?.gitBranch { parts.append(branch) }
        parts.append(relative(lastActivity ?? metadata?.lastActivity ?? file.modifiedAt))
        return parts.joined(separator: " · ")
    }

    /// 对话顶栏的第二行（主对话或子代理的记录），时间取 `transcript.lastActivity`，没有再退回原来的来源。
    static func transcriptDetail(_ transcript: AgentTranscriptModel, metadata: AgentHistorySessionMetadata?) -> String {
        if let link = transcript.subagent { return subagentDetail(link, lastActivity: transcript.lastActivity) }
        return transcriptDetail(transcript.file, metadata: metadata, lastActivity: transcript.lastActivity)
    }

    static func transcriptTitle(_ metadata: AgentHistorySessionMetadata?) -> String {
        metadata?.title ?? String(localized: "（无标题）")
    }

    // MARK: 子代理

    /// 派子代理的调用下面那个入口。
    static var subagentEntry: String { String(localized: "查看子代理的记录") }

    /// 入口的第二行：类型 · 大小。
    static func subagentEntryDetail(_ link: AgentSubagentLink) -> String {
        var parts: [String] = []
        if let type = link.agentType { parts.append(type) }
        if let size = link.file.size, size > 0 { parts.append(size.formatted(.byteCount(style: .file))) }
        return parts.joined(separator: " · ")
    }

    /// 子代理记录的标题：派它时写的描述。
    static func subagentTitle(_ link: AgentSubagentLink) -> String {
        link.description ?? String(localized: "子代理", comment: "Claude Code 派出去干活的子代理（subagent）")
    }

    /// 子代理记录顶上的第二行：子代理 · 类型 · 最后活动（`lastActivity` 没有就用记录文件的修改时间）。
    static func subagentDetail(_ link: AgentSubagentLink, lastActivity: Date? = nil) -> String {
        var parts = [String(localized: "子代理", comment: "Claude Code 派出去干活的子代理（subagent）")]
        if let type = link.agentType { parts.append(type) }
        if let modified = lastActivity ?? link.file.modifiedAt { parts.append(relative(modified)) }
        return parts.joined(separator: " · ")
    }

    static var backToParent: String { String(localized: "返回上一层") }

    // MARK: 实时跟随

    /// 标题旁：这份对话最近还在变（会话开着）。
    static var updating: String {
        String(localized: "正在更新", comment: "Claude 历史会话：打开着的对话最近还在写入新内容")
    }

    /// 往上翻着时末尾来了新内容，底部的提示。
    static var newMessages: String { String(localized: "有新消息") }

    // MARK: 搜索

    static var searchPlaceholder: String {
        String(localized: "搜索对话内容", comment: "Claude 历史会话：会话列表顶上的搜索框")
    }

    static var searchHelp: String {
        String(localized: "按回车在主机上搜索：你说的话、Claude 的回答和工具调用。英文不分大小写。")
    }

    static var stopSearch: String { String(localized: "停止", comment: "Claude 历史会话：停止正在进行的搜索") }

    static func searchProgress(_ search: AgentHistoryModel.Search) -> String {
        String(localized: "正在搜索…（已搜 \(search.searched) / 共 \(search.total) 个会话）")
    }

    static func searchStopped(_ search: AgentHistoryModel.Search) -> String {
        String(localized: "已停止搜索（已搜 \(search.searched) / 共 \(search.total) 个会话）")
    }

    static func searchNoResults(_ query: AgentHistorySearchQuery) -> String {
        String(localized: "没有找到「\(query.text)」")
    }

    static var searchNoResultsDetail: String {
        String(localized: "只搜命令行会话里你说的话、Claude 的回答和工具调用的摘要，不搜思考和工具结果。")
    }

    /// 结果末尾：命中到了上限。
    static func searchTruncated(_ count: Int) -> String {
        String(localized: "只显示前 \(count) 条")
    }

    /// 一个会话的命中下面：这个会话里还有更多。
    static func sessionMoreHits(_ count: Int) -> String {
        String(localized: "这个会话里还有更多，只显示前 \(count) 条")
    }

    static var searchCannotExecute: String { String(localized: "这台主机不能执行命令，无法搜索") }

    static var searchListFailed: String { String(localized: "会话列表读不出来，无法搜索") }

    static func searchFailure(_ error: any Error) -> String {
        switch error as? AgentHistorySearchError {
        case .cannotExecute: return searchCannotExecute
        case .missingTools: return String(localized: "这台主机上缺少搜索要用的命令（sh、grep 或 awk），无法搜索")
        case .incompleteOutput: return String(localized: "搜索命令的输出不完整，请重试")
        case nil: return String(localized: "搜索失败：\(FriendlyError.describe(error))")
        }
    }

    static func searchProblem(_ problem: AgentHistorySearchQuery.Problem) -> String {
        switch problem {
        case .tooShort: return String(localized: "至少输入 \(AgentHistorySearchQuery.minCharacters) 个字")
        case .tooLong: return String(localized: "搜索词最多 \(AgentHistorySearchQuery.maxCharacters) 个字")
        case .controlCharacters: return String(localized: "搜索词里不能有换行或控制字符")
        }
    }

    /// 结果里一个会话那一组的第二行：多久以前 ·（全部项目时）项目。
    static func searchSessionDetail(_ session: AgentHistorySearchSession, showsProject: Bool) -> String {
        var parts = [relative(session.metadata.lastActivity ?? session.file.modifiedAt)]
        if showsProject {
            parts.append(session.metadata.lastDirectory.map { ($0 as NSString).lastPathComponent }
                         ?? projectName(session.file.project))
        }
        return parts.joined(separator: " · ")
    }

    /// 从搜索命中处打开的对话：顶上那一条。
    static var openedAtHit: String { String(localized: "从搜索结果打开，后面还有更晚的消息") }

    static var jumpToLatest: String { String(localized: "跳到最新") }

    static var loadLater: String { String(localized: "加载更晚的消息") }

    /// 范围里一行都没列出来时的说明。
    static func emptyListDetail(hidden: Int) -> String {
        hidden > 0
            ? String(localized: "这里的 \(hidden) 个会话没有列出：不是在命令行里起的（例如桌面版），或者没有对话内容。")
            : String(localized: "这个项目里还没有会话。可以切到「全部项目」看看。")
    }

    /// 列表读到底、有没列出来的时候，底下那一行。
    static func hiddenNote(_ hidden: Int) -> String {
        String(localized: "另有 \(hidden) 个会话没有列出：不是在命令行里起的（例如桌面版），或者没有对话内容。")
    }

    static var noHistoryDetail: String {
        String(localized: "这台主机上没有找到 Claude Code 的会话记录（~/.claude/projects）。")
    }

    /// 说话的一方。子代理的记录里「用户」那一侧是派它的主代理交给它的任务，不是你。
    static func roleLabel(_ role: AgentTranscriptItem.Role, inSubagent: Bool = false) -> String {
        guard role == .user else { return "Claude" }
        return inSubagent ? String(localized: "任务", comment: "子代理记录里，派它的那一方交给它的话") : String(localized: "你")
    }

    static func resultLabel(_ result: AgentToolResult) -> String {
        var label = result.isError ? String(localized: "结果（出错）") : String(localized: "结果")
        if result.imageCount > 0 { label += " · " + String(localized: "\(result.imageCount) 张图片（不显示）") }
        return label
    }

    static func oversized(_ bytes: Int) -> String {
        String(localized: "这条记录太大（\(Int64(bytes).formatted(.byteCount(style: .file)))），没有显示")
    }

    static func showAll(_ count: Int) -> String {
        String(localized: "显示全部（\(count) 字）")
    }

    static func clippedNote(_ text: AgentClippedText) -> String {
        String(localized: "内容太长，只显示前 \(text.text.count) 字（共 \(text.totalCount) 字）。")
    }
}

/// 哪些条目要带「你」/「Claude」的标签：换了说话的一方才带。
nonisolated enum AgentTranscriptRuns {
    static func starts(_ items: [AgentTranscriptItem]) -> Set<String> {
        var result: Set<String> = []
        var last: AgentTranscriptItem.Role?
        for item in items {
            if item.role != .system, item.role != last { result.insert(item.id) }
            last = item.role
        }
        return result
    }
}
