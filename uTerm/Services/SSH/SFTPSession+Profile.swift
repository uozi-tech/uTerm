import Foundation
import SwiftData

extension SFTPSession {
    /// 由一台已保存主机建 SFTP 会话（macOS 文件侧栏 / SFTP 窗口、iOS 文件标签共用）。
    ///
    /// 与 `SSHConnection.make` 同一套凭据解析：`@Model` 字段在主线程拍成快照，钥匙串读取放到
    /// 并发线程池里做；跳板机凭据缺了直接报错，绝不悄悄绕过跳板机直连
    /// （`SSHAuthResolver.resolveForConnect`）。底层连接走 `SSHClientFactory.connectShared`，
    /// 与同主机的终端共用一条 SSH 连接（`SharedConnectionPool`），`close()` 只归还租约。
    ///
    /// - Parameter keychain: 测试注入假钥匙串用；生产取默认的 `KeychainStore()`。
    @MainActor
    static func make(
        profile: ServerProfile,
        container: ModelContainer,
        approver: @escaping @Sendable (HostKeyChallenge) async -> Bool,
        approvesInteractively: Bool = true,
        keychain: some KeychainReading & Sendable = KeychainStore()
    ) async throws -> SFTPSession {
        let snapshot = SSHConnection.ProfileSnapshot(profile)
        let resolved = try await resolveAuthOffMain(
            SSHAuthResolver.Lookup(profile),
            jump: profile.jumpHost.map(SSHAuthResolver.Lookup.init),
            keychain: keychain)
        ConnectTimeline.current?.mark("keychain")
        let connected = try await SSHClientFactory.connectShared(
            profile: snapshot,
            auth: resolved.auth, jumpHostAuth: resolved.jump,
            hostKeyVerifier: HostKeyVerifier(modelContainer: container),
            hostKeyApprover: approver,
            approvesInteractively: approvesInteractively)
        let session = try await SFTPSession(connected: connected)
        ConnectTimeline.current?.mark("sftpInit")
        return session
    }

    /// 钥匙串读取放到并发线程池里做；规则本身是 `SSHAuthResolver.resolveForConnect` 的同步版。
    @concurrent private static func resolveAuthOffMain(
        _ profile: SSHAuthResolver.Lookup,
        jump: SSHAuthResolver.Lookup?,
        keychain: some KeychainReading & Sendable
    ) async throws -> (auth: ResolvedAuth, jump: ResolvedAuth?) {
        try SSHAuthResolver.resolveForConnect(profile, jump: jump, keychain: keychain)
    }
}
