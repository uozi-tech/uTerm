import AgentKit
import Foundation

// 并行执行「AI 介入」的共享引擎：macOS `ParallelRunModel` 与 iOS `ParallelRunController` 共用
// （这个文件两个 target 都编）。引擎只管「一台服务器上的 Agent 怎么跑」：
// 模型请求与重试、轮数预算、命令审批、回喂裁剪、结论判定、提示词。
// 两端各自只负责两件事：**怎么在这台上执行一条命令**（`execute`，含往自己的状态里追加原始输出），
// 以及**怎么把进度写进自己的状态类型**（`onEvent`）。

/// 一条命令在一台服务器上的执行结果（两端各自的执行路径归一成这三种）。
nonisolated enum ParallelCommandOutcome: Sendable {
    /// 跑完了（退出码可能非 0）。
    case completed(CommandResult)
    /// 跑起来了，但被看门狗判卡住并终止。`partial` 是判定前的输出，`reason` 是一句话原因。
    case stalled(partial: String, reason: String)
    /// 没跑起来或拿不到结果（连接失败、外层兜底超时）。`reason` 已是给人看的完整一句。
    case unreachable(reason: String, timedOut: Bool)
}

/// 命令审批：每条模型下发的命令执行前要不要过一道闸。
nonisolated enum ParallelAgentApproval: Sendable {
    /// 不审批，模型下发什么就执行什么（iOS 目前的行为）。
    case unrestricted
    /// 按 Agent 安全档位：`.confirm` 只给建议不执行；`.readAuto` 只读放行、写操作交 AI 复核；
    /// `.auto` 全部交 AI 复核（macOS 读全局 `agentSafety`）。
    case safety(AgentSafety)

    var autoExecute: Bool {
        if case .safety(.confirm) = self { return false }
        return true
    }
}

/// 一台服务器交给 Agent 时的起点。
nonisolated struct ParallelAgentRequest: Sendable {
    /// 自然语言目标（intent 优先，其次等效命令，再次命令名）。
    let goal: String
    /// 等效 shell 命令；空 = 没有初始命令，Agent 从零开始按目标下发。
    let command: String
    let serverName: String
    let endpoint: String
    /// 初始命令的结果；nil = 没跑初始命令。
    let initial: Initial?

    nonisolated struct Initial: Sendable {
        let output: String
        /// nil = 没有退出码（被看门狗终止）。
        let exitCode: Int?
        /// 附加说明（例如「这条命令被判定卡住并已终止」）。
        let note: String?
    }
}

/// Agent 跑的过程中报给界面的事件。
nonisolated enum ParallelAgentEvent: Sendable {
    /// 两步之间在做什么（「正在分析结果…」「AI 服务暂时不可用，第 1 次重试…」）。
    case activity(String)
    /// 安全档位不允许自动执行时，模型建议的一步（不会执行）。
    case suggested(String)
    /// 审批通过的理由（只读放行 / AI 复核通过）。
    case approved(String)
    /// 第 `index` 步开始执行。
    case stepStarted(index: Int, command: String, explanation: String?)
    /// 第 `index` 步结束。`line` 是落日志用的一句「执行 X → 退出码 N」。
    case stepFinished(index: Int, outcome: ParallelCommandOutcome, line: String)
}

/// 一台服务器的 Agent 最终结论。
nonisolated struct ParallelAgentOutcome: Sendable {
    let succeeded: Bool
    let summary: String
    let executedAny: Bool
    /// 最后一条真实命令的退出码（没执行过就是初始命令的）。
    let lastExit: Int?
}

/// 共享 Agent 引擎。`run` 在主线程上编排、模型请求与命令执行在线程外跑。
@MainActor
struct ParallelAgentEngine {
    let doctor: ParallelAIDoctor
    let approval: ParallelAgentApproval
    /// 写进系统提示词的宿主描述，如「macOS 原生 SSH 终端」「iOS SSH 终端」。
    let host: String

