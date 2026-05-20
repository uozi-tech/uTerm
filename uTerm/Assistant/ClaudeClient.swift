import Foundation

/// `AssistantModel` 依赖的 AI 后端抽象 —— 便于用 `MockAssistantBackend` 单测。
protocol AssistantBackend: Sendable {
    /// 流式发送一轮对话，逐段产出助手回复的文本增量。
    func stream(messages: [ChatMessage], system: String, apiKey: String)
        -> AsyncThrowingStream<String, Error>
}

enum ClaudeClientError: Error, Equatable {
    case httpError(status: Int, body: String)
    case invalidResponse
}

/// 调用 Anthropic Claude Messages API（流式 SSE）。
nonisolated struct ClaudeClient: AssistantBackend {
    /// 默认模型标识。一个当前可用的 Claude 模型；可调整。
    static let defaultModel = "claude-sonnet-4-5"
    static let maxTokens = 2048
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func stream(messages: [ChatMessage], system: String, apiKey: String)
        -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: Self.endpoint)
                    request.httpMethod = "POST"
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.setValue("application/json", forHTTPHeaderField: "content-type")
                    let body: [String: Any] = [
                        "model": Self.defaultModel,
                        "max_tokens": Self.maxTokens,
                        "system": system,
                        "stream": true,
                        "messages": messages.map { ["role": $0.role.rawValue, "content": $0.text] },
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw ClaudeClientError.invalidResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var bodyText = ""
                        for try await line in bytes.lines { bodyText += line }
                        throw ClaudeClientError.httpError(status: http.statusCode, body: bodyText)
                    }
                    var parser = SSEParser()
                    for try await line in bytes.lines {
                        if let delta = parser.parse(line: line) {
                            continuation.yield(delta)
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
