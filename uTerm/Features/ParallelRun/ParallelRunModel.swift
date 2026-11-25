import Foundation
import Observation
import SwiftData

/// 并行执行的执行 / 聚合状态机，macOS 并行执行窗口与 iOS 并行执行页共用（两个 target 都编）。
/// 一条快捷命令在多台服务器上**真实并行**下发：先按顺序为每台开好执行会话（认证材料在主线程外读），
/// 再一起起泳道，捕获退出码 / 输出 / 耗时。两种视图共用同一次执行：
/// - **Shell**：逐台输出 + 退出码（`status` / `lines`）。
/// - **AI**：开启 AI 介入时把目标交给 `ParallelAgentEngine` 跑多步自愈 Agent，末尾产出跨台汇总。
///
/// 两端的差异全是参数：`approval`（macOS 按全局 `AgentSafety` 审批，iOS 不审批）、
/// `hostLabel`（写进提示词的终端描述）、`executor`（默认真实 SSH，测试 / 探针注入假实现）。
/// iOS 只画结构化步骤 `agentSteps` 与当前动作 `activity`；macOS 不画这两项。
@MainActor
@Observable
final class ParallelRunModel {
    /// 单条命令的超时由会话里的 `SupervisedExec` 看门狗管（按静默判、总时长兜底，超时终止
    /// 远端进程组，抛 `ParallelExecutionStalled`）。这个计时器只是再外一层的兜底：会话自己
    /// 挂死（假会话、将来别的实现）时也保证泳道能收尾。比看门狗的总时长上限宽，正常到不了。
    nonisolated static let backstopTimeout: Duration = SupervisedExec.interactiveMaxDuration + .seconds(60)

    let commandName: String
    let command: String
    let intent: String
    let aiAssisted: Bool
    var mode: ParallelViewMode

    private(set) var states: [ParallelServerState]
    private(set) var startedAt = Date()
    private(set) var finishedAt: Date?
    private(set) var synthesis = ""

    private let targets: [ServerProfile]
    private let container: ModelContainer
    private let store: QuickCommandStore
    private let commandID: UUID
    private let doctor: ParallelAIDoctor?
    /// 模型下发的命令执行前过不过闸（macOS `.safety(全局档位)` / iOS `.unrestricted`）。
    private let approval: ParallelAgentApproval
    /// 提示词里对执行环境的描述（「macOS 原生 SSH 终端」/「iOS SSH 终端」）。
    private let hostLabel: String
    /// 按主机起执行会话的执行器。默认 `SSHParallelExecutor`（与抽协议前逐行等价的真实路径）；
    /// 探针注入假实现，整屏就能在没有真机器的情况下跑起来。
    private let executor: ParallelCommandExecuting

    private var running = false
    private var generation = 0
    private var recordOnFinalize = true
    /// 每台一条在跑的任务 —— 只为 `cancel()`（探针拆窗、将来的「中途返回就停」）留把手。
    private var laneTasks: [Task<Void, Never>] = []
    /// 「加密方式变弱了」卡片上点「仍然连接并重试」时记下同意的地方（测试换成单独的一份）。
    var legacyConsent: LegacyAlgorithmConsent = .shared

