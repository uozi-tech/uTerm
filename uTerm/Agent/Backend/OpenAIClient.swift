import Foundation

/// 调用 OpenAI Chat Completions API（流式 SSE）。
/// 同时覆盖 OpenAI 原生（baseURL=https://api.openai.com）和兼容端点
/// （DeepSeek/Groq/Ollama/OpenRouter…）。本 client append "/v1/chat/completions"。
nonisolated struct OpenAIClient: LLMClient {
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
                    let url = config.baseURL.appendingPathComponent("v1/chat/completions")
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    var msgs: [[String: Any]] = []
                    if !system.isEmpty {
                        msgs.append(["role": "system", "content": system])
                    }
                    for m in messages {
                        msgs.append(["role": m.role.rawValue, "content": m.text])
                    }
                    let body: [String: Any] = [
                        "model": config.model,
                        "stream": true,
                        "messages": msgs,
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
                    var parser = OpenAISSEParser()
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
