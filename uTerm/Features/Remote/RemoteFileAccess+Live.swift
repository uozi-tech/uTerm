import Foundation

// App 进程里的落点：经 App 内嵌的 `uTermShellAgent.xpc` 执行。远控进程有自己的一份（`RemoteHostFileClient`）。
extension RemoteFileAccess {
    /// 文件访问和「允许打开本机终端」共用一个开关：能开本机 shell 的设备本来就能读写这台 Mac 上的任何文件、
    /// 跑任何命令，再单设一道开关只是摆设。
    @MainActor
    static func live(settings: RemoteControlSettings) -> RemoteFileAccess {
        RemoteFileAccess(refusal: { [weak settings] _ in
            guard let settings else { return RemoteFileError(.unreachable, "uTerm 正在退出") }
            guard settings.isLocalShellEnabled else {
                return RemoteFileError(.disabled, "Mac 上没有打开「允许打开本机终端」（远程访问文件、执行命令和它共用这个开关）。"
                                       + "在 Mac 的 uTerm 里打开「设置 › 远程控制」。")
            }
            return nil
        }, perform: { payload in
            do {
                return try await LocalShellService.shared.client.fileRequest(payload)
            } catch {
                return RemoteFileCodec.packReply(
                    .failure(RemoteFileCodec.requestID(of: payload) ?? UUID(),
                             RemoteFileError(.unreachable, "Mac 上的辅助程序没有响应：\(error.localizedDescription)")),
                    compress: false)
            }
        })
    }
}