    /// 跑完一台服务器的 Agent 循环。
    /// - Parameters:
    ///   - execute: 在这台上执行一条命令。由调用方负责往自己的状态里追加原始输出。
    ///   - onEvent: 进度事件，在主线程上回调。
    func run(_ request: ParallelAgentRequest,
             execute: (String) async -> ParallelCommandOutcome,
             onEvent: @escaping (ParallelAgentEvent) -> Void) async -> ParallelAgentOutcome {
        let system = Self.systemPrompt(host: host, approval: approval)
        var convo = [ChatMessage(role: .user, text: Self.initialPrompt(request))]
        var executedAny = false
        var lastExit = request.initial?.exitCode
        var stepCount = 0
        var conclusion: (status: String, summary: String)?
        var stoppedForSafety = false
        var interruption: String?

        agentLoop: for turnIndex in 0..<ParallelAgentPolicy.maxTurns {
            onEvent(.activity((request.initial != nil || executedAny)
                ? String(localized: "正在分析结果…") : String(localized: "正在规划步骤…")))
            let turn: ParallelAIDoctor.Turn
            switch await doctor.turn(messages: convo, system: system, withTools: true,
                                     onRetry: Self.retryNotice(onEvent)) {
            case .success(let t):
                turn = t
            case .failure(let error):
                interruption = String(localized: "AI 服务请求失败（\(ParallelAgentPolicy.describe(error))），已重试仍未恢复")
                break agentLoop
            }

            // 模型不再调用工具 → 这轮文本即结论。
            if turn.calls.isEmpty {
                conclusion = ParallelAIDoctor.parseConclusion(turn.text)
                    ?? (turn.text.isEmpty ? nil : (status: "", summary: turn.text))
                break
            }

            // 档位不允许自动执行：只记建议、停下交人工确认。
            if !approval.autoExecute {
                for call in turn.calls {
                    let st = ToolCallState(from: call)
                    if !st.command.isEmpty { onEvent(.suggested(String(localized: "建议执行：\(Self.stepLabel(st))"))) }
                }
                conclusion = (status: "failed",
                              summary: turn.text.isEmpty
                                ? String(localized: "已诊断并给出修复建议；审批档位「\(safetyLabel)」需要人工确认，未自动执行。")
                                : turn.text)
                stoppedForSafety = true
                break
            }

            var resolvedCalls: [ToolCallState] = []
            for call in turn.calls {
                var st = ToolCallState(from: call)
                guard !st.command.isEmpty else {
                    st.status = .failed; st.output = "(空命令)"; resolvedCalls.append(st); continue
                }
                if case .safety(let safety) = approval {
                    let verdict = await review(st, safety: safety, request: request)
                    guard verdict.approved, !Task.isCancelled else {
                        onEvent(.suggested(String(localized: "需人工确认：\(Self.stepLabel(st))；\(verdict.reason)")))
                        conclusion = (status: "failed", summary: verdict.reason)
                        stoppedForSafety = true
                        break
                    }
                    onEvent(.approved(verdict.reason))
                }

                let index = stepCount
                stepCount += 1
                onEvent(.stepStarted(index: index, command: st.command, explanation: st.explanation))
                if let e = st.explanation, !e.isEmpty {
                    onEvent(.activity(e))
                } else {
                    onEvent(.activity(String(localized: "正在执行 \(st.command)")))
                }
                let outcome = await execute(st.command)
                let exit: Int?
                switch outcome {
                case .completed(let r):
                    exit = r.exitCode
                    st.output = ParallelAgentPolicy.clipForModel(r.output)
                case .stalled(let partial, let reason):
                    // 判定前的输出 + 原因一起回喂（卡在哪一步通常就在最后几行）。
                    exit = nil
                    st.output = ParallelAgentPolicy.clipForModel(partial.isEmpty ? reason : partial + "\n" + reason)
                case .unreachable(let reason, _):
                    exit = nil
                    st.output = reason
                }
                st.exitCode = exit
                st.status = .done
                lastExit = exit
                executedAny = true
                onEvent(.stepFinished(index: index, outcome: outcome,
                                      line: String(localized: "执行 \(Self.stepLabel(st)) → 退出码 \(Self.exitText(exit))")))
                resolvedCalls.append(st)
            }
            if stoppedForSafety { break }
            if let note = ParallelAgentPolicy.budgetNote(afterTurn: turnIndex), let last = resolvedCalls.indices.last {
                resolvedCalls[last].output = (resolvedCalls[last].output ?? "") + "\n\n" + note
            }
            convo.append(ChatMessage(role: .assistant, text: turn.text, toolCalls: resolvedCalls))
            if turnIndex == ParallelAgentPolicy.maxTurns - 1 {
                interruption = String(localized: "已用完 \(ParallelAgentPolicy.maxTurns) 轮仍未得出结论")
            }
        }

        return Self.conclude(conclusion: conclusion, interruption: interruption,
                             stoppedForSafety: stoppedForSafety, executedAny: executedAny,
                             stepCount: stepCount, lastExit: lastExit, initial: request.initial)
    }

