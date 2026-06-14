import Foundation
import SwiftData

/// 记录一次非交互建连过程中触发的 host-key 质询，供并行窗口展示指纹 /
/// 提供「信任并重试」。线程安全（`NSLock`）；约定**每台一个实例**（每个执行器一个），
/// 同台内 `run` 串行，无跨台争用。
///
/// 标 `nonisolated`：审批闭包在 NIO event-loop 线程（非主 actor）调用 `record`，
/// 而项目以 `-default-isolation=MainActor` 编译会把本类方法默认推断为 `@MainActor`。
nonisolated final class HostKeyChallengeSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: HostKeyChallenge?

    func record(_ challenge: HostKeyChallenge) {
        lock.lock(); defer { lock.unlock() }
        stored = challenge
    }

    /// 读取并清空 —— 避免上一轮的陈旧质询泄漏到下一次 `run`。
    func take() -> HostKeyChallenge? {
        lock.lock(); defer { lock.unlock() }
        let value = stored
        stored = nil
        return value
    }
}

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
/// host-key 审批：默认（`trustNewKeys == false`）**记录质询并拒绝** —— 终端 / SFTP 先连过、
/// 已知主机密钥已写入信任库时校验直接放行；遇到未知 / 不匹配的主机密钥则**把质询写进
/// `HostKeyChallengeSink`** 再拒绝、不弹 UI（Agent 侧没有交互入口）。调用方（并行窗口）
/// 据此 sink 把真实指纹摆给用户、提供「信任并重试」。
/// `trustNewKeys == true`（「信任并重试」重连时）则**信任并继续** —— 握手成功即把密钥写入
/// 信任库（TOFU），实现一次性的内联信任。
enum WorkspaceCommandExecutorFactory {

    /// 从 `server` 与 `container` 构造执行器；解析认证材料（可能抛错，调用方用
    /// `try?` 包住 → 失败则不注入执行器，Agent 自然不提供工具）。
    ///
    /// 返回执行器与其 `HostKeyChallengeSink`：建连若因未知 / 不匹配主机密钥被拒，
    /// 质询会落进 sink，调用方读出后展示指纹。
    @MainActor
    static func make(
        server: ServerProfile,
        container: ModelContainer,
        trustNewKeys: Bool = false
    ) throws -> (executor: SSHCommandExecutor, hostKeyChallenges: HostKeyChallengeSink) {
        // 1) 在 MainActor 上解析所有建连输入为 Sendable 值。
        let keychain = KeychainStore()
        let snapshot = SSHConnection.ProfileSnapshot(server)
        let auth = try SSHAuthResolver.resolve(profile: server, keychain: keychain)
        var jumpAuth: ResolvedAuth?
        if let jump = server.jumpHost {
            jumpAuth = try SSHAuthResolver.resolve(profile: jump, keychain: keychain)
        }
        let resolvedJumpAuth = jumpAuth
        let sink = HostKeyChallengeSink()

        // 2) 构造执行器。闭包 @Sendable，仅捕获上面的 Sendable 值（sink 经 @unchecked Sendable）；
        //    HostKeyVerifier（actor）在闭包内由 container 构造。
        let executor = SSHCommandExecutor { wrappedCommand in
            let connected = try await SSHClientFactory.connect(
                profile: snapshot,
                auth: auth,
                jumpHostAuth: resolvedJumpAuth,
                hostKeyVerifier: HostKeyVerifier(modelContainer: container),
                hostKeyApprover: { challenge in
                    sink.record(challenge)   // 记录指纹供「信任并重试」展示
                    return trustNewKeys      // false=记录并拒绝（默认）；true=信任并继续
                })
            do {
                let out = try await connected.exec(wrappedCommand)
                await connected.close()
                return out
            } catch {
                await connected.close()
                throw error
            }
        }
        return (executor, sink)
    }
}
