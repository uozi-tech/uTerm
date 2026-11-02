import AgentKit
import Foundation

/// 一次 LLM 流式请求的配置。由 AssistantModel 按当前活动 provider 现造。
/// 留口：Spec B 在此处加 tools / temperature 等。
struct LLMRequestConfig: Sendable, Equatable {
    let model: String
    let baseURL: URL
    let apiKey: String
    var tools: [ToolSpec] = []
    /// 连续多久没有产出任何可消费的文本 / 工具事件，就认为 SSE 已失去进展。
    /// 这是应用层 idle timeout，不依赖 URLSession 对长连接超时的实现细节。
    var streamIdleTimeout: Duration = .seconds(60)
    /// 思考深度（已按模型折算）；nil = 不带任何思考参数，交给模型默认。
    var reasoning: AgentReasoningRequest?
}
