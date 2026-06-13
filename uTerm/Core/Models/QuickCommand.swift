import Foundation
import SwiftData

/// 一条「快捷命令」：把常用运维命令存成可复用条目，绑定一台或多台服务器，
/// 一键并行执行；可选「AI 介入」。经 SwiftData + CloudKit 跨设备同步。
///
/// CloudKit 约束（与 `ServerProfile`/`ServerGroup`/`ForwardingRule` 一致）：所有存储属性
/// 须有默认值或可选，**禁** `@Attribute(.unique)`，枚举存 String rawValue。命令↔服务器
/// 用外键数组 `serverIDs`（非 `@Relationship`，仿 `ForwardingRule.serverID`）。
@Model
final class QuickCommand {
    var id: UUID = UUID()
    /// 名称（如「重启 Nginx 并健康检查」）。
    var name: String = ""
    /// 关联服务器（外键 → `ServerProfile.id`，可一台或多台 · 并行）。
    var serverIDs: [UUID] = []
    /// 执行命令（支持 `&&` 串联多条）。
    var command: String = ""
    /// AI 介入：开启后运行路由到工作区 Agent 会话。
    var aiAssisted: Bool = false
    /// 上次运行时间（展示用，相对格式化）。
    var lastRunAt: Date?
    /// 运行次数。
    var runCount: Int = 0
    var sortOrder: Int = 0
    var createdAt: Date = Date()

    /// CloudKit 要求的零参 init（所有属性已有默认值）。
    init() {}

    /// 设满全部存储字段的便利构造器。
    convenience init(name: String,
                     serverIDs: [UUID],
                     command: String,
                     aiAssisted: Bool = false,
                     sortOrder: Int = 0,
                     id: UUID = UUID(),
                     createdAt: Date = Date()) {
        self.init()
        self.id = id
        self.name = name
        self.serverIDs = serverIDs
        self.command = command
        self.aiAssisted = aiAssisted
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

/// 一次快捷命令运行的留痕。**保留近 30 天**（见 `QuickCommandStore.pruneExpiredRuns`）。
/// 命令↔运行用外键 `commandID`（仿 `ForwardingRule.serverID`）。
///
/// 每台服务器的结果与 AI 介入记录是嵌套结构，按工程既有约定（`ChatMessageRecord.toolCallsJSON`）
/// 以 **JSON 字符串**持久化（CloudKit 安全），由计算属性编解码。
@Model
final class QuickCommandRun {
    var id: UUID = UUID()
    /// 外键 → `QuickCommand.id`。
    var commandID: UUID = UUID()
    /// 执行起始时间（30 天滚动清理按此字段）。
    var startedAt: Date = Date()
    /// 总耗时（毫秒）。
    var durationMs: Int = 0
    /// `[QuickCommandServerResult]` 的 JSON。
    var resultsJSON: String = "[]"
    /// `QuickCommandAIRecord?` 的 JSON（未开启 AI 介入则为 nil）。
    var aiRecordJSON: String?

    init() {}

    convenience init(commandID: UUID,
                     startedAt: Date,
                     durationMs: Int,
                     results: [QuickCommandServerResult],
                     aiRecord: QuickCommandAIRecord? = nil,
                     id: UUID = UUID()) {
        self.init()
        self.id = id
        self.commandID = commandID
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.results = results
        self.aiRecord = aiRecord
    }

    /// 每台服务器的结果（由 `resultsJSON` 编解码）。
    var results: [QuickCommandServerResult] {
        get { (try? JSONDecoder().decode([QuickCommandServerResult].self,
                                          from: Data(resultsJSON.utf8))) ?? [] }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8)
            resultsJSON = String(decoding: data, as: UTF8.self)
        }
    }

    /// AI 介入记录（由 `aiRecordJSON` 编解码；nil 表示该次未启用 AI）。
    var aiRecord: QuickCommandAIRecord? {
        get {
            guard let json = aiRecordJSON, !json.isEmpty else { return nil }
            return try? JSONDecoder().decode(QuickCommandAIRecord.self, from: Data(json.utf8))
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                aiRecordJSON = nil
                return
            }
            aiRecordJSON = String(decoding: data, as: UTF8.self)
        }
    }

    /// 失败台数（退出码非 0 或执行报错）。
    var failureCount: Int { results.filter { !$0.ok }.count }
    /// 是否整体成功（无失败台）。
    var allSucceeded: Bool { failureCount == 0 && !results.isEmpty }
}

/// 一次运行里某台服务器的结果。`Sendable` 值类型，可跨 actor 带出执行任务组。
/// 快照服务器名 / 端点 —— 即使服务器后续被改名 / 删除，历史日志仍可读。
/// `nonisolated`：在 `QuickCommandRunner` 的并发任务组（非主线程）里构造。
nonisolated struct QuickCommandServerResult: Codable, Sendable, Identifiable, Equatable {
    /// 外键 → `ServerProfile.id`。
    var serverID: UUID
    /// 运行时刻的服务器名快照。
    var serverName: String
    /// 运行时刻的 `user@host:port` 快照（展示用）。
    var endpoint: String
    /// 退出码；执行无法建立 / 异常时为 nil。
    var exitCode: Int?
    /// 单台耗时（毫秒）。
    var durationMs: Int
    /// 是否成功（退出码 == 0）。
    var ok: Bool

    var id: UUID { serverID }
}

/// 一次运行的 AI 介入记录：诊断摘要 + 处置步骤（有序）。`Sendable` 值类型。
nonisolated struct QuickCommandAIRecord: Codable, Sendable, Equatable {
    var summary: String
    var steps: [String]
}
