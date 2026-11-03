import CryptoKit
import Foundation
@preconcurrency import Network
import Observation

/// 接入一个终端后，接收它的输出与关闭事件。回调在连接队列上直接触发，不经主线程。
nonisolated final class RemoteChannelSink: @unchecked Sendable {
    let onOutput: @Sendable (Data) -> Void
    /// `sessionEnded` = Mac 明确结束了这个终端（关闭 / 断开 / 被别的设备接管）；
    /// false = 只是连接断了，可以重连再接入。
    let onClosed: @Sendable (_ reason: String, _ sessionEnded: Bool) -> Void
    /// 桌面通道的视频帧与光标（`desktopFrame` / `desktopCursor`）原样交给它，连同它来自的那条连接
    ///（接收端要在同一条连接上回确认，而这时开流的调用可能还没返回）。终端通道不用。
    let onMessage: (@Sendable (RemoteMessage, RemoteLink) -> Void)?

    init(onOutput: @escaping @Sendable (Data) -> Void,
         onClosed: @escaping @Sendable (_ reason: String, _ sessionEnded: Bool) -> Void,
         onMessage: (@Sendable (RemoteMessage, RemoteLink) -> Void)? = nil) {
        self.onOutput = onOutput
        self.onClosed = onClosed
        self.onMessage = onMessage
    }
}

/// 一次接入：往哪条连接、哪个通道发输入与尺寸。
nonisolated struct RemoteAttachment: Sendable {
    let link: RemoteLink
    let channel: UInt32
}

nonisolated enum RemoteAttachError: LocalizedError {
    /// Mac 拒绝接入（终端已关闭等），重试也没用。
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .rejected(let message): return message
        }
    }
}

/// 通道表：连接队列上查（转发输出），主线程上增删。
///
/// 接入时先按会话 ID 登记接收方；收到 `attached` 的那一刻就在连接队列上把通道号绑上去。
/// 数据流里 `attached` 总在快照之前，在队列上同步绑定才不会丢掉第一帧。
nonisolated final class RemoteChannelTable: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UUID: RemoteChannelSink] = [:]
    private var sinks: [UInt32: RemoteChannelSink] = [:]

    func expect(sessionID: UUID, sink: RemoteChannelSink) {
        lock.lock(); pending[sessionID] = sink; lock.unlock()
    }

    func bind(sessionID: UUID, channel: UInt32) {
        lock.lock(); defer { lock.unlock() }
        if let sink = pending.removeValue(forKey: sessionID) { sinks[channel] = sink }
    }

    func cancel(sessionID: UUID) {
        lock.lock(); pending.removeValue(forKey: sessionID); lock.unlock()
    }

    func sink(_ channel: UInt32) -> RemoteChannelSink? {
        lock.lock(); defer { lock.unlock() }
        return sinks[channel]
    }

    func remove(_ channel: UInt32) -> RemoteChannelSink? {
        lock.lock(); defer { lock.unlock() }
        return sinks.removeValue(forKey: channel)
    }

    func removeAll() -> [RemoteChannelSink] {
        lock.lock(); defer { lock.unlock() }
        let all = Array(sinks.values)
        sinks.removeAll()
        pending.removeAll()
        return all
    }
}

/// 手机这一侧与一台 Mac 的远控连接：握手、配对、会话列表、接入。同一台 Mac 的所有远控标签
/// 共用这一条连接（多路复用），断了由各个 `RemoteTerminalBackend` 发起重连。
@MainActor
@Observable
final class RemoteMacClient: Identifiable {
    enum State: Equatable {
        case idle
        case connecting
        /// 首次配对：等 Mac 上的人点「允许」。附带 6 位核对码，应与 Mac 上显示的一致。
        case awaitingApproval(String)
        case connected
        case failed(String)
    }

    nonisolated var id: String { macName }
    nonisolated let macName: String
    private(set) var state: State = .idle
    private(set) var sessions: [RemoteSessionInfo] = []
    /// 握手后才知道的 Mac 设备 ID（「忘记这台 Mac」要用）。
    private(set) var macDeviceID: UUID?
    /// 这台 Mac 报的可选能力（握手后才有；老版本 Mac 为空）。
    private(set) var macFeatures: [String] = []

    /// Mac 认不认桌面消息。老版本 Mac 收到桌面消息会当作未知消息断开整条连接，所以发之前必须先看这个。
    var supportsDesktop: Bool { macFeatures.contains(RemoteFeature.desktop) }
    /// 远程桌面里能不能粘贴手机的图片 / 文字（老 Mac 收到 `desktopPaste` 会断开整条连接）。
    var supportsDesktopPaste: Bool { macFeatures.contains(RemoteFeature.desktopPaste) }

