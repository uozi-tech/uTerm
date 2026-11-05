import AgentKit
import SwiftUI
import SwiftData

/// 并行执行窗口的执行 / 聚合状态机。一条快捷命令在多台服务器上**真实并行**下发：
/// 每台各开一条一次性 SSH exec 连接（复用 `WorkspaceCommandExecutorFactory`），捕获
/// 退出码 / 输出 / 耗时。两种视图共用同一次执行：
/// - **Shell**：逐台输出 + 退出码（`status`/`lines`）。
/// - **AI**：开启 AI 介入时，把目标交给 `ParallelAIDoctor` 驱动一个**多步自愈 Agent 循环**——
///   模型用 `run_command` 工具逐条执行（按安全档位 `AgentSafety` 自动执行 / 仅建议），每条真实输出
///   回喂模型，按需多步（如更新后再重启、改配置后再校验），直到达成目标或确认无法自动修复；
///   末尾产出跨台汇总。
///
/// 并发与超时范式对齐 `QuickCommandRunner`：建连输入在 `@MainActor` 解析成 `Sendable` 值带进逐台
/// 任务；exec 走 `SupervisedExec` 看门狗（按静默判卡死、总时长兜底，超时终止远端进程组）。
@MainActor
@Observable
final class ParallelRunModel {

    // 单台单条命令的超时交给 `SupervisedExec.runInteractive`：连续 `interactiveIdle` 没输出、
    // 或跑满 `interactiveMaxDuration` 才判超时。`apt upgrade` 这种刷着输出跑好几分钟的运维
    // 操作不再被一刀切误判；挂死命令也不会永久卡「执行中」。
    // 自愈 Agent 每台最多几轮、模型请求怎么重试：见 `ParallelAgentPolicy`（与 iOS 共用）。

    let commandName: String
    let command: String
    /// AI 指令（自然语言）。AI 命令的真正目标在此——`command`（等效 shell）可留空。
    let intent: String
    let aiAssisted: Bool

    var mode: ParallelViewMode
    private(set) var states: [ParallelServerState]
    private(set) var startedAt = Date()
    private(set) var finishedAt: Date?
    /// 跨服务器 AI 汇总（AI 视图末尾紫卡）。全部落定后产出。
    private(set) var synthesis: String = ""

    private let targets: [ServerProfile]
    private let container: ModelContainer
    private let store: QuickCommandStore
    private let commandID: UUID
    private let doctor: ParallelAIDoctor?
    private let safety: AgentSafety

    private var running = false
    /// 单调递增的轮次号：每次 start()/trustAndRetry() +1。异步的 synthesize/落库尾活捕获它，
    /// 写回前比对，丢弃被「重新运行」/「信任并重试」作废的上一轮回写（防陈旧汇总盖到新一轮）。
    private var generation = 0
    /// 本轮终局是否写一条新执行日志。`start()`（含 rerun）置 true；单台「信任并重试」置 false
    /// ——只更新窗口实时状态与跨台汇总，不再追加重复日志。
    private var recordOnFinalize = true

    init(commandID: UUID,
         commandName: String,
         command: String,
         intent: String,
         aiAssisted: Bool,
         targets: [ServerProfile],
         doctor: ParallelAIDoctor?,
         safety: AgentSafety,
         store: QuickCommandStore,
         container: ModelContainer) {
        self.commandID = commandID
        self.commandName = commandName
        self.command = command
        self.intent = intent
        self.aiAssisted = aiAssisted
        self.targets = targets
        self.doctor = doctor
        self.safety = safety
        self.store = store
        self.container = container
        self.mode = aiAssisted ? .ai : .shell
        self.states = targets.map {
            ParallelServerState(id: $0.id,
                                name: QuickCommandTargets.displayName($0),
                                endpoint: QuickCommandTargets.endpoint($0),
                                endpointDisplay: "\($0.username)@\($0.host)")
        }
    }

    // MARK: - 聚合（广播条 / 状态栏）

    var total: Int { states.count }
    var doneCount: Int { states.filter { resolved($0) }.count }
    var okCount: Int { states.filter { $0.tone == .ok }.count }
    /// 失败 / 需人工的台数（红色）。
    var failedCount: Int { states.filter { $0.tone == .failed }.count }
    var allDone: Bool { finishedAt != nil }

