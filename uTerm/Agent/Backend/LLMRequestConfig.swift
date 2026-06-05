import Foundation

/// 一次 LLM 流式请求的配置。由 AssistantModel 按当前活动 provider 现造。
/// 留口：Spec B 在此处加 tools / temperature 等。
struct LLMRequestConfig: Sendable, Equatable {
    let model: String
    let baseURL: URL
    let apiKey: String
    var tools: [ToolSpec] = []
}
