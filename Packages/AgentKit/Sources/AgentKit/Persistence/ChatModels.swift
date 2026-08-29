import Foundation
import SwiftData

/// One AI assistant conversation (one row of chat history).
///
/// Entity name and every field that predates this package are **frozen**:
/// this is uTerm's `ChatSession`, shipped in uTerm 1.10.0 against the CloudKit
/// container `iCloud.com.uozi.uTerm`. SwiftData/CloudKit identify a record
/// type by class name only (not by module), so moving the class into this
/// package does not by itself require a migration — renaming it would.
/// uTable's previously separate, unreleased `AgentChatSession` was renamed to
/// match when the two models were unified (see AgentKit HANDOFF notes) — it
/// never shipped, so renaming it cost nothing.
///
/// CloudKit mirroring constraints apply (checked by both apps' own schema
/// tests): every property has a default, `init()` takes no arguments, no
/// `.unique`, and relationships are optional with an explicit inverse. Fields
/// added after 1.10.0 (`scopeID`) carry defaults so lightweight migration
/// handles them for existing installs.
@Model
public final class ChatSession {
    public var id: UUID = UUID()
    /// Title shown in the history list; derived from the first message on
    /// first send.
    public var title: String = ""
    public var createdAt: Date = Date()
    /// Most recent activity time; sorts the history list.
    public var updatedAt: Date = Date()
    /// Caller-defined scope this session belongs to — e.g. uTable's
    /// connection id, so its history list can filter by active connection.
    /// uTerm has no such scoping and leaves this `nil`. Added after 1.10.0;
    /// defaults to `nil` so existing rows need no migration.
    public var scopeID: UUID? = nil

    @Relationship(deleteRule: .cascade, inverse: \ChatMessageRecord.session)
    public var messages: [ChatMessageRecord]? = nil

    public init() {}

    public init(title: String, id: UUID = UUID(), createdAt: Date = Date(), scopeID: UUID? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.scopeID = scopeID
    }

    /// The relationship itself is unordered; `orderIndex` (added after
    /// 1.10.0, defaults to 0) breaks ties within the same `createdAt`
    /// millisecond. Rows written before it existed all sort as 0, which
    /// degrades to the original createdAt-only ordering — no behavior change
    /// for uTerm's existing store.
    public var orderedMessages: [ChatMessageRecord] {
        (messages ?? []).sorted { ($0.orderIndex, $0.createdAt) < ($1.orderIndex, $1.createdAt) }
    }

    /// Second-line preview for the history list: the last user message
    /// (preferring its display alias, e.g. uTable's `/explain` shorthand,
    /// when one was recorded).
    public var preview: String {
        guard let last = orderedMessages.last(where: { $0.roleRaw == "user" }) else { return "" }
        return last.displayText.isEmpty ? last.text : last.displayText
    }
}

/// One persisted message. At runtime each app drives its own value type
/// (uTerm's `ChatMessage` + `ToolCallState`, uTable's `AgentMessage` +
/// `ToolCall`) and maps it onto this record when writing through; `toolCallsJSON`
/// is opaque to this package on purpose — the two apps encode different Codable
/// shapes into it; see each app's `ChatMessageRecord` extension for the
/// decode/encode side.
@Model
public final class ChatMessageRecord {
    public var id: UUID = UUID()
    /// "user" / "assistant" (uTerm's two roles), or "tool" (uTable's third
    /// stored role; uTerm never writes it). System prompts are never
    /// persisted — both apps rebuild them fresh each turn.
    public var roleRaw: String = "user"
    public var text: String = ""
    public var createdAt: Date = Date()
    /// JSON-encoded tool calls (assistant) — shape is app-specific and never
    /// interpreted here. Empty string means none.
    public var toolCallsJSON: String = ""
    /// The tool_call id a "tool" role message answers. Added after 1.10.0;
    /// uTerm never sets it.
    public var toolCallID: String = ""
    /// Whether a "tool" role message represents an error result. Added after
    /// 1.10.0; uTerm never sets it.
    public var isError: Bool = false
    /// Display alias for a user message (e.g. uTable's `/explain` slash
    /// command as typed, vs. the expanded prompt actually sent). Added after
    /// 1.10.0; uTerm never sets it.
    public var displayText: String = ""
    /// Stable ordering key for messages written within the same `createdAt`
    /// millisecond. Added after 1.10.0; defaults to 0 (see `orderedMessages`).
    public var orderIndex: Int = 0
    public var session: ChatSession?

    public init() {}

    public init(
        roleRaw: String,
        text: String,
        toolCallsJSON: String = "",
        toolCallID: String = "",
        isError: Bool = false,
        displayText: String = "",
        orderIndex: Int = 0,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.roleRaw = roleRaw
        self.text = text
        self.toolCallsJSON = toolCallsJSON
        self.toolCallID = toolCallID
        self.isError = isError
        self.displayText = displayText
        self.orderIndex = orderIndex
        self.createdAt = createdAt
    }
}
