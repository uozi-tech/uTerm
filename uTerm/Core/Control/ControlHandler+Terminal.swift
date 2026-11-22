import Foundation
import SwiftData

/// 终端组：`terminals` / `terminal-read` / `terminal-send` / `terminal-open` / `terminal-wait`。
///
/// `terminal-open -- <命令>` + `terminal-wait` 是「要人交互的命令」的正路：命令在用户看得见
/// 的窗口里跑，用户自己输密码、回答提示，调用方只等退出码和输出（`TerminalSession+TrackedRun`）。
///
/// 硬约束（技能文档必须原样转述给模型）：
/// - **读屏是快照不是流**：两次 `terminal-read` 之间的输出会丢。要拿命令结果请用 `run`。
/// - **注入没有输出边界**：`terminal-send` 与用户键入交错，不保证你能拿到这条命令的结果；
///   它的正当用途是「让用户看见」，不是拿数据。
/// - 读屏读的是影子终端（`TerminalSession.snapshotScreen` → `ShadowTerminal.recentLines`），不碰画面；
///   会话的其余状态只能在 MainActor 上读 —— 整个 `ControlHandler` 就是 `@MainActor`，天然满足。
extension ControlHandler {

    func handleTerminal(
        _ request: ControlRequest,
        _ deps: Dependencies
    ) async throws -> ControlResponse {
        switch request.action {
        case .terminals:
            let snapshots = deps.registry.snapshots()
            return .success(
                id: request.id,
                message: snapshots.isEmpty ? String(localized: "当前没有活着的终端会话") : String(localized: "共 \(snapshots.count) 条终端会话"),
                terminals: snapshots
            )

        case .terminalRead:
            let entry = try resolveTerminal(request, deps)
            guard let session = deps.registry.session(for: entry.id) else {
                throw ControlFailure(
                    code: .terminal_disconnected,
                    message: String(localized: "会话「\(entry.title)」已经不在了（窗口关了？）")
                )
            }
            let lines = clampScreenLines(request.lines)
            let screen = session.snapshotScreen(
                lines: lines, maxBytes: ControlProtocol.maxScreenBytes)
            return .success(
                id: request.id,
                message: screen.truncated
                    ? String(localized: "读到 \(screen.lines.count) 行（上方已截断）")
                    : String(localized: "读到 \(screen.lines.count) 行"),
                screen: ControlScreenSnapshot(
                    terminal: entry.id.uuidString,
                    lines: screen.lines,
                    truncated: screen.truncated
                )
            )

        case .terminalSend:
            let entry = try resolveTerminal(request, deps)
            guard let text = request.text, !text.isEmpty else {
                throw ControlFailure(
                    code: .invalid_request,
                    message: String(localized: "terminal-send 需要非空的 text")
                )
            }
            // 主机级硬规则：`sftpOnly` 主机拒绝一切终端操作。档案已被删的会话
            // 没法再判定，放行（会话本身是用户自己开的）。
            try requireExecCapableSession(entry, action: .terminalSend, deps)
            guard let session = deps.registry.session(for: entry.id) else {
                throw ControlFailure(
                    code: .terminal_disconnected,
                    message: String(localized: "会话「\(entry.title)」已经不在了（窗口关了？）")
                )
            }
            do {
                try await session.injectInput(text, appendEnter: request.enter ?? false)
            } catch {
                throw ControlFailure(
                    code: .terminal_disconnected,
                    message: String(localized: "会话「\(entry.title)」的连接已断开，没有写进去")
                )
            }
            return .success(
                id: request.id,
                message: (request.enter ?? false)
                    ? String(localized: "已写入会话「\(entry.title)」（带回车）；注入没有输出边界，要结果请改用 run")
                    : String(localized: "已写入会话「\(entry.title)」（未回车，用户需自己按 Enter）；注入没有输出边界，要结果请改用 run"),
                terminals: [deps.registry.snapshot(of: entry)]
            )

        case .terminalOpen:
            guard let needle = request.host?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !needle.isEmpty else {
                throw ControlFailure(code: .invalid_request, message: String(localized: "terminal-open 需要 --host"))
            }
            let profile = try resolveHost(needle)
            try requireExecCapable(profile, action: .terminalOpen)
            let command = try Self.windowCommand(request)
            guard let open = deps.registry.openTerminalWindow else {
                throw ControlFailure(
                    code: .app_not_ready,
                    message: String(localized: "uTerm 还没接好开窗口的入口（主窗口尚未出现？）")
                )
            }
            guard let windowID = open(profile.id) else {
                throw ControlFailure(
                    code: .operation_failed,
                    message: String(localized: "打开终端窗口失败")
                )
            }
            // `openWindow` 是同步返回的，但窗口 / 会话都还在异步搭：等注册表里
            // 出现这个窗口的会话再回 id，等不到就如实说明（窗口确实已经开了）。
            if let entry = await deps.registry.waitForSession(
                inWindow: windowID, timeout: .seconds(terminalOpenWaitSeconds)) {
                guard let command else {
                    return .success(
                        id: request.id,
                        message: String(localized: "已为「\(profile.name)」打开终端窗口"),
                        terminals: [deps.registry.snapshot(of: entry)]
                    )
                }
                guard let session = deps.registry.session(for: entry.id) else {
                    throw ControlFailure(
                        code: .terminal_disconnected,
                        message: String(localized: "窗口开了，但会话「\(entry.title)」随即不在了，命令没有执行")
                    )
                }
                session.startTrackedRun(command)
                let shortID = String(entry.id.uuidString.prefix(8))
                return .success(
                    id: request.id,
                    message: String(localized: "已为「\(profile.name)」打开终端窗口，命令会在连上后自动执行。需要输入（sudo 密码、确认提示）的话请用户在这个窗口里操作；用 `terminal wait -t \(shortID)` 等它结束、拿退出码和输出。"),
                    terminals: [deps.registry.snapshot(of: entry)],
                    run: session.trackedRunSnapshot(
                        terminalID: entry.id, maxBytes: ControlProtocol.maxTerminalRunOutputBytes)
                )
            }
            if command != nil {
                return .failure(
                    id: request.id,
                    code: .operation_failed,
                    message: String(localized: "已为「\(profile.name)」打开终端窗口 \(windowID.uuidString)，但 \(terminalOpenWaitSeconds) 秒内还没有会话注册上来（可能卡在首连或主机密钥确认），**命令没有执行**。等窗口连上后用 terminals 找到会话，再请用户在窗口里跑，或重新 terminal open。")
                )
            }
            return .success(
                id: request.id,
                message: String(localized: "已为「\(profile.name)」打开终端窗口 \(windowID.uuidString)，但 \(terminalOpenWaitSeconds) 秒内还没有会话注册上来（可能卡在首连或主机密钥确认）。稍后用 terminals 再看一次。"),
                terminals: []
            )

        case .terminalWait:
            let entry = try resolveTerminal(request, deps)
            guard let session = deps.registry.session(for: entry.id) else {
                throw ControlFailure(
                    code: .terminal_disconnected,
                    message: String(localized: "会话「\(entry.title)」已经不在了（窗口关了？）")
                )
            }
            guard session.trackedRun != nil else {
                throw ControlFailure(
                    code: .invalid_request,
                    message: String(localized: "会话「\(entry.title)」里没有用 `terminal open -H <主机> -- <命令>` 跑过命令，没有可等的结果。看屏幕用 terminal read。")
                )
            }
            let seconds = min(
                max(0, request.waitSeconds ?? ControlProtocol.defaultTerminalWaitSeconds),
                ControlProtocol.maxTerminalWaitSeconds)
            let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
            while !Task.isCancelled, ContinuousClock.now < deadline,
                  let run = session.trackedRunSnapshot(terminalID: entry.id, maxBytes: 0),
                  run.state == "pending" || run.state == "running" {
                IOActivity.touch()
                try? await Task.sleep(for: .milliseconds(200))
            }
            let run = session.trackedRunSnapshot(
                terminalID: entry.id, maxBytes: ControlProtocol.maxTerminalRunOutputBytes)
            return .success(
                id: request.id,
                message: Self.waitMessage(run, entry: entry),
                terminals: [deps.registry.snapshot(of: entry)],
                run: run
            )

        default:
            throw ControlFailure(
                code: .invalid_request,
                message: String(localized: "动作 \(request.action.rawValue) 不属于终端组")
            )
        }
    }

