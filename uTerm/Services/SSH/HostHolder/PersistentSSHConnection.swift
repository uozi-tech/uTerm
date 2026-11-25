import Foundation
import Synchronization
import SwiftData
import NIOCore

/// 连接断了自己重连、不结束会话的后端。重连期间在 `reconnecting` 上报 true，接回后报 false。
protocol ReconnectingTerminalBackend: TerminalBackend {
    nonisolated var reconnecting: AsyncStream<Bool> { get }
    /// 自动重连停下来等用户处理时给出原因（服务器拒绝了凭据、主机密钥被拒、握手不成——重试也不会好的那类），
    /// 处理完、重新开始重连时给 nil。会话还在（主机上的 shell 照常跑），用户处理完调 `retryAfterAttention()` 接回。
    nonisolated var attention: AsyncStream<String?> { get }
    /// 自动重连这一次又没连上（还会接着试的那类：拒绝连接、不可达、超时……）时给出原因，接回时给 nil。
    /// 界面在「正在重新连接」旁边说明为什么还没连上，而不是一直只说「断了」。
    nonisolated var reconnectFailure: AsyncStream<String?> { get }
    /// 连接多半已经断了的时刻（App 回到前台、网络刚变）：立刻处置，不等看门狗（它要等网络稳定 3 秒、再探活）。
    /// `lostInterface`：变之前走的那块网卡没了，上面的连接不可能再通。
    /// 判错的代价只是多重连一次的后端才实现；判错就等于断开的不实现，仍然等看门狗。
    func recheckAfterDisruption(lostInterface: Bool) async
    /// 用户处理完了（改了密码、确认了主机密钥）：重新读凭据，马上再连一次，接回同一个会话。
    func retryAfterAttention() async
}

extension ReconnectingTerminalBackend {
    nonisolated var attention: AsyncStream<String?> { AsyncStream { $0.finish() } }
    nonisolated var reconnectFailure: AsyncStream<String?> { AsyncStream { $0.finish() } }
    func recheckAfterDisruption(lostInterface: Bool) async {}
    func retryAfterAttention() async {}
}

/// 后端结束（`exitStream`）时，主机上的那个会话是不是也没了。只有它说「没了」，界面才换一个会话 id；
/// 连不上、被关掉之类的结束，主机上的 shell 还在，下次凭同一个 id 接回。
protocol HostSessionOwning: TerminalBackend {
    nonisolated var hostSessionHasEnded: Bool { get }
    /// 至少接上过一次主机上的会话。没接上过就结束的（第一次连接就失败），下次再连开的是**新**会话，不是接回。
    nonisolated var hasAttachedToHostSession: Bool { get }
}

extension RemoteTerminalBackend: ReconnectingTerminalBackend {}

