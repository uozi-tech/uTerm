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

    /// 对话顶上的那一行：目录 · 分支 · 最后活动。
    static func transcriptDetail(_ file: AgentHistorySessionFile, metadata: AgentHistorySessionMetadata?) -> String {
        var parts: [String] = []
        if let directory = metadata?.resumeDirectory ?? metadata?.lastDirectory { parts.append(directory) }
        if let branch = metadata?.gitBranch { parts.append(branch) }
        parts.append(relative(metadata?.lastActivity ?? file.modifiedAt))
        return parts.joined(separator: " · ")
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

    /// 子代理记录顶上的第二行：子代理 · 类型 · 最后活动。
    static func subagentDetail(_ link: AgentSubagentLink) -> String {
        var parts = [String(localized: "子代理", comment: "Claude Code 派出去干活的子代理（subagent）")]
        if let type = link.agentType { parts.append(type) }
        if let modified = link.file.modifiedAt { parts.append(relative(modified)) }
        return parts.joined(separator: " · ")
    }

    static var backToParent: String { String(localized: "返回上一层") }

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