    init(commandID: UUID, commandName: String, command: String, intent: String,
         aiAssisted: Bool, targets: [ServerProfile], doctor: ParallelAIDoctor?,
         approval: ParallelAgentApproval, hostLabel: String,
         store: QuickCommandStore, container: ModelContainer,
         executor: ParallelCommandExecuting? = nil) {
        self.commandID = commandID
        self.commandName = commandName
        self.command = command
        self.intent = intent
        self.aiAssisted = aiAssisted
        self.targets = targets
        self.doctor = doctor
        self.approval = approval
        self.hostLabel = hostLabel
        self.store = store
        self.container = container
        self.executor = executor ?? SSHParallelExecutor(container: container)
        self.mode = aiAssisted ? .ai : .shell
        self.states = targets.map {
            ParallelServerState(id: $0.id,
                                name: QuickCommandTargets.displayName($0),
                                endpoint: QuickCommandTargets.endpoint($0),
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
    private func resolved(_ s: ParallelServerState) -> Bool { s.tone != .running }

    // MARK: 运行
    func start() {
        guard !running else { return }
        running = true
        generation += 1
        recordOnFinalize = true
        startedAt = Date()
        finishedAt = nil
        synthesis = ""
        let gen = generation
        // 先按顺序把各台的会话开好（认证材料要读钥匙串，不在主线程上），再一起起泳道。
        laneTasks = [Task {
            var execTargets: [ExecTarget] = []
            for profile in targets {
                execTargets.append(await makeExecTarget(profile: profile, trustNewKeys: false))
            }
            guard !Task.isCancelled, gen == generation else { return }
            laneTasks += execTargets.enumerated().map { index, target in
                Task { await self.runServer(at: index, target: target) }
            }
        }]
    }

    /// 停掉所有在跑的泳道（取消传到会话的 `run`）。**生产当前不调用** —— 关掉页面 / 窗口后
    /// 仍跑完并记录；这是执行器缝「可取消」那一半的落点，探针拆窗时用。
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
              case .hostKeyUntrusted(let challenge)? = states[index].failure,
              let profile = targets.first(where: { $0.id == serverID }) else { return }
        // 加密方式变弱了：用户在卡片上同意了，记下同意，照常（不信任新密钥）重连——之后主机密钥要是也变了，
        // 还会再出一张主机密钥的卡片，不会被这一下顺手放过去。
        let weakAlgorithms = challenge.isWeakAlgorithms
        if weakAlgorithms { legacyConsent.insert(host: challenge.host, port: challenge.port) }
        // 首轮已经收尾、落过日志，补跑这一台才不再记第二条；首轮还在跑（别的台还没完）时
        // 点的，照常在最终收尾时记一次——改前一律置 false，整次运行就从日志里消失了。
        if finishedAt != nil { recordOnFinalize = false }
        resetLane(index)
        finishedAt = nil
        generation += 1
        running = true
        laneTasks.append(Task {
            let target = await makeExecTarget(profile: profile, trustNewKeys: !weakAlgorithms)
            await self.runServer(at: index, target: target)
        })
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
        states[i].agentSteps = []
        states[i].activity = nil
        states[i].failure = nil
    }

    private func makeExecTarget(profile: ServerProfile, trustNewKeys: Bool) async -> ExecTarget {
        let session = await executor.makeSession(for: profile, trustNewKeys: trustNewKeys)
        return ExecTarget(id: profile.id, name: QuickCommandTargets.displayName(profile),
                          endpoint: QuickCommandTargets.endpoint(profile),
                          session: session)
    }

    /// 把「按节拍回吐的行」接回泳道。回调可能在任意线程发生，所以经由主 actor 落地；
    /// `generation` 守住 rerun / trustAndRetry 之后的迟到批次。
    private func lineSink(at index: Int, generation gen: Int,
                          counter: ParallelStreamedLineCount) -> @Sendable ([ParallelTermLine]) -> Void {
        { [weak self] lines in
            guard !lines.isEmpty else { return }
            counter.add(lines.count)
            Task { @MainActor in self?.appendStreamed(lines, at: index, generation: gen) }
        }
    }

    private func appendStreamed(_ lines: [ParallelTermLine], at index: Int, generation gen: Int) {
        guard gen == generation, states.indices.contains(index) else { return }
        states[index].lines.append(contentsOf: lines)
    }

    private func runServer(at index: Int, target: ExecTarget) async {
        let started = Date()
        await runLane(at: index, target: target)
        states[index].activity = nil
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
        var initialNote: String?
        if !command.isEmpty {
            states[index].lines = [ParallelTermLine(kind: .cmd, text: command)]
            states[index].activity = String(localized: "正在执行 \(command)")
            let start = Date()
            let streamed = ParallelStreamedLineCount()
            let outcome = await Self.execBounded(
                session: target.session, command: command,
                onLines: lineSink(at: index, generation: generation, counter: streamed))
            states[index].durationMs = Int(Date().timeIntervalSince(start) * 1000)
            if let stall = outcome.stall {
                // 命令跑起来了、只是卡住（或超总时长）被终止：不是连不上。纯 Shell / 没配 AI 时
                // 直接收尾；AI 介入时交给 Agent 查现场接着处理（dpkg 半完成、锁残留这类，
                // 改前一律交人工，用户看到的就是「一遇到错误就退出」）。
                guard aiAssisted, doctor != nil else {
                    markStalled(at: index, stall: stall, streamed: streamed.count > 0)
                    return
                }
                let partial = stall.stalled.partial
                if streamed.count == 0, !partial.output.isEmpty {
                    states[index].lines.append(contentsOf: Self.outputLines(from: partial, failed: false))
                }
                states[index].lines.append(ParallelTermLine(kind: .err, text: String(localized: "执行超时：\(stall.message)")))
                initialOutput = partial.output
                initialNote = ParallelRunCopy.stalledNote(stall.message)
                ranInitial = true
            } else if let result = outcome.result {
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
            } else {
                markUnreachable(at: index, target: target, outcome: outcome)
                return
            }
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
            states[index].summary = ok ? ParallelRunCopy.succeeded : ParallelRunCopy.shellFailed(exit: initialExit)
            return
        }

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

    private var goalText: String {
        if !intent.isEmpty { return intent }
        if !command.isEmpty { return command }
        return commandName
    }

    /// 多步 Agent：交给共享的 `ParallelAgentEngine`，按 `approval` 审批每条命令。这里只负责在这台上
    /// 执行命令（并把原始输出追加进 Shell 视图），以及把进度写进泳道（文字步骤 + 结构化步骤 + 当前动作）。
    private func runAgent(at index: Int, target: ExecTarget, doctor: ParallelAIDoctor,
                          request: ParallelAgentRequest) async {
        states[index].diagnosing = request.initial.map { $0.exitCode != 0 } ?? false
        let engine = ParallelAgentEngine(doctor: doctor, approval: approval, host: hostLabel)
        let outcome = await engine.run(
            request,
            execute: { command in await self.executeAgentCommand(command, at: index, target: target) },
            onEvent: { [weak self] event in self?.apply(event, at: index) })
        states[index].diagnosing = false
        states[index].activity = nil
        states[index].tone = outcome.succeeded ? .ok : .failed
        states[index].summary = outcome.summary
        // 没有「单条等效命令」时，退出码取 Agent 最后一条真实命令的（否则日志恒显示「—」）。
        if outcome.executedAny { states[index].exitCode = outcome.lastExit }
    }

    private func apply(_ event: ParallelAgentEvent, at index: Int) {
        guard states.indices.contains(index) else { return }
        switch event {
        case .activity(let text):
            // 重试提示可能在泳道落定后才到，落定了就不写。
            if states[index].tone == .running { states[index].activity = text }
        case .suggested(let line), .approved(let line):
            states[index].steps.append(line)
        case .stepStarted(_, let command, let explanation):
            states[index].agentSteps.append(ParallelAgentStep(command: command, explanation: explanation))
        case .stepFinished(let i, let outcome, let line):
            states[index].steps.append(line)
            guard states[index].agentSteps.indices.contains(i) else { return }
            switch outcome {
            case .completed(let r):
                states[index].agentSteps[i].state = r.exitCode == 0 ? .ok : .failed
                states[index].agentSteps[i].exitCode = r.exitCode
            case .stalled:
                states[index].agentSteps[i].state = .timedOut
            case .unreachable(_, let timedOut):
                states[index].agentSteps[i].state = timedOut ? .timedOut : .failed
            }
        }
    }

    /// 在这台上执行 Agent 下发的一条命令。会话按节拍回吐的行直接进 Shell 卡片；真实 SSH 不回吐，
    /// 跑完再切行。
    private func executeAgentCommand(_ command: String, at index: Int,
                                     target: ExecTarget) async -> ParallelCommandOutcome {
        states[index].lines.append(ParallelTermLine(kind: .cmd, text: command))
        let streamed = ParallelStreamedLineCount()
        let outcome = await Self.execBounded(
            session: target.session, command: command,
            onLines: lineSink(at: index, generation: generation, counter: streamed))
        if let r = outcome.result {
            if streamed.count == 0 {
                states[index].lines.append(contentsOf: Self.outputLines(from: r, failed: (r.exitCode ?? -1) != 0))
            }
            return .completed(r)
        }
        if let stall = outcome.stall {
            let partial = stall.stalled.partial
            let reason = String(localized: "执行超时：\(stall.message)")
            if streamed.count == 0, !partial.output.isEmpty {
                states[index].lines.append(contentsOf: Self.outputLines(from: partial, failed: false))
            }
            states[index].lines.append(ParallelTermLine(kind: .err, text: reason))
            return .stalled(partial: partial.output, reason: reason)
        }
        let reason = outcome.timedOut
            ? String(localized: "执行超时（超过 \(Self.backstopSeconds) 秒仍无结果）")
            : String(localized: "连接失败：\(ParallelRunCopy.connectionReason(outcome.errorText))")
        states[index].lines.append(ParallelTermLine(kind: .err, text: reason))
        return .unreachable(reason: reason, timedOut: outcome.timedOut)
    }

    private func markUnreachable(at index: Int, target: ExecTarget, outcome: ExecOutcome) {
        states[index].status = .failed
        states[index].tone = .failed
        states[index].exitCode = nil
        if let challenge = target.session.takeHostKeyChallenge() {
            states[index].failure = .hostKeyUntrusted(challenge)
            switch challenge.kind {
            case .weakAlgorithms:
                states[index].lines.append(ParallelTermLine(kind: .err, text: String(localized: "主机只提供较旧的加密方式（SHA-1），连接被拒绝")))
                states[index].summary = ParallelRunCopy.weakAlgorithms
            case .unknown, .mismatch:
                states[index].lines.append(ParallelTermLine(kind: .err, text: String(localized: "主机指纹未信任，连接被拒绝")))
                states[index].summary = ParallelRunCopy.hostKeyUntrusted(mismatch: challenge.kind == .mismatch)
            }
        } else if let stall = outcome.stall {
            // 连通性预检（`true`）都卡住：多半是连接半死不活。
            markStalled(at: index, stall: stall, streamed: false)
        } else if outcome.timedOut {
            let reason = String(localized: "连接 / 执行超时（超过 \(Self.backstopSeconds) 秒仍无结果）")
            states[index].failure = .connection(reason)
            states[index].lines.append(ParallelTermLine(kind: .err, text: reason))
            states[index].summary = String(localized: "\(reason)，未能确认结果。")
        } else {
            let reason = ParallelRunCopy.connectionReason(outcome.errorText ?? target.session.setupErrorText)
            states[index].failure = .connection(reason)
            states[index].lines.append(ParallelTermLine(kind: .err, text: String(localized: "连接失败：\(reason)")))
            states[index].summary = ParallelRunCopy.unreachable(reason)
        }
    }

    /// 命令跑起来了但被看门狗判超时并终止：把判定前的输出和原因摆出来。
    private func markStalled(at index: Int, stall: ParallelExecutionStalled, streamed: Bool) {
        states[index].status = .failed
        states[index].tone = .failed
        states[index].exitCode = nil
        if !streamed, !stall.stalled.partial.output.isEmpty {
            states[index].lines.append(contentsOf: Self.outputLines(from: stall.stalled.partial, failed: false))
        }
        states[index].lines.append(ParallelTermLine(kind: .err, text: String(localized: "执行超时：\(stall.message)")))
        states[index].summary = ParallelRunCopy.stalled(stall.message, signalled: stall.stalled.kill == .signalled)
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
        ParallelRunCopy.fallbackSynthesis(total: total, failedNames: states.filter { $0.tone == .failed }.map(\.name))
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
                                            steps: notable.flatMap { lane in
                                                [String(localized: "\(lane.name)：\(lane.summary)", comment: "运行日志：主机名：结论")] + lane.steps
                                            })
        }
        let durationMs = Int((finishedAt ?? Date()).timeIntervalSince(startedAt) * 1000)
        store.recordRun(commandID: commandID, startedAt: startedAt, durationMs: durationMs,
                        results: results, aiRecord: aiRecord)
    }

    // MARK: 文案 / 解析
    nonisolated static var backstopSeconds: Int { Int(backstopTimeout.components.seconds) }
    nonisolated static func outputLines(from result: CommandResult?, failed: Bool) -> [ParallelTermLine] {
        guard let result else { return [ParallelTermLine(kind: .err, text: String(localized: "连接或执行失败"))] }
        if result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [ParallelTermLine(kind: failed ? .err : .out, text: String(localized: "（无输出）"))]
        }
        let raw = result.output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return raw.enumerated().map { idx, text in
            let isLast = idx == raw.count - 1
            return ParallelTermLine(kind: failed && isLast && !text.isEmpty ? .err : .out, text: text)
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
        /// 外层兜底计时器到点（会话自己挂死）。
        let timedOut: Bool
        /// 会话里的看门狗判超时（静默太久 / 超总时长 / 取消）。
        var stall: ParallelExecutionStalled?
    }
    private enum GateOutcome: Sendable {
        case completed(CommandResult?)
        case failed(String)
        case stalled(ParallelExecutionStalled)
        case timedOut
    }

    /// 会话建不起来（`setupErrorText != nil`）等价于抽协议前的 `executor == nil`：
    /// 不执行、`errorText` 留空，交 `markUnreachable` 用 `setupErrorText` 兜底。
    private nonisolated static func execBounded(
        session: ParallelExecutionSession, command: String,
        onLines: @escaping @Sendable ([ParallelTermLine]) -> Void
    ) async -> ExecOutcome {
        guard session.setupErrorText == nil else {
            return ExecOutcome(result: nil, errorText: nil, timedOut: false)
        }
        let gate = OneShotGate()
        let work = Task<Void, Never> {
            do { await gate.deliver(.completed(try await session.run(command, onLines: onLines))) }
            catch let stall as ParallelExecutionStalled { await gate.deliver(.stalled(stall)) }
            catch { await gate.deliver(.failed(error.localizedDescription)) }
        }
        let timer = Task<Void, Never> {
            try? await Task.sleep(for: backstopTimeout)
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
        case .stalled(let s):   return ExecOutcome(result: nil, errorText: nil, timedOut: false, stall: s)
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
