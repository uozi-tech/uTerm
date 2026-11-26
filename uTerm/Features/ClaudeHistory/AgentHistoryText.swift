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

    private static func later(_ date: Date, _ other: Date?) -> Date {
        other.map { max(date, $0) } ?? date
    }

    /// 列表一行的标题。读不到标题时用会话 ID 的前 8 位。
    static func sessionTitle(_ file: AgentHistorySessionFile, metadata: AgentHistorySessionMetadata?) -> String {
        if let title = metadata?.title { return title }
        return String(localized: "（无标题）\(String(file.sessionID.prefix(8)))")
    }

    /// 列表一行的第二行：多久以前 · 大小 · 分支 ·（全部项目时）项目。`activity` 是看这个会话时读到的更新的时间
    /// （`AgentHistoryModel.liveActivity`），比文件的修改时间新就用它。
    /// `showsTool`：组里不止一种工具时，最前面写工具名（行前不画工具标记）。整行一行、放不下截掉尾巴：
    /// 工具名与时间在前，先被截掉的是后面的分支、项目。
    static func sessionSubtitle(_ file: AgentHistorySessionFile, metadata: AgentHistorySessionMetadata?,
                                showsProject: Bool, showsTool: Bool = false, activity: Date? = nil) -> String {
        var parts = showsTool ? [file.tool.displayName] : []
        parts += [relative(later(file.modifiedAt, activity)), file.size.formatted(.byteCount(style: .file))]
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

    /// 结果里一个会话那一组的第二行：多久以前 ·（全部项目时）项目。`activity` 同 `sessionSubtitle`。
    /// `showsTool`：结果里不止一种工具时，最前面写工具名（同列表的行）。
    static func searchSessionDetail(_ session: AgentHistorySearchSession, showsProject: Bool, showsTool: Bool = false,
                                    activity: Date? = nil) -> String {
        var parts = showsTool ? [session.file.tool.displayName] : []
        parts.append(relative(later(session.metadata.lastActivity ?? session.file.modifiedAt, activity)))
        if showsProject {
            parts.append(session.metadata.lastDirectory.map { ($0 as NSString).lastPathComponent }
                         ?? projectName(session.file.project))
        }
        return parts.joined(separator: " · ")
    }

    /// 从搜索命中处打开的对话：顶上那一条。
    static var openedAtHit: String { String(localized: "从搜索结果打开，后面还有更晚的消息") }

    static var jumpToLatest: String { String(localized: "跳到最新") }

    /// 记录顶上那一条：这份记录是「接着往下聊」串起来的几份之一（Claude Code 上下文满了另起一份新记录）。
    static func continuationNotice(_ link: AgentHistoryContinuation.Link) -> String {
        switch link {
        case .previous:
            String(localized: "这段对话接着之前的记录往下聊（上下文满了另起的一份）",
                   comment: "历史会话：记录顶上的提示，这一份是上下文满了之后接着往下聊的新记录")
        case .next:
            String(localized: "这段对话后来接着在另一份记录里往下聊",
                   comment: "历史会话：记录顶上的提示，这一份上下文满了，后面的对话在另一份新记录里")
        }
    }

    /// 那一条上的按钮。
    static func continuationAction(_ link: AgentHistoryContinuation.Link) -> String {
        switch link {
        case .previous: String(localized: "看之前那段", comment: "历史会话：打开接着聊之前的那份记录")
        case .next: String(localized: "看后来那段", comment: "历史会话：打开接着往下聊的那份新记录")
        }
    }

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

    /// 读了几种工具的记录、一种都没找到时的说明。只读 Claude Code 时同 `noHistoryDetail`。
    static func noHistoryDetail(tools: [AgentHistoryTool]) -> String {
        guard tools != [.claude], !tools.isEmpty else { return noHistoryDetail }
        return String(localized: "这台主机上没有找到 \(toolList(tools)) 的会话记录。")
    }

    /// 没选会话时右边的说明。
    static func selectSessionDetail(tools: [AgentHistoryTool]) -> String {
        guard tools.count > 1 else {
            return String(localized: "左边列的是在命令行里用 \((tools.first ?? .claude).displayName) 的会话，内容只读。")
        }
        return String(localized: "左边列的是在命令行里用 \(toolList(tools)) 的会话，内容只读。")
    }

    /// 几种工具的名字连成一串（产品名不翻译）。
    static func toolList(_ tools: [AgentHistoryTool]) -> String {
        tools.map(\.displayName).joined(separator: String(localized: "、", comment: "并列项之间的分隔符"))
    }

    // MARK: 几种工具

    /// 搜索结果上方：这几种工具的会话没参与搜索。
    static func searchUnsupported(_ tools: [AgentHistoryTool]) -> String {
        String(localized: "\(toolList(tools)) 的会话不参与搜索")
    }

    /// 列表底下：某种工具的记录读不出来（别的照常列着）。
    static func toolFailure(_ tool: AgentHistoryTool, message: String) -> String {
        String(localized: "\(tool.displayName) 的记录读不出来：\(message)")
    }

    static func groupingName(_ grouping: AgentHistoryGrouping) -> String {
        switch grouping {
        case .project: return String(localized: "项目", comment: "历史会话按项目（工作目录）分组")
        case .date: return String(localized: "日期", comment: "历史会话按日期分组")
        case .tool: return String(localized: "工具", comment: "历史会话按编码工具（Claude Code、Codex…）分组")
        case .none: return String(localized: "不分组", comment: "历史会话不分组")
        }
    }

    static func dateBucket(_ bucket: AgentHistoryDateBucket) -> String {
        switch bucket {
        case .today: return String(localized: "今天")
        case .yesterday: return String(localized: "昨天")
        case .pastWeek: return String(localized: "过去 7 天")
        case .pastMonth: return String(localized: "过去 30 天")
        case .older: return String(localized: "更早")
        }
    }

    /// 有压缩过的记录没搜。
    static func searchSkippedCompressed(_ count: Int) -> String {
        String(localized: "有 \(count) 份压缩过的记录没有搜：这台主机上没有解压用的 zstd")
    }

    /// 组标题。项目组是目录名（不翻译）。
    static func groupTitle(_ group: AgentHistoryGroup) -> String {
        switch group.kind {
        case .project(_, let name): return name
        case .noDirectory: return String(localized: "没有工作目录")
        case .date(let bucket): return dateBucket(bucket)
        case .tool(let tool): return tool.displayName
        case .all: return String(localized: "全部会话")
        case .pinned: return pinnedTitle
        }
    }

    /// 「置顶」一组的标题（同欢迎窗口侧栏的「置顶」，是组名不是动作）。
    static var pinnedTitle: String {
        String(localized: "sidebar.pinned", defaultValue: "置顶", comment: "侧栏：置顶的主机（列表名，不是动作）")
    }

    /// 行的菜单：置顶 / 取消置顶（同主机列表的那两项）。
    static func pinAction(isPinned: Bool) -> String {
        isPinned ? String(localized: "取消置顶") : String(localized: "置顶")
    }

    /// Mac 侧栏：拖动一个会话、还没有置顶的会话时，列表顶上出的那个落点。
    static var dropToPin: String {
        String(localized: "拖到这里置顶", comment: "历史会话列表：拖动一个会话时列表顶上的落点")
    }

    /// 组标题的悬停：项目组是完整路径，对不上路径的说明一句。
    static func groupHelp(_ group: AgentHistoryGroup) -> String? {
        switch group.kind {
        case .project(let directory, let name):
            return directory ?? String(localized: "记录目录 \(name)（对不上工作目录）")
        case .noDirectory(let tool):
            return String(localized: "\(tool.displayName) 没有记下这些会话的工作目录")
        case .date, .tool, .all, .pinned:
            return nil
        }
    }

    /// 组标题的读屏文字：标题 + 几个会话 + 折没折。
    static func groupAccessibility(_ group: AgentHistoryGroup, collapsed: Bool) -> String {
        let title = groupTitle(group)
        return collapsed
            ? String(localized: "\(title)，\(group.files.count) 个会话，已收起")
            : String(localized: "\(title)，\(group.files.count) 个会话")
    }

    /// 收起的组标题上那个点（`CodeRunGroupMark`）的说明（悬停提示、读屏）：几个会话在跑，报过状态的带上最要紧的那个。
    static func groupRunsNote(_ mark: CodeRunGroupMark) -> String {
        let running = String(localized: "\(mark.running) 个会话正在运行", comment: "Code 标签页收起的侧栏上：在跑的会话个数")
        guard case .program(let record) = mark.status else { return running }
        return String(localized: "\(running)：\(record.statusLabel)", comment: "几个会话在运行：最要紧那个的状态（等待确认、运行中……）")
    }

    /// 组标题的读屏文字带上里面跑着的会话（收起时才有）。
    static func groupAccessibility(_ group: AgentHistoryGroup, collapsed: Bool, runs: CodeRunGroupMark?) -> String {
        let base = groupAccessibility(group, collapsed: collapsed)
        guard let runs else { return base }
        return String(localized: "\(base)，\(groupRunsNote(runs))", comment: "组标题的读屏文字，后面接里面跑着的会话")
    }

    /// 「＋」新会话菜单的标题：在哪个目录里新开。
    static func newSessionTitle(directory: String) -> String {
        String(localized: "在「\((directory as NSString).lastPathComponent)」里新开")
    }

    static var newSession: String { String(localized: "新会话", comment: "历史会话列表顶上：新开一个编码会话") }

    /// 跑着的会话里程序已经退出、终端留着最后的画面：侧栏那一行的状态。
    static var sessionEnded: String {
        String(localized: "已结束", comment: "Code 标签页：会话里的编码工具已经退出，终端还留着最后的画面")
    }

    /// 右边终端顶上那一条：程序退出了，没有对话记录可看。
    static var sessionEndedBanner: String {
        String(localized: "会话已结束", comment: "Code 标签页：会话里的编码工具已经退出，下面是终端最后的画面")
    }

    /// 那一条上的说明。
    static var sessionEndedDetail: String {
        String(localized: "这个会话没有留下对话记录。", comment: "Code 标签页「会话已结束」那一条上的说明")
    }

    /// 那一条上的按钮：同一种工具、同一个目录再开一次（继续的会话再继续同一份）。
    static var restartSession: String {
        String(localized: "重新开始", comment: "Code 标签页：会话结束后，同一个工具、同一个目录再开一次")
    }

    /// 那一条上的按钮：结束这个终端，右边回到起始页。
    static var closeEndedSession: String {
        String(localized: "关闭", comment: "Code 标签页：会话结束后，关掉留着的终端")
    }

    /// 看一个在 Code 标签页里跑着的会话的对话记录（Mac：侧栏那一行的右键菜单；iOS：终端标题行的「更多」）。
    static var viewRecord: String {
        String(localized: "查看记录", comment: "Code 标签页：看这个正在跑的会话的对话记录")
    }

    /// 看着一个跑着的会话的记录时回到它的终端（右键菜单项、记录标题行上的按钮）。
    static var backToTerminal: String {
        String(localized: "返回终端")
    }

    /// 把 Code 标签页里跑着的会话的终端开成普通的终端标签页。
    static var moveToTab: String {
        String(localized: "移到新标签页", comment: "Code 标签页：把这个会话的终端开成普通的终端标签页")
    }

    /// 行的菜单：继续这个会话（同对话顶上的按钮）。
    static var resumeSession: String {
        String(localized: "继续这个会话")
    }

    /// 行的菜单：拷贝会话 ID（在终端里自己 `claude --resume <ID>` 用）。
    static var copySessionID: String {
        String(localized: "拷贝会话 ID", comment: "历史会话列表的菜单：把会话 ID 拷贝到剪贴板")
    }

    /// 行的菜单：删除会话（点了先确认）。
    static var deleteSession: String {
        String(localized: "删除会话…", comment: "历史会话列表的菜单：删除这个会话的记录，点了先确认")
    }

    /// 删除前确认的标题。
    static var deleteConfirmTitle: String {
        String(localized: "删除这个会话？", comment: "历史会话：删除前确认的标题")
    }

    /// 删除前确认的说明：删的是主机上的记录，收不回来。
    static func deleteConfirmMessage(title: String) -> String {
        String(localized: "「\(title)」的记录会从这台主机上删除，删了不能恢复。",
               comment: "历史会话：删除前确认的说明。参数是会话标题")
    }

    /// 确认框里的「删除」按钮。
    static var deleteConfirmButton: String {
        String(localized: "删除", comment: "历史会话：确认删除的按钮")
    }

    /// 删不掉时的提示标题。
    static var deleteFailedTitle: String {
        String(localized: "没能删除这个会话", comment: "历史会话：删除失败的提示标题")
    }

    /// 结束一个在 Code 标签页里跑着的会话（Mac：终端顶上「⋯」、侧栏那一行的右键菜单与悬停的 ×；iOS 同名菜单项）。
    static var endSession: String {
        String(localized: "结束会话")
    }

    static func newSessionHelp(directory: String?) -> String {
        guard let directory else { return String(localized: "不知道终端当前在哪个目录，无法新开会话") }
        return String(localized: "在 \(directory) 里新开一个会话")
    }

    // MARK: 新会话（选目录、选工具）

    static var newSessionDirectoryLabel: String {
        String(localized: "目录", comment: "新会话：在哪个目录里开")
    }

    static var newSessionToolLabel: String {
        String(localized: "工具", comment: "新会话：用哪种编码工具")
    }

    /// 目录还不知道时选择器上的字。
    static var newSessionNoDirectory: String {
        String(localized: "选择一个目录", comment: "新会话：还没选目录时目录选择器上的字")
    }

    /// 「开始」按钮：只有一种工具时写明是哪种。
    static func newSessionStartTitle(tool: AgentHistoryTool?, toolCount: Int) -> String {
        guard let tool, toolCount == 1 else { return String(localized: "开始", comment: "新会话：开始按钮") }
        return String(localized: "用 \(tool.displayName) 开始", comment: "新会话：只有一种工具时的开始按钮")
    }

    /// 开始不了的原因；开得了为 nil。
    static func newSessionBlockedReason(directory: String?, tools: [AgentHistoryTool]) -> String? {
        guard directory != nil else { return String(localized: "先选一个目录", comment: "新会话：还没选目录时开始按钮下的说明") }
        guard tools.isEmpty else { return nil }
        return String(localized: "这台主机上的编码工具都不能在终端里新开会话")
    }

    /// 目录菜单最后一项：本机是系统的文件夹面板，SSH 主机是输入路径。
    static var chooseFolder: String {
        String(localized: "选择文件夹…", comment: "新会话：目录菜单的最后一项")
    }

    /// 文件夹面板、输入路径面板上确认的按钮。
    static var chooseFolderPrompt: String {
        String(localized: "选择", comment: "新会话：选好目录后确认的按钮")
    }

    /// iOS 面板里目录列表的最后一项。
    static var enterPath: String {
        String(localized: "输入路径…", comment: "新会话：手动输入一个目录")
    }

    static var enterPathTitle: String {
        String(localized: "输入路径", comment: "新会话：手动输入目录的面板标题")
    }

    static var enterPathPlaceholder: String {
        String(localized: "~/project 或 /srv/app", comment: "新会话：输入目录的占位提示，路径照原样不翻译")
    }

    static var enterPathHint: String {
        String(localized: "~ 开头的按这台主机上的主目录展开。", comment: "新会话：输入目录时的说明")
    }

    /// 手输的目录核对不过时的说明（`AgentHistoryDirectoryInput.Problem`）。
    static func directoryProblem(_ problem: AgentHistoryDirectoryInput.Problem) -> String {
        switch problem {
        case .empty:
            return String(localized: "请输入一个目录")
        case .notAbsolute:
            return String(localized: "请输入以 / 或 ~ 开头的完整路径")
        case .unknownHome:
            return String(localized: "还不知道这台主机的主目录，请输入以 / 开头的完整路径")
        case .missing(let path):
            return String(localized: "找不到 \(path)")
        case .notDirectory(let path):
            return String(localized: "\(path) 不是目录")
        }
    }

    /// 「继续这个会话」的悬停。
    static func resumeHelp(_ tool: AgentHistoryTool, canResume: Bool) -> String {
        guard canResume else { return String(localized: "不知道这个会话的工作目录，无法继续") }
        if tool == .claude { return String(localized: "在这台主机上新开一个终端标签页，执行 claude --resume") }
        return String(localized: "在这台主机上新开一个终端标签页，在里面继续这个会话")
    }

    /// 说话的一方。子代理的记录里「用户」那一侧是派它的主代理交给它的任务，不是你。回答的一方是那种工具（Claude Code 照旧叫「Claude」）。
    static func roleLabel(_ role: AgentTranscriptItem.Role, inSubagent: Bool = false, tool: AgentHistoryTool = .claude) -> String {
        guard role == .user else { return tool == .claude ? "Claude" : tool.displayName }
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
