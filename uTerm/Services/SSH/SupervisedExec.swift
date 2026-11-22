import Foundation

/// 远端命令的执行看门狗：按**静默**判卡死，而不是按总时长一刀切。
///
/// 原来的 `BoundedExec` 只有一个总超时：`apt upgrade`、`docker build` 这种一直在刷
/// 输出、只是跑得久的命令，到点照样被放弃；而放弃也只是「不再等」，命令还在远端跑。
/// 这里换成两道闸：
/// - **静默超时**（主判据）：连续 `idle` 没有任何输出才判定卡住；
/// - **总时长上限**（兜底）：`tail -f` 这类永远在出输出的命令不会静默，没有这道闸
///   就会永久占着一个 IPC 名额。
///
/// 任一道闸触发后**真的杀**：命令包装时首行报出会话 shell 的 pid（= 进程组号，见
/// `SSHCommandExecutor.wrapAnnouncingPID`），另开一条 exec 对整组先 TERM、宽限几秒
/// 再 KILL。拿不到 pid（底层不支持流式、首行都没到）就退回「放手不等」的老语义。
///
/// 调用方：CLI 的 `run*`（`ControlHandler+Run`，按请求给阈值）、macOS 欢迎页快捷命令
/// （`QuickCommandRunner`）与并行执行窗口（`ParallelRunModel`）、iOS 并行执行
/// （`SSHParallelSession`）—— GUI 没有逐次参数，用 `interactiveIdle` / `interactiveMaxDuration`；
/// Agent 对话的 `run_command`（`SupervisedAgentCommandExecutor`）用 `agentIdle`。
///
/// 调用方的任务被取消（iOS 拆窗）也按「停」处理：后台发出进程组终止，立刻返回 `.cancelled`。
///
/// 看门狗每一拍都 `IOActivity.touch()`：它自己在按静默判超时，就要让外层
/// `ControlServer` 的静默闸知道「这条请求有人在管」，否则长命令会先被 IPC 层掐掉。
nonisolated enum SupervisedExec {

    struct Limits: Sendable {
        let idle: Duration
        let maxDuration: Duration
        let maxLines: Int
        let maxBytes: Int
    }

    enum StopReason: String, Sendable {
        case idle
        case maxDuration = "max_duration"
        /// 调用方的任务被取消。
        case cancelled
    }

    enum KillOutcome: Sendable, Equatable {
        /// 已对进程组发出 TERM（宽限后 KILL）。
        case signalled
        /// 没拿到 pid，没法杀 —— 命令可能还在远端跑。
        case noPID
        /// 杀的那条 exec 本身失败 / 超时。
        case failed(String)
    }

    struct Stalled: Sendable {
        let reason: StopReason
        /// 判定前已经收到的输出（已裁剪；没有退出码）。
        let partial: CommandResult
        let kill: KillOutcome

        /// 一句话说清为什么停、远端进程还在不在。CLI 响应、GUI 失败行、AI 回喂共用。
        func message(limits: Limits) -> String {
            let cause: String
            switch reason {
            case .idle:
                cause = String(localized: "连续 \(String(Int(limits.idle.components.seconds))) 秒没有任何输出，判定卡住")
            case .maxDuration:
                cause = String(localized: "运行满 \(String(Int(limits.maxDuration.components.seconds))) 秒总时长上限")
            case .cancelled:
                return kill == .signalled ? String(localized: "已取消，已终止远端进程组。")
                    : String(localized: "已取消；命令可能仍在远端运行。")
            }
            switch kill {
            case .signalled:
                return String(localized: "\(cause)，已终止远端进程组（TERM，\(SupervisedExec.killGraceSeconds) 秒后 KILL）。")
            case .noPID:
                return String(localized: "\(cause)，已放弃等待；没拿到远端进程号，命令可能仍在远端运行。")
            case .failed(let why):
                return String(localized: "\(cause)，已放弃等待；终止远端进程失败（\(why)），命令可能仍在远端运行。")
            }
        }
    }

    enum Outcome: Sendable {
        case completed(CommandResult)
        case failed(BoundedExecFailure)
        case stalled(Stalled)
    }

    /// TERM 之后等进程组自己退出的秒数，到点补 KILL。
    static let killGraceSeconds = 5

    /// GUI（快捷命令、并行执行窗口）的静默预算。GUI 没有 `--timeout` 可调，而用户写进
    /// 快捷命令的常有本身就不出声的活（`pg_dump > 文件`、`tar czf`），所以比 CLI 的默认
    /// 60 秒宽得多；一直有输出的命令不受它影响。
    static let interactiveIdle: Duration = .seconds(300)
    /// GUI 的总时长上限（兜底，同 CLI 默认）。
    static let interactiveMaxDuration: Duration = .seconds(3600)

    /// Agent **对话**里 `run_command` 的静默预算。比快捷命令的 300 秒紧：这里的命令是模型
    /// 现写的排查 / 运维语句，用户盯着卡片等结果，卡住了要尽快把控制权还回来；又比 CLI 的
    /// 60 秒松，给 `du -sh /`、`find /` 这类本身不出声的命令留余地。一直有输出的命令不受影响。
    static let agentIdle: Duration = .seconds(120)

    /// GUI 入口：阈值取 `interactive*`，输出裁剪沿用执行器自己的 `maxLines` / `maxBytes`。
    static func runInteractive(_ command: String, on executor: SSHCommandExecutor) async -> Outcome {
        await run(command, on: executor, limits: interactiveLimits(for: executor))
    }

    static func interactiveLimits(for executor: SSHCommandExecutor) -> Limits {
        Limits(
            idle: interactiveIdle,
            maxDuration: interactiveMaxDuration,
            maxLines: executor.maxLines,
            maxBytes: executor.maxBytes
        )
    }

    /// - `tick`：看门狗的检查间隔。缺省 `min(1 s, idle / 4)`；测试可以调小。
    static func run(
        _ command: String,
        on executor: SSHCommandExecutor,
        limits: Limits,
        tick: Duration? = nil
    ) async -> Outcome {
        let clock = ContinuousClock()
        let start = clock.now
        let collector = OutputCollector(
            headCap: limits.maxBytes + headSlack,
            start: start
        )
        let wrapped = SSHCommandExecutor.wrapAnnouncingPID(command)
        // exec 不可取消，必须是非结构化 Task：判定卡住后看门狗直接返回，消费者留在
        // 后台，等远端进程组被杀、channel 收到 EOF 后自己结束。
        _ = Task<Void, Never> {
            do {
                try await executor.runStreaming(wrapped) { collector.append($0) }
                collector.finish(nil)
            } catch {
                collector.finish(BoundedExecFailure(error))
            }
        }

        let interval = tick ?? min(.seconds(1), limits.idle / 4)
        while true {
            IOActivity.touch()
            if let finish = await collector.waitForFinish(upTo: interval) {
                if let failure = finish.failure { return .failed(failure) }
                return .completed(collector.result(maxLines: limits.maxLines, maxBytes: limits.maxBytes))
            }
            let now = clock.now
            let reason: StopReason
            if Task.isCancelled {
                // 取消方要的是马上停：终止放到后台（宽限 + KILL 最长十几秒），不陪着等。
                let partial = collector.result(maxLines: limits.maxLines, maxBytes: limits.maxBytes)
                guard let pid = collector.pid else {
                    return .stalled(Stalled(reason: .cancelled, partial: partial, kill: .noPID))
                }
                Task.detached { _ = await killProcessGroup(pid, on: executor) }
                return .stalled(Stalled(reason: .cancelled, partial: partial, kill: .signalled))
            }
            if now - start >= limits.maxDuration {
                reason = .maxDuration
            } else if now - collector.lastActivity >= limits.idle {
                reason = .idle
            } else {
                continue
            }
            let partial = collector.result(maxLines: limits.maxLines, maxBytes: limits.maxBytes)
            let kill: KillOutcome
            if let pid = collector.pid {
                kill = await killProcessGroup(pid, on: executor)
            } else {
                kill = .noPID
            }
            return .stalled(Stalled(reason: reason, partial: partial, kill: kill))
        }
    }

    /// 头部缓冲在 `maxBytes` 之外多留的余量：装 pid 行，并保证溢出时正文一定长过
    /// `maxBytes`，`SSHCommandExecutor.parse` 才会把它标成截断。
    private static let headSlack = 4096

    /// 另开一条 exec 杀掉整组：先 TERM，每秒看一次组还在不在，宽限到点补 KILL。
    ///
    /// 用 `kill -TERM -<pid>` 而不是 `kill -TERM -- -<pid>`：信号已经给出时负数只能是
    /// 进程组号，dash / bash / zsh / busybox 都认；`--` 反倒有的 shell 的内建 kill 不认。
    /// 组已经没了（命令恰好刚结束）时 kill 失败是正常的，脚本一律 exit 0。
    static func killScript(pid: Int32) -> String {
        "kill -TERM -\(pid) 2>/dev/null || exit 0; i=0; "
            + "while [ $i -lt \(killGraceSeconds) ] && kill -0 -\(pid) 2>/dev/null; do sleep 1; i=$((i+1)); done; "
            + "kill -KILL -\(pid) 2>/dev/null; exit 0"
    }

    private static func killProcessGroup(_ pid: Int32, on executor: SSHCommandExecutor) async -> KillOutcome {
        let script = killScript(pid: pid)
        let outcome = await BoundedExec.run(timeout: .seconds(killGraceSeconds + 10)) {
            try await executor.runRaw(script)
        }
        switch outcome {
        case .completed: return .signalled
        case .failed(let failure): return .failed(failure.rawText)
        case .timedOut: return .failed(String(localized: "终止命令本身在 \(killGraceSeconds + 10) 秒内没有返回"))
        }
    }
}

