import Foundation
@preconcurrency import Citadel
import NIOCore
import NIOSSH

/// 已建立的 SSH 连接束：目标客户端，以及（若经跳板机）跳板机客户端。
///
/// 终端（`SSHConnection`）与 SFTP 共享同一套连接建立逻辑 —— 它们都需要连到
/// 一个 `ServerProfile`（直连或单跳跳板机），并完成主机密钥校验。`SSHClientFactory`
/// 把这套逻辑从 `SSHConnection` 中抽出，`ConnectedClient` 则把建立结果打包成一个
/// `Sendable` 值，便于被持有它的并发任务（如 `SSHConnection` 的 `sessionTask`）
/// 捕获并独占负责 teardown。
///
/// `SSHClient` 本身非 `Sendable`；但 `ConnectedClient` 仅在构造后被传递、不再
/// 跨隔离域并发触碰，因此声明为 `@unchecked Sendable` —— 与 `SSHConnection`
/// 原先把目标/跳板机客户端作为区域隔离局部值 `sending` 进 `sessionTask` 的做法
/// 语义一致。
nonisolated struct ConnectedClient: @unchecked Sendable {
    /// 目标主机的 SSH 客户端（开 PTY / SFTP 子系统的对象）。
    let target: SSHClient
    /// 跳板机客户端；直连时为 `nil`。
    let bastion: SSHClient?

    /// 关闭连接 —— 先关目标、再关跳板机，与 `SSHConnection` 原 teardown 顺序一致。
    /// 每步 `try?`，不抛错。
    func close() async {
        try? await target.close()
        try? await bastion?.close()
    }
}