    /// 广播条展示文案：AI 命令且无等效 shell 时显示自然语言意图（无 `$`），否则显示 `$ command`。
    var broadcastIsIntent: Bool { aiAssisted && command.isEmpty && !intent.isEmpty }
    var broadcastText: String { broadcastIsIntent ? intent : command }

    /// 一台是否已落定——以 `tone` 为准（与 AI 泳道 / Shell spinner 判据一致）：诊断 / 续接命令
    /// 期间 tone 仍为 `.running`，故不会出现「进度条已计完成、徽标却还在转」的错位。
    private func resolved(_ s: ParallelServerState) -> Bool { s.tone != .running }

    // MARK: - 运行

    /// 启动一轮执行（幂等：运行中重复调用忽略）。视图 `.task` 里调一次。
    func start() {
        guard !running else { return }
        running = true
        generation += 1
        recordOnFinalize = true
        startedAt = Date()
        finishedAt = nil
        synthesis = ""

        // 在 MainActor 解析每台的建连材料为 Sendable 执行器，再带进逐台任务。
        let execTargets = targets.map { makeExecTarget(profile: $0, trustNewKeys: false) }
        // N 台真并发（N 通常 2–5，不另设滑动窗口）。Task 继承 MainActor：off-main 跑
        // exec/LLM，回主线程增量更新 states[index]。
        for (index, target) in execTargets.enumerated() {
            Task { await self.runServer(at: index, target: target) }
        }
    }

    /// 解析单台的建连材料为 `Sendable` 执行器 + host-key sink，包成逐台任务的 `ExecTarget`。
    /// `trustNewKeys` 为真时该执行器遇未知 / 不匹配密钥会**信任并继续**（「信任并重试」用）。
    /// 认证解析抛错 → executor 为 nil，原因落 `setupErrorText` 供失败提示展示。
    private func makeExecTarget(profile: ServerProfile, trustNewKeys: Bool) -> ExecTarget {
        var executor: SSHCommandExecutor?
        var sink: HostKeyChallengeSink?
        var connection: ReusableSSHConnection?
        var setupError: String?
        do {
            // reuseConnection: true —— 同台多条命令复用一条 SSH 连接、断线自动重连（健壮性）。
            let made = try WorkspaceCommandExecutorFactory.make(
                server: profile, container: container,
                trustNewKeys: trustNewKeys, reuseConnection: true)
            executor = made.executor
            sink = made.hostKeyChallenges
            connection = made.connection
        } catch {
            setupError = FriendlyError.describe(error)
        }
        return ExecTarget(id: profile.id,
                          name: QuickCommandTargets.displayName(profile),
                          endpoint: QuickCommandTargets.endpoint(profile),
                          executor: executor,
                          hostKeyChallenges: sink,
                          connection: connection,
                          setupErrorText: setupError)
    }

    /// 重新运行：重置全部台状态后再跑一轮。仅在已结束时允许（标题栏按钮也据 allDone 门禁）。
    func rerun() {
        guard finishedAt != nil else { return }
        for i in states.indices { resetLane(i) }
        running = false
        start()
    }

    /// 把单台状态清回「执行中」初值（rerun 全清 / trustAndRetry 单清共用）。
    private func resetLane(_ i: Int) {
        states[i].status = .running
        states[i].exitCode = nil
        states[i].durationMs = nil
        states[i].lines = []
        states[i].tone = .running
        states[i].diagnosing = false
        states[i].summary = ""
        states[i].steps = []
        states[i].failure = nil
    }

    /// 「信任并重试」：信任该台当前出示的主机密钥后，仅重跑这一台。用一个会信任新密钥的
    /// 执行器重建该台 —— 握手成功即把密钥写入信任库（TOFU），随后照常执行 / 自愈。
    /// 仅对「主机指纹未信任」失败可用；先匹配 `failure` 再 `resetLane`（清掉 failure）即作为
    /// 防重入闸——重置后再次点击会因 `failure` 不再是 `.hostKeyUntrusted` 而早返回。
    func trustAndRetry(serverID: UUID) {
        guard let index = states.firstIndex(where: { $0.id == serverID }),
              case .hostKeyUntrusted = states[index].failure,
              let profile = targets.first(where: { $0.id == serverID }) else { return }

        resetLane(index)
        // 重新打开终局：该台（及其它仍在重试的台）全部落定后再次 finalize 更新汇总。
        // generation +1 作废上一轮陈旧的 synthesize/落库；本次重试不写新日志。
        finishedAt = nil
        generation += 1
        recordOnFinalize = false
        running = true

        let target = makeExecTarget(profile: profile, trustNewKeys: true)
        Task { await self.runServer(at: index, target: target) }
    }

