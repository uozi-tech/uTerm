import AgentKit
import Foundation

/// LLM 流式输出的一个事件。类型现由 `AgentKit.LLMEvent` 统一定义
/// （与 uTable 共享——两边的 SSE 累积器都聚合成这一形状再 yield），本文件只
/// 收口本地名字，行为零变化。见 AgentKit HANDOFF 二期笔记。
typealias LLMEvent = AgentKit.LLMEvent

/// 模型发起的一次工具调用。同上，收口为包类型的别名。
typealias LLMToolCall = AgentKit.LLMToolCall
