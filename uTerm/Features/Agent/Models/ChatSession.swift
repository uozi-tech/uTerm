import AgentKit
import Foundation

// `ChatSession` / `ChatMessageRecord` themselves moved into the `AgentKit`
// package (shared with uTable): same `@Model` entity names and every
// pre-existing field, frozen because this is uTerm 1.10.0's already-shipped
// CloudKit schema (`iCloud.com.uozi.uTerm`) — SwiftData/CloudKit identify a
// record type by class name only, so relocating the class to a package
// doesn't itself require a migration. See `AgentKit/Persistence/ChatModels.swift`.
//
// What stays here is the app-specific decode/encode of `toolCallsJSON`: the
// package treats that column as an opaque string because uTerm encodes
// `ToolCallState` into it while uTable encodes `ToolCall` — two different
// Codable shapes the package must not know about.
extension ChatMessageRecord {
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
