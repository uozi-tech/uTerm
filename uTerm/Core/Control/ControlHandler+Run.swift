import Foundation
import SwiftData

/// 执行组：`run` / `run-many` / `quick-commands` / `quick-run`。
///
/// 全组共同的硬约束：
/// - `run*` 与 `quick-run` 是 mutation（shell 无法可靠分类读写），门禁已在
///   `ControlHandler.handle` 统一判过，这里只判主机级 `sftpOnly`。
/// - Citadel 的 exec **不可取消**：超时必须走 `BoundedExec` 的「非结构化 Task +
///   一次性闸门」放手模式，否则 `tail -f` 会挂死整个任务组。超时返回后**命令可能
///   还在远端跑**，文案与技能文档都要写明。
/// - 未知 / 变更的主机密钥一律拒绝并回 fingerprint，绝不自动 TOFU。
extension ControlHandler {

    func handleRun(
        _ request: ControlRequest,
        _ deps: Dependencies
    ) async throws -> ControlResponse {
        switch request.action {
        case .run:
            return try await runResponse(request, deps)
        case .runMany:
            return try await runManyResponse(request, deps)
        case .quickCommands:
            return quickCommandsResponse(request, deps)
        case .quickRun:
            return try await quickRunResponse(request, deps)
        default:
            throw ControlFailure(
                code: .invalid_request,
                message: "动作 \(request.action.rawValue) 不属于执行组"
            )
        }
    }

    // MARK: - run

    private func runResponse(
        _ request: ControlRequest,
        _ deps: Dependencies
    ) async throws -> ControlResponse {
        let profile = try resolveHost(request.host ?? "")
        try requireExecCapable(profile, action: .run)
        let command = try Self.commandText(request)
        let limits = Self.limits(request)

        let spec: HostConnectionSpec
        do {
            spec = try HostConnectionSpec.resolve(profile: profile, container: deps.modelContainer)
        } catch let error as ControlConnectError {
            return response(for: error, id: request.id, host: profile.name)
        }

        let outcome = await Self.execute(
            target: RunTarget(spec: spec, name: profile.name),
            command: command,
            limits: limits,
            pool: deps.pool
        )

        if let connectError = outcome.connectError {
            var failure = response(for: connectError, id: request.id, host: profile.name)
            failure.results = [outcome.result]
            return failure
        }
        if outcome.result.timedOut {
            return .failure(
                id: request.id,
                code: .command_timeout,
                message: "命令在 \(limits.timeoutSeconds) 秒内没有结束，已放弃等待。"
                    + "**命令可能仍在远端运行**（Citadel 的 exec 不可取消，uTerm 只是不再等它）。"
                    + "需要长跑的命令请用 nohup / systemd-run 之类丢到后台，再用 `run` 查状态。",
                results: [outcome.result]
            )
        }
        return .success(
            id: request.id,
            message: "在「\(profile.name)」上执行完成，退出码 \(outcome.result.exitCode.map(String.init) ?? "未知")",
            result: outcome.result
        )
    }

    // MARK: - run-many

    private func runManyResponse(
        _ request: ControlRequest,
        _ deps: Dependencies
    ) async throws -> ControlResponse {
        let needles = Self.hostNeedles(request)
        guard !needles.isEmpty else {
            throw ControlFailure(
                code: .invalid_request,
                message: "缺少主机：run-many 至少要一个 `-H <主机>`"
            )
        }
        let command = try Self.commandText(request)
        let limits = Self.limits(request)
        // 主机解析失败**整条拒绝**，不做部分执行 —— 名字打错时半数机器已经跑了命令
        // 是最难收拾的局面。认证解析失败则只算该台失败（那是连接问题，不是指错机器）。
        let prepared = try prepareTargets(needles, action: .runMany, deps)

        let results = await Self.runAll(prepared, command: command, limits: limits, pool: deps.pool)
        let failed = results.filter { $0.errorCode != nil || ($0.exitCode ?? -1) != 0 }.count
        return .success(
            id: request.id,
            message: failed == 0
                ? "\(results.count) 台全部执行成功"
                : "\(results.count) 台中 \(failed) 台失败",
            results: results
        )
    }