/// 断线不丢会话的 SSH 终端后端：shell 由主机上的 `uterm-holder` 持有（见 `HostHolder`）。
///
/// 和 `SSHConnection` 的区别：
/// - 连接断了（手机退后台被挂起、换网络、主机那头超时）不结束会话。自己重连，按已收到的位置接回，
///   断开期间的输出补上。终端这头什么都不用做：字节流是连续的，影子终端和画面照常往下吃。
/// - shell 退出、会话在主机上没了（主机重启过）、被另一台设备接走，才算结束（`exitStream`）。
/// - 关标签（`close()`）连同主机上的 shell 一起结束；App 被系统杀掉不走 `close()`，会话留在主机上。
/// - App 重新打开后用同一个 `sessionID` 再建一个后端就接回来了：第一次接入从主机存着的检查点开始
///   （`saveCheckpoint`，App 进后台时存），检查点还原进影子终端，之后的输出按历史补上。主机上没有这个会话就新建一个。
///
/// 主机上用不了保持进程时（不是 Linux、装不上、退出登录会清进程）退回 `SSHConnection`，行为与之前相同。
actor PersistentSSHConnection: TerminalImageReceiving, TerminalVideoReceiving, TerminalTrueColorConfiguring, ReconnectingTerminalBackend,
                               CheckpointingTerminalBackend, HostSessionOwning {
    /// 用户处理完、点重试时重新读**整份**主机设置：地址与跳板机（快照）、用户名、认证方式、用哪把钥匙，以及
    /// 钥匙串里的密码 / 私钥。认证失败时用户改的往往正是用户名、认证方式、钥匙或跳板机，只重读钥匙串等于白改。
    /// 规则同 `SSHAuthResolver.resolveForConnect`（跳板机缺凭据报错，绝不直连）。
    typealias SettingsResolver = @Sendable () async throws -> ResolvedSettings

    nonisolated struct ResolvedSettings: Sendable {
        let profile: SSHConnection.ProfileSnapshot
        let auth: ResolvedAuth
        let jump: ResolvedAuth?
    }

    /// 重读的设置把目标的地址或端口改了：主机上的这个会话属于原来那台机器，拿它的 id 去新地址上接是错的。
    nonisolated struct HostMovedError: LocalizedError {
        var errorDescription: String? {
            String(localized: "这台主机的地址或端口改了，原来的会话在另一台机器上。关掉这个标签页，再重新打开主机。")
        }
    }

    /// 第一次接入途中断了、重连又没连上：「仍然连不上：<那一次的原因>」。值不值得重试照原因的。
    nonisolated struct FirstAttachReconnectError: LocalizedError, SSHFailureClassifying {
        let underlying: any Error
        var errorDescription: String? {
            String(localized: "仍然连不上：\(TerminalConnectFailure.reason(of: underlying))")
        }
        var isPermanentConnectFailure: Bool { SSHTransportFailure.isPermanentConnectFailure(underlying) }
        var transportFailureVerdict: Bool? { SSHTransportFailure.isTransportFailure(underlying) }
    }

    /// 已保存的主机被删了。
    nonisolated struct HostRemovedError: LocalizedError {
        var errorDescription: String? { String(localized: "这台主机已被删除。") }
    }

    /// 这个后端接上过主机上的会话没有（至少一次）。第一次就没连上的话，主机上多半还没有这个会话：界面重试时不能当成
    /// 「接回」，否则新 shell 启动时的输出按历史处理、终端查询没人答（fish 等 10 秒报错、提示符卡住）。
    nonisolated var hasAttachedToHostSession: Bool { attachedOnce.value.withLock { $0 } }

    // MARK: - TerminalBackend

    nonisolated let outputItems: AsyncStream<TerminalOutputItem>
    nonisolated let exitStream: AsyncStream<Void>
    nonisolated let reconnecting: AsyncStream<Bool>
    nonisolated let attention: AsyncStream<String?>
    nonisolated let reconnectFailure: AsyncStream<String?>

    private let itemContinuation: AsyncStream<TerminalOutputItem>.Continuation
    private let exitContinuation: AsyncStream<Void>.Continuation
    private let reconnectingContinuation: AsyncStream<Bool>.Continuation
    private let attentionContinuation: AsyncStream<String?>.Continuation
    private let reconnectFailureContinuation: AsyncStream<String?>.Continuation

    /// 见 `HostSessionOwning`：只有保持进程说会话没了（shell 退出、被另一台设备接走、主机上没有这个会话）才为真。
    nonisolated var hostSessionHasEnded: Bool { sessionEnded.value.withLock { $0 } }
    private nonisolated let sessionEnded = SessionEndFlag()
    private nonisolated let attachedOnce = SessionEndFlag()

    private final class SessionEndFlag: Sendable {
        let value = Mutex(false)
        func set() { value.withLock { $0 = true } }
    }

    // MARK: - 配置

    /// 主机上的会话 id。同一个 id 重新接入得到同一个 shell。
    nonisolated let sessionID: UUID
    private var profile: SSHConnection.ProfileSnapshot
    private nonisolated let machineKey: String
    private var auth: ResolvedAuth
    private var jumpHostAuth: ResolvedAuth?
    private let resolveSettings: SettingsResolver?
    private let hostKeyVerifier: HostKeyVerifier
    private let hostKeyApprover: @Sendable (HostKeyChallenge) async -> Bool
    private let bundle: Bundle
    /// `sessionID` 是上次运行留下的，主机上多半还有这个会话：没接上就被关掉时也要去结束它。
    private let resumesSession: Bool

    // MARK: - 运行时状态

    private enum Phase {
        case idle, connecting, attached, reconnecting
        /// 自动重连停下了，等用户处理（`attention`）。
        case needsAttention
        /// 这台主机用不了保持进程，全部转给 `fallback`。
        case plain
        case ended
    }

    private enum InitialOutcome {
        case attached, usePlainConnection, closed
        /// 第一次接入途中断了，重连又没连上（重试不会好的，或可以再试的已经试满了）：带着那一次的原因失败。
        case reconnectFailed(any Error)
        /// 第一次接入时连接一再断开：报连接失败，**不**退到普通连接、**不**当成主机上的会话没了。
        case lostBeforeAttach
    }

    /// 第一次接入（回放还没收完）就断了的话，再连几次。不退到普通连接：那会悄悄换成一个不保持的 shell，主机上那个
    /// 还在跑的会话也就没人接了。
    static let firstAttachAttempts = 3
    /// 第一次接入途中断了之后，重连「可以再试」的失败（握手前被断开、超时、不可达……）最多试这么多次，
    /// 到了就带着原因失败返回：这时界面停在连接中页，不能一直退避下去。
    static let firstAttachReconnectAttempts = 4

    private static let initialReconnectDelay = Duration.milliseconds(500)
    private static let maxReconnectDelay = Duration.seconds(15)
    /// 探活的时限比 `SSHConnection` 短：判错了只是多重连一次，画面不受影响。
    private static let probeTimeout = Duration.seconds(5)
    /// 回前台、网络刚变时的探活时限：这种时刻连接多半已经死了，等得越久画面停得越久。
    private static let disruptionProbeTimeout = Duration.seconds(2)

    private var phase = Phase.idle
    private var isClosed = false
    private var didFinishStreams = false
    private let position: HostHolderStreamPosition
    private let checkpoints = CheckpointState()
    /// 拍好了但当时没接着会话、还没发出去的检查点：接回后补发。
    private var pendingCheckpoint: HolderFrame?
    /// 发出去（或排着补发）的最新一张检查点的位置。回放流在锁外各拍各的，先拍的可能后到，旧的不能盖掉新的。
    private var latestCheckpointOffset: UInt64?

    /// 检查点那几样要在 actor 外面（收帧的线程、建连之前）读写的东西。
    private final class CheckpointState: Sendable {
        let hooks = Mutex<TerminalCheckpointHooks?>(nil)
        /// 第一次接入时主机回的检查点用不了（别的引擎版本存的）：之后的字节接不上，按缺了一块处理。
        let restoredUnusable = Mutex(false)
    }
    private var link: HostHolderLink?
    private var client: ConnectedClient?
    private var supervisor: Task<Void, Never>?
    private var backoffTask: Task<Void, Never>?
    private var isRechecking = false
    private var reconnectDelay = PersistentSSHConnection.initialReconnectDelay
    private var firstAttach: CheckedContinuation<InitialOutcome, Never>?
    private var hasAttached = false
    /// 上一条 link 有没有走到「接入完成」。
    private var didAttachOnLastLink = false
    private var shellPID: Int32 = 0
    /// 停在 `needsAttention` 时，等用户的那个续点（`retryAfterAttention` / `close` 叫醒）。
    private var attentionWaiter: CheckedContinuation<Void, Never>?
    private var cols: UInt16 = 80
    private var rows: UInt16 = 24
    private var fallback: SSHConnection?

    init(sessionID: UUID = UUID(),
         resumesSession: Bool = false,
         profile: SSHConnection.ProfileSnapshot,
         auth: ResolvedAuth,
         jumpHostAuth: ResolvedAuth?,
         hostKeyVerifier: HostKeyVerifier,
         hostKeyApprover: @escaping @Sendable (HostKeyChallenge) async -> Bool,
         resolveSettings: SettingsResolver? = nil,
         bundle: Bundle = .main) {
        self.sessionID = sessionID
        self.resolveSettings = resolveSettings
        self.resumesSession = resumesSession
        self.profile = profile
        self.machineKey = "\(profile.host):\(profile.port)"
        self.auth = auth
        self.jumpHostAuth = jumpHostAuth
        self.hostKeyVerifier = hostKeyVerifier
        self.hostKeyApprover = hostKeyApprover
        self.bundle = bundle
        (outputItems, itemContinuation) = AsyncStream.makeStream(of: TerminalOutputItem.self)
        position = HostHolderStreamPosition(items: itemContinuation, markInterval: Self.checkpointIntervalBytes)
        (exitStream, exitContinuation) = AsyncStream<Void>.makeStream()
        (reconnecting, reconnectingContinuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        (attention, attentionContinuation) = AsyncStream<String?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        (reconnectFailure, reconnectFailureContinuation) = AsyncStream<String?>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    // MARK: - connect

    func connect() async throws {
        guard phase == .idle, !isClosed else { throw SSHConnection.SSHConnectionError.alreadyClosed }
        phase = .connecting
        position.setOnMarkDue { [weak self] in
            Task { await self?.saveCheckpoint() }
        }
        let connected: ConnectedClient
        do {
            connected = try await openConnection()
        } catch {
            isClosed = true
            finishStreams()
            throw error
        }
        // 握手期间被 close() 了（用户在连接中页点了返回）。
        guard !isClosed else {
            await connected.close()
            throw SSHConnection.SSHConnectionError.alreadyClosed
        }
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<InitialOutcome, Never>) in
            firstAttach = continuation
            supervisor = Task { await self.supervise(startingWith: connected) }
        }
        switch outcome {
        case .attached:
            return
        case .usePlainConnection:
            try await connectPlain()
        case .closed:
            throw SSHConnection.SSHConnectionError.alreadyClosed
        case .lostBeforeAttach:
            isClosed = true
            finishStreams()
            throw SSHConnection.SSHConnectionError.connectFailed(String(localized: "SSH 连接已断开"))
        case .reconnectFailed(let error):
            isClosed = true
            finishStreams()
            throw FirstAttachReconnectError(underlying: error)
        }
    }

    private func openConnection() async throws -> ConnectedClient {
        try await SSHClientFactory.connectShared(
            profile: profile, auth: auth, jumpHostAuth: jumpHostAuth,
            hostKeyVerifier: hostKeyVerifier, hostKeyApprover: hostKeyApprover)
    }

    private func resolveFirstAttach(_ outcome: InitialOutcome) {
        firstAttach?.resume(returning: outcome)
        firstAttach = nil
    }

    // MARK: - 会话的一生

    /// 一条 link 接一条 link 地跑，直到会话结束。每条 link 是一条 SSH 连接上的一个 exec 通道。
    private func supervise(startingWith first: ConnectedClient) async {
        var connected = first
        var installTried = false
        var lostBeforeAttach = 0
        while true {
            let end = await runLink(on: connected)
            if isClosed {
                await connected.close()
                break
            }
            switch end {
            case .exited, .replaced, .noSession:
                // 保持进程说会话没了：之后再连就是新会话。
                sessionEnded.set()
                await connected.close()
                finishStreams()
                return
            case .closed:
                await connected.close()
                finishStreams()
                return
            case .notInstalled where !hasAttached && !installTried:
                // 第一次连这台主机：装上，在同一条连接上再试。
                installTried = true
                if case .installed = await HostHolderInstaller.install(on: connected, bundle: bundle), !isClosed {
                    continue
                }
                await connected.close()
                resolveFirstAttach(.usePlainConnection)
                return
            case .notInstalled, .unsupported, .transport:
                await connected.close()
                guard hasAttached || end == .transport else {
                    // 还没接上过、这台主机用不了保持进程：交给普通连接，报错也由它报。
                    resolveFirstAttach(.usePlainConnection)
                    return
                }
                if !hasAttached {
                    // 第一次接入时连接断了（回放到一半）：主机上的会话多半还在。再试几次，不行就报连接失败——
                    // 不退到普通连接，也不说会话没了（界面留着这个会话 id，下次接着接）。
                    lostBeforeAttach += 1
                    guard lostBeforeAttach < Self.firstAttachAttempts else {
                        resolveFirstAttach(.lostBeforeAttach)
                        return
                    }
                }
                if end != .transport {
                    // 接回时发现二进制没了：会话也跟着没了。
                    sessionEnded.set()
                    finishStreams()
                    return
                }
            }
            // 连接断了，会话还在主机上：重连、接回。
            phase = .reconnecting
            reconnectingContinuation.yield(true)
            // 这一轮连上了却没接回就又断了：等一等再试，别原地打转。
            if !didAttachOnLastLink { await backOff() }
            // 第一次接入还没完成：界面停在连接中页、还没有终端，也没有「重试」入口，不能像接上之后那样
            // 一直退避或停下等用户——那样 `connect()` 永远不返回，一直「正在连接」。
            let reconnected = hasAttached ? await reconnect() : await reconnectBeforeFirstAttach()
            guard let next = reconnected else { break }
            connected = next
        }
        resolveFirstAttach(.closed)
    }

    private func runLink(on connected: ConnectedClient) async -> HostHolderLink.End {
        let link = HostHolderLink()
        self.link = link
        client = connected
        didAttachOnLastLink = false
        // 传输层关闭（FIN/RST 到了，或探活判死后强关）：这条 link 立刻收尾，不等通道自己察觉。
        await connected.onDisconnect { link.connectionLost() }
        let command = HostHolder.attachCommand(
            sessionID: sessionID, create: !hasAttached, cols: cols, rows: rows,
            environment: RemoteTrueColor.terminalEnvironment)
        // 这个后端第一次接入：影子终端是空的（新会话，或者 App 重新打开后接回），从主机存着的检查点开始。
        // 之后的重连影子里有状态，只要断开之后的字节。
        let restoring = !hasAttached
        let payload = restoring ? HostHolderAttach.fromStoredCheckpoint : HostHolderAttach.fromOffset(position.value)
        let events = link.start(on: connected, command: command, attachPayload: payload, position: position,
                                replayIsHistory: hasAttached || resumesSession) {
            [position, checkpoints] checkpoint in
            guard restoring else { return }
            Self.restore(checkpoint, into: position, state: checkpoints)
        }
        var end = HostHolderLink.End.transport
        for await event in events {
            switch event {
            case .attached(let hadGap, let shellPID):
                didAttach(on: link, hadGap: hadGap, shellPID: shellPID)
            case .ended(let reason):
                end = reason
            }
        }
        self.link = nil
        client = nil
        return end
    }

    private func didAttach(on link: HostHolderLink, hadGap: Bool, shellPID: Int32) {
        guard !isClosed else { return }
        if phase == .reconnecting {
            reconnectingContinuation.yield(false)
            reconnectFailureContinuation.yield(nil)
        }
        phase = .attached
        hasAttached = true
        attachedOnce.set()
        didAttachOnLastLink = true
        self.shellPID = shellPID
        reconnectDelay = Self.initialReconnectDelay
        // 断开期间可能转过屏；尺寸没变的话主机那头什么都不会发生。
        link.send(Self.resizeFrame(cols: cols, rows: rows))
        let unusable = checkpoints.restoredUnusable.withLock { value -> Bool in
            defer { value = false }
            return value
        }
        if hadGap || unusable {
            // 离开期间的输出超过了主机上留着的那段（或者检查点用不了）：中间缺了一块，全屏程序靠重画恢复。
            let notice = String(localized: "断开期间输出过多，较早内容已丢弃")
            position.deliverAside(.history(Data("\r\n\u{1b}[2m[\(notice)]\u{1b}[0m\r\n".utf8)))
            link.send(HolderFrame(.redraw))
        }
        if let pendingCheckpoint {
            link.send(pendingCheckpoint)
            self.pendingCheckpoint = nil
        }
        resolveFirstAttach(.attached)
    }

    /// 第一次接入时主机回的检查点：还原进影子终端（排在它之后的历史字节之前），位置跟到检查点那里。
    /// 在收帧的那条线程上调。主机上没存过检查点时 `blob` 是空的、位置是 0，什么都不用做。
    private nonisolated static func restore(_ checkpoint: HolderCheckpoint, into position: HostHolderStreamPosition,
                                            state: CheckpointState) {
        position.set(checkpoint.offset)
        guard !checkpoint.blob.isEmpty else { return }
        // 换了引擎（App Store 更新）、快照格式变了的话，用检查点里的回放流重画出一张。
        if let snapshot = TerminalCheckpointBlob.restorableSnapshot(checkpoint.blob, cols: checkpoint.cols, rows: checkpoint.rows) {
            position.deliverAside(.snapshot(snapshot))
        } else {
            state.restoredUnusable.withLock { $0 = true }
        }
        // 程序状态和快照格式无关，快照用不了也照用。
        if let hooks = state.hooks.withLock({ $0 }),
           let status = TerminalCheckpointBlob.decodeProgramStatus(checkpoint.blob) {
            position.deliverAside(.afterFed { hooks.restoreProgramStatus(status) })
        }
    }

    /// 一直试到连上，或者这个后端被关掉（返回 nil）。
    ///
    /// 重试也不会好的失败（服务器拒绝了凭据、主机密钥被拒绝或等确认超时、握手协商不成——见
    /// `SSHTransportFailure.isPermanentConnectFailure`）不自动再试（再试只是又一次失败的登录、又弹一次确认框），
    /// 停在 `needsAttention`，经 `attention` 把原因交给界面。**会话不结束**：主机上的 shell 还在，
    /// 用户处理完点重试（`retryAfterAttention`），重新读凭据、接回同一个会话。
    private func reconnect() async -> ConnectedClient? {
        while !isClosed {
            do {
                let connected = try await openConnection()
                if isClosed {
                    await connected.close()
                    return nil
                }
                return connected
            } catch where SSHTransportFailure.isPermanentConnectFailure(error) {
                AppLogger.error("保持会话的重连停下等用户处理：\(FriendlyError.describe(error))")
                reconnectFailureContinuation.yield(nil)
                await waitForUser(FriendlyError.describe(error))
            } catch {
                // 服务器不在（拒绝连接）、不可达、超时：接着试，同时告诉界面这一次为什么没连上。
                reconnectFailureContinuation.yield(TerminalConnectFailure.reason(of: error))
                await backOff()
            }
        }
        return nil
    }

    /// 第一次接入途中断了之后的重连：重试不会好的失败（拒绝连接、认证、主机密钥、连接方式变弱、地址不合法）
    /// 马上带着原因失败；可以再试的（握手前被断开、超时、不可达……）最多试 `firstAttachReconnectAttempts` 次。
    /// 失败时经 `resolveFirstAttach(.reconnectFailed)` 让 `connect()` 抛出，返回 nil。
    private func reconnectBeforeFirstAttach() async -> ConnectedClient? {
        var attempts = 0
        while !isClosed {
            do {
                let connected = try await openConnection()
                if isClosed {
                    await connected.close()
                    return nil
                }
                return connected
            } catch {
                attempts += 1
                reconnectFailureContinuation.yield(TerminalConnectFailure.reason(of: error))
                if Self.endsFirstAttach(error, host: profile.host, port: profile.port)
                    || attempts >= Self.firstAttachReconnectAttempts {
                    AppLogger.error("第一次接入途中断开后重连失败（第 \(attempts) 次），不再试：\(FriendlyError.describe(error))")
                    resolveFirstAttach(.reconnectFailed(error))
                    return nil
                }
                await backOff()
            }
        }
        return nil
    }

    /// 第一次接入时重连碰到就不再试的失败：重试不会好的那类，以及拒绝连接（服务器已经不在了）。
    nonisolated static func endsFirstAttach(_ error: any Error, host: String, port: Int) -> Bool {
        if SSHTransportFailure.isPermanentConnectFailure(error) { return true }
        if case SSHConnection.SSHConnectionError.connectFailed(let detail) = error {
            return SSHConnectFailureText.isRefusal(detail, host: host, port: port)
        }
        return false
    }

    /// 停下来等用户：把原因交给界面，等 `retryAfterAttention()`（或 `close()`），然后重新读凭据。
    /// 凭据读不出来（钥匙串里的密码被删了）也算要用户处理，接着等。
    private func waitForUser(_ reason: String) async {
        var reason = reason
        while !isClosed {
            phase = .needsAttention
            attentionContinuation.yield(reason)
            await withCheckedContinuation { attentionWaiter = $0 }
            guard !isClosed else { return }
            phase = .reconnecting
            reconnectDelay = Self.initialReconnectDelay
            guard let resolveSettings else { break }
            do {
                let fresh = try await resolveSettings()
                guard Self.isSameMachine(fresh.profile, profile) else { throw HostMovedError() }
                (profile, auth, jumpHostAuth) = (fresh.profile, fresh.auth, fresh.jump)
                break
            } catch {
                reason = FriendlyError.describe(error)
            }
        }
        attentionContinuation.yield(nil)
    }

    /// 会话 id 属于「这台机器」：地址（不分大小写）与端口都没变。跳板机换了没关系，目标还是那台。
    nonisolated static func isSameMachine(_ a: SSHConnection.ProfileSnapshot, _ b: SSHConnection.ProfileSnapshot) -> Bool {
        a.host.lowercased() == b.host.lowercased() && a.port == b.port
    }

    /// 用户处理完了：叫醒停在 `needsAttention` 的重连。没在等就什么都不做。
    func retryAfterAttention() async {
        attentionWaiter?.resume()
        attentionWaiter = nil
    }

    /// 等一会儿再试，间隔逐次加倍。`verifyConnectionAlive`（回前台、网络恢复）会提前叫醒。
    private func backOff() async {
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, Self.maxReconnectDelay)
        let waiting = Task { _ = try? await Task.sleep(for: delay) }
        backoffTask = waiting
        await waiting.value
        backoffTask = nil
    }

    // MARK: - 检查点

    /// 收到这么多输出就存一张：主机上留着 16 MiB，检查点不能落到它外面。
    private static let checkpointIntervalBytes = 8 * 1024 * 1024

    nonisolated func setCheckpointHooks(_ hooks: TerminalCheckpointHooks) {
        checkpoints.hooks.withLock { $0 = hooks }
    }

    /// 把终端此刻的状态存到主机上（App 进后台时、每收到一段输出）。App 被系统结束后重新打开，从它接回画面。
    func saveCheckpoint() async {
        guard fallback == nil, !isClosed, hasAttached, position.bytesSinceMark > 0,
              let hooks = checkpoints.hooks.withLock({ $0 }) else { return }
        // 同步点排在已经交出去的输出后面：影子解析到那里时拍，位置正好是这里读到的。
        position.mark { [weak self] offset in
            guard let captured = hooks.capture() else { return }
            // 拍快照要在泵的锁里（和位置对齐），回放流从拍好的快照出，挪到锁外。
            Task {
                let checkpoint = captured.addingReplay()
                let frame = HolderFrame(.checkpoint, payload: HolderCheckpoint(
                    offset: offset, cols: checkpoint.cols, rows: checkpoint.rows, hasGap: false,
                    blob: checkpoint.blob).encoded())
                await self?.send(checkpoint: frame, offset: offset)
            }
        }
    }

    private func send(checkpoint frame: HolderFrame, offset: UInt64) {
        guard !isClosed, latestCheckpointOffset.map({ offset >= $0 }) ?? true else { return }
        latestCheckpointOffset = offset
        if phase == .attached, let link {
            link.send(frame)
        } else {
            pendingCheckpoint = frame
        }
    }

    // MARK: - 退回普通连接

    private func connectPlain() async throws {
        let plain = SSHConnection(profile: profile, auth: auth, jumpHostAuth: jumpHostAuth,
                                  hostKeyVerifier: hostKeyVerifier, hostKeyApprover: hostKeyApprover)
        await plain.resize(cols: cols, rows: rows)
        fallback = plain
        phase = .plain
        reconnectingContinuation.finish()
        reconnectFailureContinuation.finish()
        let items = itemContinuation
        let exit = exitContinuation
        Task {
            for await item in plain.outputItems { items.yield(item) }
            items.finish()
        }
        didFinishStreams = true
        do {
            try await plain.connect()
        } catch {
            // 普通连接没连上：这里从没有过会话，主机上的（如果有）也没动——不说「会话没了」。
            exit.yield(())
            exit.finish()
            throw error
        }
        let ended = sessionEnded
        Task {
            // 普通连接没有留在主机上的会话：它结束了，之后再连就是新会话。连上之后才挂这一条。
            for await _ in plain.exitStream {
                ended.set()
                exit.yield(())
            }
            ended.set()
            exit.finish()
        }
    }

    // MARK: - write / resize / close

    func write(_ data: Data) async {
        if let fallback {
            await fallback.write(data)
            return
        }
        // 重连期间的按键不留着补发：断线时打的字过一阵突然在主机上执行，比丢掉更糟。界面会说明正在重连。
        guard phase == .attached, let link else { return }
        link.send(HolderFrame(.input, payload: Array(data)))
    }

    func resize(cols: UInt16, rows: UInt16) async {
        self.cols = cols
        self.rows = rows
        if let fallback {
            await fallback.resize(cols: cols, rows: rows)
            return
        }
        guard phase == .attached, let link else { return }
        link.send(Self.resizeFrame(cols: cols, rows: rows))
    }

    /// 关标签：连同主机上的 shell 一起结束。
    func close() async {
        guard !isClosed else { return }
        isClosed = true
        if let fallback {
            await fallback.close()
            return
        }
        backoffTask?.cancel()
        attentionWaiter?.resume()
        attentionWaiter = nil
        if phase == .attached, let link {
            link.send(HolderFrame(.terminate))
            // 主机上的会话结束后通道自己会关。等不到（连接其实已经半死）就强关。
            let closer = Task {
                try? await Task.sleep(for: .seconds(3))
                link.close()
            }
            await supervisor?.value
            closer.cancel()
        } else {
            link?.close()
            // 连不上的时候没法告诉主机结束会话：另起一条连接去结束它，成不成都不等。
            if hasAttached || resumesSession { endSessionInBackground() }
        }
        resolveFirstAttach(.closed)
        finishStreams()
    }

    /// 关标签时连不上：另起一条连接去把主机上的会话结束掉。
    ///
    /// - 先重读一遍主机设置（停在 `needsAttention` 时用户可能已经改好了凭据、只是没点重试），地址没变才用新的；
    /// - 主机密钥**不问**（标签已经关了，不能再弹信任框）：不认识或对不上就作罢，会话留在主机上，没人接 24 小时后自己结束。
    private func endSessionInBackground() {
        let profile = profile, auth = auth, jumpHostAuth = jumpHostAuth
        let verifier = hostKeyVerifier, resolveSettings = resolveSettings
        let command = HostHolder.killCommand(sessionID: sessionID)
        Task.detached {
            _ = await BoundedTask.run(timeout: .seconds(30)) {
                var target = (profile: profile, auth: auth, jump: jumpHostAuth)
                if let fresh = try? await resolveSettings?(), Self.isSameMachine(fresh.profile, profile) {
                    target = (fresh.profile, fresh.auth, fresh.jump)
                }
                guard let connected = try? await SSHClientFactory.connectShared(
                    profile: target.profile, auth: target.auth, jumpHostAuth: target.jump,
                    hostKeyVerifier: verifier, hostKeyApprover: { _ in false },
                    approvesInteractively: false) else { return }
                _ = try? await connected.exec(command)
                await connected.close()
            }
        }
    }

    private func finishStreams() {
        guard !didFinishStreams else { return }
        didFinishStreams = true
        phase = .ended
        exitContinuation.yield(())
        exitContinuation.finish()
        itemContinuation.finish()
        reconnectingContinuation.finish()
        attentionContinuation.finish()
        reconnectFailureContinuation.finish()
    }

    private static func resizeFrame(cols: UInt16, rows: UInt16) -> HolderFrame {
        var payload = HolderByteWriter()
        payload.u16(cols)
        payload.u16(rows)
        return HolderFrame(.resize, payload: payload.bytes)
    }

    // MARK: - 存活探测

    /// 看门狗每 30 秒、以及网络稳定后各探一次（回前台、网络刚变的那一下走 `recheckAfterDisruption`）。判死就强关连接，重连由 `supervise` 接手；正在重连时让它立刻再试一次。
    func verifyConnectionAlive() async -> Bool {
        if let fallback { return await fallback.verifyConnectionAlive() }
        guard !isClosed else { return false }
        guard phase == .attached, let client else {
            backoffTask?.cancel()
            return true
        }
        return await probe(client, timeout: Self.probeTimeout)
    }

    /// 回前台、网络刚变：后台挂久了、换了网络，连接多半已经死了；判错了也只是多重连一次，画面不动。
    /// 原来那块网卡没了就不用探，直接断开重连；正在重连的话别等退避，马上再试。
    func recheckAfterDisruption(lostInterface: Bool) async {
        guard fallback == nil, !isClosed else { return }
        guard phase == .attached, let client else {
            reconnectDelay = Self.initialReconnectDelay
            backoffTask?.cancel()
            return
        }
        if lostInterface {
            await client.closeTransport()
            return
        }
        // 路径接连变几次时只留一次在途的探测。
        guard !isRechecking else { return }
        isRechecking = true
        _ = await probe(client, timeout: Self.disruptionProbeTimeout)
        isRechecking = false
    }

    /// 发一笔要对端应答的流量；时限内没回就强关连接，重连由 `supervise` 接手。
    private func probe(_ client: ConnectedClient, timeout: Duration) async -> Bool {
        let alive = await BoundedTask.run(timeout: timeout) {
            do {
                _ = try await client.exec("true")
                return true
            } catch {
                // 服务器拒绝开通道之类的应用层失败也说明连接活着。
                return !SSHTransportFailure.isTransportFailure(error)
            }
        }
        if alive != true { await client.closeTransport() }
        return alive == true
    }

    /// 测试用：像网络断了一样掐掉底下的连接（主机上的会话不受影响）。
    func dropTransportForTesting() async {
        await client?.closeTransport()
    }

    /// 测试用：像 App 被系统结束了一样丢下这个后端。不告诉主机结束会话，也不再重连。
    func abandonForTesting() async {
        guard !isClosed else { return }
        isClosed = true
        backoffTask?.cancel()
        attentionWaiter?.resume()
        attentionWaiter = nil
        link?.close()
        await supervisor?.value
        finishStreams()
    }

    // MARK: - 前台进程、图片、真彩

    func foregroundActivity() async -> TerminalActivity {
        if let fallback { return await fallback.foregroundActivity() }
        guard phase == .attached, let client, shellPID > 0 else { return .unknown }
        let pid = shellPID
        return await TerminalActivity.probed(timeout: .milliseconds(1500)) {
            guard let output = try? await client.collectOutput(of: RemoteProcessTable.command),
                  let table = RemoteProcessTable(output: output),
                  let shell = table.processes[pid] else { return .unknown }
            return table.activity(of: shell)
        }
    }

    func foregroundDirectories() async -> RemoteForegroundDirectories? {
        if let fallback { return await fallback.foregroundDirectories() }
        guard phase == .attached, let client, shellPID > 0 else { return nil }
        let pid = shellPID
        return await RemoteForegroundDirectories.probed(timeout: .seconds(3)) {
            guard let output = try? await client.collectOutput(of: RemoteProcessTable.command),
                  let table = RemoteProcessTable(output: output),
                  let shell = table.processes[pid],
                  let dirs = try? await client.collectOutput(
                      of: RemoteForegroundDirectories.command(pid: table.foregroundPID(of: shell))) else { return nil }
            return RemoteForegroundDirectories(output: dirs)
        }
    }

    nonisolated var programsCanReadMacClipboard: Bool { false }

    func deliverImage(_ image: TerminalImage) async throws -> TerminalImageDelivery {
        if let fallback { return try await fallback.deliverImage(image) }
        guard !isClosed, let client else { throw TerminalImageError.notConnected }
        return try await client.uploadTerminalImage(image)
    }

    func deliverVideo(_ video: TerminalVideo) async throws -> String {
        if let fallback { return try await fallback.deliverVideo(video) }
        guard !isClosed, let client else { throw TerminalImageError.notConnected }
        return try await client.uploadTerminalVideo(video)
    }

    /// 目标的地址与端口在这个后端的一生里不会变（重读设置时变了就拒绝，见 `isSameMachine`），所以建的时候定下来。
    nonisolated var trueColorHostKey: String { machineKey }

    func trueColorStatus() async throws -> RemoteTrueColor.Status {
        if let fallback { return try await fallback.trueColorStatus() }
        return RemoteTrueColor.parseProbe(try await runSetupCommand(RemoteTrueColor.probeCommand))
    }

    func enableTrueColor() async throws -> String {
        if let fallback { return try await fallback.enableTrueColor() }
        let output = try await runSetupCommand(RemoteTrueColor.enableCommand)
        guard let file = RemoteTrueColor.parseEnabledFile(output) else {
            throw RemoteTrueColorError.unexpectedOutput
        }
        return file
    }

    private func runSetupCommand(_ command: String) async throws -> String {
        guard !isClosed, let client else { throw RemoteTrueColorError.notConnected }
        return try await client.runTerminalSetupCommand(command)
    }
}

