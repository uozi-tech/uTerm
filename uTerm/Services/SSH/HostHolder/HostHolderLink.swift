import Foundation
import Synchronization
@preconcurrency import Citadel
import NIOCore

/// 已经交给终端的输出在整条输出流里的位置。连接断了重新接入时，从这里往后要。
///
/// 同一时刻只有一条 `HostHolderLink` 在写它（上一条彻底结束才开下一条），锁只是为了跨线程读。
nonisolated final class HostHolderStreamPosition: Sendable {
    private let offset = Mutex<UInt64>(0)

    var value: UInt64 { offset.withLock { $0 } }

    func advance(by count: Int) {
        offset.withLock { $0 += UInt64(count) }
    }

    func set(_ value: UInt64) {
        offset.withLock { $0 = value }
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
    /// 输出直接交给 `output`（不经 actor），位置记在 `position` 上。
    func start(on client: ConnectedClient, command: String, attachPayload: [UInt8],
               position: HostHolderStreamPosition,
               output: @escaping @Sendable (Data) -> Void) -> AsyncStream<Event> {
        let (events, eventContinuation) = AsyncStream<Event>.makeStream()
        send(HolderFrame(.hello))
        send(HolderFrame(.attach, payload: attachPayload))
        Task {
            do {
                try await client.target.withExec(command) { inbound, writer in
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask { await self.pumpOutbound(to: writer) }
                        group.addTask {
                            await self.pumpInbound(inbound, position: position, output: output) {
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

    private func pumpOutbound(to writer: TTYStdinWriter) async {
        for await bytes in outbound {
            do {
                try await writer.write(ByteBuffer(bytes: bytes))
            } catch {
                return
            }
        }
    }

    private func pumpInbound(_ inbound: TTYOutput, position: HostHolderStreamPosition,
                             output: @escaping @Sendable (Data) -> Void,
                             onEvent: @Sendable (Event) -> Void) async {
        var reader = HolderFrameReader()
        do {
            for try await chunk in inbound {
                if Task.isCancelled { return }
                // 标准错误上是 uterm-holder 的报错文案，结束原因看退出码就够了。
                guard case .stdout(let buffer) = chunk else { continue }
                buffer.withUnsafeReadableBytes { reader.append($0) }
                while let frame = try reader.next() {
                    if handle(frame, position: position, output: output, onEvent: onEvent) { return }
                }
            }
        } catch let failure as SSHClient.CommandFailed {
            state.withLock { $0.exitCode = failure.exitCode }
        } catch {
            // 连接断了，或对端发来的不是帧。
        }
    }

    /// 处理一帧。返回 true 表示这条 link 到此为止。
    private func handle(_ frame: HolderFrame, position: HostHolderStreamPosition,
                        output: @Sendable (Data) -> Void, onEvent: @Sendable (Event) -> Void) -> Bool {
        switch frame.kind {
        case .helloReply:
            if let hello = HolderHelloReply(decoding: frame.payload) {
                state.withLock { $0.shellPID = hello.shellPID }
            }
        case .replayCheckpoint:
            if let checkpoint = HolderCheckpoint(decoding: frame.payload), checkpoint.hasGap {
                state.withLock { $0.replayHadGap = true }
            }
        case .output:
            output(Data(frame.payload))
            position.advance(by: frame.payload.count)
        case .replayEnd:
            // 回放有缺口时，数出来的位置落在真实位置后面；以主机报的为准。
            var payload = HolderByteReader(frame.payload)
            if let end = payload.u64() { position.set(end) }
            let (hadGap, shellPID) = state.withLock { ($0.replayHadGap, $0.shellPID) }
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
