import Foundation
import SwiftData

/// 设备「经这台 Mac 打开主机」在 Mac 上的落点：给那台保存着的主机开一个终端窗口（Mac 自己用它的凭据去连），
/// 等会话登记进注册表，回会话 id。设备拿到 id 后走正常的接入流程。
///
/// SSH 连接在 Mac 上：设备退到后台、断网、被系统结束都不影响它，窗口留在 Mac 上接着用。
///
/// 做成可注入的闭包：测试里换成直接登记一个假后端会话的版本，不碰真实的窗口与连接。
nonisolated struct RemoteHostOpener: Sendable {
    typealias Failure = RemoteLocalShellOpener.Failure

    /// 参数是主机的 id（`ServerProfile.id`）。
    let open: @MainActor @Sendable (UUID) async -> Result<UUID, Failure>

    init(open: @escaping @MainActor @Sendable (UUID) async -> Result<UUID, Failure>) {
        self.open = open
    }

    static let unavailable = RemoteHostOpener { _ in .failure(Failure(message: "这台 Mac 不支持代为打开主机")) }

    /// 开窗口之后等会话登记的上限。会话要等 SSH 连上才登记；首次连接要在 Mac 上确认主机密钥的话等不到。
    static let waitSeconds = 30

    @MainActor
    static func live(settings: RemoteControlSettings, registry: TerminalSessionRegistry,
                     container: ModelContainer) -> RemoteHostOpener {
        RemoteHostOpener { [weak settings, weak registry] serverID in
            guard let settings, let registry else { return .failure(Failure(message: "uTerm 正在退出")) }
            guard settings.isOpenHostEnabled else {
                return .failure(Failure(message: "Mac 上没有打开「允许打开已保存的主机」。在 Mac 的 uTerm 里打开「设置 › 远程控制」。"))
            }
            let wanted = FetchDescriptor<ServerProfile>(predicate: #Predicate { $0.id == serverID })
            guard let profile = try? container.mainContext.fetch(wanted).first else {
                return .failure(Failure(message: "这台 Mac 上没有这台主机。主机经 iCloud 同步过去需要一点时间，稍后再试，或者在 Mac 上添加它。"))
            }
            guard !profile.sftpOnly else {
                return .failure(Failure(message: "这台主机设成了仅 SFTP，不能开终端"))
            }
            guard let open = registry.openTerminalWindow, let windowID = open(serverID) else {
                return .failure(Failure(message: "Mac 上的 uTerm 还没准备好打开窗口，稍后再试"))
            }
            guard let entry = await registry.waitForSession(inWindow: windowID, timeout: .seconds(waitSeconds)) else {
                return .failure(Failure(message: "Mac 未能在 \(waitSeconds) 秒内连上这台主机，原因见 Mac 上的终端窗口"))
            }
            return .success(entry.id)
        }
    }
}
