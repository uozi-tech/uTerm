import Foundation

/// 手机「新建本机终端」在 Mac 上的落点：开一个本机终端窗口，等它的会话登记进注册表，回会话 id。
/// 手机拿到 id 后走正常的接入流程，所以 shell 在 Mac 上也有窗口、断开后留着接着用。
///
/// 做成可注入的闭包：测试里换成直接登记一个假后端会话的版本，不碰真实的辅助进程与窗口。
nonisolated struct RemoteLocalShellOpener: Sendable {
    nonisolated struct Failure: Error, Equatable {
        let message: String
    }

    let open: @MainActor @Sendable () async -> Result<UUID, Failure>

    static let unavailable = RemoteLocalShellOpener { .failure(Failure(message: "这台 Mac 不支持打开本机终端")) }

    /// 开窗口之后等会话登记的上限：辅助程序冷启动 + 登录 shell 起来，正常一两秒。
    static let waitSeconds = 15

    @MainActor
    static func live(settings: RemoteControlSettings, registry: TerminalSessionRegistry) -> RemoteLocalShellOpener {
        RemoteLocalShellOpener { [weak settings, weak registry] in
            guard let settings, let registry else { return .failure(Failure(message: "uTerm 正在退出")) }
            guard settings.isLocalShellEnabled else {
                return .failure(Failure(message: "Mac 上没有打开「允许打开本机终端」。请在 Mac 的 uTerm 里打开 设置 › 远程控制"))
            }
            guard let open = registry.openLocalShellWindow, let windowID = open() else {
                return .failure(Failure(message: "Mac 上的 uTerm 还没准备好开窗口，请稍后再试"))
            }
            guard let entry = await registry.waitForSession(inWindow: windowID, timeout: .seconds(waitSeconds)) else {
                return .failure(Failure(message: "本机终端没能在 \(waitSeconds) 秒内启动，原因见 Mac 上新开的窗口"))
            }
            return .success(entry.id)
        }
    }
}
