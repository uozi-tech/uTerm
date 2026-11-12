import Foundation
import Synchronization
import SwiftData
@preconcurrency import Citadel
import NIOCore
import NIOSSH

/// 连接断了自己重连、不结束会话的后端。重连期间在 `reconnecting` 上报 true，接回后报 false。
protocol ReconnectingTerminalBackend: TerminalBackend {
    nonisolated var reconnecting: AsyncStream<Bool> { get }
    /// 连接多半已经断了的时刻（App 回到前台、网络刚变）：立刻处置，不等看门狗（它要等网络稳定 3 秒、再探活）。
    /// `lostInterface`：变之前走的那块网卡没了，上面的连接不可能再通。
    /// 判错的代价只是多重连一次的后端才实现；判错就等于断开的不实现，仍然等看门狗。
    func recheckAfterDisruption(lostInterface: Bool) async
}

extension ReconnectingTerminalBackend {
    func recheckAfterDisruption(lostInterface: Bool) async {}
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
actor PersistentSSHConnection: TerminalImageReceiving, TerminalTrueColorConfiguring, ReconnectingTerminalBackend,
                               CheckpointingTerminalBackend {
    // MARK: - TerminalBackend

    nonisolated let outputItems: AsyncStream<TerminalOutputItem>
    nonisolated let exitStream: AsyncStream<Void>
    nonisolated let reconnecting: AsyncStream<Bool>

    private let itemContinuation: AsyncStream<TerminalOutputItem>.Continuation
    private let exitContinuation: AsyncStream<Void>.Continuation
    private let reconnectingContinuation: AsyncStream<Bool>.Continuation

    // MARK: - 配置

    /// 主机上的会话 id。同一个 id 重新接入得到同一个 shell。
    nonisolated let sessionID: UUID
    private let profile: SSHConnection.ProfileSnapshot
    private let auth: ResolvedAuth
    private let jumpHostAuth: ResolvedAuth?
    private let hostKeyVerifier: HostKeyVerifier
    private let hostKeyApprover: @Sendable (HostKeyChallenge) async -> Bool
    private let bundle: Bundle
    /// `sessionID` 是上次运行留下的，主机上多半还有这个会话：没接上就被关掉时也要去结束它。
    private let resumesSession: Bool

    // MARK: - 运行时状态

    private enum Phase {
        case idle, connecting, attached, reconnecting
        /// 这台主机用不了保持进程，全部转给 `fallback`。
        case plain
        case ended
    }

    private enum InitialOutcome {
        case attached, usePlainConnection, closed
    }

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
         bundle: Bundle = .main) {
        self.sessionID = sessionID
        self.resumesSession = resumesSession
        self.profile = profile
        self.auth = auth
        self.jumpHostAuth = jumpHostAuth
        self.hostKeyVerifier = hostKeyVerifier
        self.hostKeyApprover = hostKeyApprover
        self.bundle = bundle
        (outputItems, itemContinuation) = AsyncStream.makeStream(of: TerminalOutputItem.self)
        position = HostHolderStreamPosition(items: itemContinuation, markInterval: Self.checkpointIntervalBytes)
        (exitStream, exitContinuation) = AsyncStream<Void>.makeStream()
        (reconnecting, reconnectingContinuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
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
        while true {
            let end = await runLink(on: connected)
            if isClosed {
                await connected.close()
                break
            }
            switch end {
            case .exited, .replaced, .noSession, .closed:
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
                guard hasAttached else {
                    // 还没接上过：这台主机用不了保持进程，或者连接刚建好就断了。交给普通连接，报错也由它报。
                    resolveFirstAttach(.usePlainConnection)
                    return
                }
                if end != .transport {
                    // 接回时发现二进制没了：会话也跟着没了。
                    finishStreams()
                    return
                }
            }
            // 连接断了，会话还在主机上：重连、接回。
            phase = .reconnecting
            reconnectingContinuation.yield(true)
            // 这一轮连上了却没接回就又断了：等一等再试，别原地打转。
            if !didAttachOnLastLink { await backOff() }
            guard let next = await reconnect() else { break }
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
        if phase == .reconnecting { reconnectingContinuation.yield(false) }
        phase = .attached
        hasAttached = true
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
        if let snapshot = TerminalCheckpointBlob.decode(checkpoint.blob) {
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
    private func reconnect() async -> ConnectedClient? {
        while !isClosed {
            if let connected = try? await openConnection() {
                if isClosed {
                    await connected.close()
                    return nil
                }
                return connected
            }
            await backOff()
        }
        return nil
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
            guard let checkpoint = hooks.capture() else { return }
            let frame = HolderFrame(.checkpoint, payload: HolderCheckpoint(
                offset: offset, cols: checkpoint.cols, rows: checkpoint.rows, hasGap: false,
                blob: checkpoint.blob).encoded())
            Task { await self?.send(checkpoint: frame) }
        }
    }

    private func send(checkpoint frame: HolderFrame) {
        guard !isClosed else { return }
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
        let items = itemContinuation
        let exit = exitContinuation
        Task {
            for await item in plain.outputItems { items.yield(item) }
            items.finish()
        }
        Task {
            for await _ in plain.exitStream { exit.yield(()) }
            exit.finish()
        }
        didFinishStreams = true
        try await plain.connect()
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

    private func endSessionInBackground() {
        let profile = profile, auth = auth, jumpHostAuth = jumpHostAuth
        let verifier = hostKeyVerifier, approver = hostKeyApprover
        let command = HostHolder.killCommand(sessionID: sessionID)
        Task.detached {
            _ = await BoundedTask.run(timeout: .seconds(30)) {
                guard let connected = try? await SSHClientFactory.connectShared(
                    profile: profile, auth: auth, jumpHostAuth: jumpHostAuth,
                    hostKeyVerifier: verifier, hostKeyApprover: approver) else { return }
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

    nonisolated var programsCanReadMacClipboard: Bool { false }

    func deliverImage(_ image: TerminalImage) async throws -> TerminalImageDelivery {
        if let fallback { return try await fallback.deliverImage(image) }
        guard !isClosed, let client else { throw TerminalImageError.notConnected }
        return try await client.uploadTerminalImage(image)
    }

    nonisolated var trueColorHostKey: String { "\(profile.host):\(profile.port)" }

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
        let resolved = try await SSHAuthResolver.resolveForConnect(
            SSHAuthResolver.Lookup(profile),
            jump: profile.jumpHost.map(SSHAuthResolver.Lookup.init))
        return PersistentSSHConnection(sessionID: sessionID, resumesSession: resumesSession,
                                       profile: snapshot, auth: resolved.auth,
                                       jumpHostAuth: resolved.jump,
                                       hostKeyVerifier: HostKeyVerifier(modelContainer: container),
                                       hostKeyApprover: approver)
    }
}
