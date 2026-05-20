import SwiftUI
import SwiftData

/// 一个窗格：绑定一台服务器，按 `kind` 是终端或文件浏览。
/// 终端走 `TerminalSession`，文件走 `FileBrowserModel`；连接 / 释放统一由本类按 kind 分派。
@MainActor
@Observable
final class PaneModel: Identifiable {
    let id: UUID
    let serverProfileID: UUID
    let kind: PaneKind

    /// 终端连接的 host-key 审批桥接。文件窗格用 `FileBrowserModel` 自带的 relay。
    let hostKeyRelay = HostKeyChallengeRelay()
    private var isConnecting = false

    init(id: UUID = UUID(), serverProfileID: UUID, kind: PaneKindTag) {
        self.id = id
        self.serverProfileID = serverProfileID
        switch kind {
        case .terminal: self.kind = .terminal(TerminalSession())
        case .files: self.kind = .files(FileBrowserModel())
        }
    }

    /// 用给定的服务器配置发起连接。按 kind 分派。`profile` 由视图层按
    /// `serverProfileID` 取出，取不到（服务器已删除）时改调 `markServerMissing()`。
    func connect(profile: ServerProfile, modelContainer: ModelContainer) async {
        switch kind {
        case .terminal(let session):
            await connectTerminal(session: session, profile: profile,
                                  modelContainer: modelContainer)
        case .files(let model):
            await model.connect(profile: profile, modelContainer: modelContainer)
        }
    }

    private func connectTerminal(session: TerminalSession, profile: ServerProfile,
                                 modelContainer: ModelContainer) async {
        guard !isConnecting else { return }
        // 重访标签时窗格会重新进入视图层级触发 connect；已连接/连接中则视为 no-op。
        guard session.connectionState != .connected,
              session.connectionState != .connecting else { return }
        isConnecting = true
        defer { isConnecting = false }

        await session.close()
        let keychain = KeychainStore()
        do {
            let auth = try SSHAuthResolver.resolve(profile: profile, keychain: keychain)
            var jumpAuth: ResolvedAuth?
            if let jump = profile.jumpHost {
                jumpAuth = try SSHAuthResolver.resolve(profile: jump, keychain: keychain)
            }
            let verifier = HostKeyVerifier(modelContainer: modelContainer)
            let approver = hostKeyRelay.makeApprover()
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
        switch kind {
        case .terminal(let session):
            session.markFailed("服务器配置已被删除")
        case .files(let model):
            model.markUnavailable("服务器配置已被删除")
        }
    }

    /// 窗格被关闭/移除时调用。
    func dispose() {
        switch kind {
        case .terminal(let session):
            session.dispose()
            Task { await session.close() }
        case .files(let model):
            model.dispose()
        }
        hostKeyRelay.resolve(false)
    }
}
