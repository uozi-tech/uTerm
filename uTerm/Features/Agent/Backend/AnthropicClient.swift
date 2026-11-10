import AgentKit
import Foundation

/// 调用 Anthropic Claude Messages API（流式 SSE）。
/// baseURL 应为 root（如 https://api.anthropic.com），本 client append "/v1/messages"。
nonisolated struct AnthropicClient: LLMClient {
    /// 单次回复的输出上限。原先是 2048：一份带几段代码块的排查结论就能撞线，
    /// 而且撞线后没有任何提示（见 `LLMClientError.outputLimitReached`）。
    static let maxTokens = 8192
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// - Parameter replayThinking: 开着思考时为 true —— 最后一条用户消息之后（即本轮工具
    ///   循环里）的 assistant 消息把 thinking 块原样放回最前。更早的轮次不回传：从历史前端
    ///   整段移除是 API 允许的形状，而且出站压缩会改写旧轮次，回传反而会被判签名不符。
    ///   循环中途并进来的用户消息（`continuesTurn`）不算新一轮：它前面那几步仍在本轮里，
    ///   thinking 照样回传。
    ///
    /// 紧跟在用户消息后面的用户消息并进同一条：工具结果后的那条写成
    /// `[tool_result…, text]`（tool_result 必须排在最前），不发连续两条 user。
    static func buildMessages(conversation: [ChatMessage], replayThinking: Bool = false) -> [[String: Any]] {
        var msgs: [[String: Any]] = []
        let turnStart = replayThinking
            ? (conversation.lastIndex(where: { $0.role == .user && !$0.continuesTurn }) ?? -1) + 1
            : conversation.count
        for (offset, m) in conversation.enumerated() {
            let thinking = offset >= turnStart ? m.thinking.map(\.anthropicJSON) : []
            if m.role == .assistant, !m.toolCalls.isEmpty {
                var content: [[String: Any]] = thinking
                if !m.text.isEmpty { content.append(["type": "text", "text": m.text]) }
                for c in m.toolCalls {
                    content.append(["type": "tool_use", "id": c.id, "name": c.name,
                                    "input": Self.inputObject(for: c)])
                }
                msgs.append(["role": "assistant", "content": content])
                let results: [[String: Any]] = m.toolCalls.map { c in
                    ["type": "tool_result", "tool_use_id": c.id,
                     "content": OpenAIClient.resultContent(for: c)]
                }
                msgs.append(["role": "user", "content": results])
            } else if m.role == .assistant, !thinking.isEmpty {
                var content = thinking
                if !m.text.isEmpty { content.append(["type": "text", "text": m.text]) }
                msgs.append(["role": "assistant", "content": content])
            } else if m.role == .user, let last = msgs.last, last["role"] as? String == "user" {
                var blocks = (last["content"] as? [[String: Any]])
                    ?? [["type": "text", "text": last["content"] as? String ?? ""]]
                blocks.append(["type": "text", "text": m.text])
                msgs[msgs.count - 1]["content"] = blocks
            } else {
                msgs.append(["role": m.role.rawValue, "content": m.text])
            }
        }
        return msgs
    }

    static func inputObject(for c: ToolCallState) -> [String: Any] {
        var obj: [String: Any] = ["command": c.command]
        if let e = c.explanation { obj["explanation"] = e }
        return obj
    }

    nonisolated func stream(messages: [ChatMessage], system: String,
                            config: LLMRequestConfig) -> AsyncThrowingStream<LLMEvent, Error> {
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = config.baseURL.appendingPathComponent("v1/messages")
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.setValue("application/json", forHTTPHeaderField: "content-type")
                    let reasoning = config.reasoning?.anthropicBody(baseMaxTokens: Self.maxTokens)
                    var body: [String: Any] = [
                        "model": config.model,
                        "max_tokens": reasoning?.maxTokens ?? Self.maxTokens,
                        "system": system,
                        "stream": true,
                        "messages": Self.buildMessages(
                            conversation: messages,
                            replayThinking: config.reasoning?.replaysThinking ?? false),
                    ]
                    body.merge(reasoning?.fields ?? [:]) { _, new in new }
                    if !config.tools.isEmpty {
                        body["tools"] = config.tools.map { $0.anthropicJSON() }
                    }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw LLMClientError.invalidResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var bodyText = ""
                        for try await line in bytes.lines { bodyText += line }
                        throw LLMClientError.httpError(status: http.statusCode, body: bodyText)
                    }
                    var parser = AnthropicSSEParser()
                    for try await line in bytes.lines {
                        for event in parser.parse(line: line) {
                            continuation.yield(event)
                        }
                        if let message = parser.streamError {
                            throw LLMClientError.streamError(message)
                        }
                    }
                    // EOF 不等于说完了：先看流是怎么收的尾。
                    if parser.endedEarly { throw LLMClientError.incompleteStream }
                    if parser.stopReason == "max_tokens" { throw LLMClientError.outputLimitReached }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
