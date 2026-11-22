import Foundation
import SwiftData
@_spi(uTermIntegration) import USSHKit

/// SSH 终端的后端：连接和 PTY 都在 `uterm-holder` 里跑的 `uterm-ssh` 进程上，App 重启不影响远端程序。
///
/// 先问 XPC 服务要会话。已有会话就直接接回，不碰钥匙串、不握手；新会话才解析凭据，经控制通道交给 `uterm-ssh`，
/// 再替它回答主机密钥的问题（信任记录和弹层都在 App 这边）。
///
/// SFTP、端口转发、CLI 都走 App 自己的连接，这里只管终端。贴图同理（见 `deliverImage`）。
actor HeldSSHBackend: HeldTerminalBackend, TerminalImageReceiving, TerminalTrueColorConfiguring {
    /// 连接一台服务器需要的东西。`resolveAuth` 只在真的要新建连接时才调。
    struct Target: Sendable {
        let profile: SSHConnection.ProfileSnapshot
        let resolveAuth: @Sendable () async throws -> (auth: ResolvedAuth, jump: ResolvedAuth?)
        let hostKeyVerifier: HostKeyVerifier
        let hostKeyApprover: @Sendable (HostKeyChallenge) async -> Bool

        /// 由一台已保存主机组装：凭据规则与进程内终端的 `SSHConnection.make` 是同一份
        /// （`SSHAuthResolver.resolveForConnect`，钥匙串离开主线程读、跳板机缺凭据报错），
        /// 只是推迟到真要新建连接时才读——接回已有会话不碰钥匙串。
        @MainActor
        static func make(
            profile: ServerProfile,
            container: ModelContainer,
            approver: @escaping @Sendable (HostKeyChallenge) async -> Bool
        ) -> Target {
            let lookup = SSHAuthResolver.Lookup(profile)
            let jumpLookup = profile.jumpHost.map(SSHAuthResolver.Lookup.init)
            return Target(
                profile: SSHConnection.ProfileSnapshot(profile),
                resolveAuth: { try await SSHAuthResolver.resolveForConnect(lookup, jump: jumpLookup) },
                hostKeyVerifier: HostKeyVerifier(modelContainer: container),
                hostKeyApprover: approver)
        }
    }

    private static let foregroundTimeout = Duration.milliseconds(1500)
    private static let setupCommandTimeout = Duration.seconds(10)

    private let core = HeldSessionCore()
    nonisolated var outputItems: AsyncStream<TerminalOutputItem> { core.output.items }
    nonisolated var exitStream: AsyncStream<Void> { core.exitStream }
    nonisolated var holderLink: HolderLink { core.holderLink }

    private let client: LocalShellAgentClient
    private let namespace: String
    private let sessionID: UUID
    private let initialColumns: Int
    private let initialRows: Int
    private let target: Target
    private var attributes: Data?
    private var handshake: HolderConnection?
    /// 新建连接失败在「路由不可达」上：`uterm-ssh` 的局域网权限多半没拿到。调用方据此退回进程内连接。
    private(set) var failedOnLocalNetwork = false

    init(client: LocalShellAgentClient, namespace: String = SSHSessionNamespace.current, sessionID: UUID,
         columns: Int, rows: Int, target: Target, attributes: Data?) {
        self.client = client
        self.namespace = namespace
        self.sessionID = sessionID
        initialColumns = max(1, columns)
        initialRows = max(1, rows)
        self.target = target
        self.attributes = attributes
    }

    func connect() async throws {
        do {
            try await open()
        } catch HolderSessionFailure.disconnected {
            // 连上了一个正在退出的 holder。socket 文件这时已经没了，再来一次就是新的。
            try await open()
        }
    }

    private func open() async throws {
        let opened = try await client.openSSHSession(namespace: namespace, id: sessionID,
                                                     columns: initialColumns, rows: initialRows)
        ConnectTimeline.current?.mark("holder")
        guard try await core.attach(opened.holder) else { throw SSHConnection.SSHConnectionError.alreadyClosed }
        if let attributes { await core.setAttributes(attributes) }
        guard let control = opened.control else {
            // 接回：App 不在的这段时间连接可能已经死了，问一声。死了 `uterm-ssh` 自己退出，走正常的断开路径。
            await core.send(HolderFrame(.probe))
            ConnectTimeline.current?.finish("reattached")
            return
        }
        do {
            try await handshake(control)
            ConnectTimeline.current?.mark("handshake")
            ConnectTimeline.current?.finish()
        } catch {
            ConnectTimeline.current?.finish("failed")
            await core.close()
            throw error
        }
    }

    private func handshake(_ control: FileHandle) async throws {
        let request = try await connectRequest()
        ConnectTimeline.current?.mark("keychain")
        let connection = HolderConnection(control)
        handshake = connection
        defer {
            connection.close()
            handshake = nil
        }
        let peer = SSHBridgeAppPeer(connection: connection, verifier: target.hostKeyVerifier, approver: target.hostKeyApprover)
        let outcome = await peer.run(request)
        switch outcome {
        case .connected:
            return
        case .failed(let failure):
            failedOnLocalNetwork = failure.localNetworkUnreachable == true
            switch failure.kind {
            case .jumpHost: throw SSHConnection.SSHConnectionError.jumpHostFailed(failure.message)
            case .connect: throw SSHConnection.SSHConnectionError.connectFailed(failure.message)
            }
        case .disconnected:
            // 本端要结束时对面也就退出了，这不算失败。
            guard await !core.finished else { throw SSHConnection.SSHConnectionError.alreadyClosed }
            throw SSHConnection.SSHConnectionError.connectFailed(String(localized: "终端的辅助进程意外退出"))
        }
    }

    private func connectRequest() async throws -> SSHBridgeConnectRequest {
        let resolved = try await target.resolveAuth()
        let material = Self.material(resolved.auth)
        var jumpHost: SSHBridgeJumpHost?
        if let jump = target.profile.jumpHost {
            guard let jumpAuth = resolved.jump else {
                throw SSHConnection.SSHConnectionError.jumpHostFailed(String(localized: "缺少登录凭据"))
            }
            let jumpMaterial = Self.material(jumpAuth)
            jumpHost = SSHBridgeJumpHost(host: jump.host, port: jump.port, username: jumpMaterial.username,
                                         credential: jumpMaterial.credential)
        }
        return SSHBridgeConnectRequest(
            host: target.profile.host, port: target.profile.port, username: material.username, credential: material.credential,
            jumpHost: jumpHost, hostKeyPolicy: SSHClientFactory.packageHostKeyPolicy().rawValue,
            connectTimeoutSeconds: Int(SSHClientFactory.connectTimeoutSeconds()),
            environment: RemoteTrueColor.terminalEnvironment.map { SSHBridgeEnvironmentVariable(name: $0.name, value: $0.value) })
    }

    private static func material(_ auth: ResolvedAuth) -> (username: String, credential: SSHBridgeCredential) {
        switch auth {
        case .password(let username, let password):
            return (username, .password(password))
        case .privateKey(let username, let pem, let passphrase):
            return (username, .privateKey(pem: pem, passphrase: passphrase))
        }
    }

    func takeReplay() async -> HolderReplay? {
        await core.takeReplay()
    }

    func write(_ data: Data) async {
        await core.write(data)
    }

    func resize(cols: UInt16, rows: UInt16) async {
        await core.resize(cols: cols, rows: rows)
    }

    func setAttributes(_ attributes: Data) async {
        self.attributes = attributes
        await core.setAttributes(attributes)
    }

    /// 同步交给连接的发送队列（退出 App 途中异步任务不一定来得及跑，之后的 `flushAndClose` 会等它写完），
    /// 再记下来供重连时重发。
    nonisolated func sendAttributes(_ attributes: Data) {
        holderLink.send(HolderFrame(.setAttributes, payload: Array(attributes)))
        Task { await remember(attributes) }
    }

    private func remember(_ attributes: Data) {
        self.attributes = attributes
    }

    /// 探活在 `uterm-ssh` 里做（它才有连接）。死了它退出，由退出流程报告，所以这里总是回 true。
    func verifyConnectionAlive() async -> Bool {
        await core.send(HolderFrame(.probe))
        return true
    }

    /// 每个标签各一条连接，这条连接上只有它自己的 shell，不用认 pty。关标签的路上等着它，所以限时。
    func foregroundActivity() async -> TerminalActivity {
        guard let output = try? await core.execOnChild(RemoteProcessTable.command, timeout: Self.foregroundTimeout),
              let table = RemoteProcessTable(output: output),
              table.shells.count == 1 else { return .unknown }
        return table.activity(of: table.shells[0])
    }

    nonisolated var trueColorHostKey: String { "\(target.profile.host):\(target.profile.port)" }

    func trueColorStatus() async throws -> RemoteTrueColor.Status {
        RemoteTrueColor.parseProbe(try await runSetupCommand(RemoteTrueColor.probeCommand))
    }

    func enableTrueColor() async throws -> String {
        let output = try await runSetupCommand(RemoteTrueColor.enableCommand)
        guard let file = RemoteTrueColor.parseEnabledFile(output) else {
            throw RemoteTrueColorError.unexpectedOutput
        }
        return file
    }

    /// 登录 shell 的 rc 可能卡住，所以限时。
    private func runSetupCommand(_ command: String) async throws -> String {
        do {
            return try await core.execOnChild(command, timeout: Self.setupCommandTimeout)
        } catch HeldExecFailure.unavailable {
            throw RemoteTrueColorError.notConnected
        } catch HeldExecFailure.timedOut {
            throw RemoteTrueColorError.timedOut
        } catch {
            throw RemoteTrueColorError.unexpectedOutput
        }
    }

    nonisolated var programsCanReadMacClipboard: Bool { false }

    /// 把图片传成远端 `/tmp` 下的文件。连接在 `uterm-ssh` 里，开不了 SFTP，所以这里走 App 自己的共享连接。
    func deliverImage(_ image: TerminalImage) async throws -> TerminalImageDelivery {
        guard await core.isConnected else { throw TerminalImageError.notConnected }
        let resolved = try await target.resolveAuth()
        let connected = try await SSHClientFactory.connectShared(
            profile: target.profile, auth: resolved.auth, jumpHostAuth: resolved.jump,
            hostKeyVerifier: target.hostKeyVerifier, hostKeyApprover: target.hostKeyApprover)
        do {
            let delivery = try await connected.uploadTerminalImage(image)
            await connected.close()
            return delivery
        } catch {
            await connected.close()
            throw error
        }
    }

    func close() async {
        handshake?.close()
        await core.close()
    }

    func detach() async {
        handshake?.close()
        await core.detach()
    }
}

