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

    init(id: UUID = UUID(), role: Role, text: String, toolCalls: [ToolCallState] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
    }
}

/// 一条尚未发出的排队消息（Agent 忙碌时提交的待发输入）。运行期纯内存，不落库。
nonisolated struct QueuedMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String

    init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}
