import AgentKit
import Foundation

/// 一条聊天消息。
nonisolated struct ChatMessage: Equatable, Sendable, Identifiable {
    enum Role: String, Sendable { case user, assistant }

    let id: UUID
    let role: Role
    /// 助手消息在流式过程中逐步增长，故为 `var`。
    var text: String
    /// 助手消息携带的工具调用（用户/纯文本消息默认为空）。
    var toolCalls: [ToolCallState]
    /// Anthropic 回复里的 thinking 块，只为同一轮工具循环里原样回传（不展示、不落库）。
    var thinking: [LLMThinkingBlock] = []
    /// 这条用户消息是在工具循环中途并进来的（排队消息的「下一步送达」），不是新一轮的
    /// 起点：thinking 回传与上下文压缩都不把它当轮次边界。只在内存里有意义，不落库 ——
    /// 从记录恢复的会话没有在途的工具循环，也没有 thinking 可回传。
    var continuesTurn = false

    init(id: UUID = UUID(), role: Role, text: String, toolCalls: [ToolCallState] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
    }
}

/// 一条尚未发出的排队消息。类型与排队规则在 AgentKit（uTable 共用），这里只留旧名。
typealias QueuedMessage = AgentQueuedMessage