    @ObservationIgnored private var endpoint: NWEndpoint
    @ObservationIgnored private let identity: RemoteIdentityStore
    @ObservationIgnored private let table = RemoteChannelTable()
    @ObservationIgnored private var link: RemoteLink?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var outcomeWaiter: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var attachWaiters: [UUID: CheckedContinuation<UInt32, Error>] = [:]
    @ObservationIgnored private var desktopWaiters: [UUID: CheckedContinuation<(UInt32, RemoteDesktopInfo), Error>] = [:]
    @ObservationIgnored private var localShellWaiters: [UUID: CheckedContinuation<UUID, Error>] = [:]
    @ObservationIgnored private var peer: RemoteHello?

    /// - Parameters:
    ///   - macName: 显示用（Bonjour 服务名，即 Mac 的电脑名）。
    ///   - endpoint: Bonjour 发现的服务端点；测试里直接给 127.0.0.1 的端口。
    init(macName: String, endpoint: NWEndpoint, identity: RemoteIdentityStore) {
        self.macName = macName
        self.endpoint = endpoint
        self.identity = identity
    }

    func updateEndpoint(_ endpoint: NWEndpoint) {
        self.endpoint = endpoint
    }

    // MARK: - 连接与配对

    /// 确保已连上并通过配对。首次配对时会一直等到 Mac 上的人作出决定（或超时）。
    func connect() async {
        if state == .connected { return }
        if connectTask == nil {
            connectTask = Task { await runConnect() }
        }
        await connectTask?.value
    }