/// 握手期间 App 这一头：发连接参数，回答 `uterm-ssh` 的主机密钥问题，等到连上或失败。
nonisolated private final class SSHBridgeAppPeer: @unchecked Sendable {
    enum Outcome: Sendable {
        case connected
        case failed(SSHBridgeFailure)
        case disconnected
    }

    private let connection: HolderConnection
    private let verifier: HostKeyVerifier
    private let approver: @Sendable (HostKeyChallenge) async -> Bool
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Outcome, Never>?

    init(connection: HolderConnection, verifier: HostKeyVerifier, approver: @escaping @Sendable (HostKeyChallenge) async -> Bool) {
        self.connection = connection
        self.verifier = verifier
        self.approver = approver
    }

    func run(_ request: SSHBridgeConnectRequest) async -> Outcome {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            connection.onFrame = { [self] frame in
                if let message = frame.bridgeMessage { receive(message) }
            }
            connection.onClosed = { [self] in finish(.disconnected) }
            connection.start()
            send(.connect(request))
        }
    }

    private func receive(_ message: SSHBridgeMessage) {
        switch message {
        case .verifyHostKey(let id, let key):
            // 信任库的查 / 记都不抛错（存储失败在 `HostKeyVerifier` 内部吞掉），原来的 do/catch 走不到。
            Task { [self] in
                send(.verifyResult(id: id, Self.verification(await verifier.verify(key.packageKey))))
            }
        case .rememberHostKey(let id, let key):
            Task { [self] in
                await verifier.remember(key.packageKey)
                send(.rememberResult(id: id))
            }
        case .approveHostKey(let id, let challenge):
            Task { [self] in
                let approved = await HostKeyApprovalCoalescer.shared.approve(HostKeyChallenge(
                    host: challenge.hostKey.host, port: challenge.hostKey.port,
                    kind: challenge.isMismatch ? .mismatch : .unknown,
                    newFingerprint: challenge.hostKey.fingerprint, oldFingerprint: challenge.previousFingerprint),
                    approver: approver)
                send(.approval(id: id, approved))
            }
        case .connected:
            finish(.connected)
        case .failed(let failure):
            finish(.failed(failure))
        case .connect, .verifyResult, .rememberResult, .approval, .exec, .execResult:
            break
        }
    }

    private func send(_ message: SSHBridgeMessage) {
        guard let frame = try? HolderFrame(bridge: message) else { return }
        connection.send(frame)
    }

    private func finish(_ outcome: Outcome) {
        lock.lock()
        let taken = continuation
        continuation = nil
        lock.unlock()
        taken?.resume(returning: outcome)
    }

    private static func verification(_ result: USSHKit.SSHHostKeyVerification) -> SSHBridgeVerification {
        switch result {
        case .trusted: return .trusted
        case .unknown: return .unknown
        case .mismatch(let previous): return .mismatch(previousFingerprint: previous)
        }
    }
}

