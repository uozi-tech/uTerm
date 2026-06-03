import Foundation
import SwiftData

/// 一次 AI 助手对话（会话历史的一条）。
///
/// 与 `AIProvider` 一样遵循 CloudKit 约束：所有属性带默认值、零参 `init()`、
/// 无 `.unique`，关系可选且有 inverse。消息以 `ChatMessageRecord` 一对多挂载。
@Model
final class ChatSession {
    var id: UUID = UUID()
    /// 列表里展示的标题；首次发送时从用户第一句话派生。
    var title: String = ""
    var createdAt: Date = Date()
    /// 最近一次活动时间，用于会话历史排序。
    var updatedAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \ChatMessageRecord.session)
    var messages: [ChatMessageRecord]? = nil

    init() {}

    init(title: String, id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    /// 关系本身无序，按时间还原对话顺序。
    var orderedMessages: [ChatMessageRecord] {
        (messages ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    /// 会话历史下拉里展示的预览（最后一条用户消息）。
    var preview: String {
        orderedMessages.last(where: { $0.role == .user })?.text ?? ""
    }
}

/// 持久化的一条消息。运行期用值类型 `ChatMessage` 驱动 UI / 流式，
/// 落库时映射为此 `@Model`。
@Model
final class ChatMessageRecord {
    var id: UUID = UUID()
    var roleRaw: String = ChatMessage.Role.user.rawValue
    var text: String = ""
    var createdAt: Date = Date()
    var session: ChatSession?

    init() {}

    init(role: ChatMessage.Role, text: String,
         id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.roleRaw = role.rawValue
        self.text = text
        self.createdAt = createdAt
    }

    var role: ChatMessage.Role { ChatMessage.Role(rawValue: roleRaw) ?? .user }

    var asChatMessage: ChatMessage {
        ChatMessage(id: id, role: role, text: text)
    }
}
