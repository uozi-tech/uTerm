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
/// - 假流吐的是 `.text` 事件。要造工具调用卡片（`MToolCall`）请用
///   `toolCallScript(...)` 直接给 `.toolCall` 事件，但**批准执行**那条路
///   （`approveAndRun`）会走 `model.executor`，而 `MobileAgentChat` 自己用
///   `WorkspaceCommandExecutorFactory.make(server:container:)` 造真执行器 ——
///   夹具能把 `model.executor` 换掉（它是 internal `var`），但屏幕的
///   `configureModel()` 只在 `executor == nil` 时才覆盖，所以**先设好再挂载**。
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

    private let lock = NSLock()
    private var _delivered = 0
    private var _finished = false

    /// 已经真的 yield 出去的块数。自证测试与探针都靠它当证人。
    var deliveredChunks: Int { lock.withLock { _delivered } }
    /// 流是否已自然结束（吐完或被取消）。
    var finished: Bool { lock.withLock { _finished } }
    /// 已投递部分拼出来的文本 —— 模型里的文本应当以它为前缀。
    var deliveredText: String {
        let n = deliveredChunks
        return chunks.prefix(n).joined()
    }

    init(chunks: [String], chunksPerSecond: Double = 20,
         trailingToolCalls: [LLMToolCall] = []) {
        self.chunks = chunks
        self.chunksPerSecond = max(0.001, chunksPerSecond)
        self.trailingToolCalls = trailingToolCalls
    }

    func stream(messages: [ChatMessage], system: String,
                config: LLMRequestConfig) -> AsyncThrowingStream<LLMEvent, Error> {
        let chunks = chunks
        let interval = Duration.seconds(1.0 / chunksPerSecond)
        let tools = trailingToolCalls
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
