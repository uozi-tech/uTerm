import Foundation

/// 按 AIProvider.kind 派一个 LLMClient。client 是值类型、无状态，造成本可忽略。
enum LLMClientFactory {
    static func make(for provider: AIProvider) -> LLMClient {
        switch provider.kind {
        case .anthropic: return AnthropicClient()
        case .openai:    return OpenAIClient()
        }
    }
}
