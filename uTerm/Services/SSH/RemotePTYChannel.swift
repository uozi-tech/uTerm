import Foundation
@preconcurrency import Citadel
import NIOCore
import NIOSSH

/// 一条 PTY 通道的尺寸与终端类型。
nonisolated struct PTYSpec: Sendable, Equatable {
    var term: String
    var cols: Int
    var rows: Int
}

/// 一条开着的 PTY 通道：写 stdin、改尺寸、关。输出与结束走打开时给的回调。
///
/// 抽成协议是给命令行的交互会话做测试替身 —— 会话本身不认识 SSH。
nonisolated protocol PTYHandle: AnyObject, Sendable {
    /// 字节按调用顺序写入（内部单一 FIFO），不等远端确认。
    func write(_ data: Data)
    func resize(cols: Int, rows: Int)
    /// 关通道。远端进程随 PTY 挂断收到 SIGHUP。幂等。
    func close()
}

/// PTY 通道是怎么结束的。
nonisolated enum PTYEnding: Sendable, Equatable {
    /// 远端进程退出。`exitCode` 是 sshd 回报的退出码；被信号杀掉时 sshd 不报退出码，
    /// Citadel 把这种 EOF 当正常结束，于是也是 0 —— 这层分不出来。
    case exited(Int)
    /// 本端调了 `close()`。
    case closedLocally
    /// 通道 / 连接出错（断网、sshd 被重启、连接被 `disconnect` 释放）。
    case failed(String)
}

/// Citadel `withPTY` 的句柄化包装：开一条 PTY + shell 通道，返回能随时写、随时关的句柄。
///
/// `withPTY` 是作用域闭包、闭包返回就关通道，所以与 `SSHConnection` 一样把闭包挂在一个
/// 独立 Task 里，stdin 走 `PTYStdinState` 的有序 FIFO。区别是这里**不拥有连接**：通道开在
/// 调用方给的 `SSHClient` 上（命令行连接池的复用连接），关通道不关连接。
///
/// Citadel 只公开「PTY + shell」，没有「PTY + exec」：要跑指定命令时，调用方把命令作为
/// 第一行输入写给登录 shell（见 `ControlPTYCommand`）。
nonisolated final class RemotePTYChannel: PTYHandle {
    private let state = PTYStdinState()

    private init() {}

    /// 在一条已连上的连接（跳板机路径下是目标那一跳）上开通道。
    static func open(
        on connected: ConnectedClient,
        spec: PTYSpec,
        onOutput: @escaping @Sendable (Data) -> Void,
        onEnd: @escaping @Sendable (PTYEnding) -> Void
    ) async throws -> RemotePTYChannel {
        try await open(on: connected.target, spec: spec, onOutput: onOutput, onEnd: onEnd)
    }

    /// 开通道。返回时 PTY 已就绪、stdin 可写；开不起来直接抛错，`onEnd` 不会被调。
    ///
    /// - `onOutput`：每块输出（stdout / stderr 合流，PTY 本来就不分）回调一次，在 NIO /
    ///   流消费者的线程上同步调用 —— 调用方别在里面做重活。
    /// - `onEnd`：通道结束时恰好调一次。
    static func open(
        on client: SSHClient,
        spec: PTYSpec,
        environment: [String: String] = ["LANG": "en_US.UTF-8"],
        onOutput: @escaping @Sendable (Data) -> Void,
        onEnd: @escaping @Sendable (PTYEnding) -> Void
    ) async throws -> RemotePTYChannel {
        let channel = RemotePTYChannel()
        let state = channel.state
        let gate = OpenGate()
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: spec.term,
            terminalCharacterWidth: spec.cols,
            terminalRowHeight: spec.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        let env = environment.sorted { $0.key < $1.key }.map {
            SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: $0.key, value: $0.value)
        }

        Task.detached {
            var ending = PTYEnding.closedLocally
            do {
                try await client.withPTY(request, environment: env) { inbound, outbound in
                    state.attach(writer: outbound)
                    gate.open(nil)
                    ending = await withTaskGroup(of: PTYEnding?.self) { group in
                        group.addTask {
                            do {
                                for try await chunk in inbound {
                                    switch chunk {
                                    case .stdout(let buffer), .stderr(let buffer):
                                        onOutput(Data(buffer.readableBytesView))
                                    }
                                }
                                return Task.isCancelled ? nil : .exited(0)
                            } catch let failed as SSHClient.CommandFailed {
                                return .exited(failed.exitCode)
                            } catch {
                                return Task.isCancelled ? nil : .failed(FriendlyError.describe(error))
                            }
                        }
                        group.addTask {
                            await state.waitForClose()
                            return nil
                        }
                        let first = await group.next() ?? nil
                        // 先放掉 close 等待方：它的 continuation 不认取消，远端自己退出时
                        // 不发信号的话 task group 永远收不了尾。输出泵那边认取消
                        //（AsyncThrowingStream 在任务取消时结束迭代）。
                        state.signalClose()
                        group.cancelAll()
                        return first ?? .closedLocally
                    }
                }
            } catch {
                // 没进过闭包 = 通道没开起来：错误交给 `open` 的调用方，不报结束。
                if gate.open(error) {
                    await state.shutdownDrain()
                    return
                }
                // 进过闭包：错误来自收尾时关通道，结束原因以闭包里判定的为准。
            }
            await state.shutdownDrain()
            onEnd(ending)
        }

        try await gate.wait()
        return channel
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        state.enqueue(.write(data))
    }

    func resize(cols: Int, rows: Int) {
        state.enqueue(.resize(cols: cols, rows: rows))
    }

    func close() {
        state.signalClose()
    }
}

/// 「通道开起来没有」的一次性闸：`withPTY` 进了闭包就放行，进闭包之前就抛错则带错放行。
private nonisolated final class OpenGate: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<Void, any Error>?
    private var waiter: CheckedContinuation<Void, any Error>?

    /// 第一次调用生效并返回 true；之后的调用是空操作、返回 false。
    @discardableResult
    func open(_ error: (any Error)?) -> Bool {
        let resumed: CheckedContinuation<Void, any Error>?
        let result: Result<Void, any Error> = error.map { .failure($0) } ?? .success(())
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return false
        }
        outcome = result
        resumed = waiter
        waiter = nil
        lock.unlock()
        resumed?.resume(with: result)
        return true
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(with: outcome)
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }
}
