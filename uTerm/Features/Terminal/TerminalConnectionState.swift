import Foundation

/// 终端会话的连接状态（macOS `TerminalSession.ConnectionState` / iOS `MobileTerminalController.State`
/// 都是它的别名）。失败文案两端各自生成。
nonisolated enum TerminalConnectionState: Equatable, Sendable {
    case idle, connecting, connected
    /// 远端结束 / 连接断开 / 用户关闭。
    case disconnected
    case failed(String)
}

extension TerminalConnectionState {
    /// 系统唤醒 / 网络恢复后由 `ConnectionWatchdog` 调用。只在自认「已连接」时探测；后端判死时会自行
    /// 强制关闭通道，`exitStream` 级联把状态翻到 `.disconnected`，这里不写任何状态。
    func probeHealth(of backend: (any TerminalBackend)?) async {
        guard self == .connected, let backend else { return }
        _ = await backend.verifyConnectionAlive()
    }
}
