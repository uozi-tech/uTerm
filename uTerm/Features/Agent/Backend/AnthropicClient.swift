import AgentKit
import Foundation

/// 调用 Anthropic Claude Messages API（流式 SSE）。
/// baseURL 应为 root（如 https://api.anthropic.com），这里补 "/v1/messages"。
/// 请求序列化、SSE 解析与传输在 `AgentKit.LLMWireTransport`（uTable 共用）。
nonisolated struct AnthropicClient: LLMClient {
    /// 单次回复的输出上限。原先是 2048：一份带几段代码块的排查结论就能撞线，
    /// 而且撞线后没有任何提示（见 `LLMClientError.outputLimitReached`）。
    static let maxTokens = 8192
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func request(messages: [ChatMessage], system: String, config: LLMRequestConfig) -> LLMWireRequest {
        LLMWireRequest(
            model: config.model,
            messages: ChatMessage.wireMessages(
                system: system, conversation: messages,
                replayThinking: config.reasoning?.replaysThinking ?? false),
            tools: config.tools.map(\.wireSchema),
            maxTokens: maxTokens,
            reasoning: config.reasoning)
    }

    /// 会话编成 Messages API 的 `messages[]`（测试与排查用；发请求走 `request(…)`）。
    static func buildMessages(conversation: [ChatMessage], replayThinking: Bool = false) -> [[String: Any]] {
        AnthropicWire.encodeMessages(
            ChatMessage.wireMessages(conversation: conversation, replayThinking: replayThinking),
            replayThinking: replayThinking)
    }

    nonisolated func stream(messages: [ChatMessage], system: String,
                            config: LLMRequestConfig) -> AsyncThrowingStream<LLMEvent, Error> {
        mappingWireErrors(LLMWireTransport.stream(
            Self.request(messages: messages, system: system, config: config),
            endpoint: config.wireEndpoint(for: .anthropic), session: session,
            idleTimeout: config.streamIdleTimeout))
    }

    var enforcesIdleTimeout: Bool { true }
}
