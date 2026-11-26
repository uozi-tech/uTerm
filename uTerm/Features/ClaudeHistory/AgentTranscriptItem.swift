import Foundation

/// 历史会话里要显示的一条：用户提问、回答、思考、工具调用……与具体是哪个 Agent 的记录无关，
/// 以后接 Codex 的记录也解析成这些。
nonisolated struct AgentTranscriptItem: Identifiable, Equatable, Sendable {
    nonisolated enum Kind: Equatable, Sendable {
        /// 用户输入的文字（已经去掉系统注入的部分）。按 Markdown 显示。
        case userText(String)
        /// 用户敲的斜杠命令（`/compact 保留接口`）或 `!` 开头的 shell 命令。
        case command(String)
        /// 上面那种命令的输出。
        case commandOutput(AgentClippedText)
        /// 系统发给模型的通知（后台任务结束之类），只显示一句摘要。
        case notice(String)
        /// Agent 的回答。按 Markdown 显示。
        case assistantText(String)
        case thinking(AgentClippedText)
        case toolCall(AgentToolCall)
        /// 没找到对应调用的工具结果（调用在更早、还没读到的那一段里）。
        case toolResult(AgentToolResult)
        /// 图片只放占位，不解码。
        case image
        /// 上下文被压缩了：画一条分隔线，摘要可以展开看。
        case compactSummary(AgentClippedText)
        /// 这一行太大，没有读进来。
        case oversized(bytes: Int)
        /// 一次回答用了多少（不显示成一行，标题块取最后一条，`AgentTranscriptModel.latestUsage`）。
        case usage(AgentTurnUsage)
    }

    nonisolated enum Role: Equatable, Sendable {
        case user, assistant, system
    }

    /// 在一份记录里唯一且稳定：行在文件里的偏移 + 行内序号。
    let id: String
    var kind: Kind
    var timestamp: Date?

    init(id: String, kind: Kind, timestamp: Date? = nil) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
    }

    var role: Role {
        switch kind {
        case .userText, .command, .commandOutput, .image, .toolResult: return .user
        case .assistantText, .thinking, .toolCall: return .assistant
        case .notice, .compactSummary, .oversized, .usage: return .system
        }
    }

    /// 有没有能拷贝的文字（图片占位、太大没读的那几条没有）。不拼字，重画时用。
    var hasPlainText: Bool {
        switch kind {
        case .image, .oversized, .usage: return false
        default: return true
        }
    }

    /// 拷贝用的纯文字。
    var plainText: String {
        switch kind {
        case .userText(let text), .command(let text), .notice(let text), .assistantText(let text):
            return text
        case .commandOutput(let text), .thinking(let text), .compactSummary(let text):
            return text.text
        case .toolCall(let call):
            let head = call.summary.isEmpty ? call.name : "\(call.name) \(call.summary)"
            guard let result = call.result else { return head }
            return head + "\n" + result.content.text
        case .toolResult(let result):
            return result.content.text
        case .image, .oversized, .usage:
            return ""
        }
    }
}

nonisolated extension AgentTranscriptItem {
    /// 会画成一行（用量只是记账，不画）。分页凑够一页、「有新消息」都只数这些。
    var isDisplayed: Bool {
        if case .usage = kind { return false }
        return true
    }
}

/// 一次回答的用量。各家记录里写的不一样，解析器各自换算成这几样（`ClaudeTranscriptParser` 等）。
nonisolated struct AgentTurnUsage: Equatable, Sendable {
    var model: String?
    /// 这一次模型看到的上下文：输入加缓存（读与写）。每次回答都把整段上下文重新算一遍，所以不能把各次加起来。
    var contextTokens: Int
    var outputTokens: Int
    /// 上下文窗口多大。记录里写了的才有（Codex）；只有模型名的不猜（同一个模型有不同窗口）。
    var contextWindow: Int?
    /// 账号的额度（Codex 每次都随用量记一份）。
    var rateLimits: AgentRateLimits?

    /// 上下文占了窗口的几成；不知道窗口为 nil。
    var contextFraction: Double? {
        guard let contextWindow, contextWindow > 0 else { return nil }
        return min(1, Double(contextTokens) / Double(contextWindow))
    }
}

