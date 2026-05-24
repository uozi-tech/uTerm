import Foundation

/// 调用 Anthropic Claude Messages API（流式 SSE）。
/// baseURL 应为 root（如 https://api.anthropic.com），本 client append "/v1/messages"。
nonisolated struct AnthropicClient: LLMClient {
    static let maxTokens = 2048
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    nonisolated func stream(messages: [ChatMessage], system: String,
                            config: LLMRequestConfig) -> AsyncThrowingStream<String, Error> {
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
                    let body: [String: Any] = [
                        "model": config.model,
                        "max_tokens": Self.maxTokens,
                        "system": system,
                        "stream": true,
                        "messages": messages.map { ["role": $0.role.rawValue, "content": $0.text] },
                    ]
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
