import Foundation
import SwiftData

/// CLI 建连所需的一切，**已解析成 `Sendable` 值**。
///
/// 这是 MainActor 与连接池 actor 之间的唯一桥：认证材料在 MainActor 上从
/// `ServerProfile` + 钥匙串解析出来（`SSHAuthResolver.resolve`），之后连接闭包只捕获
/// 这些值，不捕获任何 MainActor 隔离状态 —— 与 `WorkspaceCommandExecutorFactory.make`
/// 的做法一致。
nonisolated struct HostConnectionSpec: Sendable {
    /// `ServerProfile.id`。连接池按它做键。
    let id: UUID
    /// 主机档案名（日志 / `ping.openHosts` 用）。
    let name: String
    /// host / port / 跳板机端点。
    let profile: SSHConnection.ProfileSnapshot
    let auth: ResolvedAuth
    /// 跳板机的认证材料；无跳板机为 nil。
    let jumpAuth: ResolvedAuth?

    init(
        id: UUID,
        name: String,
        profile: SSHConnection.ProfileSnapshot,
        auth: ResolvedAuth,
        jumpAuth: ResolvedAuth?
    ) {
        self.id = id
        self.name = name
        self.profile = profile
        self.auth = auth
        self.jumpAuth = jumpAuth
    }

    /// 在 MainActor 上把一台主机解析成可跨隔离域传递的建连输入。
    ///
    /// Wave 1 实现要点（照 `WorkspaceCommandExecutorFactory.make` 的前半段，但**不要**
    /// 复制它的执行器构造）：`KeychainStore()` → `SSHConnection.ProfileSnapshot(profile)`
    /// → `SSHAuthResolver.resolve(profile:keychain:)`，跳板机同样解析一次。
    /// 解析失败（钥匙串里没有密码 / 私钥）抛 `ControlConnectError.authFailed`。
    @MainActor
    static func resolve(
        profile: ServerProfile,
        container: ModelContainer
    ) throws -> HostConnectionSpec {
        throw ControlConnectError.connectFailed("HostConnectionSpec.resolve 尚未实现")
    }
}

/// 连接池建连失败的分类。三种主机密钥状态各自带指纹，供 handler 翻成
/// `host_key_unknown` / `host_key_changed` 并把指纹回给 CLI。
nonisolated enum ControlConnectError: Error, Sendable {
    /// 首连、信任库里没有这台主机的密钥。**绝不自动 TOFU** —— 拒绝并回指纹，
    /// 用户显式 `trust --fingerprint <值>` 才写 `KnownHost`。
    case hostKeyUnknown(fingerprint: String, algorithm: String)
    /// 信任库里有记录但对不上。即便 mutation 开着也不给 CLI 覆盖，必须回界面处理
    /// —— 这是中间人风险的最后一道闸。
    case hostKeyChanged(fingerprint: String, algorithm: String)
    case connectFailed(String)
    case authFailed(String)
}

/// CLI 自己的连接持有面。
///
/// uTerm 没有全局连接池（exec 走 `WorkspaceCommandExecutorFactory.make` 每窗一份），
/// 所以 CLI 需要一份**与窗口无关**的：关窗口不影响 CLI 持有，CLI 也不动任何窗口的状态。
///
/// 约定：
/// - 懒建 —— 第一次 `run` 才建 exec 连接，第一次 `sftp-*` 才建 SFTP 会话，两者独立
///   （`SFTPProviding.exec` 拿不到退出码，不能拿来跑 `run`）。
/// - 空闲 10 分钟自动 `close()`；`disconnect(hostID:)` 显式释放；主开关关闭时
///   `disconnectAll()` 全部释放。
protocol ControlConnectionPooling: Actor {
    /// 取（必要时建）该主机的命令执行器。
    func executor(for host: HostConnectionSpec) async throws -> SSHCommandExecutor
    /// 取（必要时建）该主机的 SFTP 会话。
    func sftp(for host: HostConnectionSpec) async throws -> any SFTPProviding
    /// 松开对某主机的 exec / SFTP 持有。
    func disconnect(hostID: UUID) async
    /// 释放全部持有（主开关关闭 / app 退出）。
    func disconnectAll() async
    /// 当前持有的主机 id（喂 `ping.openHosts` 与 `hosts.cliConnected`）。
    func heldHostIDs() async -> [UUID]
}
