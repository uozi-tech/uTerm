import SwiftUI
import SwiftData

// MARK: - 状态类型（iOS 本地版，移植自 macOS ParallelRunTypes）

enum PMode: String, CaseIterable { case shell, ai }
enum PStatus: Sendable, Equatable { case running, succeeded, failed }
enum PTone: Sendable, Equatable { case running, ok, failed }

struct PLine: Identifiable, Sendable {
    enum Kind: Sendable { case cmd, out, ok, err }
    let id = UUID()
    let kind: Kind
    let text: String
}

enum PFailure { case hostKeyUntrusted(HostKeyChallenge); case connection(String) }

@MainActor
struct PServerState: Identifiable {
    let id: UUID
    let name: String
    let endpoint: String
    let endpointDisplay: String

    var status: PStatus = .running
    var exitCode: Int?
    var durationMs: Int?
    var lines: [PLine] = []

    var tone: PTone = .running
    var diagnosing = false
    var summary = ""
    var steps: [String] = []
    var failure: PFailure?

    var laneStatusText: String {
        switch tone {
        case .running: return diagnosing ? "诊断中…" : "执行中…"
        case .ok:      return "成功"
        case .failed:  return "失败"
        }
    }
    var hostKeyUntrusted: Bool {
        if case .hostKeyUntrusted = failure { return true }
        return false
    }
}

// MARK: - 并行执行控制器（移植自 macOS ParallelRunModel；iOS 默认自动执行，无安全档位）

@MainActor
@Observable
final class ParallelRunController {
    nonisolated static let perServerTimeout: Duration = .seconds(300)
    nonisolated static let maxAgentSteps = 6

    let commandName: String
    let command: String
    let intent: String
    let aiAssisted: Bool
    var mode: PMode

    private(set) var states: [PServerState]
    private(set) var startedAt = Date()
    private(set) var finishedAt: Date?
    private(set) var synthesis = ""

    private let targets: [ServerProfile]
    private let container: ModelContainer
    private let store: QuickCommandStore
    private let commandID: UUID
    private let doctor: ParallelDoctor?
    /// 按主机起执行会话的执行器。默认 `SSHParallelExecutor`（与抽协议前逐行等价的真实路径）；
    /// 探针注入假实现，整屏就能在没有真机器的情况下跑起来。
    private let executor: ParallelCommandExecuting

    private var running = false
    private var generation = 0
    private var recordOnFinalize = true
    /// 每台一条在跑的任务 —— 只为 `cancel()`（探针拆窗、将来的「中途返回就停」）留把手。
    private var laneTasks: [Task<Void, Never>] = []

    init(commandID: UUID, commandName: String, command: String, intent: String,
         aiAssisted: Bool, targets: [ServerProfile], doctor: ParallelDoctor?,
         store: QuickCommandStore, container: ModelContainer,
         executor: ParallelCommandExecuting? = nil) {
        self.commandID = commandID
        self.commandName = commandName
        self.command = command
        self.intent = intent
        self.aiAssisted = aiAssisted
        self.targets = targets
        self.doctor = doctor
        self.store = store
        self.container = container
        self.executor = executor ?? SSHParallelExecutor(container: container)
        self.mode = aiAssisted ? .ai : .shell
        self.states = targets.map {
            PServerState(id: $0.id, name: $0.name,
                         endpoint: "\($0.username)@\($0.host):\($0.port)",
                         endpointDisplay: "\($0.username)@\($0.host)")
        }
    }

    // MARK: 聚合
    var total: Int { states.count }
    var doneCount: Int { states.filter { resolved($0) }.count }
    var okCount: Int { states.filter { $0.tone == .ok }.count }
    var failedCount: Int { states.filter { $0.tone == .failed }.count }
    var allDone: Bool { finishedAt != nil }
    var broadcastIsIntent: Bool { aiAssisted && command.isEmpty && !intent.isEmpty }
    var broadcastText: String { broadcastIsIntent ? intent : command }
    private func resolved(_ s: PServerState) -> Bool { s.tone != .running }

    // MARK: 运行
    func start() {
        guard !running else { return }
        running = true
        generation += 1
        recordOnFinalize = true
        startedAt = Date()
        finishedAt = nil
        synthesis = ""
        let execTargets = targets.map { makeExecTarget(profile: $0, trustNewKeys: false) }
        laneTasks = execTargets.enumerated().map { index, target in
            Task { await self.runServer(at: index, target: target) }
        }
    }

