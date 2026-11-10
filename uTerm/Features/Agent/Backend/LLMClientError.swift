import AgentKit
import Foundation

/// 所有 LLMClient 实现共享的错误类型。
enum LLMClientError: Error, Equatable {
    case httpError(status: Int, body: String)
    case invalidResponse
    case streamIdleTimeout
    /// 服务端在 SSE 流**内部**报错（HTTP 已经是 200）：Anthropic 的 `error` 事件、
    /// OpenAI 兼容端点的 `{"error":…}` 帧。中转网关上游过载 / 超时最常走这条。
    case streamError(String)
    /// 字节流结束了，却没等到任何收尾标记（Anthropic 的 `message_stop` / `stop_reason`，
    /// OpenAI 的 `[DONE]` / `finish_reason`）—— 连接被中途掐断，回复不完整。
    case incompleteStream
    /// 模型撞上单次输出上限（`max_tokens` / `length`），回复在半句话处被截断。
    case outputLimitReached
}

extension LLMClientError {
    /// 请求层（`AgentKit.LLMWireError`）的错误折成本应用的类型；不是请求层的错误原样返回。
    nonisolated static func map(_ error: Error) -> Error {
        guard let wire = error as? LLMWireError else { return error }
        switch wire {
        case .http(let status, let body, _): return LLMClientError.httpError(status: status, body: body)
        case .invalidResponse: return LLMClientError.invalidResponse
        case .streamIdleTimeout: return LLMClientError.streamIdleTimeout
        case .streamError(let message): return LLMClientError.streamError(message)
        case .incompleteStream: return LLMClientError.incompleteStream
        case .outputLimitReached: return LLMClientError.outputLimitReached
        }
    }
}
