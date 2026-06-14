import Foundation
import SwiftData

/// 集中所有 `QuickCommand` / `QuickCommandRun` 读写，便于内存容器单测。
/// 仿 `ServerProfileStore` / `GroupStore`（`@MainActor struct` 持 `ModelContext`）。
@MainActor
struct QuickCommandStore {
    let context: ModelContext

    /// 执行日志留存窗口（天）。超过自动清理（功能文档 §7）。
    nonisolated static let retentionDays = 30

    /// 给定参考时刻的过期临界点：`startedAt` 早于此的 run 视为过期。
    /// 纯函数，便于单测 30 天边界。
    nonisolated static func expiryCutoff(now: Date = Date(), days: Int = retentionDays) -> Date {
        now.addingTimeInterval(-Double(days) * 86_400)
    }

    func nextSortOrder() -> Int {
        let all = (try? context.fetch(FetchDescriptor<QuickCommand>())) ?? []
        return (all.map(\.sortOrder).max() ?? -1) + 1
    }

    // MARK: - CRUD

    @discardableResult
    func create(name: String, serverIDs: [UUID], command: String,
                intent: String = "", aiAssisted: Bool) -> QuickCommand {
        let cmd = QuickCommand(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                               serverIDs: serverIDs,
                               command: command.trimmingCharacters(in: .whitespacesAndNewlines),
                               intent: intent.trimmingCharacters(in: .whitespacesAndNewlines),
                               aiAssisted: aiAssisted,
                               sortOrder: nextSortOrder())
        context.insert(cmd)
        try? context.save()
        return cmd
    }

    /// 原地更新一条命令的可编辑字段。
    func update(_ cmd: QuickCommand, name: String, serverIDs: [UUID], command: String,
                intent: String = "", aiAssisted: Bool) {
        cmd.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        cmd.serverIDs = serverIDs
        cmd.command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        cmd.intent = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        cmd.aiAssisted = aiAssisted
        try? context.save()
    }

    /// 仅切 AI 介入开关（详情面板直接开 / 关）。
    func setAIAssisted(_ cmd: QuickCommand, _ on: Bool) {
        cmd.aiAssisted = on
        try? context.save()
    }

    /// 删命令：连带删它的全部执行日志（仿 `WelcomeView.deleteProfile` 连带删规则），同事务 save。
    func delete(_ cmd: QuickCommand) {
        let commandID = cmd.id
        let descriptor = FetchDescriptor<QuickCommandRun>(
            predicate: #Predicate { $0.commandID == commandID })
        for run in (try? context.fetch(descriptor)) ?? [] {
            context.delete(run)
        }
        context.delete(cmd)
        try? context.save()
    }

    // MARK: - 执行日志

    /// 某命令近 30 天的执行日志，按 `startedAt` 倒序。过滤过期记录（防御性，配合 prune）。
    func runs(for commandID: UUID, now: Date = Date()) -> [QuickCommandRun] {
        let cutoff = Self.expiryCutoff(now: now)
        let descriptor = FetchDescriptor<QuickCommandRun>(
            predicate: #Predicate { $0.commandID == commandID && $0.startedAt >= cutoff },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// 写一条执行日志 + 更新命令的 `lastRunAt` / `runCount`，同事务 save。
    @discardableResult
    func recordRun(commandID: UUID,
                   startedAt: Date,
                   durationMs: Int,
                   results: [QuickCommandServerResult],
                   aiRecord: QuickCommandAIRecord? = nil) -> QuickCommandRun {
        let run = QuickCommandRun(commandID: commandID,
                                  startedAt: startedAt,
                                  durationMs: durationMs,
                                  results: results,
                                  aiRecord: aiRecord)
        context.insert(run)
        if let cmd = try? context.fetch(
            FetchDescriptor<QuickCommand>(predicate: #Predicate { $0.id == commandID })).first {
            cmd.lastRunAt = startedAt
            cmd.runCount += 1
        }
        try? context.save()
        return run
    }

    /// 仅记录一次「调用」：更新 `lastRunAt` / `runCount`，**不**写执行日志。
    /// 用于「AI 介入」命令路由到工作区 Agent —— 真实执行在 Agent 会话里交互进行，
    /// 没有可捕获的逐台退出码，故只更新元信息、不伪造逐台日志。
    func recordInvocation(_ cmd: QuickCommand, at: Date = Date()) {
        cmd.lastRunAt = at
        cmd.runCount += 1
        try? context.save()
    }

    /// 物理删除超过 30 天的执行记录（含其 `aiRecordJSON`），确保「自动清理」语义。
    /// 幂等；启动时与每次运行后调用。
    func pruneExpiredRuns(now: Date = Date()) {
        let cutoff = Self.expiryCutoff(now: now)
        let descriptor = FetchDescriptor<QuickCommandRun>(
            predicate: #Predicate { $0.startedAt < cutoff })
        let expired = (try? context.fetch(descriptor)) ?? []
        guard !expired.isEmpty else { return }
        for run in expired { context.delete(run) }
        try? context.save()
    }
}
