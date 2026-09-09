import Foundation

/// `ControlConnectionPooling` 的生产实现：按 hostID 持有 `ReusableSSHConnection`（exec）
/// 与 `SFTPSession`（文件），懒建、空闲 10 分钟自动关、`disconnect` 显式释放。
///
/// Wave 1 待填。实现要点：
/// - 建连闭包用 `HostConnectionSpec` 里已解析好的 Sendable 值 + `SSHClientFactory.connect`，
///   `hostKeyVerifier` 由捕获的 `ModelContainer` 在闭包内构造（`HostKeyVerifier` 是 actor）。
/// - `hostKeyApprover` 走**非交互**路径：`trustNewKeys: false` —— 记录质询到
///   `HostKeyChallengeSink` 后拒绝，再由本 actor 翻成 `ControlConnectError.hostKeyUnknown`
///   / `.hostKeyChanged` 上抛。绝不自动 TOFU。
/// - 空闲回收用一个 `lastUsedAt` + 周期检查（或每次访问时顺手清理），不要起常驻 Timer。
actor ControlConnectionPool: ControlConnectionPooling {

    /// app 级单例。`uTermApp` 注入给 `ControlHandler`。
    static let shared = ControlConnectionPool()

    /// 空闲多久后自动关闭一台主机的持有。
    static let idleTimeout: Duration = .seconds(600)

    init() {}

    func executor(for host: HostConnectionSpec) async throws -> SSHCommandExecutor {
        throw ControlConnectError.connectFailed("ControlConnectionPool.executor 尚未实现")
    }

    func sftp(for host: HostConnectionSpec) async throws -> any SFTPProviding {
        throw ControlConnectError.connectFailed("ControlConnectionPool.sftp 尚未实现")
    }

    func disconnect(hostID: UUID) async {}

    func disconnectAll() async {}

    func heldHostIDs() async -> [UUID] { [] }
}