    /// 逐台入口：跑完该台 → status 与 tone 收口对齐 → 关闭其复用连接（释放资源 / 防泄漏）→ 记一台落定。
    private func runServer(at index: Int, target: ExecTarget) async {
        let started = Date()
        await runLane(at: index, target: target)
        // Shell 窗格用 status、聚合用 tone：AI 泳道（尤其 intent-only）在 runLane 里只动 tone，
        // status 会残留 .running——不收口就会出现「聚合已完成、窗格仍在运行中」的纯显示错位。
        if states[index].tone != .running {
            states[index].status = (states[index].tone == .failed) ? .failed : .succeeded
        }
        // intent-only AI 命令没有「初始命令耗时」，给个泳道总耗时，免得窗格头显示「—」。
        if states[index].durationMs == nil {
            states[index].durationMs = Int(Date().timeIntervalSince(started) * 1000)
        }
        await target.connection?.close()
        finishServer()
    }

    private func runLane(at index: Int, target: ExecTarget) async {
        states[index].status = .running
        states[index].tone = .running
        states[index].lines = []
        states[index].failure = nil

        // 1) 有等效 shell 才先真实跑一次原命令（非 AI 必有；AI 可留空）。AI 命令留空时**不**跑空命令——
        //    真正目标是自然语言 intent，交给下面的 Agent 据 intent 逐条下发。
        var ranInitial = false
        var initialOutput: String?
        var initialExit: Int?
        var initialNote: String?
        if !command.isEmpty {
            states[index].lines = [ParallelTermLine(kind: .cmd, text: command)]
            let start = Date()
            let outcome = await Self.execSupervised(executor: target.executor, command: command)
            states[index].durationMs = Int(Date().timeIntervalSince(start) * 1000)
            if let stalled = outcome.stalled, !(aiAssisted && doctor != nil) {
                // 命令跑起来了、只是卡住（或超总时长）被终止：不是连不上。纯 Shell / 没配 AI
                // 时单独收尾；AI 介入时落到下面交给 Agent 查现场接着处理。
                markStalled(at: index, stalled: stalled, message: outcome.stallMessage ?? "")
                return
            }
            if let stalled = outcome.stalled {
                let message = outcome.stallMessage ?? ""
                if !stalled.partial.output.isEmpty {
                    states[index].lines.append(contentsOf: Self.outputLines(from: stalled.partial, failed: false))
                }
                states[index].lines.append(ParallelTermLine(kind: .err, text: "执行超时：" + message))
                initialOutput = stalled.partial.output
                initialNote = ParallelRunCopy.stalledNote(message)
                ranInitial = true
            } else if let result = outcome.result {
                initialExit = result.exitCode
                initialOutput = result.output
                states[index].exitCode = initialExit
                states[index].lines.append(contentsOf: Self.outputLines(from: result, failed: initialExit != 0))
                // 非 AI：这条命令就是全部，立刻定终态。AI：后面 Agent 还要接着跑，status 先保持 .running，
                // 等整条泳道落定再按 tone 收口（见 runServer），否则 Shell 窗格会在自愈期间提前显示「完成」。
                if !aiAssisted {
                    states[index].status = (initialExit == 0) ? .succeeded : .failed
                }
                ranInitial = true
            } else {
                // 连接层失败：命令根本没跑起来。识别原因（指纹未信任 / 连接错误 / 超时），
                // 给确定性结论、暴露指纹，**不**跑 AI 自愈（连不上，自愈无意义且会让模型瞎猜）。
                markUnreachable(at: index, target: target, outcome: outcome)
                return
            }
        } else if doctor != nil {
            // AI 意图（无等效命令）：跑 Agent 前先做一次连通性预检（`true`），尽早暴露
            // 「指纹未信任 / 连不上」，否则 Agent 会对着连不上的机器空跑、并瞎猜结论。
            let start = Date()
            let probe = await Self.execSupervised(executor: target.executor, command: "true")
            if probe.result == nil {
                states[index].durationMs = Int(Date().timeIntervalSince(start) * 1000)
                markUnreachable(at: index, target: target, outcome: probe)
                return
            }
        }
        let ok = ranInitial && (initialExit == 0)

        // 2) 非 AI 命令：必有 command（表单校验），按退出码模板叙述。
        guard aiAssisted else {
            states[index].tone = ok ? .ok : .failed
            states[index].summary = ok ? ParallelRunCopy.succeeded : ParallelRunCopy.shellFailed(exit: initialExit)
            return
        }

        // 3) AI 命令：多步 Agent（无可用 provider → 退回模板叙述）。
        guard let doctor else {
            states[index].tone = ok ? .ok : .failed
            states[index].summary = ok
                ? ParallelRunCopy.succeeded
                : ParallelRunCopy.noProvider(ranInitial: ranInitial, exit: initialExit, goal: goalText)
            return
        }
        let request = ParallelAgentRequest(
            goal: goalText, command: command, serverName: target.name, endpoint: target.endpoint,
            initial: ranInitial
                ? .init(output: initialOutput ?? "", exitCode: initialExit, note: initialNote)
                : nil)
        await runAgent(at: index, target: target, doctor: doctor, request: request)
    }

