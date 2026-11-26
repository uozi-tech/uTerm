import Foundation

/// 设备请 Mac 在它的 Code 标签页里做的事（64 号消息 `codeTabAction`）在 Mac 上的落点：继续、新开、重新开始会话，
/// 或把会话移到新标签页，回做完之后的那个会话 id 或给人看的失败原因（65 号消息）。
///
/// 做成可注入的闭包（同 `RemoteLocalShellOpener`）：App 里接上本机终端窗口（`RemoteCodeTabActor.live`），远控进程里
/// 转给 App 办（XPC），测试里换成假的。远控进程也编这个文件，所以只用 Foundation，不碰 Code 标签页与终端引擎。
nonisolated struct RemoteCodeTabActor: Sendable {
    let perform: @MainActor @Sendable (RemoteCodeTabAction) async -> RemoteCodeTabActionResult

    init(perform: @escaping @MainActor @Sendable (RemoteCodeTabAction) async -> RemoteCodeTabActionResult) {
        self.perform = perform
    }

    static let unavailable = RemoteCodeTabActor { action in
        .failure(action, String(localized: "这台 Mac 不能在 Code 标签页里替设备开会话"))
    }
}

extension RemoteCodeTabActionResult {
    nonisolated static func success(_ action: RemoteCodeTabAction, session: UUID) -> RemoteCodeTabActionResult {
        RemoteCodeTabActionResult(requestID: action.requestID, session: session, error: nil)
    }

    nonisolated static func failure(_ action: RemoteCodeTabAction, _ message: String) -> RemoteCodeTabActionResult {
        RemoteCodeTabActionResult(requestID: action.requestID, session: nil, error: message)
    }
}
