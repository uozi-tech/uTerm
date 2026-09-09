import Foundation
import SwiftData

/// 终端组：`terminals` / `terminal-read` / `terminal-send` / `terminal-open`。
///
/// 硬约束（技能文档必须原样转述给模型）：
/// - **读屏是快照不是流**：两次 `terminal-read` 之间的输出会丢。要拿命令结果请用 `run`。
/// - **注入没有输出边界**：`terminal-send` 与用户键入交错，不保证你能拿到这条命令的结果；
///   它的正当用途是「让用户看见」，不是拿数据。
/// - SwiftTerm 的 buffer 读取只能在 MainActor 上做（`getScrollInvariantLine` /
///   `translateToString`）—— 整个 `ControlHandler` 就是 `@MainActor`，天然满足。
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
                message: snapshots.isEmpty ? "当前没有活着的终端会话" : "共 \(snapshots.count) 条终端会话",
                terminals: snapshots
            )

        case .terminalRead:
            let entry = try resolveTerminal(request, deps)
            guard let session = deps.registry.session(for: entry.id) else {
                throw ControlFailure(
                    code: .terminal_disconnected,
                    message: "会话「\(entry.title)」已经不在了（窗口关了？）"
                )
            }
            let lines = clampScreenLines(request.lines)
            let screen = session.snapshotScreen(
                lines: lines, maxBytes: ControlProtocol.maxScreenBytes)
            return .success(
                id: request.id,
                message: "读到 \(screen.lines.count) 行" + (screen.truncated ? "（上方已截断）" : ""),
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
                    message: "terminal-send 需要非空的 text"
                )
            }
            // 主机级硬规则：`sftpOnly` 主机拒绝一切终端操作。档案已被删的会话
            // 没法再判定，放行（会话本身是用户自己开的）。
            try requireExecCapableSession(entry, action: .terminalSend, deps)
            guard let session = deps.registry.session(for: entry.id) else {
                throw ControlFailure(
                    code: .terminal_disconnected,
                    message: "会话「\(entry.title)」已经不在了（窗口关了？）"
                )
            }
            do {
                try await session.injectInput(text, appendEnter: request.enter ?? false)
            } catch {
                throw ControlFailure(
                    code: .terminal_disconnected,
                    message: "会话「\(entry.title)」的连接已断开，没有写进去"
                )
            }
            return .success(
                id: request.id,
                message: "已写入会话「\(entry.title)」"
                    + ((request.enter ?? false) ? "（带回车）" : "（未回车，用户需自己按 Enter）")
                    + "；注入没有输出边界，要结果请改用 run",
                terminals: [entry.snapshot]
            )

        case .terminalOpen:
            guard let needle = request.host?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !needle.isEmpty else {
                throw ControlFailure(code: .invalid_request, message: "terminal-open 需要 --host")
            }
            let profile = try resolveHost(needle)
            try requireExecCapable(profile, action: .terminalOpen)
            guard let open = deps.registry.openTerminalWindow else {
                throw ControlFailure(
                    code: .app_not_ready,
                    message: "uTerm 还没接好开窗口的入口（主窗口尚未出现？）"
                )
            }
            guard let windowID = open(profile.id) else {
                throw ControlFailure(
                    code: .operation_failed,
                    message: "打开终端窗口失败"
                )
            }
            // `openWindow` 是同步返回的，但窗口 / 会话都还在异步搭：等注册表里
            // 出现这个窗口的会话再回 id，等不到就如实说明（窗口确实已经开了）。
            if let entry = await deps.registry.waitForSession(
                inWindow: windowID, timeout: .seconds(terminalOpenWaitSeconds)) {
                return .success(
                    id: request.id,
                    message: "已为「\(profile.name)」打开终端窗口",
                    terminals: [entry.snapshot]
                )
            }
            return .success(
                id: request.id,
                message: "已为「\(profile.name)」打开终端窗口 \(windowID.uuidString)，"
                    + "但 \(terminalOpenWaitSeconds) 秒内还没有会话注册上来"
                    + "（可能卡在首连或主机密钥确认）。稍后用 terminals 再看一次。",
                terminals: []
            )

        default:
            throw ControlFailure(
                code: .invalid_request,
                message: "动作 \(request.action.rawValue) 不属于终端组"
            )
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
                message: "\(request.action.rawValue) 需要 --terminal <会话 id 或唯一前缀>；"
                    + "先用 terminals 列一下"
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
        let profiles = (try? deps.modelContainer.mainContext
            .fetch(FetchDescriptor<ServerProfile>())) ?? []
        guard let profile = profiles.first(where: { $0.id == entry.serverID }) else { return }
        try requireExecCapable(profile, action: action)
    }

    /// `--lines` 收口：非正数回默认，上限一屏字节兜底（真正的封顶是 `maxScreenBytes`）。
    private func clampScreenLines(_ requested: Int?) -> Int {
        guard let requested, requested > 0 else { return ControlProtocol.defaultScreenLines }
        // 字节上限才是硬顶；行数放宽到它的 4 倍，免得「我要 2000 行」直接被砍成 80。
        return min(requested, ControlProtocol.defaultScreenLines * 25)
    }
}