extension PersistentSSHConnection {
    /// 由一台已保存主机组装（与 `SSHConnection.make` 同一套凭据解析）。
    @MainActor
    static func make(
        sessionID: UUID = UUID(),
        resumesSession: Bool = false,
        profile: ServerProfile,
        container: ModelContainer,
        approver: @escaping @Sendable (HostKeyChallenge) async -> Bool
    ) async throws -> PersistentSSHConnection {
        let snapshot = SSHConnection.ProfileSnapshot(profile)
        let lookup = SSHAuthResolver.Lookup(profile)
        let jumpLookup = profile.jumpHost.map(SSHAuthResolver.Lookup.init)
        let resolved = try await SSHAuthResolver.resolveForConnect(lookup, jump: jumpLookup)
        // 不在库里的主机（临时主机）没得重读，就用建标签时的那份。
        let reread: SettingsResolver
        if profile.modelContext != nil {
            reread = settingsResolver(hostID: profile.id, container: container)
        } else {
            reread = {
                let again = try await SSHAuthResolver.resolveForConnect(lookup, jump: jumpLookup)
                return ResolvedSettings(profile: snapshot, auth: again.auth, jump: again.jump)
            }
        }
        return PersistentSSHConnection(sessionID: sessionID, resumesSession: resumesSession,
                                       profile: snapshot, auth: resolved.auth,
                                       jumpHostAuth: resolved.jump,
                                       hostKeyVerifier: HostKeyVerifier(modelContainer: container),
                                       hostKeyApprover: approver,
                                       resolveSettings: reread)
    }

    /// 按 id 从库里重新取已保存的主机，现做快照与两跳的凭据。
    nonisolated static func settingsResolver(hostID: UUID, container: ModelContainer) -> SettingsResolver {
        {
            let current = try await MainActor.run { () throws -> (SSHConnection.ProfileSnapshot, SSHAuthResolver.Lookup, SSHAuthResolver.Lookup?) in
                let descriptor = FetchDescriptor<ServerProfile>(predicate: #Predicate { $0.id == hostID })
                guard let profile = try container.mainContext.fetch(descriptor).first else { throw HostRemovedError() }
                return (SSHConnection.ProfileSnapshot(profile), SSHAuthResolver.Lookup(profile),
                        profile.jumpHost.map(SSHAuthResolver.Lookup.init))
            }
            let resolved = try await SSHAuthResolver.resolveForConnect(current.1, jump: current.2)
            return ResolvedSettings(profile: current.0, auth: resolved.auth, jump: resolved.jump)
        }
    }
}
