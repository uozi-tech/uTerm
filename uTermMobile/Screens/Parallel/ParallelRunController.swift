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

/// AI 泳道里的一步（模型下发的一条命令）。`PServerState.steps` 是落日志用的纯文本，
/// 这个是给界面画「命令 + 结果」用的结构化版本，两者一一对应。
struct PAgentStep: Identifiable, Sendable {
    enum State: Sendable { case running, ok, failed, timedOut }
    let id = UUID()
    let command: String
    let explanation: String?
    var state: State = .running
    var exitCode: Int?
}

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
    var agentSteps: [PAgentStep] = []
    /// 运行中这一刻在做什么（「正在分析结果…」「AI 服务繁忙，重试中…」）；落定后为 nil。
    var activity: String?
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
    /// 单条命令的超时由会话里的 `SupervisedExec` 看门狗管（按静默判、总时长兜底，超时终止
    /// 远端进程组，抛 `ParallelExecutionStalled`）。这个计时器只是再外一层的兜底：会话自己
    /// 挂死（假会话、将来别的实现）时也保证泳道能收尾。比看门狗的总时长上限宽，正常到不了。
    nonisolated static let backstopTimeout: Duration = SupervisedExec.interactiveMaxDuration + .seconds(60)

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
    private let doctor: ParallelAIDoctor?
    /// 按主机起执行会话的执行器。默认 `SSHParallelExecutor`（与抽协议前逐行等价的真实路径）；
    /// 探针注入假实现，整屏就能在没有真机器的情况下跑起来。
    private let executor: ParallelCommandExecuting

    private var running = false
    private var generation = 0
    private var recordOnFinalize = true
    /// 每台一条在跑的任务 —— 只为 `cancel()`（探针拆窗、将来的「中途返回就停」）留把手。
    private var laneTasks: [Task<Void, Never>] = []

    init(commandID: UUID, commandName: String, command: String, intent: String,
         aiAssisted: Bool, targets: [ServerProfile], doctor: ParallelAIDoctor?,
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
        // 首轮已经收尾、落过日志，补跑这一台才不再记第二条；首轮还在跑（别的台还没完）时
        // 点的，照常在最终收尾时记一次——改前一律置 false，整次运行就从日志里消失了。
        if finishedAt != nil { recordOnFinalize = false }
        resetLane(index)
        finishedAt = nil
        generation += 1
        running = true
        laneTasks.append(Task {
            let target = await makeExecTarget(profile: profile, trustNewKeys: true)
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
        return ExecTarget(id: profile.id, name: profile.name,
                          endpoint: "\(profile.username)@\(profile.host):\(profile.port)",
                          session: session)
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
            states[index].lines = [PLine(kind: .cmd, text: command)]
            states[index].activity = "正在执行 \(command)"
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
                states[index].lines.append(PLine(kind: .err, text: "执行超时：" + stall.message))
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

    /// 多步 Agent：交给与 macOS 共用的 `ParallelAgentEngine`。iOS 不审批（模型下发即执行，
    /// 与改前一致）。这里只负责在这台上执行命令（并把原始输出追加进 Shell 卡片），以及把进度
    /// 写进泳道（结构化步骤 + 当前动作）。
    private func runAgent(at index: Int, target: ExecTarget, doctor: ParallelAIDoctor,
                          request: ParallelAgentRequest) async {
        states[index].diagnosing = request.initial.map { $0.exitCode != 0 } ?? false
        let engine = ParallelAgentEngine(doctor: doctor, approval: .unrestricted, host: "iOS SSH 终端")
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
            states[index].agentSteps.append(PAgentStep(command: command, explanation: explanation))
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
        states[index].lines.append(PLine(kind: .cmd, text: command))
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
            let reason = "执行超时：" + stall.message
            if streamed.count == 0, !partial.output.isEmpty {
                states[index].lines.append(contentsOf: Self.outputLines(from: partial, failed: false))
            }
            states[index].lines.append(PLine(kind: .err, text: reason))
            return .stalled(partial: partial.output, reason: reason)
        }
        let reason = outcome.timedOut
            ? "执行超时（超过 \(Self.backstopSeconds) 秒仍无结果）"
            : "连接失败：\(ParallelRunCopy.connectionReason(outcome.errorText))"
        states[index].lines.append(PLine(kind: .err, text: reason))
        return .unreachable(reason: reason, timedOut: outcome.timedOut)
    }

    private func markUnreachable(at index: Int, target: ExecTarget, outcome: ExecOutcome) {
        states[index].status = .failed
        states[index].tone = .failed
        states[index].exitCode = nil
        if let challenge = target.session.takeHostKeyChallenge() {
            let mismatch: Bool = { if case .mismatch = challenge.kind { return true }; return false }()
            states[index].failure = .hostKeyUntrusted(challenge)
            states[index].lines.append(PLine(kind: .err, text: "主机指纹未信任，连接被拒绝"))
            states[index].summary = ParallelRunCopy.hostKeyUntrusted(mismatch: mismatch)
        } else if let stall = outcome.stall {
            // 连通性预检（`true`）都卡住：多半是连接半死不活。
            markStalled(at: index, stall: stall, streamed: false)
        } else if outcome.timedOut {
            let reason = "连接 / 执行超时（超过 \(Self.backstopSeconds) 秒仍无结果）"
            states[index].failure = .connection(reason)
            states[index].lines.append(PLine(kind: .err, text: reason))
            states[index].summary = "\(reason)，未能确认结果。"
        } else {
            let reason = ParallelRunCopy.connectionReason(outcome.errorText ?? target.session.setupErrorText)
            states[index].failure = .connection(reason)
            states[index].lines.append(PLine(kind: .err, text: "连接失败：\(reason)"))
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
        states[index].lines.append(PLine(kind: .err, text: "执行超时：" + stall.message))
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
                                            steps: notable.flatMap { lane in ["\(lane.name)：\(lane.summary)"] + lane.steps })
        }
        let durationMs = Int((finishedAt ?? Date()).timeIntervalSince(startedAt) * 1000)
        store.recordRun(commandID: commandID, startedAt: startedAt, durationMs: durationMs,
                        results: results, aiRecord: aiRecord)
    }

    // MARK: 文案 / 解析
    nonisolated static var backstopSeconds: Int { Int(backstopTimeout.components.seconds) }
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
        onLines: @escaping @Sendable ([PLine]) -> Void
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