    private var safetyLabel: String {
        if case .safety(let s) = approval { return s.label }
        return ""
    }

    /// 写操作前过一道审批：只读命令按规则放行，其余交 AI 复核（档位 `.readAuto` 下只读才放行）。
    private func review(_ st: ToolCallState, safety: AgentSafety,
                        request: ParallelAgentRequest) async -> (approved: Bool, reason: String) {
        let req = AgentToolApproval.Request(
            id: UUID().uuidString, toolName: st.name, command: st.command,
            userIntent: request.goal, context: "目标服务器：\(request.serverName)",
            mode: safety == .readAuto ? .readOnly : .standard)
        let doctor = self.doctor
        let decision = await AgentToolApproval.evaluate(req) { system, prompt in
            let config = LLMRequestConfig(model: doctor.model, baseURL: doctor.baseURL, apiKey: doctor.apiKey)
            return try await reviewToolApproval(client: doctor.client, config: config,
                                                system: system, prompt: prompt)
        }
        let reason = AgentToolApproval.isReadOnly(req) ? decision.reason : String(localized: "AI 已批准：\(decision.reason)")
        return (decision.approved, decision.approved ? reason : decision.reason)
    }

    /// 模型请求要重试时报一条「重试中」，让人知道不是卡死。重试回调在模型请求所在的线程上
    /// 触发，这里切回主线程再调 `onEvent`（它只在主线程上用，所以包一层带过线程边界）。
    private static func retryNotice(_ onEvent: @escaping (ParallelAgentEvent) -> Void)
        -> @Sendable (Int, Error) -> Void {
        let sink = MainThreadSink(onEvent)
        return { attempt, error in
            let text = String(localized: "AI 服务暂时不可用（\(ParallelAgentPolicy.describe(error))），第 \(attempt) 次重试…")
            Task { @MainActor in sink.send(.activity(text)) }
        }
    }

    /// 只在主线程上调用的回调，包起来才能放进 `@Sendable` 闭包。
    private nonisolated final class MainThreadSink: @unchecked Sendable {
        private let body: (ParallelAgentEvent) -> Void
        init(_ body: @escaping (ParallelAgentEvent) -> Void) { self.body = body }
        @MainActor func send(_ event: ParallelAgentEvent) { body(event) }
    }

    // MARK: - 结论