    /// 停掉所有在跑的泳道（取消传到会话的 `run`）。**生产当前不调用** —— 关闭覆盖态后
    /// 仍跑完并记录，与抽协议前一致；这是执行器缝「可取消」那一半的落点，探针拆窗时用。
    func cancel() {
        for task in laneTasks { task.cancel() }
        laneTasks.removeAll()
    }

    func rerun() {
        guard finishedAt != nil else { return }
        for i in states.indices { resetLane(i) }
        running = false
        start()
    }

    func trustAndRetry(serverID: UUID) {
        guard let index = states.firstIndex(where: { $0.id == serverID }),
              states[index].hostKeyUntrusted,
              let profile = targets.first(where: { $0.id == serverID }) else { return }
        resetLane(index)
        finishedAt = nil
        generation += 1
        recordOnFinalize = false
        running = true
        let target = makeExecTarget(profile: profile, trustNewKeys: true)
        laneTasks.append(Task { await self.runServer(at: index, target: target) })
    }

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

    private func makeExecTarget(profile: ServerProfile, trustNewKeys: Bool) -> ExecTarget {
        ExecTarget(id: profile.id, name: profile.name,
                   endpoint: "\(profile.username)@\(profile.host):\(profile.port)",
                   session: executor.makeSession(for: profile, trustNewKeys: trustNewKeys))
    }

    /// 把「按节拍回吐的行」接回泳道。回调可能在任意线程发生，所以经由主 actor 落地；
    /// `generation` 守住 rerun / trustAndRetry 之后的迟到批次。
    private func lineSink(at index: Int, generation gen: Int,
                          counter: ParallelStreamedLineCount) -> @Sendable ([PLine]) -> Void {
        { [weak self] lines in
            guard !lines.isEmpty else { return }
            counter.add(lines.count)
            Task { @MainActor in self?.appendStreamed(lines, at: index, generation: gen) }
        }
    }

    private func appendStreamed(_ lines: [PLine], at index: Int, generation gen: Int) {
        guard gen == generation, states.indices.contains(index) else { return }
        states[index].lines.append(contentsOf: lines)
    }

    private func runServer(at index: Int, target: ExecTarget) async {
        let started = Date()
        await runLane(at: index, target: target)
        if states[index].tone != .running {
            states[index].status = (states[index].tone == .failed) ? .failed : .succeeded
        }
        if states[index].durationMs == nil {
            states[index].durationMs = Int(Date().timeIntervalSince(started) * 1000)
        }
        await target.session.close()
        finishServer()
    }

    private func runLane(at index: Int, target: ExecTarget) async {
        states[index].status = .running
        states[index].tone = .running
        states[index].lines = []
        states[index].failure = nil

        var ranInitial = false
        var initialOutput: String?
        var initialExit: Int?
        if !command.isEmpty {
            states[index].lines = [PLine(kind: .cmd, text: command)]
            let start = Date()
            let streamed = ParallelStreamedLineCount()
            let outcome = await Self.execBounded(
                session: target.session, command: command,
                onLines: lineSink(at: index, generation: generation, counter: streamed))
            states[index].durationMs = Int(Date().timeIntervalSince(start) * 1000)
            guard let result = outcome.result else {
                markUnreachable(at: index, target: target, outcome: outcome)
                return
            }
            initialExit = result.exitCode
            initialOutput = result.output
            states[index].exitCode = initialExit
            // 会话已经按节拍把行吐过一遍就别再切一次（真实 SSH 从不吐，走的还是老路）。
            if streamed.count == 0 {
                states[index].lines.append(contentsOf: Self.outputLines(from: result, failed: initialExit != 0))
            }
            if !aiAssisted {
                states[index].status = (initialExit == 0) ? .succeeded : .failed
            }
            ranInitial = true
        } else if doctor != nil {
            let start = Date()
            let probe = await Self.execBounded(session: target.session, command: "true",
                                               onLines: { _ in })
            if probe.result == nil {
                states[index].durationMs = Int(Date().timeIntervalSince(start) * 1000)
                markUnreachable(at: index, target: target, outcome: probe)
                return
            }
        }
        let ok = ranInitial && (initialExit == 0)

        guard aiAssisted else {
            states[index].tone = ok ? .ok : .failed
            states[index].summary = ok
                ? "命令执行完成，退出码 0。"
                : "命令以退出码 \(exitText(initialExit)) 结束，执行失败。"
            return
        }

        guard let doctor else {
            if ranInitial {
                states[index].tone = ok ? .ok : .failed
                states[index].summary = ok
                    ? "命令执行完成，退出码 0。"
                    : "命令执行失败（退出码 \(exitText(initialExit))）。未配置 AI provider，无法自动诊断修复。"
            } else {
                states[index].tone = .failed
                states[index].summary = "未配置 AI provider，无法按「\(goalText)」自主下发命令。请到设置里配置 AI provider。"
            }
            return
        }
        await runAgent(at: index, target: target, doctor: doctor, ranInitial: ranInitial,
                       initialOutput: initialOutput ?? "", initialExit: initialExit)
    }

