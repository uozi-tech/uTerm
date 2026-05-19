import SwiftUI
import SwiftData

/// 一个终端窗格：绑定一台服务器，持有一个 `TerminalSession` 及其连接生命周期。
/// 连接流程（认证解析、host-key 审批、SSH 建立）由 M1 `TerminalPaneView` 迁入。
@MainActor
@Observable
final class PaneModel: Identifiable {
    let id: UUID
    let serverProfileID: UUID
    let session = TerminalSession()

    /// 待用户裁决的主机密钥挑战（驱动 `PaneView` 的 sheet）。
    var pendingChallenge: HostKeyChallenge?
    private var challengeDecision: CheckedContinuation<Bool, Never>?
    private var isConnecting = false

    init(id: UUID = UUID(), serverProfileID: UUID) {
        self.id = id
        self.serverProfileID = serverProfileID
    }

    /// 用给定的服务器配置发起连接。`profile` 由视图层按 `serverProfileID` 取出，
    /// 取不到（服务器已删除）时不调用本方法，改为 `markServerMissing()`。
    func connect(profile: ServerProfile, modelContainer: ModelContainer) async {
        guard !isConnecting else { return }
        // 重访标签时窗格会重新进入视图层级触发 connect；已连接/连接中则视为 no-op，
        // 不撕掉活动会话。仅 .idle（首次）/ .failed / .disconnected（重试）才继续。
        guard session.connectionState != .connected,
              session.connectionState != .connecting else { return }
        isConnecting = true
        defer { isConnecting = false }

        await session.close()
        let keychain = KeychainStore()
        do {
            let auth = try resolveAuth(for: profile, keychain: keychain)
            var jumpAuth: ResolvedAuth?
            if let jump = profile.jumpHost {
                jumpAuth = try resolveAuth(for: jump, keychain: keychain)
            }
            let verifier = HostKeyVerifier(modelContainer: modelContainer)
            let approver: @Sendable (HostKeyChallenge) async -> Bool = { [weak self] challenge in
                await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    Task { @MainActor in
                        guard let self else { cont.resume(returning: false); return }
                        if let stale = self.challengeDecision {
                            stale.resume(returning: false)
                        }
                        self.challengeDecision = cont
                        self.pendingChallenge = challenge
                    }
                }
            }
            let connection = SSHConnection(
                profile: SSHConnection.ProfileSnapshot(profile),
                auth: auth, jumpHostAuth: jumpAuth,
                hostKeyVerifier: verifier,
                hostKeyApprover: approver)
            await session.connect(using: connection)
        } catch {
            session.markFailed("\(error)")
        }
    }

    /// 服务器配置已不存在时调用。
    func markServerMissing() {
        session.markFailed("服务器配置已被删除")
    }

    /// host-key sheet 的裁决出口。两处（sheet 回调、teardown）都经此，
    /// 读取并置空后再 resume —— 双重 resume 结构上不可能。
    func resolveChallenge(_ trusted: Bool) {
        guard let cont = challengeDecision else { return }
        challengeDecision = nil
        pendingChallenge = nil
        cont.resume(returning: trusted)
    }

    /// 窗格被关闭/移除时调用：severs SwiftTerm delegate、关闭 SSH、解挂任何待决挑战。
    func dispose() {
        let s = session
        s.dispose()
        Task { await s.close() }
        resolveChallenge(false)
    }

    private func resolveAuth(for profile: ServerProfile,
                             keychain: KeychainStore) throws -> ResolvedAuth {
        try SSHAuthResolver.resolve(
            profile: profile,
            password: try? keychain.load(profileID: profile.id, kind: .password),
            privateKey: try? keychain.load(profileID: profile.id, kind: .privateKey),
            passphrase: try? keychain.load(profileID: profile.id, kind: .passphrase))
    }
}