    /// `terminal-open` 要在窗口里跑的命令（`-c` 或 `--` 之后）；都没给是 nil（只开窗口）。
    private static func windowCommand(_ request: ControlRequest) throws(ControlFailure) -> String? {
        let hasArgs = !(request.args ?? []).isEmpty
        let inline = request.command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard hasArgs || !inline.isEmpty else { return nil }
        let command = try commandText(request)
        if let problem = TerminalTrackedRun.validate(command) {
            throw ControlFailure(code: .invalid_request, message: problem)
        }
        return command
    }

    private static func waitMessage(_ run: ControlTerminalRun?, entry: TerminalSessionEntry) -> String {
        let id = String(entry.id.uuidString.prefix(8))
        switch run?.state {
        case "finished":
            let exitText = run?.exitCode.map(String.init) ?? String(localized: "未知", comment: "退出码未知")
            return String(localized: "命令已结束，退出码 \(exitText)")
        case "disconnected":
            return String(localized: "命令没跑完会话就断了（远端退出或网络断开），没有退出码")
        case "pending":
            return String(localized: "窗口还没连上 / 命令还没开始（可能在等首连或主机密钥确认）。再 `terminal wait -t \(id)`")
        default:
            return String(localized: "命令还在跑（可能在等用户在窗口里输入）。再 `terminal wait -t \(id)` 继续等，或 `terminal read -t \(id)` 看看屏幕上停在哪")
        }
    }

