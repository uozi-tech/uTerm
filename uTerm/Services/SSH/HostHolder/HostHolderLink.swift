import Foundation
import Synchronization
import NIOCore
import USSHKit

/// 会话的输出交给终端的那一头：往后端的输出流里放东西，同时记着已经交出去的字节在整条输出流里的位置。
/// 连接断了重新接入时从这个位置往后要；拍检查点时靠它知道检查点对应哪个位置。
///
/// 「交字节 + 推位置」和「插同步点 + 读位置」在同一把锁里做，所以同步点拿到的位置正好是排在它前面的最后一个字节之后。
/// 同一时刻只有一条 `HostHolderLink` 在交字节（上一条彻底结束才开下一条）。
nonisolated final class HostHolderStreamPosition: Sendable {
    private struct State {
        var offset: UInt64 = 0
        var bytesSinceMark = 0
        var markDueReported = false
        var onMarkDue: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())
    private let items: AsyncStream<TerminalOutputItem>.Continuation
    private let markInterval: Int

    /// `markInterval`：上一个同步点之后交出去这么多字节，就叫一次 `onMarkDue`（该存检查点了）。
    init(items: AsyncStream<TerminalOutputItem>.Continuation, markInterval: Int = .max) {
        self.items = items
        self.markInterval = markInterval
    }

    /// 在交字节的那条线程上调，别在里面做事，只管把活派出去。
    func setOnMarkDue(_ handler: (@Sendable () -> Void)?) {
        state.withLock { $0.onMarkDue = handler }
    }

    var value: UInt64 { state.withLock { $0.offset } }

    /// 上一个同步点之后又交出去多少字节。
    var bytesSinceMark: Int { state.withLock { $0.bytesSinceMark } }

    /// 交一段会话的输出。`asHistory`：客户端不在期间的那段（见 `TerminalOutputItem.history`）。
    func deliver(_ data: Data, asHistory: Bool) {
        let due = state.withLock { state -> (@Sendable () -> Void)? in
            items.yield(asHistory ? .history(data) : .bytes(data))
            state.offset += UInt64(data.count)
            state.bytesSinceMark += data.count
            guard state.bytesSinceMark >= markInterval, !state.markDueReported else { return nil }
            state.markDueReported = true
            return state.onMarkDue
        }
        due?()
    }

    /// 交一项不属于会话输出的东西（还原检查点的快照、本端加的提示），位置不动。
    func deliverAside(_ item: TerminalOutputItem) {
        state.withLock { _ in _ = items.yield(item) }
    }

    func set(_ value: UInt64) {
        state.withLock { $0.offset = value }
    }

    /// 在输出流的当前位置插一个同步点：前面的字节都进了影子之后，`body` 在输出泵的锁里被调，参数是这个位置。
    func mark(_ body: @escaping @Sendable (UInt64) -> Void) {
        state.withLock {
            let offset = $0.offset
            $0.bytesSinceMark = 0
            $0.markDueReported = false
            items.yield(.afterFed { body(offset) })
        }
    }
}