/// 流式输出的收集器：只留头部（裁剪用）与尾部（找退出码哨兵），中间丢掉，内存有界。
///
/// `append` 在流消费者的 Task 里同步调用，`waitForFinish` 在看门狗里 await —— 两边
/// 不在同一个隔离域，所以是带锁的类而不是 actor（actor 的话每块输出都要跳一次）。
nonisolated final class OutputCollector: @unchecked Sendable {

    struct Finish: Sendable {
        let failure: BoundedExecFailure?
    }

    private static let tailCap = 256

    private let lock = NSLock()
    private let headCap: Int
    private var head = Data()
    private var tail = Data()
    private var overflowed = false
    private var parsedPID: Int32?
    private var pidSettled = false
    private var lastActivityAt: ContinuousClock.Instant
    private var finished: Finish?
    private var waiter: (generation: UInt64, continuation: CheckedContinuation<Void, Never>)?
    private var waitGeneration: UInt64 = 0
    private var firedGeneration: UInt64 = 0

    init(headCap: Int, start: ContinuousClock.Instant) {
        self.headCap = headCap
        self.lastActivityAt = start
    }

    var lastActivity: ContinuousClock.Instant {
        lock.withLock { lastActivityAt }
    }

    /// 会话 shell 的 pid（首行 `__UTERM_PID__:<n>`）。首行没到或格式不对时为 nil。
    var pid: Int32? {
        lock.withLock { parsedPID }
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            lastActivityAt = ContinuousClock.now
            if head.count < headCap {
                let room = headCap - head.count
                head.append(data.prefix(room))
                if data.count > room { overflowed = true }
            } else {
                overflowed = true
            }
            tail.append(data)
            if tail.count > Self.tailCap { tail = tail.suffix(Self.tailCap) }
            settlePIDIfPossible()
        }
    }

    func finish(_ failure: BoundedExecFailure?) {
        let resume: CheckedContinuation<Void, Never>? = lock.withLock {
            finished = Finish(failure: failure)
            defer { waiter = nil }
            return waiter?.continuation
        }
        resume?.resume()
    }

    /// 等命令结束，最多等 `timeout`。结束了返回结果，到点还没结束返回 nil。
    /// 只有看门狗一个等待者。
    func waitForFinish(upTo timeout: Duration) async -> Finish? {
        let generation: UInt64 = lock.withLock {
            waitGeneration &+= 1
            return waitGeneration
        }
        let timer = Task { [self] in
            try? await Task.sleep(for: timeout)
            fire(generation)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready: Bool = lock.withLock {
                if finished != nil || firedGeneration >= generation { return true }
                waiter = (generation, continuation)
                return false
            }
            if ready { continuation.resume() }
        }
        timer.cancel()
        return lock.withLock { finished }
    }

    private func fire(_ generation: UInt64) {
        let resume: CheckedContinuation<Void, Never>? = lock.withLock {
            firedGeneration = max(firedGeneration, generation)
            guard let waiter, waiter.generation == generation else { return nil }
            self.waiter = nil
            return waiter.continuation
        }
        resume?.resume()
    }

    /// 组装结果：剥掉 pid 行；溢出时正文取头部、退出码哨兵从尾部补回来。
    func result(maxLines: Int, maxBytes: Int) -> CommandResult {
        let (headData, tailData, overflow) = lock.withLock { (head, tail, overflowed) }
        var raw = String(decoding: headData, as: UTF8.self)
        if raw.hasPrefix(SSHCommandExecutor.pidMarker + ":") {
            if let newline = raw.firstIndex(of: "\n") {
                raw = String(raw[raw.index(after: newline)...])
            } else {
                raw = ""
            }
        }
        if overflow {
            let tailText = String(decoding: tailData, as: UTF8.self)
            if let range = tailText.range(of: "\(SSHCommandExecutor.sentinel):", options: .backwards) {
                raw += "\n" + tailText[range.lowerBound...]
            }
        }
        return SSHCommandExecutor.parse(raw, maxLines: maxLines, maxBytes: maxBytes)
    }

    /// 调用方持锁。
    private func settlePIDIfPossible() {
        guard !pidSettled, let newline = head.firstIndex(of: UInt8(ascii: "\n")) else { return }
        pidSettled = true
        let line = String(decoding: head[head.startIndex..<newline], as: UTF8.self)
        let prefix = SSHCommandExecutor.pidMarker + ":"
        guard line.hasPrefix(prefix), let value = Int32(line.dropFirst(prefix.count)), value > 1 else {
            return
        }
        parsedPID = value
    }
}
