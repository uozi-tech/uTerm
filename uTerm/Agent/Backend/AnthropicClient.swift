import Foundation

/// 调用 Anthropic Claude Messages API（流式 SSE）。
/// baseURL 应为 root（如 https://api.anthropic.com），本 client append "/v1/messages"。
nonisolated struct AnthropicClient: LLMClient {
    static let maxTokens = 2048
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func buildMessages(conversation: [ChatMessage]) -> [[String: Any]] {
        var msgs: [[String: Any]] = []
        for m in conversation {
            if m.role == .assistant, !m.toolCalls.isEmpty {
                var content: [[String: Any]] = []
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
                    var body: [String: Any] = [
                        "model": config.model,
                        "max_tokens": Self.maxTokens,
                        "system": system,
                        "stream": true,
                        "messages": Self.buildMessages(conversation: messages),
                    ]
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