/// 一条 SSH 连接上、接着某个会话的 exec 通道：通道里跑 `uterm-holder attach`，两头说帧协议。
///
/// 一条 link 只用一次。连接断了就结束，由 `PersistentSSHConnection` 另开一条接回同一个会话。
nonisolated final class HostHolderLink: Sendable {
    /// 这条 link 怎么结束的。
    enum End: Sendable, Equatable {
        /// shell 退出了（原始的 wait 状态）。
        case exited(Int32)
        /// 另一个客户端接入了这个会话。
        case replaced
        /// 主机上没有这个会话了（主机重启过、会话被结束）。
        case noSession
        /// 主机上还没装保持进程。
        case notInstalled
        /// 装的时候判定过这台主机用不了。
        case unsupported
        /// 本端关的。
        case closed
        /// 连接断了，或者通道没说明原因就结束了。
        case transport
    }

    enum Event: Sendable {
        /// 接入完成，断开期间的输出已经补完。`hadGap`：补的那段前面缺了一块（离开期间输出超过了主机上的缓冲）。
        case attached(hadGap: Bool, shellPID: Int32)
        case ended(End)
    }

    private struct State {
        var explicitEnd: End?
        var exitCode: Int?
        var finishRequested = false
        var closedLocally = false
        var closeContinuation: CheckedContinuation<Void, Never>?
        var replayHadGap = false
        /// 正在补客户端不在期间的输出，而且要按历史交（`start` 的 `replayIsHistory`）。
        var deliversHistory = false
        var shellPID: Int32 = 0
    }

    private let state = Mutex(State())
    private let outbound: AsyncStream<[UInt8]>
    private let outboundContinuation: AsyncStream<[UInt8]>.Continuation

    init() {
        (outbound, outboundContinuation) = AsyncStream<[UInt8]>.makeStream()
    }

    /// 发一帧。通道还没开好时先排着。
    func send(_ frame: HolderFrame) {
        outboundContinuation.yield(frame.encoded())
    }

    /// 本端关掉通道（结束原因记成 `.closed`）。幂等。
    func close() {
        finish(byLocalClose: true)
    }

    /// 底下的连接已经断了：让这条 link 立刻收尾，结束原因按连接断开算（`.transport`）。
    func connectionLost() {
        finish(byLocalClose: false)
    }

    private func finish(byLocalClose: Bool) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            if byLocalClose { state.closedLocally = true }
            state.finishRequested = true
            defer { state.closeContinuation = nil }
            return state.closeContinuation
        }
        continuation?.resume()
    }

    /// 开通道并接入。`attachPayload`：空 = 从主机存着的检查点接回；`HostHolderAttach.fromOffset` = 只要某个位置之后的字节。
    /// 输出直接交给 `position`（不经 actor）。`replayIsHistory`：接入完成之前补的那段按历史交（客户端不在期间的输出，
    /// 里面的查询不该再答）；刚新建的会话传 false——shell 启动时发的查询可能赶在接入完成之前，那是等着回答的。
    /// `onCheckpoint`：主机回的检查点（`fromOffset` 接入时不带数据），在收帧的那条线程上、排在它之后的输出之前调。
    func start(on client: ConnectedClient, command: String, attachPayload: [UInt8],
               position: HostHolderStreamPosition, replayIsHistory: Bool,
               onCheckpoint: @escaping @Sendable (HolderCheckpoint) -> Void = { _ in }) -> AsyncStream<Event> {
        let (events, eventContinuation) = AsyncStream<Event>.makeStream()
        state.withLock { $0.deliversHistory = replayIsHistory }
        send(HolderFrame(.hello))
        send(HolderFrame(.attach, payload: attachPayload))
        Task {
            do {
                try await client.target.withExec(command) { inbound, writer in
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask { await self.pumpOutbound(to: writer) }
                        group.addTask {
                            await self.pumpInbound(inbound, exit: writer, position: position,
                                                   onCheckpoint: onCheckpoint) {
                                eventContinuation.yield($0)
                            }
                        }
                        group.addTask { await self.waitForClose() }
                        // 任一头结束（通道关了、写不进去了、本端要关）就收尾。
                        await group.next()
                        group.cancelAll()
                        // 等关闭信号的那个子任务不响应取消，要叫醒它，任务组才收得了尾。
                        self.finish(byLocalClose: false)
                    }
                }
            } catch {
                // 开通道失败，或收尾时通道已经关了。结束原因看下面记下的状态。
            }
            self.outboundContinuation.finish()
            eventContinuation.yield(.ended(self.resolvedEnd()))
            eventContinuation.finish()
        }
        return events
    }

    private func pumpOutbound(to writer: SSHExecHandle) async {
        for await bytes in outbound {
            do {
                try await writer.write(ByteBuffer(bytes: bytes))
            } catch {
                return
            }
        }
    }

    private func pumpInbound(_ inbound: SSHChannelOutput, exit process: SSHExecHandle,
                             position: HostHolderStreamPosition,
                             onCheckpoint: @escaping @Sendable (HolderCheckpoint) -> Void,
                             onEvent: @Sendable (Event) -> Void) async {
        var reader = HolderFrameReader()
        do {
            for try await chunk in inbound {
                if Task.isCancelled { return }
                // 标准错误上是 uterm-holder 的报错文案，结束原因看退出码就够了。
                guard case .stdout(let buffer) = chunk else { continue }
                buffer.withUnsafeReadableBytes { reader.append($0) }
                while let frame = try reader.next() {
                    if handle(frame, position: position, onCheckpoint: onCheckpoint, onEvent: onEvent) { return }
                }
            }
        } catch {
            // 连接断了，或对端发来的不是帧。
            return
        }
        // 输出读完了（对端发了 EOF）：通道关时带着 uterm-holder 的退出码，结束原因看它。
        if case .exited(let code) = await process.exitStatus() {
            state.withLock { $0.exitCode = code }
        }
    }

    /// 处理一帧。返回 true 表示这条 link 到此为止。
    private func handle(_ frame: HolderFrame, position: HostHolderStreamPosition,
                        onCheckpoint: @Sendable (HolderCheckpoint) -> Void, onEvent: @Sendable (Event) -> Void) -> Bool {
        switch frame.kind {
        case .helloReply:
            if let hello = HolderHelloReply(decoding: frame.payload) {
                state.withLock { $0.shellPID = hello.shellPID }
            }
        case .replayCheckpoint:
            if let checkpoint = HolderCheckpoint(decoding: frame.payload) {
                if checkpoint.hasGap { state.withLock { $0.replayHadGap = true } }
                onCheckpoint(checkpoint)
            }
        case .output:
            position.deliver(Data(frame.payload), asHistory: state.withLock { $0.deliversHistory })
        case .replayEnd:
            // 回放有缺口时，数出来的位置落在真实位置后面；以主机报的为准。
            var payload = HolderByteReader(frame.payload)
            if let end = payload.u64() { position.set(end) }
            let (hadGap, shellPID) = state.withLock { state in
                state.deliversHistory = false
                return (state.replayHadGap, state.shellPID)
            }
            onEvent(.attached(hadGap: hadGap, shellPID: shellPID))
        case .exited:
            var payload = HolderByteReader(frame.payload)
            let status = payload.i32() ?? 0
            state.withLock { $0.explicitEnd = .exited(status) }
            return true
        case .replaced:
            state.withLock { $0.explicitEnd = .replaced }
            return true
        default:
            // 不认识的帧忽略：主机上可能是更新的保持进程。
            break
        }
        return false
    }

    private func waitForClose() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyRequested = state.withLock { state -> Bool in
                if state.finishRequested { return true }
                state.closeContinuation = continuation
                return false
            }
            if alreadyRequested { continuation.resume() }
        }
    }

    private func resolvedEnd() -> End {
        state.withLock { state in
            if let explicit = state.explicitEnd { return explicit }
            if state.closedLocally { return .closed }
            switch state.exitCode {
            case HostHolder.ExitCode.noSession: return .noSession
            case HostHolder.ExitCode.notInstalled: return .notInstalled
            case HostHolder.ExitCode.unsupported: return .unsupported
            default: return .transport
            }
        }
    }
}

/// attach 帧的负载（主机上的 `holder/internal/holder/wire.go` 同一份定义）。
nonisolated enum HostHolderAttach {
    /// 从主机存着的检查点接回。
    static let fromStoredCheckpoint: [UInt8] = []

    /// 客户端自己留着终端状态，只要 `offset` 之后的字节。
    static func fromOffset(_ offset: UInt64) -> [UInt8] {
        var writer = HolderByteWriter()
        writer.u8(1)
        writer.u64(offset)
        return writer.bytes
    }
}