/// 账号额度：几个时间窗（Codex 的 primary / secondary；Claude 的 5 小时与每周；Antigravity 的各个 bucket），
/// 各自用了几成、什么时候重置。
nonisolated struct AgentRateLimits: Equatable, Sendable {
    nonisolated struct Window: Equatable, Sendable {
        /// 0–100。
        var usedPercent: Double
        var windowMinutes: Int?
        var resetsAt: Date?
        /// 时间窗的名字（Antigravity 的 bucket 名，原样）；有窗长的按窗长起名（`AgentHistoryText.rateLimitWindow`）。
        var label: String? = nil
        /// 只管某个模型的额度（Claude 的 `seven_day_fable` 之类，记录里的原样，首字母大写）；管全部的为 nil。
        var scope: String? = nil
        /// 记下之后已经过了重置时间：之后再没用过（这是最后一次记录），按用了 0 算（`AgentHistoryModel.accountLimits`）。
        var didReset = false
    }

    var primary: Window?
    var secondary: Window?
    /// 套餐名（记录里的原样，如 `prolite`）。
    var plan: String?
    /// 不止两个时间窗的（Antigravity）。
    var extra: [Window] = []

    var windows: [Window] { [primary, secondary].compactMap { $0 } + extra }

    /// 最紧的在前：用了最多（剩得最少）的那个最先碰到上限，窄的地方只放得下一两个时先放它。一样多时短的时间窗在前。
    static func tightestFirst(_ windows: [Window]) -> [Window] {
        windows.enumerated().sorted { a, b in
            if a.element.usedPercent != b.element.usedPercent { return a.element.usedPercent > b.element.usedPercent }
            let left = a.element.windowMinutes ?? .max, right = b.element.windowMinutes ?? .max
            return left != right ? left < right : a.offset < b.offset
        }.map(\.element)
    }
}

/// 用量到了什么程度（额度、上下文共用）：蓝（正常）、黄（快满了）、红（满了或差不多满了）。
///
/// - 红：用了 90% 以上。
/// - 黄：用了 75% 以上；或者额度照这个时间窗里到现在的速度，到重置前会用完（用了至少 20%、窗口过了至少一成时才算，
///   刚开头的一点用量算不出速度）。
/// - 上下文只看用了几成（没有重置时间）。
nonisolated enum AgentUsageLevel: Int, Comparable, Sendable {
    case normal, warning, critical

    static let warningPercent: Double = 75
    static let criticalPercent: Double = 90

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// 只看用了几成（0–100）。
    static func of(percent: Double) -> Self {
        if percent >= criticalPercent { return .critical }
        if percent >= warningPercent { return .warning }
        return .normal
    }

    /// 额度的一个时间窗：用了几成，再看照现在的速度到重置前会不会用完。
    static func of(_ window: AgentRateLimits.Window, now: Date = Date()) -> Self {
        let level = of(percent: window.usedPercent)
        guard level == .normal, !window.didReset, window.usedPercent >= 20,
              let minutes = window.windowMinutes, minutes > 0, let resets = window.resetsAt else { return level }
        let total = Double(minutes) * 60
        let elapsed = 1 - resets.timeIntervalSince(now) / total
        guard elapsed >= 0.1, elapsed < 1 else { return level }
        return window.usedPercent / 100 / elapsed >= 1 ? .warning : level
    }
}