    // MARK: - quick-commands

    private func quickCommandsResponse(
        _ request: ControlRequest,
        _ deps: Dependencies
    ) -> ControlResponse {
        let profiles = sortedProfiles(deps)
        var nameByID: [UUID: String] = [:]
        for profile in profiles { nameByID[profile.id] = profile.name }
        let snapshots = quickCommands(deps).map { command in
            ControlQuickCommandSnapshot(
                id: command.id.uuidString,
                name: command.name,
                command: command.command,
                serverIDs: command.serverIDs.map(\.uuidString),
                serverNames: command.serverIDs.map { nameByID[$0] ?? $0.uuidString },
                lastRunAt: ControlProtocol.iso8601(command.lastRunAt)
            )
        }
        return .success(
            id: request.id,
            message: snapshots.isEmpty ? "还没有快捷命令" : "共 \(snapshots.count) 条快捷命令",
            quickCommands: snapshots
        )
    }

    // MARK: - quick-run

    /// 按名字 / id 跑一条快捷命令。目标 = 请求里的 `hosts`（覆盖），否则命令自带的
    /// `serverIDs`。跑完写 30 天执行日志（与欢迎页「动作」里跑的记录同表同字段）。
    private func quickRunResponse(
        _ request: ControlRequest,
        _ deps: Dependencies
    ) async throws -> ControlResponse {
        guard let needle = Self.trimmed(request.name) ?? Self.trimmed(request.command) else {
            throw ControlFailure(
                code: .invalid_request,
                message: "缺少快捷命令名（先跑 `utermctl quick-commands` 看有哪些）"
            )
        }
        let commands = quickCommands(deps)
        let candidates = commands.map { HostResolver.Candidate(id: $0.id, name: $0.name) }
        let command: QuickCommand
        switch HostResolver.resolve(needle, in: candidates) {
        case .matched(let id):
            guard let match = commands.first(where: { $0.id == id }) else {
                throw ControlFailure(code: .invalid_request, message: "没有名为「\(needle)」的快捷命令")
            }
            command = match
        case .ambiguous(let matches):
            throw ControlFailure(
                code: .invalid_request,
                message: "「\(needle)」匹配到 \(matches.count) 条快捷命令："
                    + matches.map(\.name).joined(separator: "、") + "。改用 UUID 重试。"
            )
        case .notFound:
            throw ControlFailure(
                code: .invalid_request,
                message: "没有名为「\(needle)」的快捷命令（跑 `utermctl quick-commands` 看有哪些）"
            )
        }

        let shell = command.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shell.isEmpty else {
            throw ControlFailure(
                code: .invalid_request,
                message: "快捷命令「\(command.name)」没有等效 shell 命令（AI 介入命令），"
                    + "CLI 跑不了它 —— 请在 uTerm 界面里运行，或用 `run` 自己下发命令。"
            )
        }

        // 目标：请求里的 --host 覆盖优先，其次命令自带的绑定。
        let overrides = Self.hostNeedles(request)
        let prepared: [PreparedTarget]
        if overrides.isEmpty {
            prepared = preparedTargets(forServerIDs: command.serverIDs, action: .quickRun, deps)
        } else {
            prepared = try prepareTargets(overrides, action: .quickRun, deps)
        }
        guard !prepared.isEmpty else {
            throw ControlFailure(
                code: .invalid_request,
                message: "快捷命令「\(command.name)」没有绑定任何服务器，也没有给 `-H`"
            )
        }

        let startedAt = Date()
        let limits = Self.limits(request)
        let results = await Self.runAll(prepared, command: shell, limits: limits, pool: deps.pool)
        let totalMs = Int(Date().timeIntervalSince(startedAt) * 1000)

        // 写 30 天日志：字段与 `QuickCommandRunner.run` 记的那份一致，欢迎页的执行
        // 日志里能直接看到 CLI 跑的这次。`recordRun` 自己会更新 lastRunAt / runCount，
        // 所以**不**再调 `recordInvocation`（会把次数记两遍）。
        let endpoints = Dictionary(uniqueKeysWithValues: prepared.map { ($0.hostID, $0.endpoint) })
        let logged = results.map { result in
            QuickCommandServerResult(
                serverID: UUID(uuidString: result.hostID) ?? UUID(),
                serverName: result.host,
                endpoint: endpoints[UUID(uuidString: result.hostID) ?? UUID()] ?? "",
                exitCode: result.exitCode,
                durationMs: result.durationMs,
                ok: result.errorCode == nil && result.exitCode == 0
            )
        }
        QuickCommandStore(context: deps.modelContainer.mainContext)
            .recordRun(
                commandID: command.id,
                startedAt: startedAt,
                durationMs: totalMs,
                results: logged
            )

        let failed = logged.filter { !$0.ok }.count
        return .success(
            id: request.id,
            message: failed == 0
                ? "快捷命令「\(command.name)」在 \(logged.count) 台上全部成功"
                : "快捷命令「\(command.name)」在 \(logged.count) 台中有 \(failed) 台失败",
            results: results
        )
    }

