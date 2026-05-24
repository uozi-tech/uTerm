import Foundation

/// `AssistantModel` 依赖的 LLM 后端抽象。每家 provider 一个实现。
/// 输出仍是文本增量——Spec B 引入 tool calling 时会升为
/// `AsyncThrowingStream<LLMEvent, Error>`，client 与 AssistantModel 同步改。
protocol LLMClient: Sendable {
    nonisolated func stream(messages: [ChatMessage],
                            system: String,
                            config: LLMRequestConfig)
        -> AsyncThrowingStream<String, Error>
}
