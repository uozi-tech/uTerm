import Foundation

/// 一条聊天消息。
nonisolated struct ChatMessage: Equatable, Sendable, Identifiable {
    enum Role: String, Sendable { case user, assistant }

    let id: UUID
    let role: Role
    /// 助手消息在流式过程中逐步增长，故为 `var`。
    var text: String

    init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}
