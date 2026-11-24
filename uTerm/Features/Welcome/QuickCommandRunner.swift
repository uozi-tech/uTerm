import Foundation
import SwiftData

/// 快捷命令的**真实并行执行器**。对每台绑定服务器各开一条一次性 SSH exec 连接
/// （复用 Agent 的 `WorkspaceCommandExecutorFactory`），**有上限地并发**下发命令、
/// 捕获每台退出码 + 耗时，完成后经 `QuickCommandStore` 落库为执行日志。
///
/// AI 介入命令**不走**此路径 —— 由调用方路由到工作区 Agent 会话（见 `QuickCommandInbox`）。
@MainActor
@Observable
final class QuickCommandRunner {

    /// 并发上限：绑定多台时同时在飞的 SSH 连接数（避免 N 台一齐建连耗尽 fd / 抢占 NIO）。
    nonisolated static let maxConcurrent = 6
    // 单台超时交给 `SupervisedExec.runInteractive`：连续 `interactiveIdle` 没输出、或跑满
    // `interactiveMaxDuration` 才判超时并终止远端进程组。一直在刷输出的长命令不再被误杀，
    // 挂死的命令（如 `tail -f`）也不会让整个 run 永远完不成、UI 卡在「运行中…」。

    /// 单台服务器的运行态。
    enum ServerPhase: Equatable {
        case running
        case done(ok: Bool, exitCode: Int?, durationMs: Int)
    }

    /// 进行中的运行：命令 id → （服务器 id → 状态）。命令不在表中即未运行。
    private(set) var inFlight: [UUID: [UUID: ServerPhase]] = [:]

    func isRunning(_ commandID: UUID) -> Bool { inFlight[commandID] != nil }

    /// 某命令进行中的每台状态（未运行返回空）。详情面板据此显示「运行中…」实时态。
    func phases(for commandID: UUID) -> [UUID: ServerPhase] { inFlight[commandID] ?? [:] }

    /// 把建连所需输入解析成 `Sendable` 值，连同执行器一起带进并发任务。
    private nonisolated struct Target: Sendable {
        let id: UUID
        let name: String
        let endpoint: String
        let executor: SSHCommandExecutor?   // nil = 认证解析失败（缺密码 / 私钥等）
    }

    /// 真实并行执行。已在运行 / 无目标时返回 nil（不重入）。
    /// 调用方须先剔除 `sftpOnly` 主机（禁命令执行）。
    @discardableResult
    func run(_ command: QuickCommand,
             targets: [ServerProfile],
             store: QuickCommandStore,
             container: ModelContainer) async -> QuickCommandRun? {
        let commandID = command.id

        // 去重（同一台被绑定多次时只跑一次），保序。
        var seen = Set<UUID>()
        let uniqueTargets = targets.filter { seen.insert($0.id).inserted }
        guard !uniqueTargets.isEmpty, inFlight[commandID] == nil else { return nil }

        let shell = command.command
        let startedAt = Date()
        let order = uniqueTargets.map(\.id)

        // 1) 先把全部目标置 running —— UI 立即显示「运行中…」，再做（可能触发钥匙串/解锁的）
        //    认证解析建执行器，避免解析阶段 UI 无反馈。
        var initial: [UUID: ServerPhase] = [:]
        for profile in uniqueTargets { initial[profile.id] = .running }
        inFlight[commandID] = initial

        var built: [Target] = []
        for profile in uniqueTargets {
            let executor = (try? WorkspaceCommandExecutorFactory.make(server: profile, container: container))?.executor
            built.append(Target(id: profile.id,
                                 name: profile.name.isEmpty ? profile.host : profile.name,
                                 endpoint: "\(profile.username)@\(profile.host):\(profile.port)",
                                 executor: executor))
        }

        // 2) 有上限并发（滑动窗口）：先播种 cap 个，每完成一台补一台。
        var collected: [UUID: QuickCommandServerResult] = [:]
        let cap = max(1, min(Self.maxConcurrent, built.count))
        var pending = built.makeIterator()
        await withTaskGroup(of: QuickCommandServerResult.self) { group in
            var inWindow = 0
            while inWindow < cap, let target = pending.next() {
                group.addTask { await Self.execute(target, shell: shell) }
                inWindow += 1
            }
            for await result in group {
                collected[result.serverID] = result
                inFlight[commandID]?[result.serverID] = .done(ok: result.ok,
                                                              exitCode: result.exitCode,
                                                              durationMs: result.durationMs)
                if let target = pending.next() {
                    group.addTask { await Self.execute(target, shell: shell) }
                }
            }
        }

        // 3) 按命令的服务器顺序整理结果，落库。（过期清理交给启动时的 prune，不在每次运行后做。）
        let ordered = order.compactMap { collected[$0] }
        let totalMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        inFlight[commandID] = nil
        return store.recordRun(commandID: commandID,
                               startedAt: startedAt,
                               durationMs: totalMs,
                               results: ordered)
    }

    /// 单台执行（离主线程并发）：建执行器失败 / 超时 / 抛错均记为失败，不丢台。
    private nonisolated static func execute(_ target: Target, shell: String) async -> QuickCommandServerResult {
        let start = Date()
        var exitCode: Int?
        var ok = false
        if let executor = target.executor {
            if let result = await runBounded(executor: executor, shell: shell) {
                exitCode = result.exitCode
                ok = (result.exitCode == 0)
            }
        }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        return QuickCommandServerResult(serverID: target.id,
                                        serverName: target.name,
                                        endpoint: target.endpoint,
                                        exitCode: exitCode,
                                        durationMs: ms,
                                        ok: ok)
    }

    /// 在看门狗下执行命令：静默超时 / 总时长超限都返回 nil（记失败），让本次 run 能收尾。
    ///
    /// `SupervisedExec` 内部用**非结构化** `Task` 跑 exec —— 写的时候（Citadel）exec 流不可取消，结构化
    /// 任务组会在作用域退出时强制 await 子任务，会被挂死命令永久阻塞。现在 exec 响应取消，这个形态仍然成立。超时时它会先终止远端
    /// 进程组，exec 随之收到 EOF，那条 SSH 连接也就跟着释放。
    private nonisolated static func runBounded(executor: SSHCommandExecutor, shell: String) async -> CommandResult? {
        if case .completed(let result) = await SupervisedExec.runInteractive(shell, on: executor) {
            return result
        }
        return nil   // 失败与超时都当成「这台没跑成」，与旧的 `try?` 行为一致。
    }
}
