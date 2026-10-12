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