    private func runConnect() async {
        defer { connectTask = nil }
        state = .connecting
        let link = RemoteLink(connection: NWConnection(to: endpoint, using: RemoteLink.parameters()))
        self.link = link
        let table = self.table
        link.setHandlers(
            onMessage: { [weak self, weak link] message in
                guard let link else { return }
                Self.route(message, link: link, table: table, client: self)
            },
            onClose: { [weak self] error in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.linkClosed(link, error: error) } }
            }
        )
        do {
            let staticKey = try identity.localIdentity()
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            let hello = RemoteHello(version: RemoteConstants.protocolVersion, deviceID: RemoteLocalDevice.id(),
                                    deviceName: LANSyncCoordinator.localDeviceName(),
                                    ephemeralKey: ephemeral.publicKey.rawRepresentation,
                                    staticKey: staticKey.publicKey.rawRepresentation,
                                    features: RemoteConstants.localFeatures)
            let established = try await link.establish(role: .initiator, hello: hello, staticKey: staticKey,
                                                       ephemeralKey: ephemeral)
            // 配对过的 Mac 换了长期密钥：可能是冒充，也可能是重装过 uTerm。宁可拒绝，让用户手动忘记重配。
            if let known = identity.peer(id: established.peer.deviceID), known.publicKey != established.peer.staticKey {
                throw RemoteProtocolError.peerIdentityChanged
            }
            peer = established.peer
            macDeviceID = established.peer.deviceID
            macFeatures = established.peer.features ?? []
            // 等 Mac 告诉我们配对结果（已信任 / 等审批 / 同意 / 拒绝）。核对码先备着，等审批时显示。
            pendingCode = established.verificationCode
            await withCheckedContinuation { continuation in
                if state == .connected || isFailed {
                    continuation.resume()
                } else {
                    outcomeWaiter = continuation
                }
            }
            if state == .connected {
                link.send(RemoteMessage(.subscribeSessions))
            }
        } catch {
            state = .failed(error.localizedDescription)
            link.close(error)
            if self.link === link { self.link = nil }
        }
    }

    @ObservationIgnored private var pendingCode = ""

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func handlePairing(_ pairing: RemotePairingState) {
        switch pairing {
        case .trusted, .approved:
            if let peer {
                // 第一次见到这台 Mac（或手机这边忘过）：记住它的长期公钥，之后每次握手都核对。
                try? identity.trust(RemotePeer(id: peer.deviceID, name: peer.deviceName,
                                               publicKey: peer.staticKey, pairedAt: Date()))
            }
            state = .connected
            resumeOutcome()
        case .awaitingApproval:
            state = .awaitingApproval(pendingCode)
        case .rejected:
            state = .failed(RemoteProtocolError.pairingRejected.localizedDescription)
            resumeOutcome()
        }
    }

    private func resumeOutcome() {
        outcomeWaiter?.resume()
        outcomeWaiter = nil
    }

    func disconnect() {
        link?.close()
    }

    /// 忘记这台 Mac：下次连接重新配对。
    func forget() {
        if let macDeviceID { try? identity.revoke(id: macDeviceID) }
        disconnect()
    }

    private func linkClosed(_ closedLink: RemoteLink, error: Error?) {
        guard closedLink === link else { return }
        link = nil
        sessions = []
        if state == .connected || state == .connecting {
            state = error.map { .failed($0.localizedDescription) } ?? .idle
        } else if case .awaitingApproval = state {
            state = .failed(error?.localizedDescription ?? "Mac 没有确认配对")
        }
        resumeOutcome()
        for (_, waiter) in attachWaiters { waiter.resume(throwing: RemoteProtocolError.closed) }
        attachWaiters.removeAll()
        for (_, waiter) in desktopWaiters { waiter.resume(throwing: RemoteProtocolError.closed) }
        desktopWaiters.removeAll()
        for (_, waiter) in localShellWaiters { waiter.resume(throwing: RemoteProtocolError.closed) }
        localShellWaiters.removeAll()
        for sink in table.removeAll() { sink.onClosed("与 Mac 的连接已断开", false) }
    }

    // MARK: - 收消息

    /// 在连接队列上分发：终端字节直接交给通道的接收方；控制消息跳回主线程。
    private nonisolated static func route(_ message: RemoteMessage, link: RemoteLink, table: RemoteChannelTable,
                                          client: RemoteMacClient?) {
        switch message.kind {
        case .output:
            table.sink(message.channel)?.onOutput(message.payload)
        case .desktopFrame, .desktopCursor:
            table.sink(message.channel)?.onMessage?(message, link)
        case .desktopStarted:
            // 同 `attached`：在队列上先绑定通道，紧随其后的第一帧（关键帧）才不会丢。
            if let info = try? RemoteJSON.decode(RemoteDesktopInfo.self, from: message.payload), info.failure == nil {
                table.bind(sessionID: info.requestID, channel: message.channel)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { client?.handleControl(message) } }
        case .closed:
            table.remove(message.channel)?.onClosed(String(decoding: message.payload, as: UTF8.self), true)
        case .attached:
            if let result = try? RemoteJSON.decode(RemoteAttachResult.self, from: message.payload), result.error == nil {
                table.bind(sessionID: result.sessionID, channel: message.channel)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { client?.handleControl(message) } }
        default:
            DispatchQueue.main.async { MainActor.assumeIsolated { client?.handleControl(message) } }
        }
    }

    private func handleControl(_ message: RemoteMessage) {
        switch message.kind {
        case .pairing:
            if let raw = message.payload.first, let pairing = RemotePairingState(rawValue: raw) {
                handlePairing(pairing)
            }
        case .sessions:
            if let list = try? RemoteJSON.decode([RemoteSessionInfo].self, from: message.payload) {
                sessions = list
            }
        case .attached:
            guard let result = try? RemoteJSON.decode(RemoteAttachResult.self, from: message.payload),
                  let waiter = attachWaiters.removeValue(forKey: result.sessionID) else { return }
            if let error = result.error {
                table.cancel(sessionID: result.sessionID)
                waiter.resume(throwing: RemoteAttachError.rejected(error))
            } else {
                waiter.resume(returning: message.channel)
            }
        case .desktopStarted:
            guard let info = try? RemoteJSON.decode(RemoteDesktopInfo.self, from: message.payload),
                  let waiter = desktopWaiters.removeValue(forKey: info.requestID) else { return }
            if info.failure != nil { table.cancel(sessionID: info.requestID) }
            waiter.resume(returning: (message.channel, info))
        case .localShellOpened:
            guard let result = try? RemoteJSON.decode(RemoteOpenLocalShellResult.self, from: message.payload),
                  let waiter = localShellWaiters.removeValue(forKey: result.requestID) else { return }
            if let sessionID = result.sessionID {
                waiter.resume(returning: sessionID)
            } else {
                waiter.resume(throwing: RemoteAttachError.rejected(result.error ?? "Mac 没能打开本机终端"))
            }
        default:
            break
        }
    }

    // MARK: - 接入

    /// 接入 Mac 上的一个终端。返回后输出开始经 `sink` 流入（第一帧是快照）。
    func attach(sessionID: UUID, size: RemoteGridSize, sink: RemoteChannelSink) async throws -> RemoteAttachment {
        await connect()
        guard state == .connected, let link else {
            if case .failed(let message) = state { throw RemoteAttachError.rejected(message) }
            throw RemoteProtocolError.closed
        }
        table.expect(sessionID: sessionID, sink: sink)
        let channel = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt32, Error>) in
            attachWaiters.removeValue(forKey: sessionID)?.resume(throwing: RemoteProtocolError.closed)
            attachWaiters[sessionID] = continuation
            link.send(RemoteMessage(.attach, payload: RemoteJSON.encode(
                RemoteAttachRequest(sessionID: sessionID, cols: size.cols, rows: size.rows))))
        }
        return RemoteAttachment(link: link, channel: channel)
    }

    func detach(_ attachment: RemoteAttachment) {
        attachment.link.send(RemoteMessage(.detach, channel: attachment.channel))
        _ = table.remove(attachment.channel)
    }

    /// 这台 Mac 能不能开本机终端（老 Mac 收到 `openLocalShell` 会断开整条连接）。
    var supportsLocalShell: Bool { macFeatures.contains(RemoteFeature.localShell) }

    /// 关远控标签时能不能连 Mac 上的终端一起关（老 Mac 收到 `closeSession` 会断开整条连接）。
    var supportsCloseSession: Bool { macFeatures.contains(RemoteFeature.closeSession) }

    /// 请 Mac 关掉它上面的一条会话（所在标签连同连接 / shell）。只发不等：手机这边随后照常关自己的标签，
    /// Mac 关掉以后会话列表会推来新的一份。没连着或 Mac 不支持时什么也不做。
    func closeSessionOnMac(_ sessionID: UUID) {
        guard state == .connected, let link, supportsCloseSession else { return }
        link.send(RemoteMessage(.closeSession, payload: RemoteJSON.encode(RemoteCloseSessionRequest(sessionID: sessionID))))
    }

    /// 请 Mac 开一个本机 shell（Mac 上同时弹出它的终端窗口），返回会话 id；之后照常 `attach`。
    /// Mac 上没开「允许打开本机终端」、辅助程序没授权等情况抛 `RemoteAttachError.rejected`，带给人看的原因。
    func openLocalShell() async throws -> UUID {
        await connect()
        guard state == .connected, let link else {
            if case .failed(let message) = state { throw RemoteAttachError.rejected(message) }
            throw RemoteProtocolError.closed
        }
        guard supportsLocalShell else {
            throw RemoteAttachError.rejected("这台 Mac 上的 uTerm 版本太旧，不能新建本机终端。请把 Mac 上的 uTerm 更新到最新版")
        }
        let requestID = UUID()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UUID, Error>) in
            localShellWaiters[requestID] = continuation
            link.send(RemoteMessage(.openLocalShell, payload: RemoteJSON.encode(RemoteOpenLocalShellRequest(requestID: requestID))))
        }
    }
}