    /// AI 命令交给 Agent 的自然语言目标：优先 intent，其次等效命令，再次命令名。
    private var goalText: String {
        if !intent.isEmpty { return intent }
        if !command.isEmpty { return command }
        return commandName
    }

    /// 多步 Agent：交给与 iOS 共用的 `ParallelAgentEngine`，按全局安全档位审批每条命令。
    /// 这里只负责在这台上执行命令（并把原始输出追加进 Shell 窗格），以及把进度写进泳道。
    private func runAgent(at index: Int, target: ExecTarget, doctor: ParallelAIDoctor,
                          request: ParallelAgentRequest) async {
        // 跑过初始命令且失败 → 诊断中；否则（无初始命令）显「执行中」直到 Agent 下发命令。
        states[index].diagnosing = request.initial.map { $0.exitCode != 0 } ?? false
        let engine = ParallelAgentEngine(doctor: doctor, approval: .safety(safety), host: "macOS 原生 SSH 终端")
        let outcome = await engine.run(
            request,
            execute: { command in await self.executeAgentCommand(command, at: index, target: target) },
            onEvent: { [weak self] event in self?.apply(event, at: index) })
        states[index].diagnosing = false
        states[index].tone = outcome.succeeded ? .ok : .failed
        states[index].summary = outcome.summary
    }

    /// 泳道只记文字步骤（建议 / 审批理由 / 「执行 X → 退出码 N」），不显示两步之间的动态。
    private func apply(_ event: ParallelAgentEvent, at index: Int) {
        switch event {
        case .suggested(let line), .approved(let line), .stepFinished(_, _, let line):
            states[index].steps.append(line)
        case .activity, .stepStarted:
            break
        }
    }

    /// 在这台上执行 Agent 下发的一条命令，原始输出追加进 Shell 窗格。
    private func executeAgentCommand(_ command: String, at index: Int,
                                     target: ExecTarget) async -> ParallelCommandOutcome {
        states[index].lines.append(ParallelTermLine(kind: .cmd, text: command))
        let outcome = await Self.execSupervised(executor: target.executor, command: command)
        if let r = outcome.result {
            states[index].lines.append(contentsOf: Self.outputLines(from: r, failed: (r.exitCode ?? -1) != 0))
            return .completed(r)
        }
        if let stalled = outcome.stalled {
            let reason = "执行超时：" + (outcome.stallMessage ?? "")
            if !stalled.partial.output.isEmpty {
                states[index].lines.append(contentsOf: Self.outputLines(from: stalled.partial, failed: false))
            }
            states[index].lines.append(ParallelTermLine(kind: .err, text: reason))
            return .stalled(partial: stalled.partial.output, reason: reason)
        }
        // 真实失败原因回喂模型 + 显示在原始输出里（不笼统「连接或执行失败」）。
        let reason = "连接失败：\(ParallelRunCopy.connectionReason(outcome.errorText))"
        states[index].lines.append(ParallelTermLine(kind: .err, text: reason))
        return .unreachable(reason: reason, timedOut: false)
    }

