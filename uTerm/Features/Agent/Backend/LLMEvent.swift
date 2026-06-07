import Foundation

/// LLM 流式输出的一个事件。Spec B 把 `stream` 从 `<String>` 升到 `<LLMEvent>`。
nonisolated enum LLMEvent: Sendable, Equatable {
    case text(String)            // 文本增量
    case toolCall(LLMToolCall)   // 一次完整的工具调用请求（参数已聚合完）
}

/// 模型发起的一次工具调用。
nonisolated struct LLMToolCall: Sendable, Equatable {
    let id: String              // provider 的 tool_use id / tool_call id
    let name: String            // "run_command"
    let argumentsJSON: String   // 原始 JSON 参数字符串
}
