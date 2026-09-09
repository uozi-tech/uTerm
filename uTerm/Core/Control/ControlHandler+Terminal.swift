import Foundation

/// 终端组：`terminals` / `terminal-read` / `terminal-send` / `terminal-open`。
///
/// 硬约束（技能文档必须原样转述给模型）：
/// - **读屏是快照不是流**：两次 `terminal-read` 之间的输出会丢。要拿命令结果请用 `run`。
/// - **注入没有输出边界**：`terminal-send` 与用户键入交错，不保证你能拿到这条命令的结果；
///   它的正当用途是「让用户看见」，不是拿数据。
/// - SwiftTerm 的 buffer 读取只能在 MainActor 上做（`getLine` / `translateToString`）。
///
/// Wave 3 待填：四个动作的实现 + 会话解析（id 或唯一前缀，歧义回 `terminal_ambiguous`）。
extension ControlHandler {

    func handleTerminal(
        _ request: ControlRequest,
        _ deps: Dependencies
    ) async throws -> ControlResponse {
        switch request.action {
        case .terminals:
            // Wave 3：deps.registry.entries → [ControlTerminalSnapshot]。
            throw ControlFailure.notImplemented("terminals")
        case .terminalRead:
            // Wave 3：解析会话 → TerminalSession.snapshotScreen(lines:)（默认
            // defaultScreenLines，封顶 maxScreenBytes）→ ControlScreenSnapshot。
            throw ControlFailure.notImplemented("terminal-read")
        case .terminalSend:
            // Wave 3：解析会话 → requireExecCapable → TerminalSession.injectInput(_:)
            //（`enter == true` 追加 "\r"）。
            throw ControlFailure.notImplemented("terminal-send")
        case .terminalOpen:
            // Wave 3：resolveHost → requireExecCapable → deps.registry.openTerminalWindow(hostID)
            // → 返回新会话 id。
            throw ControlFailure.notImplemented("terminal-open")
        default:
            throw ControlFailure(
                code: .invalid_request,
                message: "动作 \(request.action.rawValue) 不属于终端组"
            )
        }
    }
}
