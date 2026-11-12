import Foundation

/// 远控文件请求在被控 Mac 上的落点：先过门禁，再交给不带沙盒的辅助程序执行。
///
/// 和 `RemoteLocalShellOpener` 一样做成可注入的闭包：测试里换成直接调 `RemoteFileService` 的版本，
/// 不碰真实的辅助进程。
nonisolated struct RemoteFileAccess: Sendable {
    /// 放行回 nil；不放行回拒绝的原因。
    let refusal: @MainActor @Sendable (RemoteFileOp) -> RemoteFileError?
    /// 打包好的请求进、打包好的应答出。不抛错：出了岔子也回一条带错误的应答。
    let perform: @Sendable (Data) async -> Data

    init(refusal: @escaping @MainActor @Sendable (RemoteFileOp) -> RemoteFileError? = { _ in nil },
         perform: @escaping @Sendable (Data) async -> Data) {
        self.refusal = refusal
        self.perform = perform
    }

    static let unavailable = RemoteFileAccess(
        refusal: { _ in RemoteFileError(.disabled, "这台 Mac 不支持远程访问文件") },
        perform: { payload in
            RemoteFileCodec.packReply(.failure(RemoteFileCodec.requestID(of: payload) ?? UUID(),
                                               RemoteFileError(.disabled, "这台 Mac 不支持远程访问文件")), compress: false)
        })

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
