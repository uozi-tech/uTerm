import SwiftUI
import SwiftData

/// 一个终端窗格：绑定一台服务器，持有 SwiftTerm 会话。
@MainActor
@Observable
final class PaneModel: Identifiable {
    let id: UUID
    let serverProfileID: UUID
    let fileBuffer: FileBuffer?
    let session = TerminalSession()
    /// 终端连接的 host-key 审批桥接。
    let hostKeyRelay = HostKeyChallengeRelay()
    private var isConnecting = false

    /// 跨窗口会话注册的凭条（CLI 的 `terminals` / `terminal-read` / `terminal-send`）。
    /// 由 `WorkspaceModel.attachSessionRegistry` 在窗口视图注入注册表后 stamp；
    /// 没 stamp（单测 / 预览）时全部 no-op。是接线不是状态，故 `@ObservationIgnored`。
    @ObservationIgnored var registrar: TerminalSessionRegistrar?

    /// 上次连接成功时那台服务器的名字。注册表要它当 `serverName` / `title`，
    /// 而 `PaneModel` 只存 `serverProfileID` —— 连上时顺手记一份，
    /// 供「先连上、后注入注册表」的窗口补登记（`adopt(registrar:)`）。
    @ObservationIgnored private(set) var connectedServerName: String?

    init(id: UUID = UUID(), serverProfileID: UUID, fileBuffer: FileBuffer? = nil) {
        self.id = id
        self.serverProfileID = serverProfileID
        self.fileBuffer = fileBuffer
    }

    /// 用给定的服务器配置发起连接。
    func connect(profile: ServerProfile, modelContainer: ModelContainer) async {
        guard fileBuffer == nil else { return }
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
            connectedServerName = profile.name
            // 连上了才登记 —— `terminals` 列的是「能读能写的活会话」，
            // 连接中 / 已失败的窗格对 CLI 没有意义。
            if session.connectionState == .connected {
                registrar?.register(paneID: id,
                                    serverID: profile.id,
                                    serverName: profile.name,
                                    session: session)
            }
        } catch {
            session.markFailed("\(error)")
        }
    }

    /// 窗口把注册表凭条补发下来时调用（窗口视图的 `.task` 可能晚于窗格建连）。
    /// 已经连上的窗格立刻补登记，未连上的等 `connect` 走正常路径。
    func adopt(registrar: TerminalSessionRegistrar) {
        guard fileBuffer == nil else { return }
        self.registrar = registrar
        guard session.connectionState == .connected, let name = connectedServerName else { return }
        registrar.register(paneID: id,
                           serverID: serverProfileID,
                           serverName: name,
                           session: session)
    }

    /// 服务器配置已不存在时调用。
    func markServerMissing() {
        guard fileBuffer == nil else { return }
        session.markFailed("服务器配置已被删除")
    }

    /// 窗格被关闭/移除时调用。
    func dispose() {
        guard fileBuffer == nil else { return }
        registrar?.unregister(paneID: id)
        session.dispose()
        Task { await session.close() }
        hostKeyRelay.resolve(false)
    }
}
