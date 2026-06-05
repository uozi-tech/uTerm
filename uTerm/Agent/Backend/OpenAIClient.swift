import Foundation

/// 调用 OpenAI Chat Completions API（流式 SSE）。
/// 同时覆盖 OpenAI 原生（baseURL=https://api.openai.com）和兼容端点
/// （DeepSeek/Groq/Ollama/OpenRouter…）。本 client append "/v1/chat/completions"。
nonisolated struct OpenAIClient: LLMClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 把会话历史编排成 OpenAI `messages[]`。assistant 的已完成 toolCalls 展开为
    /// assistant(tool_calls) + 每调用一条 role:tool（tool_call_id + 输出）。
    static func buildMessages(system: String, conversation: [ChatMessage]) -> [[String: Any]] {
        var msgs: [[String: Any]] = []
        if !system.isEmpty { msgs.append(["role": "system", "content": system]) }
        for m in conversation {
            if m.role == .assistant, !m.toolCalls.isEmpty {
                var a: [String: Any] = ["role": "assistant", "content": m.text]
                a["tool_calls"] = m.toolCalls.map { c in
                    ["id": c.id, "type": "function",
                     "function": ["name": c.name,
                                  "arguments": Self.argumentsJSON(for: c)]]
                }
                msgs.append(a)
                for c in m.toolCalls {
                    msgs.append(["role": "tool", "tool_call_id": c.id,
                                 "content": Self.resultContent(for: c)])
                }
            } else {
                msgs.append(["role": m.role.rawValue, "content": m.text])
            }
        }
        return msgs
    }

    static func resultContent(for c: ToolCallState) -> String {
        switch c.status {
        case .skipped: return "(用户跳过了该命令)"
        default:       return c.output ?? ""
        }
    }

    static func argumentsJSON(for c: ToolCallState) -> String {
        var obj: [String: Any] = ["command": c.command]
        if let e = c.explanation { obj["explanation"] = e }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    nonisolated func stream(messages: [ChatMessage], system: String,
                            config: LLMRequestConfig) -> AsyncThrowingStream<LLMEvent, Error> {
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = config.baseURL.appendingPathComponent("v1/chat/completions")
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    var body: [String: Any] = [
                        "model": config.model,
                        "stream": true,
                        "messages": Self.buildMessages(system: system, conversation: messages),
                    ]
                    if !config.tools.isEmpty {
                        body["tools"] = config.tools.map { $0.openAIJSON() }
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
                    var parser = OpenAISSEParser()
                    for try await line in bytes.lines {
                        for event in parser.parse(line: line) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
