import AgentKit
import Foundation
import SwiftData
@testable import uTermMobile

/// 假 Agent：一个**按节拍**吐 Markdown 的 `LLMClient`，加上一条把 N 条历史消息
/// 灌进 `AssistantModel` 的回放路径。
///
/// ## 注入点（都是产品自带的，没有开测试后门）
///
/// - **流式**：`AssistantModel.init(client:provider:apiKey:)` 是产品自带的测试构造，
///   `clientOverride` 非 nil 时绕过 `LLMClientFactory` 与 keychain。
///   `MobileAgentChat` 收的就是一个外部持有的 `AssistantModel`，所以把这个
///   模型交给它即可 —— 屏幕本身不知道后端是假的。
/// - **历史**：`AssistantModel.load(_ session:)`。`messages` 是 `private(set)`，
///   外部写不了；`load` 走的是真实持久化载入路径（`ChatSession.orderedMessages`
///   → `messages`），与用户从「历史会话」菜单切回来时走的是同一条。
///
/// ## 已知局限
///
/// - **工具执行**：`MobileFakeCommandExecutor`（本文件末尾）＋产品侧的
///   `\.agentCommandExecutorFactory` 环境注入口。改前 `MobileAgentChat` 构造执行器的那两行
///   直接 `WorkspaceCommandExecutorFactory.make(server:container:)` 现造真执行器，
///   「批准 → 执行 → 输出回填 → 完成态」这条链在测试里走不通；现在
///   `.environment(\.agentCommandExecutorFactory, .stub(fake))` 就能整条跑通。
///   （直接写 `model.executor` 那条老路仍然有效 —— `configureExecutor()` 只在
///   `executor == nil` 时才覆盖 —— 但注入口是更接近真实的那条：走屏幕自己的构造路径。）
/// - `StreamingTextBuffer` 以 50ms 为节拍向 `messages` 发布，所以 20 chunk/s
///   （50ms 一块）之下「已投递块数」与「已上屏文本」最多差一块。自证测试按
///   前缀关系断言，不按等长断言。
enum MobileFakeAgent {

    // MARK: - 语料

    /// 一条 assistant 回复的 Markdown：标题 / 段落 / 列表 / 代码块 / 表格混排。
    /// 与桌面 `AgentMessageListCostTests.assistantMarkdown` 同形（好让两端读数可比），
    /// 默认 36 块。
    static func assistantMarkdown(index: Int, blocks: Int = 36) -> String {
        var lines: [String] = []
        var produced = 0
        var section = 0
        while produced < blocks {
            section += 1
            lines.append("### 步骤 \(section)：排查 svc-\(index)-\(section)")
            produced += 1
            if produced >= blocks { break }
            lines.append(
                "先确认 **节点 \(index)** 的负载是否已经落回基线，"
                + "再看 `journalctl` 里 unit `app-\(index).service` 最近 5 分钟的报错。"
                + "这一段刻意写长一些，好让段落真的换行、排版成本进得了账。")
            produced += 1
            if produced >= blocks { break }
            lines.append("- 检查磁盘水位 `df -h /var`\n- 检查连接数 `ss -s`\n- 检查内存 `free -m`")
            produced += 1
            if produced >= blocks { break }
            lines.append("```bash\nssh node-\(index) 'systemctl status app-\(index)'\n"
                         + "journalctl -u app-\(index) --since -5min | tail -40\n```")
            produced += 1
            if produced >= blocks { break }
            lines.append("| 指标 | 当前 | 阈值 |\n| --- | --- | --- |\n"
                         + "| CPU | \(40 + index % 50)% | 80% |\n"
                         + "| 内存 | \(30 + index % 60)% | 85% |\n"
                         + "| 连接 | \(100 + index) | 4096 |")
            produced += 1
        }
        return lines.joined(separator: "\n\n")
    }

    /// 一条用户消息。
    static func userText(index: Int) -> String {
        "第 \(index) 轮：node-\(index) 上的 app 又开始 5xx 了，先看一眼负载和日志，"
        + "有需要就直接跑命令。"
    }

    /// 一条已完成的工具调用（历史里每 8 条挂一个，与桌面探针同比例）。
    static func toolCalls(index: Int) -> [ToolCallState] {
        [ToolCallState(id: "call-\(index)", name: "run_command",
                       command: "journalctl -u app-\(index) --since -5min | tail -40",
                       explanation: "查看最近 5 分钟日志",
                       status: .done,
                       output: (0..<12).map { "line \($0) of tool output for \(index)" }
                           .joined(separator: "\n"),
                       exitCode: 0)]
    }

