import AgentKit
import Foundation

/// 调用 OpenAI Chat Completions API（流式 SSE）。
/// 同时覆盖 OpenAI 原生（baseURL=https://api.openai.com）和兼容端点
/// （DeepSeek/Groq/Ollama/OpenRouter…）。这里补 "/v1/chat/completions"。
/// 请求序列化、SSE 解析与传输在 `AgentKit.LLMWireTransport`（uTable 共用）。
nonisolated struct OpenAIClient: LLMClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func request(messages: [ChatMessage], system: String, config: LLMRequestConfig) -> LLMWireRequest {
        LLMWireRequest(
            model: config.model,
            messages: ChatMessage.wireMessages(system: system, conversation: messages),
            tools: config.tools.map(\.wireSchema),
            reasoning: config.reasoning)
    }

    /// 会话编成 Chat Completions 的 `messages[]`（测试与排查用；发请求走 `request(…)`）。
    static func buildMessages(system: String, conversation: [ChatMessage]) -> [[String: Any]] {
        OpenAIWire.encodeMessages(ChatMessage.wireMessages(system: system, conversation: conversation))
    }

    nonisolated func stream(messages: [ChatMessage], system: String,
                            config: LLMRequestConfig) -> AsyncThrowingStream<LLMEvent, Error> {
        mappingWireErrors(LLMWireTransport.stream(
            Self.request(messages: messages, system: system, config: config),
            endpoint: config.wireEndpoint(for: .openAICompatible), session: session,
            idleTimeout: config.streamIdleTimeout))
    }

    var enforcesIdleTimeout: Bool { true }
}