    /// `terminal-open` 等新会话注册的上限（秒）。首连要建 SSH，几秒是常态；
    /// 再久就不该占着 `ControlServer` 的 handler 名额（它有 120 s 兜底）。
    private var terminalOpenWaitSeconds: Int { 6 }

    /// `--terminal` → 会话。缺字段是 `invalid_request`，不是「找不到」。
    private func resolveTerminal(
        _ request: ControlRequest,
        _ deps: Dependencies
    ) throws(ControlFailure) -> TerminalSessionEntry {
        guard let needle = request.terminal?.trimmingCharacters(in: .whitespacesAndNewlines),
              !needle.isEmpty else {
            throw ControlFailure(
                code: .invalid_request,
                message: String(localized: "\(request.action.rawValue) 需要 --terminal <会话 id 或唯一前缀>；先用 terminals 列一下")
            )
        }
        return try deps.registry.resolve(needle)
    }

    /// 会话所属主机的 `sftpOnly` 硬规则。档案已删（用户在会话开着时删了主机）时
    /// 查不到就放行 —— 这条会话是用户自己开的，没有可绕的定性可言。
    private func requireExecCapableSession(
        _ entry: TerminalSessionEntry,
        action: ControlAction,
        _ deps: Dependencies
    ) throws(ControlFailure) {
        let serverID = entry.serverID
        var descriptor = FetchDescriptor<ServerProfile>(
            predicate: #Predicate { $0.id == serverID })
        descriptor.fetchLimit = 1
        guard let profile = (try? deps.modelContainer.mainContext.fetch(descriptor))?.first
        else { return }
        try requireExecCapable(profile, action: action)
    }

    /// `--lines` 收口：非正数回默认，上限一屏字节兜底（真正的封顶是 `maxScreenBytes`）。
    private func clampScreenLines(_ requested: Int?) -> Int {
        guard let requested, requested > 0 else { return ControlProtocol.defaultScreenLines }
        // 字节上限才是硬顶；行数放宽到它的 4 倍，免得「我要 2000 行」直接被砍成 80。
        return min(requested, ControlProtocol.defaultScreenLines * 25)
    }
}