    // MARK: - 切块

    /// 把一段文本切成 `size` 字符一块的数组（最后一块可能短）。
    /// 切在**字符**边界上，不会把 Markdown 的 ``` 围栏或中文切坏成非法 UTF-8。
    static func chunks(_ text: String, size: Int = 24) -> [String] {
        guard size > 0 else { return [text] }
        var out: [String] = []
        var current = ""
        current.reserveCapacity(size)
        for ch in text {
            current.append(ch)
            if current.count >= size { out.append(current); current = "" }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// 按「节拍 × 秒数」反推需要多少块：20 chunk/s 跑 3 秒 = 60 块。
    /// 文本不够长就循环拼接，够长就截断到正好这么多块。
    static func pacedChunks(seconds: Double, chunksPerSecond: Double = 20,
                            chunkSize: Int = 24, index: Int = 0) -> [String] {
        let want = max(1, Int((seconds * chunksPerSecond).rounded()))
        var out: [String] = []
        var round = 0
        while out.count < want {
            out.append(contentsOf: chunks(assistantMarkdown(index: index + round), size: chunkSize))
            round += 1
        }
        return Array(out.prefix(want))
    }

    // MARK: - 后端

    /// 探针用的 provider（不会真的发请求 —— client 被 override 了）。
    static func provider(name: String = "Probe") -> AIProvider {
        AIProvider(name: name, kind: .anthropic,
                   baseURL: ProviderPreset.anthropicBaseURL, model: "probe-model")
    }

    /// 造一个「后端是假的、别的都是真的」`AssistantModel`。
    ///
    /// - Parameters:
    ///   - chunks: 要吐的文本块（用 `pacedChunks` 生成）。
    ///   - chunksPerSecond: 节拍。20 = 每 50ms 一块（与 `StreamingTextBuffer`
    ///     的发布间隔同频，是最贴近真实 SSE 的一档）。
    @MainActor
    static func streamingModel(chunks: [String],
                               chunksPerSecond: Double = 20)
        -> (model: AssistantModel, client: MobilePacedLLMClient) {
        let client = MobilePacedLLMClient(chunks: chunks, chunksPerSecond: chunksPerSecond)
        let model = AssistantModel(client: client, provider: provider(), apiKey: "sk-probe")
        return (model, client)
    }

    // MARK: - 历史回放

    /// 往 `context` 里造一条 `messages` 条消息的会话，并用产品自己的
    /// `AssistantModel.load(_:)` 装进模型。
    ///
    /// - Parameters:
    ///   - messages: 消息条数。真实档 200（一天的排障会话），极端档 1000。
    ///   - blocksPerMessage: 每条 assistant 回复的 Markdown 块数，默认 36。
    /// - Returns: 造出来的会话（探针要拿它的 id 做断言时用）。
    @MainActor
    @discardableResult
    static func replayHistory(into model: AssistantModel,
                              context: ModelContext,
                              messages: Int,
                              blocksPerMessage: Int = 36,
                              title: String = "probe") -> ChatSession {
        let session = ChatSession(title: title)
        context.insert(session)
        var records: [ChatMessageRecord] = []
        records.reserveCapacity(messages)
        for i in 0..<messages {
            let isUser = i % 2 == 0
            let record: ChatMessageRecord
            if isUser {
                record = ChatMessageRecord(roleRaw: "user", text: userText(index: i), orderIndex: i)
            } else {
                record = ChatMessageRecord(
                    roleRaw: "assistant",
                    text: assistantMarkdown(index: i, blocks: blocksPerMessage),
                    toolCallsJSON: i % 8 == 1 ? ChatMessageRecord.encode(toolCalls(index: i)) : "",
                    orderIndex: i)
            }
            record.session = session
            context.insert(record)
            records.append(record)
        }
        session.messages = records
        // `@Query` 那一侧要看得见，且 `load` 之后模型与库要一致 —— 必须 save。
        try? context.save()
        model.load(session)
        return session
    }
}

/// 按固定节拍吐 `LLMEvent` 的假后端。
///
/// 与 `uTermTests/Support/MockLLMClient` 的区别只有一条：那个把全部事件**一次性**
/// yield 完（测状态机用），这个**按 wall clock 一块一块吐**（测流式渲染成本用）。
/// 屏幕在「文本一直在长」的这几秒里到底掉不掉帧，只有后者量得到。
final class MobilePacedLLMClient: LLMClient, @unchecked Sendable {
    /// 依次吐出的文本块。
    let chunks: [String]
    /// 节拍（块/秒）。20 = 每 50ms 一块。
    let chunksPerSecond: Double
    /// 文本吐完后追加的工具调用（可空）。
    let trailingToolCalls: [LLMToolCall]
    /// 第二轮及以后（工具结果续轮）吐的文本块。`nil` = 复用 `chunks`。
    ///
    /// 为什么要分开：`AssistantModel` 在工具调用 resolved 之后会**自动续轮**，
    /// 再走一次 `stream(...)`。若续轮仍吐同一批 `trailingToolCalls`，就会
    /// 「批准 → 执行 → 又一张卡 → 批准 …」无限循环；若续轮仍吐几百块正文，
    /// 一条「批准到完成」的端到端读数会被续轮的时长淹掉。所以：
    /// **工具调用只在第一轮吐**，续轮走这份短脚本。
    let followUpChunks: [String]?

    private let lock = NSLock()
    private var _delivered = 0
    private var _finished = false
    private var _streams = 0

    /// 已经真的 yield 出去的块数。自证测试与探针都靠它当证人。
    var deliveredChunks: Int { lock.withLock { _delivered } }
    /// 流是否已自然结束（吐完或被取消）。
    var finished: Bool { lock.withLock { _finished } }
    /// 已投递部分拼出来的文本 —— 模型里的文本应当以它为前缀。
    var deliveredText: String {
        let n = deliveredChunks
        return chunks.prefix(n).joined()
    }

    /// 已经开过几条流（第 1 条是首轮，第 2 条起是工具结果续轮）。
    var streamCount: Int { lock.withLock { _streams } }

    init(chunks: [String], chunksPerSecond: Double = 20,
         trailingToolCalls: [LLMToolCall] = [],
         followUpChunks: [String]? = nil) {
        self.chunks = chunks
        self.chunksPerSecond = max(0.001, chunksPerSecond)
        self.trailingToolCalls = trailingToolCalls
        self.followUpChunks = followUpChunks
    }

    func stream(messages: [ChatMessage], system: String,
                config: LLMRequestConfig) -> AsyncThrowingStream<LLMEvent, Error> {
        let round = lock.withLock { () -> Int in _streams += 1; return _streams }
        let isFirst = round == 1
        let chunks = isFirst ? chunks : (followUpChunks ?? chunks)
        let interval = Duration.seconds(1.0 / chunksPerSecond)
        // 工具调用只在第一轮吐 —— 否则续轮会无限造卡片（见 `followUpChunks` 的注释）。
        let tools = isFirst ? trailingToolCalls : []
        return AsyncThrowingStream { continuation in
            // 强持有 self：Task 一定会结束（吐完或被取消），不存在环。
            let task = Task {
                for chunk in chunks {
                    if Task.isCancelled { break }
                    continuation.yield(.text(chunk))
                    self.bumpDelivered()
                    try? await Task.sleep(for: interval)
                }
                if !Task.isCancelled {
                    for call in tools { continuation.yield(.toolCall(call)) }
                }
                self.markFinished()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func bumpDelivered() { lock.withLock { _delivered += 1 } }
    private func markFinished() { lock.withLock { _finished = true } }
}

// MARK: - 假工具执行器

/// 假命令执行器：满足 `AgentCommandExecuting` 的全部契约，**可配**输出行数 / 节拍 /
/// 退出码 / 失败 / 超时 / 取消。
///
/// 它是「批准 → 执行 → 输出卡回填 → 完成态」这条链在测试里唯一的落点：
/// 产品侧 `MobileAgentChat` 经 `\.agentCommandExecutorFactory` 取执行器，
/// 探针 `.environment(\.agentCommandExecutorFactory, .stub(fake))` 换掉即可，
/// 屏幕本身不知道后端是假的。
///
/// 「按节拍回吐输出」：`run` 每 `1/linesPerSecond` 秒攒一行，`emittedLines`
/// 实时可读（探针据此断言「命令真的跑了一段时间」而不是瞬间返回）；
/// 合并后的整段输出在 `run` 返回时交出去 —— 与真实现（SSH exec 收完才回）同形，
/// 也与 `AssistantModel` 只认最终 `CommandResult` 的事实对齐。
final class MobileFakeCommandExecutor: AgentCommandExecuting, @unchecked Sendable {

    /// 这一条命令要怎么收场。
    enum Outcome: Sendable, Equatable {
        /// 正常跑完，带 `exitCode`（可为非零 —— 非零不是抛错）。
        case success
        /// 吐完 `failAfterLines` 行之后抛 `MobileFakeCommandError.failed(message)`。
        case failure(message: String, afterLines: Int)
        /// 一直不返回，直到 `timeout` 到点才抛 `MobileFakeCommandError.timedOut`。
        /// 模拟「远端挂住 / 网络黑洞」那一档。
        case timeout(after: Duration)
    }

    /// 一行输出多长（字符）。长行才让卡片里的 `ScrollView` 真的有内容量。
    let lineWidth: Int
    /// 总共吐多少行。真实档 40（一次 `journalctl | tail -40`），极端档 200
    /// （`SSHCommandExecutor.maxLines` 的默认上限）。
    let lines: Int
    /// 节拍（行/秒）。真实的一条远端命令通常几十到几百毫秒出全部输出，
    /// 探针要「执行确实占了一段墙钟」这条性质，默认 200 行/秒 ⇒ 40 行 = 200ms。
    let linesPerSecond: Double
    /// 退出码。`nil` = 哨兵没解析出来（真实现里也会发生）。
    let exitCode: Int?
    let outcome: Outcome

    private let lock = NSLock()
    private var _runCount = 0
    private var _emittedLines = 0
    private var _commands: [String] = []
    private var _cancelledRuns = 0
    private var _lastResult: CommandResult?

    /// `run` 被调过几次。
    var runCount: Int { lock.withLock { _runCount } }
    /// 最近一次 `run` 已经吐了几行（执行途中读得到 —— 这就是「节拍」的证人）。
    var emittedLines: Int { lock.withLock { _emittedLines } }
    /// 收到过的命令原文（已被 `SSHCommandExecutor` 包过的 wrapped 文本）。
    var commands: [String] { lock.withLock { _commands } }
    /// 因 `Task` 取消而提前返回的次数。
    var cancelledRuns: Int { lock.withLock { _cancelledRuns } }
    /// 最近一次成功返回的结果。
    var lastResult: CommandResult? { lock.withLock { _lastResult } }

    init(lines: Int = 40,
         lineWidth: Int = 72,
         linesPerSecond: Double = 200,
         exitCode: Int? = 0,
         outcome: Outcome = .success) {
        self.lines = max(0, lines)
        self.lineWidth = max(1, lineWidth)
        self.linesPerSecond = Swift.max(0.001, linesPerSecond)
        self.exitCode = exitCode
        self.outcome = outcome
    }

    func run(_ command: String) async throws -> CommandResult {
        lock.withLock { _runCount += 1; _emittedLines = 0; _commands.append(command) }

        if case .timeout(let after) = outcome {
            do { try await Task.sleep(for: after) }
            catch { lock.withLock { _cancelledRuns += 1 }; throw CancellationError() }
            throw MobileFakeCommandError.timedOut
        }

        let interval = Duration.seconds(1.0 / linesPerSecond)
        var body: [String] = []
        body.reserveCapacity(lines)
        let failAfter: Int? = {
            if case .failure(_, let afterLines) = outcome { return Swift.max(0, afterLines) }
            return nil
        }()

        for i in 0..<lines {
            if Task.isCancelled { lock.withLock { _cancelledRuns += 1 }; throw CancellationError() }
            body.append(Self.line(i, width: lineWidth))
            lock.withLock { _emittedLines = i + 1 }
            if let failAfter, i + 1 >= failAfter, case .failure(let message, _) = outcome {
                throw MobileFakeCommandError.failed(message)
            }
            do { try await Task.sleep(for: interval) }
            catch { lock.withLock { _cancelledRuns += 1 }; throw CancellationError() }
        }
        if case .failure(let message, let afterLines) = outcome, afterLines >= lines {
            throw MobileFakeCommandError.failed(message)
        }

        let result = CommandResult(output: body.joined(separator: "\n"), exitCode: exitCode)
        lock.withLock { _lastResult = result }
        return result
    }

    /// 契约里的「可取消」：本实现靠 `Task.isCancelled` + `Task.sleep` 抛错，
    /// 没有额外的在途句柄要断，所以这里是空实现（保留入口让探针能表达意图）。
    func cancelInFlight() async {}

    /// 一行输出：编号 + 定宽填充，好让「行数 × 行宽」这两个旋钮都真的进得了账。
    static func line(_ index: Int, width: Int) -> String {
        let head = String(format: "[%05d] ", index)
        let filler = "abcdefghijklmnopqrstuvwxyz0123456789 "
        var out = head
        while out.count < width {
            out += filler
        }
        return String(out.prefix(width))
    }
}

/// 假执行器抛出的两种错误（`AssistantModel` 会把它折成「[命令执行失败：…]」）。
enum MobileFakeCommandError: Error, LocalizedError, Equatable {
    case failed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        case .timedOut: return "命令执行超时"
        }
    }
}

// MARK: - 工具执行场景

extension MobileFakeAgent {

    /// 一次工具执行的完整剧本：**短开场白 → 一张 `run_command` 卡 → 批准后执行 →
    /// 输出回填 → 续轮收尾**。
    ///
    /// 为什么开场白要短：探针量的是「批准到完成」，首轮流式的时长只是背景噪声。
    /// 续轮（`followUpChunks`）同理，且**工具调用只在第一轮吐**，否则
    /// `AssistantModel` 的自动续轮会「执行完又造一张卡」无限循环。
    ///
    /// - Returns: `(model, client, executor)`。把 `model` 交给 `MobileAgentChat`，
    ///   把 `executor` 经 `.environment(\.agentCommandExecutorFactory, .stub(executor))`
    ///   注入，整条链就跑得起来。
    @MainActor
    static func toolCallScenario(command: String = "journalctl -u app --since -5min | tail -40",
                                 explanation: String = "查看最近 5 分钟日志",
                                 callID: String = "probe-call-1",
                                 executor: MobileFakeCommandExecutor = MobileFakeCommandExecutor(),
                                 openingChunks: Int = 8,
                                 chunksPerSecond: Double = 20)
        -> (model: AssistantModel, client: MobilePacedLLMClient, executor: MobileFakeCommandExecutor) {
        let args: [String: String] = ["command": command, "explanation": explanation]
        let json = String(data: try! JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
        let opening = Array(chunks(assistantMarkdown(index: 0, blocks: 4), size: 24).prefix(openingChunks))
        let client = MobilePacedLLMClient(
            chunks: opening.isEmpty ? ["先看一眼日志。"] : opening,
            chunksPerSecond: chunksPerSecond,
            trailingToolCalls: [LLMToolCall(id: callID, name: "run_command", argumentsJSON: json)],
            followUpChunks: ["日志里没有新的 5xx，服务已恢复。"])
        let model = AssistantModel(client: client, provider: provider(), apiKey: "sk-probe")
        model.executor = nil            // 由屏幕经注入口自己造 —— 走产品的真实构造路径
        return (model, client, executor)
    }

    /// 在 `model.messages` 里找某条工具调用的当前状态。
    @MainActor
    static func toolCall(_ model: AssistantModel, id: String) -> ToolCallState? {
        for m in model.messages {
            if let c = m.toolCalls.first(where: { $0.id == id }) { return c }
        }
        return nil
    }

    /// 轮询等待某条工具调用进入 `statuses` 之一（或超时返回 nil）。
    /// 轮询间隔 8ms —— 与探针心跳同频，不会额外占主线程。
    @MainActor
    static func waitForToolCall(_ model: AssistantModel, id: String,
                                in statuses: Set<ToolCallState.Status>,
                                timeout: Duration = .seconds(20)) async -> ToolCallState? {
        let deadline = Date().addingTimeInterval(timeout.probeSeconds)
        while Date() < deadline {
            if let call = toolCall(model, id: id), statuses.contains(call.status) { return call }
            try? await Task.sleep(for: .milliseconds(8))
        }
        return nil
    }

    /// 轮询等待状态机进入 `states` 之一。
    @MainActor
    static func waitForState(_ model: AssistantModel,
                             timeout: Duration = .seconds(30),
                             where predicate: @escaping (AssistantModel.State) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout.probeSeconds)
        while Date() < deadline {
            if predicate(model.state) { return true }
            try? await Task.sleep(for: .milliseconds(8))
        }
        return predicate(model.state)
    }
}

extension Duration {
    /// 秒（`Double`）—— 只在夹具里做超时算术用。
    /// 名字避开 `Duration.seconds(_:)` 那个静态工厂，免得读代码时看串。
    var probeSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
