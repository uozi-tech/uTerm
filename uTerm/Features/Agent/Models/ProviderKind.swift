import Foundation

/// AI provider 类型。决定 LLMClientFactory 派哪个 client。
nonisolated enum ProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case anthropic     // 走 AnthropicClient
    case openai        // 走 OpenAIClient（同时盖 OpenAI 原生与兼容端点）

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai:    return "OpenAI / 兼容"
        }
    }
}

/// 各 kind 的预置 baseURL。baseURL 是 root（scheme+host，不含路径段），
/// client 各自 append 全路径。OpenAI-兼容端点（DeepSeek/Groq/Ollama/OpenRouter）
/// 按同样规则填写，如 `https://api.deepseek.com`、`http://localhost:11434`。
/// 不预置模型：可选模型一律从 provider 的 `/v1/models` 实时拉（`ProviderModelCatalog`）。
nonisolated enum ProviderPreset {
    static let anthropicBaseURL = "https://api.anthropic.com"
    static let openAIBaseURL = "https://api.openai.com"

    static func defaultBaseURL(for kind: ProviderKind) -> String {
        switch kind {
        case .anthropic: return anthropicBaseURL
        case .openai:    return openAIBaseURL
        }
    }
}
