import Foundation

/// 交互会话组：`sessions` / `session-start` / `session-send` / `session-read` / `session-close`。
///
/// 给**没有终端的调用方**（Agent 的 Bash 工具）用的「一问一答」交互：`run` 没有 stdin，
/// 碰上 `sudo` 的密码提示、`[Y/n]`、REPL 只能卡到超时；这里开一条后台 PTY，调用方
/// 写一点、读一点，像 expect 一样往下推。
///
/// 硬约束（技能文档必须原样转述给模型）：
/// - **密码不经过调用方**：`passwordPrompt: true` 时用 `session-send --secret`，uTerm 弹
///   安全输入框让用户自己输，内容直接写进 PTY，响应里没有、之后的输出里出现也打码。
/// - **读是流不是快照**：`output` 是自上次以来的新输出，读过不再给。TUI 的画面看 `screen`。
/// - 会话不在任何窗口里，用户看不见；用完 `session-close`，忘了关的 30 分钟没人碰自动回收。
extension ControlHandler {

    func handleSession(
        _ request: ControlRequest,
        _ deps: Dependencies
    ) async throws -> ControlResponse {
        switch request.action {
        case .sessions:
            deps.sessions.reap()
            let snapshots = deps.sessions.all.map { $0.snapshot(consume: false, includeScreen: false) }
            return .success(
                id: request.id,
                message: snapshots.isEmpty ? "命令行没有开着的交互会话" : "共 \(snapshots.count) 个交互会话",
                sessions: snapshots
            )
        case .sessionStart:
            return try await sessionStartResponse(request, deps)
        case .sessionSend:
            return try await sessionSendResponse(request, deps)
        case .sessionRead:
            let session = try deps.sessions.resolve(request.session)
            session.touch()
            let matched = try await waitForOutput(session, request, requireNew: false)
            return sessionResponse(request, session, matched: matched)
        case .sessionClose:
            let session = try deps.sessions.resolve(request.session)
            let wasRunning = session.isRunning
            session.end(reason: "closed", message: "被 session-close 关闭")
            let snapshot = session.snapshot(consume: true, includeScreen: request.screen ?? false)
            deps.sessions.remove(session)
            return .success(
                id: request.id,
                message: wasRunning
                    ? "已关闭会话（远端进程随 PTY 挂断收到 SIGHUP）"
                    : "会话早已结束，已从列表里删掉",
                session: snapshot
            )
        default:
            throw ControlFailure(
                code: .invalid_request,
                message: "动作 \(request.action.rawValue) 不属于交互会话组"
            )
        }
    }

    // MARK: - start

    private func sessionStartResponse(
        _ request: ControlRequest,
        _ deps: Dependencies
    ) async throws -> ControlResponse {
        let profile = try resolveHost(request.host ?? "")
        try requireExecCapable(profile, action: .sessionStart)
        let command = try Self.optionalCommandText(request)

        deps.sessions.reap()
        guard deps.sessions.runningCount() < ControlProtocol.maxSessions else {
            throw ControlFailure(
                code: .session_limit,
                message: "命令行已开着 \(ControlProtocol.maxSessions) 个交互会话（上限），"
                    + "先 `utermctl sessions` 看看、`session close` 掉不用的"
            )
        }
        guard deps.sessions.runningCount(hostID: profile.id) < ControlProtocol.maxSessionsPerHost else {
            throw ControlFailure(
                code: .session_limit,
                message: "「\(profile.name)」上已开着 \(ControlProtocol.maxSessionsPerHost) 个交互会话（每台上限），"
                    + "先 `session close` 掉不用的"
            )
        }

        let hostSpec: HostConnectionSpec
        do {
            hostSpec = try HostConnectionSpec.resolve(profile: profile, container: deps.modelContainer)
        } catch let error as ControlConnectError {
            return response(for: error, id: request.id, host: profile.name)
        }

        let spec = Self.ptySpec(
            request,
            defaultCols: ControlProtocol.defaultSessionCols,
            defaultRows: ControlProtocol.defaultSessionRows
        )
        let session = ControlPTYSession(
            hostName: profile.name, hostID: profile.id, command: command, spec: spec)
        do {
            let handle = try await deps.pool.openPTY(
                for: hostSpec,
                spec: spec,
                onOutput: { session.ingest($0) },
                onEnd: { session.finish($0) }
            )
            session.attach(handle)
        } catch let error as ControlConnectError {
            return response(for: error, id: request.id, host: profile.name)
        } catch let failure as ControlFailure {
            throw failure
        } catch {
            throw ControlFailure(
                code: .operation_failed,
                message: "在「\(profile.name)」上开 PTY 失败：\(FriendlyError.describe(error))"
            )
        }
        deps.sessions.add(session)

        // 跑指定命令：先等登录 shell 把引导行执行掉（见 `ControlPTYCommand`）。
        if command != nil {
            let deadline = ContinuousClock.now + Self.bootstrapTimeout
            while session.isBootstrapping, ContinuousClock.now < deadline, !Task.isCancelled {
                IOActivity.touch()
                try? await Task.sleep(for: .milliseconds(50))
            }
            if session.isBootstrapping {
                session.end(
                    reason: "failed",
                    message: "登录 shell \(Int(Self.bootstrapTimeout.components.seconds)) 秒内没有执行命令"
                        + "（.bashrc / .zshrc 里自动起 tmux、或者在等输入？）。可以不带命令开会话，自己发命令。"
                )
            }
        }

        let matched = try await waitForOutput(session, request, requireNew: false)
        let snapshot = session.snapshot(
            consume: true, includeScreen: request.screen ?? false, matched: matched)
        if !snapshot.running, snapshot.endReason == "failed" {
            return .failure(
                id: request.id,
                code: .session_ended,
                message: snapshot.endMessage ?? "会话没开起来",
                session: snapshot
            )
        }
        return .success(
            id: request.id,
            message: "已在「\(profile.name)」上开交互会话 \(Self.shortID(session))。"
                + Self.nextStep(snapshot),
            session: snapshot
        )
    }

