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
/// 任务；exec 用**非结构化** `Task` + 一次性闸门做超时（Citadel exec 流不可取消）。
@MainActor
@Observable
final class ParallelRunModel {

    /// 单台单条命令执行超时：超过即记失败收尾，避免挂死命令永久卡「执行中」。
    nonisolated static let perServerTimeout: Duration = .seconds(120)
    /// 自愈 Agent 每台最多步数（每步 = 一轮 LLM + 其工具调用），有界防失控。
    nonisolated static let maxAgentSteps = 6

    let commandName: String
    let command: String
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

    /// 已完成（resolve）的台数——每台 `runServer` 收尾时 +1，达 N 即终局。
    private var completedCount = 0
    private var running = false
    /// 单调递增的轮次号：每次 start() +1。异步的 synthesize/落库尾活捕获它，写回前比对，
    /// 丢弃被「重新运行」作废的上一轮回写（防陈旧汇总盖到新一轮）。
    private var generation = 0

    init(commandID: UUID,
         commandName: String,
         command: String,
         aiAssisted: Bool,
         targets: [ServerProfile],
         doctor: ParallelAIDoctor?,
         safety: AgentSafety,
         store: QuickCommandStore,
         container: ModelContainer) {
        self.commandID = commandID
        self.commandName = commandName
        self.command = command
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
    /// 出错后自动修复成功的台数（AI 视图橙色「已自愈」）。
    var healedCount: Int { states.filter { $0.tone == .healed }.count }
    /// 仍失败 / 需人工的台数（红色）。
    var failedCount: Int { states.filter { $0.tone == .failed }.count }
    var allDone: Bool { finishedAt != nil }

    /// 一台是否已落定——以 `tone` 为准（与 AI 泳道 / Shell spinner 判据一致）：诊断 / 续接命令
    /// 期间 tone 仍为 `.running`，故不会出现「进度条已计完成、徽标却还在转」的错位。
    private func resolved(_ s: ParallelServerState) -> Bool { s.tone != .running }

    // MARK: - 运行

    /// 启动一轮执行（幂等：运行中重复调用忽略）。视图 `.task` 里调一次。
    func start() {
        guard !running else { return }
        running = true
        generation += 1
        startedAt = Date()
        finishedAt = nil
        synthesis = ""
        completedCount = 0

        // 在 MainActor 解析每台的建连材料为 Sendable 执行器，再带进逐台任务。
        var execTargets: [ExecTarget] = []
        for profile in targets {
            let executor = try? WorkspaceCommandExecutorFactory.make(server: profile, container: container)
            execTargets.append(ExecTarget(id: profile.id,
                                          name: QuickCommandTargets.displayName(profile),
                                          endpoint: QuickCommandTargets.endpoint(profile),
                                          executor: executor))
        }
        // N 台真并发（N 通常 2–5，不另设滑动窗口）。Task 继承 MainActor：off-main 跑
        // exec/LLM，回主线程增量更新 states[index]。
        for (index, target) in execTargets.enumerated() {
            Task { await self.runServer(at: index, target: target) }
        }
    }

    /// 重新运行：重置全部台状态后再跑一轮。仅在已结束时允许（标题栏按钮也据 allDone 门禁）。
    func rerun() {
        guard finishedAt != nil else { return }
        for i in states.indices {
            states[i].status = .running
            states[i].exitCode = nil
            states[i].durationMs = nil
            states[i].lines = []
            states[i].tone = .running
            states[i].diagnosing = false
            states[i].summary = ""
            states[i].steps = []
        }
        running = false
        start()
    }

    private func runServer(at index: Int, target: ExecTarget) async {
        states[index].status = .running
        states[index].tone = .running
        states[index].lines = [ParallelTermLine(kind: .cmd, text: command)]

        // 1) 真实执行原命令。
        let start = Date()
        let result = await Self.execBounded(executor: target.executor, command: command)
        states[index].durationMs = Int(Date().timeIntervalSince(start) * 1000)
        let exit = result?.exitCode
        states[index].exitCode = exit
        states[index].lines.append(contentsOf: Self.outputLines(from: result, failed: exit != 0))
        let ok = (exit == 0)
        states[index].status = ok ? .succeeded : .failed

        // 2) 非 AI 命令：AI 视图用模板叙述，不调 LLM、不自愈。
        guard aiAssisted else {
            states[index].tone = ok ? .ok : .failed
            states[index].summary = ok
                ? "命令执行完成，退出码 0。"
                : "命令以退出码 \(exitText(exit)) 结束，执行失败。"
            finishServer()
            return
        }

        // 3) AI 命令：多步自愈 Agent 循环（无可用 provider → 退回模板叙述）。
        guard let doctor else {
            states[index].tone = ok ? .ok : .failed
            states[index].summary = ok
                ? "命令执行完成，退出码 0。"
                : "命令执行失败（退出码 \(exitText(exit))）。未配置 AI provider，无法自动诊断修复。"
            finishServer()
            return
        }
        await runAgent(at: index, target: target, doctor: doctor,
                       initialOutput: result?.output ?? "", initialExit: exit)
        finishServer()
    }

    /// 多步自愈 Agent 循环：把目标 + 初始结果交给模型，它用 `run_command` 逐条推进，每条真实结果
    /// 回喂；按安全档位决定**自动执行**还是**仅建议**。模型停止调用工具并给出结论 JSON 即收束。
    private func runAgent(at index: Int, target: ExecTarget, doctor: ParallelAIDoctor,
                         initialOutput: String, initialExit: Int?) async {
        let autoExecute = safety.autoApprovesPending
        states[index].diagnosing = (initialExit != 0)

        let system = Self.agentSystemPrompt(autoExecute: autoExecute, safetyLabel: safety.label)
        var convo: [ChatMessage] = [ChatMessage(role: .user,
            text: agentInitialPrompt(target: target, output: initialOutput, exit: initialExit))]
        var executedAny = false
        var lastExit = initialExit
        var conclusion: (status: String, summary: String)?
        var stoppedForSafety = false

        for _ in 0..<Self.maxAgentSteps {
            guard let turn = await doctor.turn(messages: convo, system: system, withTools: true) else { break }

            // 模型不再调用工具 → 这轮文本即结论。
            if turn.calls.isEmpty {
                conclusion = ParallelAIDoctor.parseConclusion(turn.text)
                    ?? (turn.text.isEmpty ? nil : (status: "", summary: turn.text))
                break
            }

            // 安全档位不允许自动执行：记录建议命令、停止，交人工确认。
            if !autoExecute {
                for call in turn.calls {
                    let st = ToolCallState(from: call)
                    guard !st.command.isEmpty else { continue }
                    states[index].steps.append("建议执行：" + stepLabel(st))
                }
                conclusion = (status: "failed",
                              summary: turn.text.isEmpty
                                ? "已诊断并给出修复建议；当前安全档位「\(safety.label)」需人工确认，未自动执行。"
                                : turn.text)
                stoppedForSafety = true
                break
            }

            // 自动执行档位：逐条在本台执行，真实输出回喂模型。
            var resolvedCalls: [ToolCallState] = []
            for call in turn.calls {
                var st = ToolCallState(from: call)
                guard !st.command.isEmpty else {
                    st.status = .failed; st.output = "(空命令)"; resolvedCalls.append(st); continue
                }
                states[index].lines.append(ParallelTermLine(kind: .cmd, text: st.command))
                let r = await Self.execBounded(executor: target.executor, command: st.command)
                let cmdExit = r?.exitCode
                states[index].lines.append(contentsOf: Self.outputLines(from: r, failed: (cmdExit ?? -1) != 0))
                st.output = r?.output ?? "（无输出或执行失败）"
                st.exitCode = cmdExit
                st.status = .done
                lastExit = cmdExit
                executedAny = true
                states[index].steps.append("执行 \(stepLabel(st)) → 退出码 \(exitText(cmdExit))")
                resolvedCalls.append(st)
            }
            convo.append(ChatMessage(role: .assistant, text: turn.text, toolCalls: resolvedCalls))
        }

        states[index].diagnosing = false
        applyConclusion(at: index, conclusion: conclusion, executedAny: executedAny,
                        lastExit: lastExit, initialExit: initialExit, stoppedForSafety: stoppedForSafety)
    }

    /// 把 Agent 结论落到该台的 `tone` / `summary`。
    private func applyConclusion(at index: Int, conclusion: (status: String, summary: String)?,
                                 executedAny: Bool, lastExit: Int?, initialExit: Int?, stoppedForSafety: Bool) {
        let status = conclusion?.status ?? ""
        let tone: ParallelLaneTone
        if stoppedForSafety {
            tone = .failed
        } else if status == "ok" {
            tone = .ok
        } else if status == "healed" {
            tone = executedAny ? .healed : .ok
        } else if status == "failed" {
            tone = .failed
        } else if !executedAny {
            tone = (initialExit == 0) ? .ok : .failed
        } else {
            tone = (lastExit == 0) ? .healed : .failed
        }
        states[index].tone = tone
        let summary = (conclusion?.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        states[index].summary = summary.isEmpty ? defaultSummary(tone: tone, exit: initialExit) : summary
    }

    /// 一台收尾：计数 +1，达 N 则终局（AI 汇总 → 落库）。
    private func finishServer() {
        completedCount += 1
        guard completedCount >= states.count else { return }
        finalize()
    }

    private func finalize() {
        finishedAt = Date()
        // 非 AI：无跨台汇总，直接落库。
        guard aiAssisted else { recordRun(); return }
        // AI 但无 provider：用模板汇总（否则视图「汇总中」spinner 永久转、汇总卡不出）。
        guard let doctor else {
            synthesis = fallbackSynthesis()
            recordRun()
            return
        }
        // AI：先取 LLM 跨台汇总，再落库——保证执行日志里的 aiRecord.summary 与窗口实时汇总一致。
        // 捕获 generation：若期间「重新运行」开了新一轮，丢弃这条陈旧回写与落库。
        let gen = generation
        let lanes = states.map { (name: $0.name, tone: $0.laneStatusText, summary: $0.summary) }
        let name = commandName
        Task {
            let text = await doctor.synthesize(commandName: name, lanes: lanes)
            guard gen == self.generation else { return }
            self.synthesis = text ?? self.fallbackSynthesis()
            self.recordRun()
        }
    }

    /// LLM 汇总不可用时的模板兜底。
    private func fallbackSynthesis() -> String {
        let healed = states.filter { $0.tone == .healed }.map(\.name)
        let failed = states.filter { $0.tone == .failed }.map(\.name)
        if failed.isEmpty && healed.isEmpty {
            return "\(total) 台全部执行成功，无异常。"
        }
        var parts: [String] = ["\(total) 台均已完成。"]
        if !healed.isEmpty { parts.append("其中 \(healed.joined(separator: "、")) 出现异常并已自动修复恢复。") }
        if !failed.isEmpty { parts.append("\(failed.joined(separator: "、")) 仍未通过，建议人工复核最近一次相关改动。") }
        return parts.joined()
    }

    /// 把本轮真实结果落为一条执行日志（含 AI 记录），同步更新命令的 lastRunAt/runCount。
    /// 复用既有 `QuickCommandRun` 模型——详情面板「执行日志」据此展示多台运行历史。
    private func recordRun() {
        let results = states.map { s in
            QuickCommandServerResult(serverID: s.id, serverName: s.name, endpoint: s.endpoint,
                                     exitCode: s.exitCode, durationMs: s.durationMs ?? 0,
                                     ok: s.tone == .ok || s.tone == .healed)
        }
        var aiRecord: QuickCommandAIRecord?
        if aiAssisted {
            let notable = states.filter { $0.tone == .healed || $0.tone == .failed }
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

    // MARK: - 提示词

    private func agentInitialPrompt(target: ExecTarget, output: String, exit: Int?) -> String {
        """
        目标：在服务器「\(target.name)」(\(target.endpoint)) 上完成下面这条命令并确认成功：
        \(command)

        这条命令的初始执行结果：
        退出码：\(exitText(exit))
        输出：
        \(output.isEmpty ? "（无输出）" : output)

        若已成功，直接给结论；若失败或需要后续步骤（例如更新后要重启服务、改完配置后要 reload 或做一次健康检查），\
        就用 run_command 工具逐条执行，每条命令我会把真实输出与退出码回给你，直到目标达成或确认无法自动修复。
        """
    }

    nonisolated static func agentSystemPrompt(autoExecute: Bool, safetyLabel: String) -> String {
        var s = """
        你是 uTerm（macOS 原生 SSH 终端）里的运维助手，正在一台服务器上自主完成一个运维目标。
        你可以用 run_command 工具逐条执行 shell 命令；每条命令我会把真实的标准输出/错误与退出码回给你。
        请像人一样按需多步操作：例如更新代码后若需要重启服务就再执行重启，改完配置后做一次校验或健康检查。
        命令要保守、最小必要，避免破坏性操作（不要 rm -rf、不要动与目标无关的服务）。
        当目标达成、或确认无法自动修复时，停止调用工具，并只输出一个 JSON 作为结论：
        {"status":"ok|healed|failed","summary":"不超过2句中文白话结论"}
        其中 ok=一开始就成功、无需修复；healed=出现问题且你已修复并验证恢复；failed=无法自动修复（说明原因与人工建议）。
        """
        if !autoExecute {
            s += "\n\n注意：当前安全档位为「\(safetyLabel)」，不允许自动执行写操作。若需要修复，请用 run_command "
                + "给出你建议执行的命令（我不会真的执行），并给出 failed 结论说明需人工确认。"
        }
        return s
    }

    // MARK: - 文案 / 解析

    private func stepLabel(_ st: ToolCallState) -> String {
        if let e = st.explanation, !e.isEmpty { return "\(e)（\(st.command)）" }
        return st.command
    }

    private func defaultSummary(tone: ParallelLaneTone, exit: Int?) -> String {
        switch tone {
        case .ok:      return "命令执行完成，退出码 0。"
        case .healed:  return "出现异常并已自动修复，现已恢复正常。"
        case .failed:  return "命令执行失败（退出码 \(exitText(exit))），未能自动修复，需人工介入。"
        case .running: return ""
        }
    }

    private func exitText(_ code: Int?) -> String { code.map(String.init) ?? "未知" }

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

    /// 带进逐台任务的 `Sendable` 目标（执行器解析失败 → executor 为 nil → 记失败）。
    private nonisolated struct ExecTarget: Sendable {
        let id: UUID
        let name: String
        let endpoint: String
        let executor: SSHCommandExecutor?
    }

    /// 执行命令；超过 `perServerTimeout` 即放弃等待（返回 nil）。用非结构化 `Task` + 一次性闸门——
    /// Citadel exec 流不可取消，结构化任务组会被挂死命令永久阻塞（详见 `QuickCommandRunner.runBounded`）。
    private nonisolated static func execBounded(executor: SSHCommandExecutor?, command: String) async -> CommandResult? {
        guard let executor else { return nil }
        let gate = OneShotGate()
        _ = Task<Void, Never> {
            let result = try? await executor.run(command)
            await gate.deliver(result)
        }
        let timer = Task<Void, Never> {
            try? await Task.sleep(for: perServerTimeout)
            await gate.deliver(nil)
        }
        let result = await gate.wait()
        timer.cancel()
        return result
    }

    /// 一次性闸门：exec 与超时谁先到谁定结果。
    private actor OneShotGate {
        private var delivered = false
        private var stored: CommandResult??
        private var waiter: CheckedContinuation<CommandResult?, Never>?

        func deliver(_ value: CommandResult?) {
            guard !delivered else { return }
            delivered = true
            if let waiter {
                waiter.resume(returning: value)
                self.waiter = nil
            } else {
                stored = .some(value)
            }
        }

        func wait() async -> CommandResult? {
            if let stored { return stored }
            return await withCheckedContinuation { waiter = $0 }
        }
    }
}
