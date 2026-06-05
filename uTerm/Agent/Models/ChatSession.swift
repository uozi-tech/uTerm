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
    /// 工具调用以 JSON 串落库（可选列；旧记录默认空串 → 解码为空数组，无需迁移）。
    var toolCallsJSON: String = ""
    var session: ChatSession?

    init() {}

    init(role: ChatMessage.Role, text: String, toolCalls: [ToolCallState] = [],
         id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.roleRaw = role.rawValue
        self.text = text
        self.toolCallsJSON = Self.encode(toolCalls)
        self.createdAt = createdAt
    }

    var role: ChatMessage.Role { ChatMessage.Role(rawValue: roleRaw) ?? .user }

    var toolCalls: [ToolCallState] {
        get {
            guard !toolCallsJSON.isEmpty,
                  let data = toolCallsJSON.data(using: .utf8),
                  let v = try? JSONDecoder().decode([ToolCallState].self, from: data)
            else { return [] }
            return v
        }
        set { toolCallsJSON = Self.encode(newValue) }
    }

    static func encode(_ calls: [ToolCallState]) -> String {
        guard !calls.isEmpty, let data = try? JSONEncoder().encode(calls) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    var asChatMessage: ChatMessage {
        ChatMessage(id: id, role: role, text: text, toolCalls: toolCalls)
    }
}