    private var goalText: String {
        if !intent.isEmpty { return intent }
        if !command.isEmpty { return command }
        return commandName
    }

    /// 多步自愈 Agent 循环（iOS 默认自动执行）：模型用 run_command 逐条真实执行，输出回喂，直至结论。
    private func runAgent(at index: Int, target: ExecTarget, doctor: ParallelDoctor,
                          ranInitial: Bool, initialOutput: String, initialExit: Int?) async {
        states[index].diagnosing = ranInitial && (initialExit != 0)
        let system = Self.agentSystemPrompt()
        var convo: [ChatMessage] = [ChatMessage(role: .user,
            text: agentInitialPrompt(target: target, ranInitial: ranInitial, output: initialOutput, exit: initialExit))]
        var executedAny = false
        var lastExit = initialExit
        var conclusion: (status: String, summary: String)?

        for _ in 0..<Self.maxAgentSteps {
            guard let turn = await doctor.turn(messages: convo, system: system, withTools: true) else { break }
            if turn.calls.isEmpty {
                conclusion = ParallelDoctor.parseConclusion(turn.text)
                    ?? (turn.text.isEmpty ? nil : (status: "", summary: turn.text))
                break
            }
            var resolvedCalls: [ToolCallState] = []
            for call in turn.calls {
                var st = ToolCallState(from: call)
                guard !st.command.isEmpty else {
                    st.status = .failed; st.output = "(空命令)"; resolvedCalls.append(st); continue
                }
                states[index].lines.append(PLine(kind: .cmd, text: st.command))
                let streamed = ParallelStreamedLineCount()
                let outcome = await Self.execBounded(
                    session: target.session, command: st.command,
                    onLines: lineSink(at: index, generation: generation, counter: streamed))
                let cmdExit = outcome.result?.exitCode
                if let r = outcome.result {
                    if streamed.count == 0 {
                        states[index].lines.append(contentsOf: Self.outputLines(from: r, failed: (cmdExit ?? -1) != 0))
                    }
                    st.output = r.output
                } else {
                    let reason = outcome.timedOut
                        ? "执行超时（超过 \(Self.timeoutSeconds) 秒）"
                        : "连接失败：\(Self.connectionReason(outcome.errorText))"
                    states[index].lines.append(PLine(kind: .err, text: reason))
                    st.output = reason
                }
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
                        lastExit: lastExit, initialExit: initialExit, ranInitial: ranInitial)
    }

    private func applyConclusion(at index: Int, conclusion: (status: String, summary: String)?,
                                 executedAny: Bool, lastExit: Int?, initialExit: Int?, ranInitial: Bool) {
        let status = conclusion?.status ?? ""
        let tone: PTone
        if status == "ok" {
            tone = .ok
        } else if status == "failed" {
            tone = .failed
        } else if !executedAny {
            tone = (ranInitial && initialExit == 0) ? .ok : .failed
        } else {
            tone = (lastExit == 0) ? .ok : .failed
        }
        states[index].tone = tone
        // AI 模式无「单条等效命令」时，退出码取 Agent 最后一条真实命令的退出码（否则日志恒显示「—」）。
        if executedAny { states[index].exitCode = lastExit }
        let summary = (conclusion?.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        states[index].summary = summary.isEmpty ? defaultSummary(tone: tone, exit: ranInitial ? initialExit : lastExit) : summary
    }

    private func markUnreachable(at index: Int, target: ExecTarget, outcome: ExecOutcome) {
        states[index].status = .failed
        states[index].tone = .failed
        states[index].exitCode = nil
        if let challenge = target.session.takeHostKeyChallenge() {
            let mismatch: Bool = { if case .mismatch = challenge.kind { return true }; return false }()
            states[index].failure = .hostKeyUntrusted(challenge)
            states[index].lines.append(PLine(kind: .err, text: "主机指纹未信任，连接被拒绝"))
            states[index].summary = mismatch
                ? "无法连接：该主机的密钥与已信任的不一致（可能是服务器重装，也可能存在中间人风险）。请核对指纹，确认无误后「信任并重试」。"
                : "无法连接：尚未信任该主机的指纹。请核对指纹，确认无误后点「信任并重试」。"
        } else if outcome.timedOut {
            let reason = "连接 / 执行超时（超过 \(Self.timeoutSeconds) 秒）"
            states[index].failure = .connection(reason)
            states[index].lines.append(PLine(kind: .err, text: reason))
            states[index].summary = "\(reason)，未能确认结果。"
        } else {
            let reason = Self.connectionReason(outcome.errorText ?? target.session.setupErrorText)
            states[index].failure = .connection(reason)
            states[index].lines.append(PLine(kind: .err, text: "连接失败：\(reason)"))
            states[index].summary = "无法连接到该服务器：\(reason)。命令未执行。"
        }
    }

    private func finishServer() {
        guard states.allSatisfy({ resolved($0) }) else { return }
        finalize()
    }

    private func finalize() {
        finishedAt = Date()
        let record = recordOnFinalize
        guard aiAssisted else { if record { recordRun() }; return }
        guard let doctor else {
            synthesis = fallbackSynthesis()
            if record { recordRun() }
            return
        }
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

    private func fallbackSynthesis() -> String {
        let failed = states.filter { $0.tone == .failed }.map(\.name)
        if failed.isEmpty { return "\(total) 台全部执行成功，无异常。" }
        let okCount = total - failed.count
        return "\(total) 台中 \(okCount) 台成功，\(failed.joined(separator: "、")) 失败，建议人工复核。"
    }

    private func recordRun() {
        let results = states.map { s in
            QuickCommandServerResult(serverID: s.id, serverName: s.name, endpoint: s.endpoint,
                                     exitCode: s.exitCode, durationMs: s.durationMs ?? 0, ok: s.tone == .ok)
        }
        var aiRecord: QuickCommandAIRecord?
        if aiAssisted {
            let notable = states.filter { $0.tone == .failed }
            let summary = synthesis.isEmpty ? fallbackSynthesis() : synthesis
            aiRecord = QuickCommandAIRecord(summary: summary,
                                            steps: notable.flatMap { lane in ["\(lane.name)：\(lane.summary)"] + lane.steps })
        }
        let durationMs = Int((finishedAt ?? Date()).timeIntervalSince(startedAt) * 1000)
        store.recordRun(commandID: commandID, startedAt: startedAt, durationMs: durationMs,
                        results: results, aiRecord: aiRecord)
    }

    // MARK: 提示词
    private func agentInitialPrompt(target: ExecTarget, ranInitial: Bool, output: String, exit: Int?) -> String {
        var s = "目标（自然语言）：\(goalText)\n服务器：\(target.name)（\(target.endpoint)）\n\n"
        if ranInitial {
            s += """
            我已先执行了等效命令 `\(command)`，结果：
            退出码：\(exitText(exit))
            输出：
            \(output.isEmpty ? "（无输出）" : output)

            若已达成目标，直接给结论；若还需后续步骤（例如更新后要重启服务、改完配置后要 reload 或做一次健康检查），\
            就用 run_command 工具逐条继续，每条命令我会把真实输出与退出码回给你，直到达成或确认无法自动完成。
            """
        } else {
            s += """
            目前还没有执行任何命令。请你根据上面的「目标」，用 run_command 工具逐条执行来达成它\
            （例如「更新软件包」就执行对应包管理器的命令；按需多步：更新 → 必要时重启服务 → 做一次校验）。\
            每条命令我会把真实输出与退出码回给你，直到达成目标或确认无法自动完成。
            """
        }
        return s
    }

    nonisolated static func agentSystemPrompt() -> String {
        """
        你是 uTerm（iOS SSH 终端）里的运维助手，正在一台服务器上自主完成一个运维目标。
        你可以用 run_command 工具逐条执行 shell 命令；每条命令我会把真实的标准输出/错误与退出码回给你。
        请像人一样按需多步操作：例如更新代码后若需要重启服务就再执行重启，改完配置后做一次校验或健康检查。
        命令要保守、最小必要，避免破坏性操作（不要 rm -rf、不要动与目标无关的服务）。
        每条命令执行上限约 \(Self.timeoutSeconds) 秒，超时会被中止——但远端进程通常仍在后台继续。所以：
        - **重启必须是最后一步**：发出 reboot 等会让 SSH 立即断开，之后任何命令都会报错。把其它操作做完后再重启，且发出重启就立刻给结论（status=ok）——不要在重启后再等待或重连验证。
        - 绝不要用无限等待循环（while…sleep、tail -f、死等锁释放）——会把本台一直拖到超时。
        - dpkg/apt 锁被占用时最多有界等一次，仍不行就给 failed 结论说明建议稍后复核。
        当目标达成、或确认无法自动修复时，停止调用工具，只输出一个 JSON 作为结论：
        {"status":"ok|failed","summary":"不超过2句中文白话结论"}
        其中 ok=目标已达成，failed=无法达成（说明原因与人工建议）。只判成功或失败。
        """
    }

    // MARK: 文案 / 解析
    private func stepLabel(_ st: ToolCallState) -> String {
        if let e = st.explanation, !e.isEmpty { return "\(e)（\(st.command)）" }
        return st.command
    }
    private func defaultSummary(tone: PTone, exit: Int?) -> String {
        switch tone {
        case .ok:      return "命令执行完成，退出码 0。"
        case .failed:  return "命令执行失败（退出码 \(exitText(exit))），需人工介入。"
        case .running: return ""
        }
    }
    private func exitText(_ code: Int?) -> String { code.map(String.init) ?? "未知" }
    nonisolated static var timeoutSeconds: Int { Int(perServerTimeout.components.seconds) }
    private nonisolated static func connectionReason(_ text: String?) -> String {
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "无法建立连接" : t
    }
    nonisolated static func outputLines(from result: CommandResult?, failed: Bool) -> [PLine] {
        guard let result else { return [PLine(kind: .err, text: "连接或执行失败")] }
        if result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [PLine(kind: failed ? .err : .out, text: failed ? "（无输出）" : "done.")]
        }
        let raw = result.output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return raw.enumerated().map { idx, text in
            let isLast = idx == raw.count - 1
            return PLine(kind: failed && isLast && !text.isEmpty ? .err : .out, text: text)
        }
    }

    // MARK: 并发执行 + 超时
    private nonisolated struct ExecTarget: Sendable {
        let id: UUID
        let name: String
        let endpoint: String
        /// 这一台的执行会话（真实 SSH 或探针注入的假实现）。
        let session: ParallelExecutionSession
    }
    nonisolated struct ExecOutcome: Sendable {
        let result: CommandResult?
        let errorText: String?
        let timedOut: Bool
    }
    private enum GateOutcome: Sendable { case completed(CommandResult?); case failed(String); case timedOut }

    /// 会话建不起来（`setupErrorText != nil`）等价于抽协议前的 `executor == nil`：
    /// 不执行、`errorText` 留空，交 `markUnreachable` 用 `setupErrorText` 兜底。
    private nonisolated static func execBounded(
        session: ParallelExecutionSession, command: String,
        onLines: @escaping @Sendable ([PLine]) -> Void
    ) async -> ExecOutcome {
        guard session.setupErrorText == nil else {
            return ExecOutcome(result: nil, errorText: nil, timedOut: false)
        }
        let gate = OneShotGate()
        let work = Task<Void, Never> {
            do { await gate.deliver(.completed(try await session.run(command, onLines: onLines))) }
            catch { await gate.deliver(.failed(error.localizedDescription)) }
        }
        let timer = Task<Void, Never> {
            try? await Task.sleep(for: perServerTimeout)
            await gate.deliver(.timedOut)
        }
        // 取消传到会话（生产从不取消这一层，行为不变；`cancel()` 与探针拆窗靠它真的停下来）。
        let outcome = await withTaskCancellationHandler {
            await gate.wait()
        } onCancel: {
            work.cancel()
        }
        timer.cancel()
        switch outcome {
        case .completed(let r): return ExecOutcome(result: r, errorText: nil, timedOut: false)
        case .failed(let msg):  return ExecOutcome(result: nil, errorText: msg, timedOut: false)
        case .timedOut:         return ExecOutcome(result: nil, errorText: nil, timedOut: true)
        }
    }

    private actor OneShotGate {
        private var delivered = false
        private var stored: GateOutcome?
        private var waiter: CheckedContinuation<GateOutcome, Never>?
        func deliver(_ value: GateOutcome) {
            guard !delivered else { return }
            delivered = true
            if let waiter { waiter.resume(returning: value); self.waiter = nil } else { stored = value }
        }
        func wait() async -> GateOutcome {
            if let stored { return stored }
            return await withCheckedContinuation { waiter = $0 }
        }
    }
}
