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

    /// 只读不清空 —— 复用连接的重连逻辑据此判断「这次建连失败是否因主机指纹未信任」
    /// （是则不重试、立即上抛交 markUnreachable）。
    func peek() -> HostKeyChallenge? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

/// 每台一条**复用**的 SSH 连接：首条命令建连，之后所有命令在同一条连接上多开 exec channel；
/// 连接断了（sshd 重启 / 网络抖动 / apt 升级重启服务）自动重连并重试。Agent 一台跑多条命令
/// 时不再每条重新握手 —— 消除「连接风暴」（避免 MaxStartups 拒连）与重复握手开销，显著提升健壮性。
///
/// `actor` 串行化访问；持有的 `ConnectedClient` 非 `Sendable`，但只在本 actor 隔离域内触碰。
/// **用完必须 `close()`**（调用方在该台跑完后关），否则连接泄漏。
actor ReusableSSHConnection {
    private let connect: @Sendable () async throws -> ConnectedClient
    private let hostKeyChallenges: HostKeyChallengeSink
    private var client: ConnectedClient?
    private var closed = false

    /// 建连 / 重连重试次数与退避——扛瞬时拒连 / 抖动 / sshd 重启窗口；主机指纹未信任不在此重试。
    private static let maxConnectAttempts = 3
    private static let reconnectBackoff: Duration = .seconds(3)

    init(connect: @escaping @Sendable () async throws -> ConnectedClient,
         hostKeyChallenges: HostKeyChallengeSink) {
        self.connect = connect
        self.hostKeyChallenges = hostKeyChallenges
    }

    /// 在复用连接上跑一条命令。连接不存在 / 已断则（重）建连；exec 遇传输层失败（连接死了）
    /// 丢弃连接、重连一次再试。命令层错误（非零退出）已被 `SSHCommandExecutor` 包成 exit 0，
    /// 不会走到这里。
    func exec(_ command: String) async throws -> String {
        let c = try await ensureConnected()
        do {
            return try await c.exec(command)
        } catch {
            guard !closed, SSHTransportFailure.isTransportFailure(error) else { throw error }
            await dropClient()
            return try await ensureConnected().exec(command)
        }
    }

    func close() async {
        closed = true
        await dropClient()
    }

    private func ensureConnected() async throws -> ConnectedClient {
        if let client { return client }
        if closed { throw CancellationError() }
        let c = try await connectWithRetry()
        if closed { await c.close(); throw CancellationError() }
        client = c
        return c
    }

    /// 建连重试：传输 / 拒连 / 抖动退避重试；**主机指纹未信任**（sink 已记下质询）立即上抛——
    /// 重试也必被拒，且要让上层 `markUnreachable` 据 sink 弹「信任并重试」。
    private func connectWithRetry() async throws -> ConnectedClient {
        var lastError: Error?
        for attempt in 0..<Self.maxConnectAttempts {
            do {
                return try await connect()
            } catch {
                lastError = error
                if hostKeyChallenges.peek() != nil { throw error }
                if attempt < Self.maxConnectAttempts - 1 {
                    try? await Task.sleep(for: Self.reconnectBackoff)
                }
            }
        }
        throw lastError ?? CancellationError()
    }

    private func dropClient() async {
        if let client { await client.close() }
        client = nil
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
    /// - `reuseConnection`：true 则返回一条**复用连接**（`connection`），同台多条命令共用、
    ///   断线自动重连——并行窗口用（健壮性 + 省握手）；调用方跑完该台后须 `connection.close()`。
    ///   false（默认）保持「每条命令独立连接、跑完即关」的旧行为，`connection` 为 nil。
    ///
    /// 返回的 `hostKeyChallenges`：建连若因未知 / 不匹配主机密钥被拒，质询会落进 sink，
    /// 调用方读出后展示指纹。
    @MainActor
    static func make(
        server: ServerProfile,
        container: ModelContainer,
        trustNewKeys: Bool = false,
        reuseConnection: Bool = false
    ) throws -> (executor: SSHCommandExecutor, hostKeyChallenges: HostKeyChallengeSink, connection: ReusableSSHConnection?) {
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

        // 2) 建连闭包 @Sendable，仅捕获上面的 Sendable 值（sink 经 @unchecked Sendable）；
        //    HostKeyVerifier（actor）在闭包内由 container 构造。审批**仅在拒绝时记录质询**——
        //    trustNewKeys=true 时握手成功不污染 sink（否则重连逻辑会误判为指纹问题）。
        let connect: @Sendable () async throws -> ConnectedClient = {
            try await SSHClientFactory.connect(
                profile: snapshot,
                auth: auth,
                jumpHostAuth: resolvedJumpAuth,
                hostKeyVerifier: HostKeyVerifier(modelContainer: container),
                hostKeyApprover: { challenge in
                    if !trustNewKeys { sink.record(challenge) }   // 记录指纹供「信任并重试」展示
                    return trustNewKeys                           // false=拒绝（默认）；true=信任并继续
                })
        }

        if reuseConnection {
            let reusable = ReusableSSHConnection(connect: connect, hostKeyChallenges: sink)
            let executor = SSHCommandExecutor { try await reusable.exec($0) }
            return (executor, sink, reusable)
        } else {
            // 旧行为：每条命令独立连接、跑完即关。
            let executor = SSHCommandExecutor { wrappedCommand in
                let connected = try await connect()
                do {
                    let out = try await connected.exec(wrappedCommand)
                    await connected.close()
                    return out
                } catch {
                    await connected.close()
                    throw error
                }
            }
            return (executor, sink, nil)
        }
    }
}