    // MARK: - 目标准备

    /// 一台待执行的主机。`ready` 已解析出建连输入；`failed` 是解析阶段就定了的失败
    /// （认证材料缺失 / `sftpOnly`），不必再去建连。
    nonisolated struct PreparedTarget: Sendable {
        let hostID: UUID
        let hostName: String
        let endpoint: String
        let target: RunTarget?
        let failure: (code: ControlErrorCode, message: String)?
    }

    nonisolated struct RunTarget: Sendable {
        let spec: HostConnectionSpec
        let name: String
    }

    /// 按名字 / UUID 逐个解析。**任一主机解析失败整条拒绝**（不部分执行）；
    /// 认证解析失败只标记该台。
    private func prepareTargets(
        _ needles: [String],
        action: ControlAction,
        _ deps: Dependencies
    ) throws(ControlFailure) -> [PreparedTarget] {
        var prepared: [PreparedTarget] = []
        for needle in needles {
            let profile = try resolveHost(needle)
            try requireExecCapable(profile, action: action)
            prepared.append(preparedTarget(profile, deps))
        }
        return prepared
    }

    /// 快捷命令自带的绑定：档案已删 / 仅 SFTP 的主机各自记一条失败，不拖垮整批
    /// （用户在界面里跑同一条命令时也是逐台成败）。
    private func preparedTargets(
        forServerIDs ids: [UUID],
        action: ControlAction,
        _ deps: Dependencies
    ) -> [PreparedTarget] {
        let profiles = sortedProfiles(deps)
        var byID: [UUID: ServerProfile] = [:]
        for profile in profiles { byID[profile.id] = profile }
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }.map { id in
            guard let profile = byID[id] else {
                return PreparedTarget(
                    hostID: id,
                    hostName: id.uuidString,
                    endpoint: "",
                    target: nil,
                    failure: (.host_not_found, "主机档案已不存在（\(id.uuidString)）")
                )
            }
            if action.requiresExecCapableHost, profile.sftpOnly {
                return PreparedTarget(
                    hostID: id,
                    hostName: profile.name,
                    endpoint: Self.endpoint(profile),
                    target: nil,
                    failure: (.host_sftp_only, "主机「\(profile.name)」被标记为仅 SFTP，不允许执行命令")
                )
            }
            return preparedTarget(profile, deps)
        }
    }

    private func preparedTarget(_ profile: ServerProfile, _ deps: Dependencies) -> PreparedTarget {
        do {
            let spec = try HostConnectionSpec.resolve(profile: profile, container: deps.modelContainer)
            return PreparedTarget(
                hostID: profile.id,
                hostName: profile.name,
                endpoint: Self.endpoint(profile),
                target: RunTarget(spec: spec, name: profile.name),
                failure: nil
            )
        } catch let error as ControlConnectError {
            return PreparedTarget(
                hostID: profile.id,
                hostName: profile.name,
                endpoint: Self.endpoint(profile),
                target: nil,
                failure: (error.code, error.message(host: profile.name))
            )
        } catch {
            return PreparedTarget(
                hostID: profile.id,
                hostName: profile.name,
                endpoint: Self.endpoint(profile),
                target: nil,
                failure: (.auth_failed, FriendlyError.describe(error))
            )
        }
    }

    private func quickCommands(_ deps: Dependencies) -> [QuickCommand] {
        let all = (try? deps.modelContainer.mainContext.fetch(FetchDescriptor<QuickCommand>())) ?? []
        return all.sorted {
            $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.name < $1.name
        }
    }

    private nonisolated static func endpoint(_ profile: ServerProfile) -> String {
        "\(profile.username)@\(profile.host):\(profile.port)"
    }

    // MARK: - 执行

    /// 一次执行的输出裁剪与超时。都按请求给定，各自封顶。
    nonisolated struct RunLimits: Sendable {
        let timeoutSeconds: Int
        let maxLines: Int
        let maxBytes: Int

        var timeout: Duration { .seconds(timeoutSeconds) }
    }

    nonisolated struct RunOutcome: Sendable {
        let result: ControlRunResult
        /// 建连失败的分类（主机密钥两态要把指纹回给 CLI）。
        let connectError: ControlConnectError?
    }

    nonisolated static func limits(_ request: ControlRequest) -> RunLimits {
        let timeout = request.timeoutSeconds ?? ControlProtocol.defaultRunTimeoutSeconds
        let lines = request.maxLines ?? ControlProtocol.defaultMaxLines
        let bytes = request.maxBytes ?? ControlProtocol.defaultMaxBytes
        return RunLimits(
            timeoutSeconds: min(max(1, timeout), ControlProtocol.maxRunTimeoutSeconds),
            maxLines: min(max(1, lines), 100_000),
            maxBytes: min(max(1, bytes), ControlProtocol.maxOutputBytes)
        )
    }

    /// 单台执行：取（必要时建）执行器 → `BoundedExec` 有界等待 → 归类。
    /// **不抛错**：连接层失败也写进 `ControlRunResult.errorCode`，让 `run-many`
    /// 单台失败不影响其它台。
    nonisolated static func execute(
        target: RunTarget,
        command: String,
        limits: RunLimits,
        pool: any ControlConnectionPooling
    ) async -> RunOutcome {
        let start = Date()
        let executor: SSHCommandExecutor
        do {
            executor = try await pool.executor(
                for: target.spec,
                maxLines: limits.maxLines,
                maxBytes: limits.maxBytes
            )
        } catch {
            let connectError = (error as? ControlConnectError)
                ?? .connectFailed(FriendlyError.describe(error))
            return RunOutcome(
                result: failedResult(target, since: start, connectError, name: target.name),
                connectError: connectError
            )
        }

        let outcome = await BoundedExec.run(timeout: limits.timeout) {
            try await executor.run(command)
        }
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)

        switch outcome {
        case .completed(let result):
            return RunOutcome(
                result: ControlRunResult(
                    host: target.name,
                    hostID: target.spec.id.uuidString,
                    output: result.output,
                    exitCode: result.exitCode,
                    truncated: isTruncated(result.output),
                    durationMs: elapsed
                ),
                connectError: nil
            )
        case .timedOut:
            return RunOutcome(
                result: ControlRunResult(
                    host: target.name,
                    hostID: target.spec.id.uuidString,
                    output: "",
                    durationMs: elapsed,
                    timedOut: true,
                    errorCode: ControlErrorCode.command_timeout.rawValue,
                    errorMessage: "命令在 \(limits.timeoutSeconds) 秒内没有结束，已放弃等待；"
                        + "**命令可能仍在远端运行**。"
                ),
                connectError: nil
            )
        case .failed(let failure):
            // 命令层的非零退出被哨兵包成 exit 0，走不到这里；这里只可能是传输层出事。
            let connectError = (failure.underlying as? ControlConnectError)
                ?? .connectFailed(failure.text)
            return RunOutcome(
                result: failedResult(target, since: start, connectError, name: target.name),
                connectError: connectError
            )
        }
    }

    /// 有界并发跑一批（滑动窗口，上限 `ControlProtocol.maxParallelHosts`），
    /// 结果**按请求顺序**返回。单台失败只写该条的 errorCode。
    nonisolated static func runAll(
        _ prepared: [PreparedTarget],
        command: String,
        limits: RunLimits,
        pool: any ControlConnectionPooling
    ) async -> [ControlRunResult] {
        var results = [ControlRunResult?](repeating: nil, count: prepared.count)
        let cap = max(1, min(ControlProtocol.maxParallelHosts, prepared.count))
        var pending = Array(prepared.enumerated()).makeIterator()

        await withTaskGroup(of: (Int, ControlRunResult).self) { group in
            var inWindow = 0
            while inWindow < cap, let (index, item) = pending.next() {
                group.addTask { (index, await one(item, command: command, limits: limits, pool: pool)) }
                inWindow += 1
            }
            for await (index, result) in group {
                results[index] = result
                if let (nextIndex, item) = pending.next() {
                    group.addTask {
                        (nextIndex, await one(item, command: command, limits: limits, pool: pool))
                    }
                }
            }
        }
        return results.enumerated().map { index, result in
            result ?? ControlRunResult(
                host: prepared[index].hostName,
                hostID: prepared[index].hostID.uuidString,
                output: "",
                errorCode: ControlErrorCode.operation_failed.rawValue,
                errorMessage: "没有拿到执行结果"
            )
        }
    }

    private nonisolated static func one(
        _ item: PreparedTarget,
        command: String,
        limits: RunLimits,
        pool: any ControlConnectionPooling
    ) async -> ControlRunResult {
        guard let target = item.target else {
            let failure = item.failure ?? (.operation_failed, "无法准备该主机")
            return ControlRunResult(
                host: item.hostName,
                hostID: item.hostID.uuidString,
                output: "",
                errorCode: failure.code.rawValue,
                errorMessage: failure.message
            )
        }
        return await execute(target: target, command: command, limits: limits, pool: pool).result
    }

    private nonisolated static func failedResult(
        _ target: RunTarget,
        since start: Date,
        _ error: ControlConnectError,
        name: String
    ) -> ControlRunResult {
        ControlRunResult(
            host: name,
            hostID: target.spec.id.uuidString,
            output: "",
            durationMs: Int(Date().timeIntervalSince(start) * 1000),
            errorCode: error.code.rawValue,
            errorMessage: error.message(host: name)
        )
    }

    /// `SSHCommandExecutor.parse` 截断时会在末尾补一行标记，据此还原 `truncated`
    ///（`CommandResult` 本身没有这个字段）。
    private nonisolated static func isTruncated(_ output: String) -> Bool {
        output.hasSuffix("… [输出已截断]")
    }

    // MARK: - 请求解析

    /// 命令整串。优先 `command`（客户端已 shlex.join 好），否则把 `args` 安全拼接。
    static func commandText(_ request: ControlRequest) throws(ControlFailure) -> String {
        if let command = trimmed(request.command) { return command }
        if let args = request.args, !args.isEmpty {
            return shellJoin(args)
        }
        throw ControlFailure(
            code: .invalid_request,
            message: "缺少命令：用 `-- <命令…>` 或 `-c \"<命令>\"` 指定"
        )
    }

    /// 单主机 / 多主机字段的统一取法：`hosts` 优先，退回 `host`。
    static func hostNeedles(_ request: ControlRequest) -> [String] {
        let many = (request.hosts ?? []).compactMap { trimmed($0) }
        if !many.isEmpty { return many }
        if let single = trimmed(request.host) { return [single] }
        return []
    }

    /// `shlex.join` 的 Swift 版：安全字符原样，其余整段单引号包起来
    /// （单引号自身用 `'\''` 转义）。避免「引号地狱」，也不给注入留缝。
    static func shellJoin(_ args: [String]) -> String {
        args.map { argument -> String in
            let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@%+=:,./-_")
            if !argument.isEmpty, argument.unicodeScalars.allSatisfy({ safe.contains($0) }) {
                return argument
            }
            return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        .joined(separator: " ")
    }
}
