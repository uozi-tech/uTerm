import Foundation

/// `AssistantModel` 依赖的 LLM 后端抽象。每家 provider 一个实现。
protocol LLMClient: Sendable {
    nonisolated func stream(messages: [ChatMessage],
                            system: String,
                            config: LLMRequestConfig)
        -> AsyncThrowingStream<LLMEvent, Error>
}