    /// 连接层失败（命令没跑起来）落定该台：识别原因、给确定性结论，并在「指纹未信任」时
    /// 记下 `HostKeyChallenge`（驱动泳道内联「信任并重试」）。**不**跑 AI 自愈。
    private func markUnreachable(at index: Int, target: ExecTarget, outcome: ExecOutcome) {
        states[index].status = .failed
        states[index].tone = .failed
        states[index].exitCode = nil

        if let challenge = target.hostKeyChallenges?.take() {
            states[index].failure = .hostKeyUntrusted(challenge)
            states[index].lines.append(ParallelTermLine(kind: .err, text: "主机指纹未信任，连接被拒绝"))
            states[index].summary = ParallelRunCopy.hostKeyUntrusted(mismatch: challenge.kind == .mismatch)
        } else if let stalled = outcome.stalled {
            // 连通性预检（`true`）都卡住：多半是连接半死不活。
            markStalled(at: index, stalled: stalled, message: outcome.stallMessage ?? "")
        } else {
            let reason = ParallelRunCopy.connectionReason(outcome.errorText ?? target.setupErrorText)
            states[index].failure = .connection(reason)
            states[index].lines.append(ParallelTermLine(kind: .err, text: "连接失败：\(reason)"))
            states[index].summary = ParallelRunCopy.unreachable(reason)
        }
    }

    /// 命令跑起来了但被看门狗判超时（静默太久 / 超总时长）并终止：把判定前的输出和原因摆出来。
    private func markStalled(at index: Int, stalled: SupervisedExec.Stalled, message: String) {
        states[index].status = .failed
        states[index].tone = .failed
        states[index].exitCode = nil
        if !stalled.partial.output.isEmpty {
            states[index].lines.append(contentsOf: Self.outputLines(from: stalled.partial, failed: false))
        }
        states[index].lines.append(ParallelTermLine(kind: .err, text: "执行超时：" + message))
        states[index].summary = ParallelRunCopy.stalled(message, signalled: stalled.kill == .signalled)
    }

    /// 一台收尾：全部台都落定（`tone != .running`）才终局（AI 汇总 → 落库）。
    /// 用「全部已落定」判据而非计数：单台「信任并重试」会把该台重置回 running，待其
    /// 重跑落定后自然再次触发终局；并发的多台重试也只在最后一台落定时收束一次。
    private func finishServer() {
        guard states.allSatisfy({ resolved($0) }) else { return }
        finalize()
    }

    private func finalize() {
        finishedAt = Date()
        let record = recordOnFinalize
        // 非 AI：无跨台汇总，直接落库。
        guard aiAssisted else { if record { recordRun() }; return }
        // AI 但无 provider：用模板汇总（否则视图「汇总中」spinner 永久转、汇总卡不出）。
        guard let doctor else {
            synthesis = fallbackSynthesis()
            if record { recordRun() }
            return
        }
        // AI：先取 LLM 跨台汇总，再落库——保证执行日志里的 aiRecord.summary 与窗口实时汇总一致。
        // 捕获 generation：若期间「重新运行」/「信任并重试」开了新一轮，丢弃这条陈旧回写与落库。
        let gen = generation
        let lanes = states.map { (name: $0.name, tone: $0.laneStatusText, summary: $0.summary) }
        let name = commandName
        Task {
            let text = await doctor.synthesize(commandName: name, lanes: lanes)
            guard gen == self.generation else { return }
            self.synthesis = text ?? self.fallbackSynthesis()
            if record { self.recordRun() }
        }
    }

    /// LLM 汇总不可用时的模板兜底（只讲成功 / 失败）。
    private func fallbackSynthesis() -> String {
        ParallelRunCopy.fallbackSynthesis(total: total, failedNames: states.filter { $0.tone == .failed }.map(\.name))
    }