/// 截断过的长文字：只留前面一段，记下原来多长。
nonisolated struct AgentClippedText: Equatable, Sendable {
    let text: String
    /// 原文的字符数。
    let totalCount: Int

    var isClipped: Bool { totalCount > text.count }

    init(_ full: String, limit: Int) {
        let count = full.count
        totalCount = count
        text = count > limit ? String(full.prefix(limit)) : full
    }

    init(text: String, totalCount: Int) {
        self.text = text
        self.totalCount = max(totalCount, text.count)
    }

    /// 折起来那一行上的摘要：第一行非空的字，最多 200 字（后面的反正被截掉，整行排版白费）。
    var firstLine: String {
        let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first ?? ""
        return String(line.prefix(200))
    }

    /// 折叠时显示的几行。
    func preview(lines: Int, characters: Int) -> String {
        var result = ""
        var taken = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if taken == lines { break }
            if !result.isEmpty { result += "\n" }
            result += line
            taken += 1
            if result.count >= characters { break }
        }
        return result.count > characters ? String(result.prefix(characters)) : result
    }
}

nonisolated struct AgentToolCall: Equatable, Sendable {
    let toolUseID: String?
    let name: String
    /// 参数的一行摘要（命令、文件路径、搜索词……）。
    let summary: String
    var result: AgentToolResult?
    /// 这次调用派出了一个子代理（Claude：`Agent`，旧版本叫 `Task`）。
    var spawn: AgentSpawnRequest? = nil
}

/// 派子代理时写的参数。
nonisolated struct AgentSpawnRequest: Equatable, Sendable {
    var description: String?
    var agentType: String?
}

nonisolated struct AgentToolResult: Equatable, Sendable {
    let toolUseID: String?
    let content: AgentClippedText
    let isError: Bool
    let imageCount: Int
    /// 派子代理那次调用的结果里报的子代理 ID（用来找到它的记录）。
    var spawnedAgentID: String? = nil
}

/// 显示的上限。记录里的字节大头是工具结果，展开也只给前面一段。
nonisolated enum AgentTranscriptLimits {
    /// 用户与回答的文字。
    static let textCharacters = 200_000
    static let thinkingCharacters = 60_000
    /// 工具结果、命令输出展开后最多显示多少字。
    static let toolResultCharacters = 16_000
    static let compactSummaryCharacters = 60_000
    /// 工具调用摘要。
    static let summaryCharacters = 200
    /// 折叠时的预览。
    static let previewLines = 6
    static let previewCharacters = 600
    /// 一行超过这么大就不解析，显示成「太大」。
    static let maxLineBytes = 8 * 1024 * 1024
    /// 每次往前读多大一块。
    static let chunkBytes = 256 * 1024
    /// 一页至少攒够多少条，或者读满多少字节就停。
    static let pageItems = 40
    static let pageBytes = 2 * 1024 * 1024
    /// 对话末尾整段排（不进懒栈）的最多多少行，见 `AgentTranscriptLayout.eagerTailStart`。打开一份对话要付这么多行的
    /// 排版（全是长 Markdown 时一行几毫秒）；也不能太少：这一段得比视口高（一行最矮二十几点），打开时视口里才没有懒栈的行。
    static let eagerTailRows = 160
}

/// 把工具结果挂到它的调用下面。结果在下一条 `user` 行里，分页时两者可能落在不同的页，
/// 所以每次拼页之后整体再挂一遍。
nonisolated enum AgentTranscriptAssembler {
    static func attachResults(_ items: [AgentTranscriptItem]) -> [AgentTranscriptItem] {
        var output: [AgentTranscriptItem] = []
        output.reserveCapacity(items.count)
        var openCalls: [String: Int] = [:]
        for item in items {
            switch item.kind {
            case .toolCall(let call):
                if let id = call.toolUseID, call.result == nil { openCalls[id] = output.count }
                output.append(item)
            case .toolResult(let result):
                if let id = result.toolUseID, let index = openCalls.removeValue(forKey: id),
                   case .toolCall(var call) = output[index].kind {
                    call.result = result
                    output[index].kind = .toolCall(call)
                } else {
                    output.append(item)
                }
            default:
                output.append(item)
            }
        }
        return output
    }
}
