import Foundation

/// 远控进程里的文件服务：交给它包内的无沙盒 XPC 服务（和 App 里的是同一个 `uTermShellAgent`）执行。远控进程自己带沙盒，
/// 读不到用户的主目录；XPC 服务随远控进程而不是随 App 生灭，所以 App 重启时在途的文件请求、命令照常完成。
nonisolated final class RemoteHostFileClient: @unchecked Sendable {
    static let shared = RemoteHostFileClient()

    private let lock = NSLock()
    private var connection: NSXPCConnection?

    private func proxy(onError: @escaping @Sendable (Error) -> Void) -> (any LocalShellAgentProtocol)? {
        lock.withLock {
            if connection == nil {
                let connection = NSXPCConnection(serviceName: LocalShellAgent.serviceName)
                connection.remoteObjectInterface = NSXPCInterface(with: LocalShellAgentProtocol.self)
                connection.invalidationHandler = { @Sendable [weak self] in self?.lock.withLock { self?.connection = nil } }
                connection.resume()
                self.connection = connection
            }
            return connection?.remoteObjectProxyWithErrorHandler(onError) as? any LocalShellAgentProtocol
        }
    }

    func perform(_ payload: Data) async -> Data {
        await withCheckedContinuation { continuation in
            let once = RemoteOnce(continuation)
            let failure: @Sendable (String) -> Data = { message in
                RemoteFileCodec.packReply(.failure(RemoteFileCodec.requestID(of: payload) ?? UUID(),
                                                   RemoteFileError(.unreachable, message)), compress: false)
            }
            guard let proxy = proxy(onError: { @Sendable error in
                once.resume(failure(String(localized: "Mac 上的辅助程序没有响应：\(error.localizedDescription)")))
            }) else {
                return once.resume(failure(String(localized: "Mac 上的辅助程序没有响应")))
            }
            proxy.fileRequest(payload) { once.resume($0) }
        }
    }

    /// 门禁同 App 里的 `RemoteFileAccess.live`：和「允许打开本机终端」共用一个开关。
    @MainActor
    static func access(settings: RemoteControlSettings) -> RemoteFileAccess {
        RemoteFileAccess(refusal: { [weak settings] _ in
            guard let settings else { return RemoteFileError(.unreachable, String(localized: "远控进程正在退出")) }
            guard settings.isLocalShellEnabled else {
                return RemoteFileError(.disabled, String(localized: "Mac 上没有打开「允许打开本机终端」（远程访问文件、执行命令和它共用这个开关）。在 Mac 的 uTerm 里打开「设置 › 远程控制」。"))
            }
            return nil
        }, perform: { payload in await shared.perform(payload) })
    }
}