    // MARK: - send

    private func sessionSendResponse(
        _ request: ControlRequest,
        _ deps: Dependencies
    ) async throws -> ControlResponse {
        let session = try deps.sessions.resolve(request.session)
        session.touch()

        do {
            if request.secret == true {
                guard (request.text ?? "").isEmpty, (request.keys ?? []).isEmpty else {
                    throw ControlFailure(
                        code: .invalid_request,
                        message: "--secret 不带文本也不带按键：内容由用户在 uTerm 的输入框里输"
                    )
                }
                guard session.isRunning else {
                    throw ControlFailure(code: .session_ended, message: "会话已经结束，写不进去了")
                }
                let current = session.snapshot(consume: false, includeScreen: false)
                let secret = await whileTouching {
                    await deps.secretPrompt.requestSecret(
                        ControlSecretRequest(
                            host: session.hostName,
                            command: session.command,
                            promptLine: current.promptLine,
                            purpose: request.prompt
                        ),
                        timeout: ControlProtocol.secretPromptSeconds
                    )
                }
                session.touch()
                guard let secret else {
                    return .failure(
                        id: request.id,
                        code: .secret_cancelled,
                        message: "用户取消了输入（或 \(Int(ControlProtocol.secretPromptSeconds / 60)) 分钟内没输）。"
                            + "**不要**自己猜密码重试；问用户要不要继续，或用 `session send -k ctrl-c` 中断这一步。",
                        session: session.snapshot(consume: true, includeScreen: request.screen ?? false)
                    )
                }
                try session.writeSecret(secret)
            } else {
                var payload = request.text ?? ""
                for name in request.keys ?? [] {
                    guard let bytes = PTYKeys.bytes(for: name) else {
                        throw ControlFailure(code: .invalid_request, message: "不认识的按键「\(name)」。" + PTYKeys.help)
                    }
                    payload += bytes
                }
                if request.enter == true { payload += "\r" }
                guard !payload.isEmpty else {
                    throw ControlFailure(
                        code: .invalid_request,
                        message: "session-send 需要文本、按键（-k）、--enter 或 --secret 之一"
                    )
                }
                try session.write(payload)
            }
        } catch let failure as ControlFailure where failure.code == .session_ended {
            return .failure(
                id: request.id,
                code: .session_ended,
                message: failure.message,
                session: session.snapshot(consume: true, includeScreen: request.screen ?? false)
            )
        }

        let matched = try await waitForOutput(session, request, requireNew: true)
        return sessionResponse(request, session, matched: matched)
    }

    // MARK: - 共用

    private func sessionResponse(
        _ request: ControlRequest,
        _ session: ControlPTYSession,
        matched: Bool?
    ) -> ControlResponse {
        let snapshot = session.snapshot(
            consume: true, includeScreen: request.screen ?? false, matched: matched)
        return .success(
            id: request.id,
            message: Self.nextStep(snapshot),
            session: snapshot
        )
    }