// MARK: - 桌面

extension RemoteMacClient {
    /// 开一条桌面流。返回 Mac 的回复：`info.failure != nil` 表示被拒（没开开关、没授权……），
    /// 此时没有通道可用。成功后视频帧与光标经 `sink.onMessage` 在连接队列上流入（第一帧是关键帧）。
    ///
    /// 调用前应已确认 `supportsDesktop`；这里再挡一次，老 Mac 收到桌面消息会断开整条连接。
    func startDesktop(_ request: RemoteDesktopStartRequest,
                      sink: RemoteChannelSink) async throws -> (attachment: RemoteAttachment, info: RemoteDesktopInfo) {
        await connect()
        guard state == .connected, let link else {
            if case .failed(let message) = state { throw RemoteAttachError.rejected(message) }
            throw RemoteProtocolError.closed
        }
        guard supportsDesktop else { throw RemoteDesktopError.macTooOld }
        table.expect(sessionID: request.requestID, sink: sink)
        let (channel, info) = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(UInt32, RemoteDesktopInfo), Error>) in
            desktopWaiters.removeValue(forKey: request.requestID)?.resume(throwing: RemoteProtocolError.closed)
            desktopWaiters[request.requestID] = continuation
            link.send(RemoteMessage(.desktopStart, payload: RemoteJSON.encode(request)))
        }
        return (RemoteAttachment(link: link, channel: channel), info)
    }

    func stopDesktop(_ attachment: RemoteAttachment) {
        attachment.link.send(RemoteMessage(.desktopStop, channel: attachment.channel))
        _ = table.remove(attachment.channel)
    }
}

nonisolated enum RemoteDesktopError: LocalizedError, Equatable {
    /// Mac 上的 uTerm 是 P1 的版本，不认桌面消息。
    case macTooOld

    var errorDescription: String? {
        switch self {
        case .macTooOld: return "这台 Mac 上的 uTerm 版本太旧，不支持远程桌面。请把 Mac 上的 uTerm 更新到最新版"
        }
    }
}
