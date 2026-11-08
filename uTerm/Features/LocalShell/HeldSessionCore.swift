import Foundation
import UPaneGroups

/// 连着一个 `uterm-holder` 的会话：attach、收发帧、收尾。本机 shell 和 SSH 两种后端共用。
///
/// `close()` 结束会话，`detach()` 只断开。退出原因分得开：holder 明说子进程退出了（`exited`）、
/// 被别的客户端接走（`replaced`）、连接断了（holder 没了）。这三种对终端来说都是这条会话到头了。
actor HeldSessionCore {
    nonisolated let outputStream: AsyncStream<Data>
    nonisolated let exitStream: AsyncStream<Void>
    nonisolated let holderLink = HolderLink()
    private let outputContinuation: AsyncStream<Data>.Continuation
    private let exitContinuation: AsyncStream<Void>.Continuation

    private var connection: HolderConnection?
    private var replay: HolderReplay?
    private var childPID: Int32?
    private enum Teardown { case terminate, detach }
    /// 连接途中就被要求收尾时记在这，连上之后补做。
    private var teardown: Teardown?
    private var isFinished = false
    private var nextExecID = 1
    private var pendingExecs: [Int: CheckedContinuation<String, Error>] = [:]

    init() {
        (outputStream, outputContinuation) = AsyncStream.makeStream(of: Data.self)
        (exitStream, exitContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    /// 子进程的进程号（已结束 / 未启动时 nil）。
    var pid: Int32? { childPID }
    var isConnected: Bool { connection != nil && !isFinished }
    var finished: Bool { isFinished }

    /// 接入 holder。返回 false = 接入途中已经被要求收尾，这条连接已经处理掉了。
    @discardableResult
    func attach(_ handle: FileHandle) async throws -> Bool {
        let (connection, replay) = try await openAttachment(handle)
        if let teardown {
            if teardown == .terminate { connection.send(HolderFrame(.terminate)) }
            connection.close()
            return false
        }
        self.connection = connection
        self.replay = replay
        childPID = replay.hello.shellPID
        holderLink.install(connection)
        return true
    }

    private func openAttachment(_ handle: FileHandle) async throws -> (HolderConnection, HolderReplay) {
        let connection = HolderConnection(handle)
        let receiver = HolderSessionReceiver(output: outputContinuation) { [weak self] in
            Task { await self?.ended() }
        } onChildReply: { [weak self] payload in
            Task { await self?.receiveChildReply(payload) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            receiver.onReplayFinished = { result in
                // 接入失败（如回包看不懂）时连接没人再持有：先关掉，免得写端 DispatchSource
                // 没启动就随连接释放，libdispatch 直接崩（"Release of an inactive object"）。
                if case .failure = result { connection.close() }
                continuation.resume(with: result.map { (connection, $0) })
            }
            connection.onFrame = { receiver.receive($0) }
            connection.onClosed = { receiver.connectionClosed() }
            connection.start()
            connection.send(HolderFrame(.hello))
            connection.send(HolderFrame(.attach))
            // holder 卡死不能把窗口一直挂在「正在启动」。超过之后连接关掉，走上面的失败路径。
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { [weak connection, weak receiver] in
                guard receiver?.isReplayPending == true else { return }
                connection?.close()
            }
        }
    }

    func takeReplay() -> HolderReplay? {
        defer { replay = nil }
        return replay
    }

    /// 这次接入看到的 hello（`takeReplay` 之前有效）。
    var attachedHello: HolderHelloReply? { replay?.hello }

    func write(_ data: Data) {
        guard !isFinished else { return }
        connection?.send(HolderFrame(.input, payload: Array(data)))
    }

    func resize(cols: UInt16, rows: UInt16) {
        guard !isFinished else { return }
        var writer = HolderByteWriter()
        writer.u16(cols)
        writer.u16(rows)
        connection?.send(HolderFrame(.resize, payload: writer.bytes))
    }

    func setAttributes(_ attributes: Data) {
        connection?.send(HolderFrame(.setAttributes, payload: Array(attributes)))
    }

    func send(_ frame: HolderFrame) {
        connection?.send(frame)
    }

    /// 在 `uterm-ssh` 手上那条连接上跑一条命令，返回 stdout。
    /// 没回音（对面是还不认识这个帧的旧 holder、命令挂住）就超时。
    func execOnChild(_ command: String, timeout: Duration) async throws -> String {
        guard !isFinished, let connection else { throw HeldExecFailure.unavailable }
        let id = nextExecID
        nextExecID += 1
        let payload = try JSONEncoder().encode(SSHBridgeMessage.exec(id: id, command: command))
        return try await withCheckedThrowingContinuation { continuation in
            pendingExecs[id] = continuation
            connection.send(HolderFrame(.childRequest, payload: Array(payload)))
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.finishExec(id, .failure(HeldExecFailure.timedOut))
            }
        }
    }

    private func finishExec(_ id: Int, _ result: Result<String, Error>) {
        pendingExecs.removeValue(forKey: id)?.resume(with: result)
    }

    private func receiveChildReply(_ payload: [UInt8]) {
        guard case .execResult(let id, let output)? = try? JSONDecoder().decode(SSHBridgeMessage.self, from: Data(payload))
        else { return }
        finishExec(id, output.map { .success($0) } ?? .failure(HeldExecFailure.commandFailed))
    }

    func close() {
        guard !isFinished else { return }
        teardown = .terminate
        connection?.send(HolderFrame(.terminate))
        shutDown()
    }

    func detach() {
        guard !isFinished else { return }
        teardown = .detach
        shutDown()
    }

    private func shutDown() {
        isFinished = true
        for continuation in pendingExecs.values { continuation.resume(throwing: HeldExecFailure.unavailable) }
        pendingExecs = [:]
        holderLink.install(nil)
        connection?.close()
        connection = nil
        childPID = nil
        outputContinuation.finish()
        exitContinuation.finish()
    }

    private func ended() {
        guard !isFinished else { return }
        // 先 yield 再 finish：finish 之后 yield 是空操作，会话结束就没人知道了。
        exitContinuation.yield()
        shutDown()
    }
}

nonisolated enum HeldExecFailure: Error {
    case unavailable
    case timedOut
    case commandFailed
}

nonisolated enum HolderSessionFailure: LocalizedError {
    case disconnected
    case badReply

    var errorDescription: String? {
        switch self {
        case .disconnected: return "终端辅助程序断开了连接"
        case .badReply: return "终端辅助程序返回了无法识别的内容"
        }
    }
}

/// 收 holder 的帧：先攒回放，`replayEnd` 之后转成输出流。只在连接的队列上用。
nonisolated private final class HolderSessionReceiver: @unchecked Sendable {
    private let output: AsyncStream<Data>.Continuation
    private let onEnded: @Sendable () -> Void
    private let onChildReply: @Sendable ([UInt8]) -> Void
    var onReplayFinished: (@Sendable (Result<HolderReplay, Error>) -> Void)?

    private var hello: HolderHelloReply?
    private var checkpoint: HolderCheckpoint?
    private var collected: [UInt8] = []
    private var isLive = false

    /// 其它线程只用它判断要不要放弃，读到旧值也只是晚一拍。
    private let pendingLock = NSLock()
    private var pending = true
    var isReplayPending: Bool {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return pending
    }

    init(output: AsyncStream<Data>.Continuation, onEnded: @escaping @Sendable () -> Void,
         onChildReply: @escaping @Sendable ([UInt8]) -> Void) {
        self.output = output
        self.onEnded = onEnded
        self.onChildReply = onChildReply
    }

    func receive(_ frame: HolderFrame) {
        // 不认识的帧忽略：旧 App 可能连着新 holder。
        guard let kind = frame.kind else { return }
        switch kind {
        case .helloReply:
            hello = HolderHelloReply(decoding: frame.payload)
        case .replayCheckpoint:
            checkpoint = HolderCheckpoint(decoding: frame.payload)
        case .output:
            if isLive {
                output.yield(Data(frame.payload))
            } else {
                collected.append(contentsOf: frame.payload)
            }
        case .replayEnd:
            var reader = HolderByteReader(frame.payload)
            guard let hello, let checkpoint, let end = reader.u64() else {
                finishReplay(.failure(HolderSessionFailure.badReply))
                return
            }
            isLive = true
            finishReplay(.success(HolderReplay(hello: hello, checkpoint: checkpoint, output: collected, endOffset: end)))
            collected = []
        case .exited, .replaced:
            onEnded()
        case .childReply:
            onChildReply(frame.payload)
        case .hello, .attach, .input, .resize, .checkpoint, .setAttributes, .terminate, .redraw, .probe, .childRequest:
            break
        }
    }

    func connectionClosed() {
        if isReplayPending {
            finishReplay(.failure(HolderSessionFailure.disconnected))
        } else {
            onEnded()
        }
    }

    private func finishReplay(_ result: Result<HolderReplay, Error>) {
        pendingLock.lock()
        pending = false
        pendingLock.unlock()
        let finished = onReplayFinished
        onReplayFinished = nil
        finished?(result)
    }
}

// MARK: - 窗口布局

/// 窗口的终端布局（分屏方向与比例、每组的标签顺序、前台标签、活动组），标签记成会话 id。
///
/// 存进窗口里**每个**会话的 holder 归属：holder 是会话的真值，App 重启后谁活着就从谁那里读。布局一变就重写
/// 一遍，各份副本可能新旧不一（刚开的会话还没连上、写的那一刻某个 holder 正好没接上），恢复时取 `revision`
/// 最大的一份。
nonisolated struct HeldSessionLayout: Codable, Equatable, Sendable {
    /// 写下这份布局的时刻（Unix 秒）。
    var revision: Double
    var tree: UPaneGroupsSnapshot<UUID>

    static func newest(_ layouts: some Sequence<HeldSessionLayout?>) -> HeldSessionLayout? {
        layouts.compactMap { $0 }.max { $0.revision < $1.revision }
    }
}

extension UPaneGroupsModel {
    /// 接回上次留下的会话：按布局放回原来的组和位置，布局里没有的（旧版写的归属、布局还没来得及写进去的会话）
    /// 按 `ids` 的顺序交给 `append`。只在模型还空着时套用布局，已经有标签的不动它们的位置。
    /// `id` 取标签的会话 id（SSH 终端的标签 id 与会话 id 不是同一个）。
    func adoptHeldSessions(_ ids: [UUID], layout: HeldSessionLayout?, id: (UPaneTab<Payload>) -> UUID?,
                           make: (UUID) -> UPaneTab<Payload>, append: (UUID) -> Void) {
        let existing = Set(allTabs.compactMap(id))
        var remaining = ids.filter { !existing.contains($0) }
        var restoredActive: UUID?
        if allTabs.isEmpty, let layout {
            let wanted = Set(remaining)
            var placed: Set<UUID> = []
            restore(layout.tree) { id -> UPaneTab<Payload>? in
                guard wanted.contains(id), placed.insert(id).inserted else { return nil }
                return make(id)
            }
            remaining.removeAll { placed.contains($0) }
            restoredActive = activeTab?.id
        }
        for id in remaining { append(id) }
        // 补在后面的会话开进来时会抢成前台，把布局里的前台标签还回去。
        if !remaining.isEmpty, let restoredActive, let at = locateTab(restoredActive) {
            activateTab(groupID: at.groupID, index: at.index)
        }
    }
}

/// 布局一变（重排、拆分、跨组拖动、关标签、拖分隔条、切前台标签）就把新布局交给 `write`。
/// 拖分隔条每帧都在变，攒一小会儿再写。
@MainActor
final class HeldLayoutWriter<Payload> {
    private weak var groups: UPaneGroupsModel<Payload>?
    private let delay: Duration
    private let id: (UPaneTab<Payload>) -> UUID?
    private let write: @MainActor (HeldSessionLayout) -> Void
    private var pending: Task<Void, Never>?
    private var isStopped = false

    init(groups: UPaneGroupsModel<Payload>, delay: Duration = .milliseconds(300),
         id: @escaping (UPaneTab<Payload>) -> UUID?, write: @escaping @MainActor (HeldSessionLayout) -> Void) {
        self.groups = groups
        self.delay = delay
        self.id = id
        self.write = write
        observe()
    }

    func stop() {
        isStopped = true
        pending?.cancel()
        pending = nil
    }

    /// `id` 返回 nil 的标签（文件预览）不进布局。
    private func flush() {
        pending = nil
        guard !isStopped, let groups else { return }
        write(HeldSessionLayout(revision: Date().timeIntervalSince1970, tree: groups.snapshot(id)))
    }

    private func observe() {
        guard !isStopped, let groups else { return }
        withObservationTracking {
            _ = groups.snapshot(id)
        } onChange: { [weak self] in
            Task { @MainActor in self?.changed() }
        }
    }

    private func changed() {
        guard !isStopped else { return }
        observe()
        pending?.cancel()
        pending = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
}