    /// 等输出：给了 `waitFor` 就等它出现；没给就等「这一波输出静下来」。进程退出、等满
    /// `waitSeconds` 都立刻返回。返回值是 `matched`（没给 `waitFor` 为 nil）。
    ///
    /// `requireNew`：`send` 之后要等**这次写入引出的**输出，之前就攒着、早已静下来的
    /// 旧输出不算 —— 否则发完立刻返回，程序还没来得及回话。
    private func waitForOutput(
        _ session: ControlPTYSession,
        _ request: ControlRequest,
        requireNew: Bool
    ) async throws -> Bool? {
        let pattern = try Self.compile(request.waitFor)
        let seconds = min(
            max(0, request.waitSeconds ?? ControlProtocol.defaultSessionWaitSeconds),
            ControlProtocol.maxSessionWaitSeconds)
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(Int(seconds * 1000))
        let startGeneration = requireNew ? session.outputGeneration : -1

        func matches() -> Bool {
            guard let pattern else { return false }
            let text = session.peekText()
            return pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }

        while true {
            IOActivity.touch()
            if pattern != nil, matches() { return true }
            if !session.isRunning { return pattern == nil ? nil : matches() }
            if pattern == nil, session.hasUnread, session.outputGeneration != startGeneration,
               session.quietSeconds >= ControlProtocol.sessionSettleSeconds {
                return nil
            }
            if clock.now >= deadline || Task.isCancelled { return pattern == nil ? nil : false }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// 等用户输入这种慢动作期间不断给服务端的静默闸报「还活着」（它 120 秒没进展就回
    /// `handler_timeout`）。`Task {}` 继承 task-local 的 `IOActivity.pulse`。
    private func whileTouching<T>(_ body: () async -> T) async -> T {
        let ticker = Task {
            while !Task.isCancelled {
                IOActivity.touch()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        defer { ticker.cancel() }
        return await body()
    }

    /// 给调用方的下一步提示。
    nonisolated static func nextStep(_ snapshot: ControlSessionSnapshot) -> String {
        let id = String(snapshot.id.prefix(8))
        if !snapshot.running {
            let code = snapshot.exitCode.map { "，退出码 \($0)" } ?? ""
            return "会话已结束（\(snapshot.endReason ?? "exited")\(code)）。"
                + (snapshot.endMessage.map { $0 + "。" } ?? "")
        }
        if snapshot.passwordPrompt {
            return "远端在等密码。用 `session send -s \(id) --secret --prompt \"<为什么要输>\"` "
                + "让用户在 uTerm 弹出的安全输入框里自己输；不要自己编密码，也别让用户把密码发给你。"
        }
        if snapshot.matched == false {
            return "等到时限也没等到 waitFor。看 output / promptLine 判断它卡在哪；还在跑就再 `session read`。"
        }
        if snapshot.awaitingInput {
            return "输出已静下来，光标停在一行中间，多半在等输入（看 promptLine）。"
        }
        return "进程还在跑。继续 `session read -s \(id)`，或发输入 `session send -s \(id) …`。"
    }

    nonisolated static func shortID(_ session: ControlPTYSession) -> String {
        String(session.id.uuidString.prefix(8))
    }

    /// 首行引导最多等多久（远端登录 shell 的 rc 文件慢、跳板机首连都算在内）。
    nonisolated static let bootstrapTimeout: Duration = .seconds(20)

    /// `-c` / `--` 之后的命令；都没给 = nil（登录 shell）。
    static func optionalCommandText(_ request: ControlRequest) throws(ControlFailure) -> String? {
        if let args = request.args, !args.isEmpty { return try commandText(request) }
        guard let command = request.command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return command
    }

    nonisolated static func ptySpec(_ request: ControlRequest, defaultCols: Int, defaultRows: Int) -> PTYSpec {
        let term = request.term?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PTYSpec(
            term: (term?.isEmpty == false ? term! : "xterm-256color"),
            cols: min(max(request.cols ?? defaultCols, 20), 500),
            rows: min(max(request.rows ?? defaultRows, 5), 300)
        )
    }

    nonisolated static func compile(_ pattern: String?) throws(ControlFailure) -> NSRegularExpression? {
        guard let pattern, !pattern.isEmpty else { return nil }
        do {
            return try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        } catch {
            throw ControlFailure(code: .invalid_request, message: "--wait-for 不是合法的正则：\(pattern)")
        }
    }
}