/// 终端与 SFTP 共享的 SSH 连接工厂。
///
/// 把原先内嵌在 `SSHConnection` 中的 `connectDirect` / `connectViaJumpHost` /
/// `makeAuthMethod` 逐字搬到此处。行为与 `SSHConnection` 之前完全一致：
/// 直连走目标 `host:port`，跳板机走 Citadel 原生 `jump(to:)`；每次连接都用
/// 针对自身 `host:port` 的 `HostKeyValidationDelegate` 做主机密钥校验。
///
/// 错误处理：与原实现一致 —— 直连失败抛 `connectFailed`，跳板机/jump 失败抛
/// `jumpHostFailed`，`jump` 失败时已建立的跳板机连接就地关闭。流的收尾
/// （`finishStreams` / `isClosed`）是调用方的 actor 状态，仍由调用方在捕获到
/// 抛出的错误后完成。
nonisolated enum SSHClientFactory {

    /// 建立到 `profile` 的 SSH 连接。`profile.jumpHost == nil` 走直连，
    /// 否则走单跳跳板机；返回的 `ConnectedClient` 由调用方负责生命周期管理。
    static func connect(
        profile: SSHConnection.ProfileSnapshot,
        auth: ResolvedAuth,
        jumpHostAuth: ResolvedAuth?,
        hostKeyVerifier: HostKeyVerifier,
        hostKeyApprover: @escaping @Sendable (HostKeyChallenge) async -> Bool
    ) async throws -> ConnectedClient {
        if let jumpHost = profile.jumpHost {
            // 配置了跳板机：必须有跳板机认证材料，否则报错 —— 绝不静默回退直连。
            guard let jumpHostAuth else {
                throw SSHConnection.SSHConnectionError.jumpHostFailed("缺少跳板机认证材料")
            }
            return try await connectViaJumpHost(
                profile: profile, jumpHost: jumpHost,
                auth: auth, jumpHostAuth: jumpHostAuth,
                hostKeyVerifier: hostKeyVerifier, hostKeyApprover: hostKeyApprover)
        } else {
            let target = try await connectDirect(
                profile: profile, auth: auth,
                hostKeyVerifier: hostKeyVerifier, hostKeyApprover: hostKeyApprover)
            return ConnectedClient(target: target, bastion: nil)
        }
    }

    /// 直连路径：连接 `profile.host:profile.port`。失败抛 `connectFailed`。
    private static func connectDirect(
        profile: SSHConnection.ProfileSnapshot,
        auth: ResolvedAuth,
        hostKeyVerifier: HostKeyVerifier,
        hostKeyApprover: @escaping @Sendable (HostKeyChallenge) async -> Bool
    ) async throws -> SSHClient {
        let authMethod = try makeAuthMethod(from: auth)

        do {
            return try await SSHClient.connect(
                host: profile.host,
                port: profile.port,
                authenticationMethod: authMethod,
                hostKeyValidator: .custom(HostKeyValidationDelegate(
                    host: profile.host, port: profile.port,
                    verifier: hostKeyVerifier, approver: hostKeyApprover)),
                reconnect: .never
            )
        } catch {
            // I4：连接/认证失败 —— 抛出后由调用方结束流，让消费者干净终止。
            throw SSHConnection.SSHConnectionError.connectFailed(error.localizedDescription)
        }
    }

    /// 跳板机路径（Task 9）：先连跳板机，再用 Citadel 原生 `jump(to:)` 在
    /// 跳板机连接上开 `direct-tcpip` 通道并完成第二次 SSH 握手，得到目标客户端。
    ///
    /// 生命周期：成功时把跳板机连接与目标客户端一起打包成 `ConnectedClient` 返回，
    /// 由调用方持有。
    ///
    /// 错误处理：每一步失败都抛 `jumpHostFailed("<detail>")`，已打开的资源
    /// （`jump` 失败时的跳板机连接）就地关闭，不留任何泄漏 / 挂起。
    private static func connectViaJumpHost(
        profile: SSHConnection.ProfileSnapshot,
        jumpHost: SSHConnection.ProfileSnapshot.JumpHostSnapshot,
        auth: ResolvedAuth,
        jumpHostAuth: ResolvedAuth,
        hostKeyVerifier: HostKeyVerifier,
        hostKeyApprover: @escaping @Sendable (HostKeyChallenge) async -> Bool
    ) async throws -> ConnectedClient {
        let bastionAuthMethod: SSHAuthenticationMethod
        let targetAuthMethod: SSHAuthenticationMethod
        do {
            bastionAuthMethod = try makeAuthMethod(from: jumpHostAuth)
            targetAuthMethod = try makeAuthMethod(from: auth)
        } catch {
            throw SSHConnection.SSHConnectionError.jumpHostFailed(error.localizedDescription)
        }

        let bastion: SSHClient
        do {
            bastion = try await SSHClient.connect(
                host: jumpHost.host,
                port: jumpHost.port,
                authenticationMethod: bastionAuthMethod,
                hostKeyValidator: .custom(HostKeyValidationDelegate(
                    host: jumpHost.host, port: jumpHost.port,
                    verifier: hostKeyVerifier, approver: hostKeyApprover)),
                reconnect: .never
            )
        } catch {
            throw SSHConnection.SSHConnectionError.jumpHostFailed(
                "无法连接跳板机 \(jumpHost.host):\(jumpHost.port) —— \(error.localizedDescription)")
        }

        // `SSHClientSettings.authenticationMethod` 是 `@Sendable () -> SSHAuthenticationMethod`
        // 转义闭包。
        let targetSettings = SSHClientSettings(
            host: profile.host,
            port: profile.port,
            authenticationMethod: { targetAuthMethod },
            hostKeyValidator: .custom(HostKeyValidationDelegate(
                host: profile.host, port: profile.port,
                verifier: hostKeyVerifier, approver: hostKeyApprover))
        )
        let target: SSHClient
        do {
            target = try await bastion.jump(to: targetSettings)
        } catch {
            // jump 失败 —— 跳板机连接已建立，必须就地关闭，避免泄漏。
            try? await bastion.close()
            throw SSHConnection.SSHConnectionError.jumpHostFailed(
                "经跳板机连接目标 \(profile.host):\(profile.port) 失败 —— \(error.localizedDescription)")
        }

        // 成功 —— 跳板机连接与目标客户端一起返回，由调用方持有并做生命周期管理。
        return ConnectedClient(target: target, bastion: bastion)
    }

    // MARK: - 认证材料构造

    /// 把 `ResolvedAuth` 转为 Citadel 的 `SSHAuthenticationMethod`。
    /// 私钥解析委托给 `PrivateKeyImporter`。
    static func makeAuthMethod(from auth: ResolvedAuth) throws -> SSHAuthenticationMethod {
        switch auth {
        case .password(let username, let password):
            return .passwordBased(username: username, password: password)

        case .privateKey(let username, let pem, let passphrase):
            do {
                let key = try PrivateKeyImporter.resolve(pem: pem, passphrase: passphrase)
                return key.authenticationMethod(username: username)
            } catch let error as PrivateKeyImportError {
                throw SSHConnection.SSHConnectionError.connectFailed(
                    error.errorDescription ?? "私钥导入失败")
            } catch {
                throw SSHConnection.SSHConnectionError.connectFailed(error.localizedDescription)
            }
        }
    }
}
