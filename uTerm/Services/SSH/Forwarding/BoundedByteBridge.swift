import NIOCore
import NIOConcurrencyHelpers

/// 有界背压字节桥 —— 替代无界 `AsyncStream<ByteBuffer>` 做 SOCKS5(-D) 的本地→目标转发桥。
///
/// 单生产者单消费者（SPSC）、FIFO、**不丢字节**（`finish()` / 任务取消除外）。`send` 在已缓冲
/// 字节达到高水位时挂起，直到消费者取走腾出空间 —— 由此把目标侧（SSH 通道流控窗口）的背压
/// 经本地读循环反传到 NIO 本地 socket 的入站背压，杜绝 -D 上行在慢隧道上无界堆积内存。
///
/// 为什么不用 `AsyncStream`：其 `yield` 永不挂起（背压失效），而 `bufferingPolicy` 的 bounded
/// 变体会**丢弃**元素（对 TCP 流是损坏）。本工程未依赖 swift-async-algorithms 的 `AsyncChannel`，
/// 故自实现一个最小有界背压原语。仅一个生产者（`handleAccepted` 读循环）与一个消费者
/// （`glueRemote` 上行任务），SPSC 假设成立，故至多各有一个挂起的 continuation。
///
/// `nonisolated`：本模块默认 `@MainActor` 隔离，但本桥在后台转发任务（非主线程）间使用，
/// 故显式 opt-out（与 `TunnelGlue` / `ForwardingError` 同）。线程安全由内部锁保证。
nonisolated final class BoundedByteBridge: @unchecked Sendable {

    private struct State {
        var queue: [ByteBuffer] = []
        var bytes: Int = 0
        var finished = false
        /// 至多一个挂起的消费者（仅在队列空时挂起）。
        var consumer: CheckedContinuation<ByteBuffer?, Never>?
        /// 至多一个挂起的生产者（仅在缓冲满时挂起）。
        var producer: CheckedContinuation<Void, Never>?
    }

    private let state = NIOLockedValueBox(State())
    private let highWaterMark: Int

    /// - Parameter highWaterMark: 缓冲字节上限（软上限：单块超限时仍允许在队列空时入队，
    ///   避免大块永久卡死）。默认 512 KiB —— 足够不被 bridge 拖慢吞吐（真正上限是 SSH 窗口），
    ///   又把每条 -D 连接的桥内存钉在常数级。
    init(highWaterMark: Int = 1 << 19) {
        self.highWaterMark = highWaterMark
    }

    /// 生产一块字节。缓冲满则挂起，直到消费者腾出空间，或桥 `finish()` / 当前任务被取消。
    func send(_ buffer: ByteBuffer) async {
        while true {
            enum Step {
                case done                                              // 已入队 / 已 finish / 已取消 —— 返回
                case handoff(CheckedContinuation<ByteBuffer?, Never>)  // 消费者在等，直接交接
                case suspend                                           // 缓冲满，挂起等空间
            }
            let step: Step = state.withLockedValue { s in
                if s.finished || Task.isCancelled { return .done }       // 收尾中 / 已取消 → 丢弃
                if let c = s.consumer {                                  // 消费者在等（此时队列必空）→ 直接交接
                    s.consumer = nil
                    return .handoff(c)
                }
                if s.bytes < highWaterMark || s.queue.isEmpty {          // 有空间，或至少放一块
                    s.queue.append(buffer)
                    s.bytes += buffer.readableBytes
                    return .done
                }
                return .suspend
            }
            switch step {
            case .done:
                return
            case .handoff(let consumer):
                consumer.resume(returning: buffer)
                return
            case .suspend:
                await withTaskCancellationHandler {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        let resumeNow: Bool = state.withLockedValue { s in
                            // 重新核对：可能在加锁间隙已腾出空间 / 已 finish / 来了消费者 / 已取消。
                            if s.finished || Task.isCancelled || s.bytes < highWaterMark || s.consumer != nil {
                                return true
                            }
                            s.producer = cont
                            return false
                        }
                        if resumeNow { cont.resume() }
                    }
                } onCancel: {
                    let cont = state.withLockedValue { s -> CheckedContinuation<Void, Never>? in
                        let p = s.producer; s.producer = nil; return p
                    }
                    cont?.resume()
                }
                // 被唤醒后回到 while 顶重试（入队 / 交接 / 因 finish·取消而返回）。
            }
        }
    }

    /// 消费一块字节。队列空且未 `finish()` 则挂起。返回 `nil` = 桥已结束并排空，或当前任务被取消。
    func next() async -> ByteBuffer? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<ByteBuffer?, Never>) in
                enum Step {
                    case got(ByteBuffer, CheckedContinuation<Void, Never>?)  // 出队（顺带唤醒挂起的生产者）
                    case finished                                            // 已结束并排空 → nil
                    case wait                                                // 挂起，等 send / finish / 取消唤醒
                }
                let step: Step = state.withLockedValue { s in
                    if !s.queue.isEmpty {
                        let b = s.queue.removeFirst()
                        s.bytes -= b.readableBytes
                        let p = s.producer; s.producer = nil    // 腾出空间 → 唤醒生产者
                        return .got(b, p)
                    }
                    if s.finished || Task.isCancelled { return .finished }
                    s.consumer = cont
                    return .wait
                }
                switch step {
                case .got(let b, let producer):
                    cont.resume(returning: b)
                    producer?.resume()
                case .finished:
                    cont.resume(returning: nil)
                case .wait:
                    break   // 稍后由 send / finish / onCancel 唤醒
                }
            }
        } onCancel: {
            let cont = state.withLockedValue { s -> CheckedContinuation<ByteBuffer?, Never>? in
                let c = s.consumer; s.consumer = nil; return c
            }
            cont?.resume(returning: nil)
        }
    }

    /// 结束桥（幂等）。唤醒挂起的消费者（排空剩余后得 `nil`）与生产者（丢弃当前块返回）。
    func finish() {
        let (consumer, producer): (CheckedContinuation<ByteBuffer?, Never>?, CheckedContinuation<Void, Never>?) =
            state.withLockedValue { s in
                s.finished = true
                let c = s.consumer; s.consumer = nil
                let p = s.producer; s.producer = nil
                return (c, p)
            }
        consumer?.resume(returning: nil)
        producer?.resume()
    }

    /// 仅测试：当前缓冲字节数（断言背压把内存钉在上限附近）。
    var bufferedBytesForTesting: Int {
        state.withLockedValue { $0.bytes }
    }
}
