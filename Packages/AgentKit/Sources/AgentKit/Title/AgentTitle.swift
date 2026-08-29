import Foundation

/// Derives a chat-history title from a prompt: first line, trimmed, truncated
/// to 24 characters with an ellipsis. Identical logic previously lived twice
/// (uTerm's `AssistantModel.deriveTitle`, uTable's `AgentChatStore.deriveTitle`).
public enum AgentTitle {
    public static func derive(from prompt: String) -> String {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count <= 24 ? trimmed : String(trimmed.prefix(24)) + "…"
    }
}