    /// 把本轮真实结果落为一条执行日志（含 AI 记录），同步更新命令的 lastRunAt/runCount。
    /// 复用既有 `QuickCommandRun` 模型——详情面板「执行日志」据此展示多台运行历史。
    private func recordRun() {
        let results = states.map { s in
            QuickCommandServerResult(serverID: s.id, serverName: s.name, endpoint: s.endpoint,
                                     exitCode: s.exitCode, durationMs: s.durationMs ?? 0,
                                     ok: s.tone == .ok)
        }
        var aiRecord: QuickCommandAIRecord?
        if aiAssisted {
            let notable = states.filter { $0.tone == .failed }
            let summary = synthesis.isEmpty ? fallbackSynthesis() : synthesis
            aiRecord = QuickCommandAIRecord(summary: summary,
                                            steps: notable.flatMap { lane in
                                                ["\(lane.name)：\(lane.summary)"] + lane.steps
                                            })
        }
        let durationMs = Int((finishedAt ?? Date()).timeIntervalSince(startedAt) * 1000)
        store.recordRun(commandID: commandID, startedAt: startedAt, durationMs: durationMs,
                        results: results, aiRecord: aiRecord)
    }

    // MARK: - 文案 / 解析

    /// 把一次执行结果切成渲染用的逐行 `ParallelTermLine`。失败时末行标红。
    /// 输出为空（含纯空白）时给占位行——`"".split` 会得到 `[""]` 而非空数组，故不能靠 isEmpty 判空。
    nonisolated static func outputLines(from result: CommandResult?, failed: Bool) -> [ParallelTermLine] {
        guard let result else {
            return [ParallelTermLine(kind: .err, text: "连接或执行失败")]
        }
        if result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [ParallelTermLine(kind: failed ? .err : .out, text: failed ? "（无输出）" : "done.")]
        }
        let raw = result.output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return raw.enumerated().map { idx, text in
            let isLast = idx == raw.count - 1
            return ParallelTermLine(kind: failed && isLast && !text.isEmpty ? .err : .out, text: text)
        }
    }

    // MARK: - 并发执行器 + 超时

    /// 带进逐台任务的 `Sendable` 目标。`executor` 为 nil = 认证解析失败（原因在 `setupErrorText`）；
    /// `hostKeyChallenges` 收集建连时被拒的主机密钥指纹（驱动「信任并重试」）；
    /// `connection` 是该台复用的 SSH 连接，跑完该台后须 `close()`（防泄漏）。
    private nonisolated struct ExecTarget: Sendable {
        let id: UUID
        let name: String
        let endpoint: String
        let executor: SSHCommandExecutor?
        let hostKeyChallenges: HostKeyChallengeSink?
        let connection: ReusableSSHConnection?
        let setupErrorText: String?
    }

    /// 一次执行的归类结果：跑出结果 / 抛错（连接 / 认证失败，带原因）/ 超时。
    nonisolated struct ExecOutcome: Sendable {
        let result: CommandResult?
        /// 执行器抛出的错误描述（连接 / 认证失败）；超时与「无执行器」时为 nil。
        let errorText: String?
        /// 超时（静默太久 / 超总时长）：判定前的输出与是否已终止远端进程组。
        var stalled: SupervisedExec.Stalled?
        /// `stalled` 的一句话原因（含阈值秒数）。
        var stallMessage: String?

        var timedOut: Bool { stalled != nil }
    }

    /// 在 `SupervisedExec` 看门狗下执行并归类结果。看门狗内部用非结构化 `Task` 跑 exec
    /// （Citadel exec 流不可取消，结构化任务组会被挂死命令永久阻塞），超时先终止远端进程组。
    private nonisolated static func execSupervised(executor: SSHCommandExecutor?, command: String) async -> ExecOutcome {
        guard let executor else { return ExecOutcome(result: nil, errorText: nil) }
        switch await SupervisedExec.runInteractive(command, on: executor) {
        case .completed(let r): return ExecOutcome(result: r, errorText: nil)
        case .failed(let f):    return ExecOutcome(result: nil, errorText: f.text)
        case .stalled(let stalled):
            return ExecOutcome(
                result: nil, errorText: nil, stalled: stalled,
                stallMessage: stalled.message(limits: SupervisedExec.interactiveLimits(for: executor)))
        }
    }
}
