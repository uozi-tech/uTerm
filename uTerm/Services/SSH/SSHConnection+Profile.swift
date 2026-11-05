import Foundation
import SwiftData

extension SSHConnection {
    /// 由一台已保存主机组装 SSH 终端后端（macOS 进程内连接 / iOS 终端共用）。
    ///
    /// `@Model` 的字段在主线程拍成快照，钥匙串那 3~5 次（有跳板机再翻倍）读取放到并发线程池里做，
    /// 不阻塞主线程。跳板机凭据缺了直接报错：新建连接不能悄悄绕过跳板机直连
    /// （见 `SSHAuthResolver.resolveForConnect`）。
    @MainActor
    static func make(
        profile: ServerProfile,
        container: ModelContainer,
        approver: @escaping @Sendable (HostKeyChallenge) async -> Bool
    ) async throws -> SSHConnection {
        let snapshot = ProfileSnapshot(profile)
        let resolved = try await SSHAuthResolver.resolveForConnect(
            SSHAuthResolver.Lookup(profile),
            jump: profile.jumpHost.map(SSHAuthResolver.Lookup.init))
        return SSHConnection(profile: snapshot, auth: resolved.auth, jumpHostAuth: resolved.jump,
                             hostKeyVerifier: HostKeyVerifier(modelContainer: container),
                             hostKeyApprover: approver)
    }
}