    /// 把模型结论 / 中断原因 / 执行记录归成「成功或失败 + 一句话」。只判成功或失败，不单列「自愈」。
    nonisolated static func conclude(conclusion: (status: String, summary: String)?,
                                     interruption: String?, stoppedForSafety: Bool,
                                     executedAny: Bool, stepCount: Int, lastExit: Int?,
                                     initial: ParallelAgentRequest.Initial?) -> ParallelAgentOutcome {
        let status = conclusion?.status ?? ""
        let succeeded: Bool
        if stoppedForSafety {
            succeeded = false
        } else if status == "ok" {
            succeeded = true
        } else if status == "failed" {
            succeeded = false
        } else if conclusion == nil, interruption != nil, executedAny {
            // 中途断了（模型请求失败 / 轮数用完）：做到一半，不能凭最后一条的退出码报成功。
            succeeded = false
        } else if !executedAny {
            // 没下发任何命令：有初始命令且成功 → 成功；否则失败。
            succeeded = initial?.exitCode == 0
        } else {
            succeeded = lastExit == 0
        }

        let text = (conclusion?.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let summary: String
        if !text.isEmpty {
            summary = text
        } else if let interruption {
            summary = succeeded
                ? String(localized: "命令执行完成，退出码 0；\(interruption)，未做进一步复核。")
                : (stepCount > 0
                    ? String(localized: "\(interruption)，已执行 \(stepCount) 步。可查看处理过程，确认后重新运行。")
                    : String(localized: "\(interruption)。可查看处理过程，确认后重新运行。"))
        } else {
            summary = succeeded
                ? ParallelRunCopy.succeeded
                : String(localized: "命令执行失败（退出码 \(exitText(initial != nil ? initial?.exitCode : lastExit))），需人工介入。")
        }
        return ParallelAgentOutcome(succeeded: succeeded, summary: summary,
                                    executedAny: executedAny, lastExit: lastExit)
    }

    // MARK: - 提示词

    /// 系统提示词。`host` 写宿主描述；档位不允许自动执行时追加「只给建议」的约束。
    nonisolated static func systemPrompt(host: String, approval: ParallelAgentApproval) -> String {
        var s = """
        你是 uTerm（\(host)）里的运维助手，正在一台服务器上自主完成一个运维目标。
        你可以用 run_command 工具逐条执行 shell 命令；每条命令我会把真实的标准输出/错误与退出码回给你（很长的输出只给头尾）。
        请像有经验的运维一样按需多步操作：例如更新后若需要重启服务就再执行重启，改完配置后做一次校验或健康检查。

        \(ParallelAgentPolicy.workingRules(idleSeconds: idleSeconds, maxDurationSeconds: maxDurationSeconds))

        \(ParallelAgentPolicy.conclusionFormat)
        """
        if case .safety(let safety) = approval, !approval.autoExecute {
            s += "\n\n注意：当前安全档位为「\(safety.label)」，不允许自动执行写操作。若需要修复，请用 run_command "
                + "给出你建议执行的命令（我不会真的执行），并给出 failed 结论说明需人工确认。"
        }
        return s
    }

    /// 第一条用户消息：目标 + 服务器 + 初始命令的结果（有的话）。
    nonisolated static func initialPrompt(_ r: ParallelAgentRequest) -> String {
        var s = "目标（自然语言）：\(r.goal)\n服务器：\(r.serverName)（\(r.endpoint)）\n\n"
        if let initial = r.initial {
            s += """
            我已先执行了等效命令 `\(r.command)`，结果：
            退出码：\(exitText(initial.exitCode))\(initial.note.map { "\n" + $0 } ?? "")
            输出：
            \(initial.output.isEmpty ? "（无输出）" : ParallelAgentPolicy.clipForModel(initial.output))

            若退出码非 0 或输出里有报错，先判断原因并尝试处理，不要直接给 failed。
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

    // MARK: - 小工具

    nonisolated static func stepLabel(_ st: ToolCallState) -> String {
        if let e = st.explanation, !e.isEmpty { return "\(e)（\(st.command)）" }
        return st.command
    }

    nonisolated static func exitText(_ code: Int?) -> String {
        code.map(String.init) ?? String(localized: "未知", comment: "退出码未知")
    }

    /// 静默超时 / 总时长上限的秒数（取自 `SupervisedExec.interactive*`），用于提示词。
    nonisolated static var idleSeconds: Int { Int(SupervisedExec.interactiveIdle.components.seconds) }
    nonisolated static var maxDurationSeconds: Int { Int(SupervisedExec.interactiveMaxDuration.components.seconds) }
}

/// 两端并行执行共用的结论文案（引擎之外的路径：非 AI、没配 AI、连不上、超时、跨台汇总兜底）。
nonisolated enum ParallelRunCopy {
    static var succeeded: String { String(localized: "命令执行完成，退出码 0。") }

    static func shellFailed(exit: Int?) -> String {
        String(localized: "命令以退出码 \(ParallelAgentEngine.exitText(exit)) 结束，执行失败。")
    }

    static func noProvider(ranInitial: Bool, exit: Int?, goal: String) -> String {
        ranInitial
            ? String(localized: "命令执行失败（退出码 \(ParallelAgentEngine.exitText(exit))）。未配置模型服务，无法自动诊断修复。")
            : String(localized: "未配置模型服务，无法按「\(goal)」自主下发命令。在「设置 › 模型服务」里添加后再试。")
    }

    /// 命令跑起来了但被看门狗终止。`signalled` = 已终止远端进程组（远端可能停在半截）。
    static func stalled(_ reason: String, signalled: Bool) -> String {
        signalled
            ? String(localized: "执行超时：\(reason)远端可能停在中间状态，需要人工复核。")
            : String(localized: "执行超时：\(reason)")
    }

    /// 交给 Agent 时附在初始结果后的说明。
    static func stalledNote(_ reason: String) -> String {
        "这条命令被判定卡住并已终止（连同子进程）：\(reason)远端可能停在半截，先查清现场再继续。"
    }

    static func hostKeyUntrusted(mismatch: Bool) -> String {
        mismatch
            ? String(localized: "无法连接：该主机出示的主机密钥与已信任的不一致（可能是主机重装过系统，也可能是中间人攻击）。核对指纹无误后点「信任并重试」。")
            : String(localized: "无法连接：尚未信任该主机的密钥。核对指纹无误后点「信任并重试」。")
    }

    /// 信任过的主机（或它的跳板机）这次只肯用 SHA-1 时代的旧算法，并行执行不能问人，直接拒了。两端共用，动词不写「点」。
    static func weakAlgorithms(_ challenge: HostKeyChallenge) -> String {
        challenge.isJumpHost
            ? String(localized: "无法连接：跳板机 \(challenge.address) 以前用更安全的连接方式，这次要改用较旧、安全性较低的连接方式（SHA-1）才能连上；放行后经这台跳板机的连接都不再询问。确认没问题后选「仍然连接并重试」。")
            : String(localized: "无法连接：这台主机以前用更安全的连接方式，这次要改用较旧、安全性较低的连接方式（SHA-1）才能连上。确认没问题后选「仍然连接并重试」。")
    }

    /// 终端窗格里那一行。
    static func weakAlgorithmsLine(_ challenge: HostKeyChallenge) -> String {
        challenge.isJumpHost
            ? String(localized: "跳板机 \(challenge.address) 要改用较旧的连接方式（SHA-1）才能连上，连接被拒绝")
            : String(localized: "主机要改用较旧的连接方式（SHA-1）才能连上，连接被拒绝")
    }

    static func unreachable(_ reason: String) -> String { String(localized: "无法连接到该主机：\(reason)。命令未执行。") }

    /// 把连接错误整理成一句原因（去空白；空则兜底）。
    static func connectionReason(_ text: String?) -> String {
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? String(localized: "无法建立连接") : t
    }

    /// 模型汇总不可用时的跨台汇总（只讲成功 / 失败）。
    static func fallbackSynthesis(total: Int, failedNames: [String]) -> String {
        if failedNames.isEmpty { return String(localized: "\(total) 台全部执行成功，无异常。") }
        let names = failedNames.joined(separator: String(localized: "、", comment: "并列的主机名之间的分隔符"))
        return String(localized: "\(total) 台中 \(total - failedNames.count) 台成功，\(names) 失败，建议人工复核。")
    }
}