/// 同时打开同一台新主机的几个标签，每个都各握一次手，但只问用户一次：一个窗口同时只能弹一个 sheet，
/// 后来的弹不出来，那个标签就永远卡在「连接中」。
actor HostKeyApprovalCoalescer {
    static let shared = HostKeyApprovalCoalescer()

    private enum Outcome { case approved, rejected, abandoned }
    private struct Ask {
        let token = UUID()
        let task: Task<Outcome, Never>
    }

    private var inFlight: [String: Ask] = [:]

    func approve(_ challenge: HostKeyChallenge, approver: @escaping @Sendable (HostKeyChallenge) async -> Bool) async -> Bool {
        let key = "\(challenge.host):\(challenge.port) \(challenge.newFingerprint)"
        while let running = inFlight[key] {
            let outcome = await running.task.value
            if outcome != .abandoned { return outcome == .approved }
            // 问的那个标签关掉了，用户没回答：撤掉这次询问，由还在等的标签重新问。
            if inFlight[key]?.token == running.token { inFlight[key] = nil }
        }
        let ask = Ask(task: Task {
            if await approver(challenge) { return .approved }
            return HostKeyAbandonment.take(challenge.id) ? .abandoned : .rejected
        })
        inFlight[key] = ask
        let outcome = await ask.task.value
        if inFlight[key]?.token == ask.token { inFlight[key] = nil }
        return outcome == .approved
    }
}

