import Foundation

/// Agent inspector 的轻量状态。历史消息本体存在 SwiftData `ChatSession` 中；
/// workspace 快照只记录当前会话 id 和输入框草稿。
///
/// 独立成文件（而非内联在 macOS 专属的 `WorkspaceSnapshot.swift`）：`AssistantModel`
/// 引用它，而 `AssistantModel` 同时被 macOS 与 iOS（uTermMobile）两个 target 编译——
/// `WorkspaceSnapshot.swift` 在移动端被排除，故把这个共享类型抽到此处随 `AssistantModel`
/// 一并进入移动端。
nonisolated struct AgentSnapshot: Codable, Equatable, Sendable {
    var currentSessionID: UUID?
    var input: String
}
