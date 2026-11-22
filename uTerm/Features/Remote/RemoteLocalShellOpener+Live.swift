import Foundation

// App 进程里的落点：开本机终端窗口、等会话登记。远控进程经 XPC 转给 App 办。
extension RemoteLocalShellOpener {
    @MainActor
    static func live(settings: RemoteControlSettings, registry: TerminalSessionRegistry) -> RemoteLocalShellOpener {
        RemoteLocalShellOpener(workspaces: { [weak settings] in
            guard settings?.isLocalShellEnabled == true else { return [] }
            return LocalShellWorkspaces.shared.list(open: LocalShellWindowRouter.shared.openDirectories)
        }, open: { [weak settings, weak registry] directory in
            guard let settings, let registry else { return .failure(Failure(message: String(localized: "uTerm 正在退出"))) }
            guard settings.isLocalShellEnabled else {
                return .failure(Failure(message: String(localized: "Mac 上没有打开「允许打开本机终端」。在 Mac 的 uTerm 里打开「设置 › 远程控制」。")))
            }
            guard let open = registry.openLocalShell, let sessionID = open(directory) else {
                return .failure(Failure(message: String(localized: "Mac 上的 uTerm 还没准备好打开窗口，稍后再试")))
            }
            guard let entry = await registry.waitForSession(id: sessionID, timeout: .seconds(waitSeconds)) else {
                return .failure(Failure(message: String(localized: "本机终端未能在 \(waitSeconds) 秒内启动，原因见 Mac 上的本机终端窗口")))
            }
            return .success(entry.id)
        })
    }
}