nonisolated private extension SSHBridgeHostKey {
    var packageKey: USSHKit.SSHHostKey {
        USSHKit.SSHHostKey(host: host, port: port, keyType: keyType, keyBlob: keyBlob, fingerprint: fingerprint)
    }
}

/// SSH 会话的 socket 目录，跟本机 shell 分开：两边的恢复逻辑各看各的，互不相认。
nonisolated enum SSHSessionNamespace {
    static var current: String { LocalShellNamespace.current + "-ssh" }
}

/// 存在 holder 里的归属：App 重启后据此把标签放回原来的窗口。
nonisolated struct SSHSessionAttributes: Codable, Equatable, Sendable {
    var windowID: UUID
    /// `TerminalWindowKind`。
    var windowKind: String
    var serverID: UUID
    var title: String
    /// 标签打开时的时间戳。只在没有 `layout`（旧版写的）或会话不在布局里时用来排先后。
    var order: Double
    /// 写入时整个窗口的布局，位置以它为准（见 `HeldSessionLayout`）。
    var layout: HeldSessionLayout?

    init(windowID: UUID, windowKind: String, serverID: UUID, title: String, order: Double,
         layout: HeldSessionLayout? = nil) {
        self.windowID = windowID
        self.windowKind = windowKind
        self.serverID = serverID
        self.title = title
        self.order = order
        self.layout = layout
    }

    /// 存在 holder 里、会跨版本读：只有放回窗口必需的两个 ID 是硬要求，其余缺了给默认值。
    /// 以后加字段一律可选，旧版 App 读新版写的归属也不至于整条解不开。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        windowID = try container.decode(UUID.self, forKey: .windowID)
        serverID = try container.decode(UUID.self, forKey: .serverID)
        windowKind = try container.decodeIfPresent(String.self, forKey: .windowKind) ?? TerminalWindowKind.workspace
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        order = try container.decodeIfPresent(Double.self, forKey: .order) ?? 0
        // 布局只是锦上添花：别的版本写的解不开就当没有，不连累整条归属（那样会话就接不回来了）。
        layout = try? container.decodeIfPresent(HeldSessionLayout.self, forKey: .layout)
    }
}
