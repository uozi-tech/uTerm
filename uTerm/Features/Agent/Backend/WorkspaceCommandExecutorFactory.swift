import Foundation
import SwiftData

/// 为 Agent 的 `run_command` 工具构造一个真实 SSH 命令执行器。
///
/// 设计：与 SFTP 一致 —— **每条命令独立开一条一次性 exec 连接**（不复用终端的
/// `SSHConnection`，避免触碰其 actor 生命周期）。每条命令：连接 → exec（已被
/// `SSHCommandExecutor` 包成「永远 exit 0 + 退出码哨兵 + 合并 stderr」的形式）
/// → 关闭 → 返回输出。
///
/// 并发：本函数运行在 `@MainActor`，在此处把建连所需的输入**解析成 `Sendable` 值**
/// （`ProfileSnapshot` / `ResolvedAuth` / `ModelContainer` 均为 `Sendable`），再让
/// `@Sendable` 闭包仅捕获这些值。`HostKeyVerifier` 是 `actor`（天然 `Sendable`），
/// 但仍按惯例在闭包内由捕获的 `ModelContainer` 重新构造，闭包不捕获任何
/// MainActor-隔离状态。
///
/// host-key 审批：`hostKeyApprover` 恒返回 `false` —— 终端 / SFTP 先连过、已知主机
/// 密钥已写入信任库时校验直接放行；遇到未知 / 不匹配的主机密钥则拒绝、不弹 UI
///（Agent 侧没有交互入口）。
enum WorkspaceCommandExecutorFactory {

    /// 从 `server` 与 `container` 构造执行器；解析认证材料（可能抛错，调用方用
    /// `try?` 包住 → 失败则不注入执行器，Agent 自然不提供工具）。
    @MainActor
    static func make(
        server: ServerProfile,
        container: ModelContainer
    ) throws -> SSHCommandExecutor {
        // 1) 在 MainActor 上解析所有建连输入为 Sendable 值。
        let keychain = KeychainStore()
        let snapshot = SSHConnection.ProfileSnapshot(server)
        let auth = try SSHAuthResolver.resolve(profile: server, keychain: keychain)
        var jumpAuth: ResolvedAuth?
        if let jump = server.jumpHost {
            jumpAuth = try SSHAuthResolver.resolve(profile: jump, keychain: keychain)
        }
        let resolvedJumpAuth = jumpAuth

        // 2) 构造执行器。闭包 @Sendable，仅捕获上面的 Sendable 值；
        //    HostKeyVerifier（actor）在闭包内由 container 构造。
        return SSHCommandExecutor { wrappedCommand in
            let connected = try await SSHClientFactory.connect(
                profile: snapshot,
                auth: auth,
                jumpHostAuth: resolvedJumpAuth,
                hostKeyVerifier: HostKeyVerifier(modelContainer: container),
                hostKeyApprover: { _ in false })
            do {
                let out = try await connected.exec(wrappedCommand)
                await connected.close()
                return out
            } catch {
                await connected.close()
                throw error
            }
        }
    }
}
