import Foundation

/// 并行执行里「每台一个 Agent」的公共规则。macOS `ParallelRunModel` 与 iOS
/// `ParallelRunController` 共用：这个文件不在 mobile 的 membershipExceptions 里，两个 target 都编。
///
/// 改前两端各写一份，有四处让 Agent 显得「一遇到错误就交人工」：
/// 1. 一轮模型请求失败就 `break`。十几台同时请求，撞上限流（429）、网关过载（5xx / 529）、
///    流中途断开都很常见，一次失败这一台就收成「需人工介入」，其实什么都没诊断。
/// 2. 只给 6 轮。「更新 → 清理 → 校验 → 必要时重启」加上一两次纠错就用完了，用完时没有
///    结论，同样落成「需人工介入」。
/// 3. 命令输出原样回喂。`apt-get upgrade` 一条就上千行，几轮下来请求体撑爆上下文，
///    模型端报 400，又回到第 1 条。
/// 4. 提示词只说「确认无法自动修复时给 failed」，没要求先读错误、换个办法再试。
nonisolated enum ParallelAgentPolicy {

    /// 每台最多几轮模型对话（一轮可以带多条命令）。
    static let maxTurns = 16
    /// 剩几轮时提醒模型收敛。
    static let budgetWarningAt = 3
    /// 单轮模型请求的总尝试次数（含首次）。
    static let llmAttempts = 4

    // MARK: - 模型请求重试

    /// 这个错误值不值得再试一次。鉴权、参数、找不到模型这类重试也是同样结果，直接放弃。
    static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let e = error as? LLMClientError {
            switch e {
            case .httpError(let status, _):
                return status == 408 || status == 409 || status == 425 || status == 429 || status >= 500
            case .invalidResponse, .streamIdleTimeout, .streamError, .incompleteStream:
                return true
            case .outputLimitReached:
                return false
            }
        }
        // URLError（断网、超时、连接被重置）等传输层错误。
        return true
    }

    /// 第 `attempt` 次（从 1 起）失败后等多久再试：2s / 5s / 10s，再叠最多 1.5s 抖动，
    /// 免得十几台在同一时刻一起重试、又一起撞限流。
    static func retryDelay(afterAttempt attempt: Int) -> Duration {
        let base: [Double] = [2, 5, 10]
        let seconds = base[min(max(attempt - 1, 0), base.count - 1)] + Double.random(in: 0...1.5)
        return .milliseconds(Int(seconds * 1000))
    }

    /// 带重试地跑一次模型请求。返回最后一次的结果；中途被取消就返回取消错误。
    /// `onRetry(第几次失败, 错误)` 在每次决定重试、开始等待之前调用，界面拿它显示「重试中」。
    /// `delay` 只为测试注入（不真等几秒）。
    static func withRetry<T: Sendable>(
        attempts: Int = llmAttempts,
        delay: @Sendable (Int) -> Duration = { ParallelAgentPolicy.retryDelay(afterAttempt: $0) },
        onRetry: @Sendable (Int, Error) -> Void = { _, _ in },
        _ body: @Sendable () async throws -> T
    ) async -> Result<T, Error> {
        var lastError: Error = CancellationError()
        for attempt in 1...max(1, attempts) {
            do {
                return .success(try await body())
            } catch {
                lastError = error
                guard attempt < attempts, isRetryable(error), !Task.isCancelled else { break }
                onRetry(attempt, error)
                do { try await Task.sleep(for: delay(attempt)) } catch { break }
            }
        }
        return .failure(lastError)
    }

    /// 给人看的一句失败原因。
    static func describe(_ error: Error) -> String {
        guard let e = error as? LLMClientError else { return error.localizedDescription }
        switch e {
        case .httpError(let status, _):
            switch status {
            case 401, 403: return String(localized: "API Key 无效或没有权限（HTTP \(String(status))）")
            case 404:      return String(localized: "找不到所选模型或接口地址（HTTP 404）")
            case 429:      return String(localized: "请求太频繁被限流（HTTP 429）")
            default:       return String(localized: "请求失败（HTTP \(String(status))）")
            }
        case .invalidResponse:    return String(localized: "模型服务返回了无法解析的响应")
        case .streamIdleTimeout:  return String(localized: "响应长时间没有新内容")
        case .streamError(let d): return String(localized: "模型服务中途报错：\(d)")
        case .incompleteStream:   return String(localized: "连接在回复完成前断开")
        case .outputLimitReached: return String(localized: "回复超出单次输出上限")
        }
    }

    // MARK: - 回喂给模型的命令输出

    /// 回喂单条命令输出的上限。界面上照常显示完整输出，只是不全塞给模型。
    static let modelOutputHeadLines = 30
    static let modelOutputTailLines = 120
    static let modelOutputMaxChars = 12_000

    /// 头 30 行 + 尾 120 行，中间注明省略了多少；整体再按字符数封顶（保留尾部，错误多在最后）。
    static func clipForModel(_ output: String) -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        var text = output
        if lines.count > modelOutputHeadLines + modelOutputTailLines {
            let omitted = lines.count - modelOutputHeadLines - modelOutputTailLines
            text = lines.prefix(modelOutputHeadLines).joined(separator: "\n")
                + "\n…（中间省略 \(omitted) 行）…\n"
                + lines.suffix(modelOutputTailLines).joined(separator: "\n")
        }
        if text.count > modelOutputMaxChars {
            text = "…（前面省略 \(text.count - modelOutputMaxChars) 个字符）…\n" + String(text.suffix(modelOutputMaxChars))
        }
        return text
    }

    // MARK: - 轮数预算

    /// 跑完第 `turn` 轮（从 0 起）的命令后，要附在最后一条输出末尾的提醒；不需要提醒时为 nil。
    /// 附在工具输出里而不是另起一条用户消息：工具结果在协议里本身就算一条 user 消息，再跟一条
    /// 就成了两条连续的 user，有的端点会拒收；挂在输出上两家协议都稳。
    static func budgetNote(afterTurn turn: Int, maxTurns: Int = maxTurns) -> String? {
        let remaining = maxTurns - turn - 1
        if remaining == 1 {
            return "【系统提示】这是最后一轮：不要再调用工具，直接根据已有结果输出结论 JSON。"
        }
        if remaining == budgetWarningAt {
            return "【系统提示】还剩 \(remaining) 轮，请收敛：只做达成目标必需的步骤，然后给结论。"
        }
        return nil
    }

    // MARK: - 提示词

    /// 两端系统提示词里相同的「怎么干活」部分。
    static func workingRules(idleSeconds: Int, maxDurationSeconds: Int) -> String {
        """
        工作方式：
        - 先摸清环境再动手：发行版、包管理器、当前用户是否 root。可以在一条命令里用 `;` 合并几项只读检查，省轮次；同一轮也可以连发多条命令。
        - 一律用非交互方式：apt 用 `DEBIAN_FRONTEND=noninteractive apt-get -y`（配置文件冲突加 `-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold`），dnf/yum 加 `-y`，systemctl/journalctl 加 `--no-pager`。不要用会等输入的命令（vim、less、passwd、交互式 sudo）。非 root 时用 `sudo -n`；它报需要密码就说明需要人工。
        - 命令失败时**不要立刻放弃**：先读错误输出判断原因，再针对性处理，常见的有——软件源暂时不可达（等几秒重试一次，或先 `apt-get update`）、锁被占用（见下）、dpkg 半完成（`dpkg --configure -a` 后再试）、依赖冲突（`apt-get -f install -y`）、磁盘满（`df -h` 看，清 `apt-get clean` / `journalctl --vacuum-size=200M`）、命令不存在（换成这台机器实际的包管理器或工具）。同一条命令原样最多重试一次；同样的错误出现两次就换办法。
        - 只有在需要人提供的东西（密码、确认、凭据）、需要破坏性或超出目标范围的操作、或已经换过办法仍然失败时，才给 failed，并在 summary 里写清卡在哪一步、人接下来该做什么。
        - 主要目标达成、只有次要步骤（例如清理缓存）没成功时，给 ok，在 summary 里顺带提一句。
        - 命令要保守、最小必要：不要 rm -rf，不要动与目标无关的服务。
        - 每条命令若连续约 \(idleSeconds) 秒没有任何输出，会被判定卡住并**终止**（连同它启动的子进程），总时长上限约 \(maxDurationSeconds) 秒。一直有输出的命令跑多久都行，所以长操作尽量带进度或 -v；本身长时间不出声的命令（大文件校验、打包）要让它吐进度，或拆小。若某条被终止，先查清现场（进程还在不在、dpkg 是否半完成）再决定下一步。
        - 绝不要用无限等待循环（`while …; do sleep N; done`、`tail -f`、死等某进程或锁）——会把本台一直拖到超时。
        - 遇到 dpkg/apt 锁被占用（"Could not get lock /var/lib/dpkg/…"）：多半是 unattended-upgrades 等在持锁。用 `ps aux | grep -E 'apt|dpkg'` 看是谁；最多有界等一次（如 `sleep 30` 后重试），仍不行再给 failed，说明锁被谁占着、建议稍后复核。
        - **重启必须是该台的最后一步**：reboot / shutdown / `systemctl reboot` 会让 SSH 立即断开，之后任何命令都会因连接断开而报错。其它操作都做完再重启，且**发出重启就立刻给结论**（status=ok，summary 说明「已触发重启，更新在重启后生效」），不要在重启后等待或重连验证。
        - 你最多有 \(maxTurns) 轮。
        """
    }

    /// 结论格式（两端一致）。
    static var conclusionFormat: String { """
        当目标达成、或确认无法自动完成时，停止调用工具，只输出一个 JSON 作为结论：
        {"status":"ok|failed","summary":"不超过2句白话结论，用\(AgentReplyLanguage.displayName)写"}
        ok = 目标已达成（不论是本来就正常，还是你处理后达成并验证过）；failed = 无法达成（说明原因与人工建议）。只判成功或失败，不要单独区分「已修复」。
        """ }
}
