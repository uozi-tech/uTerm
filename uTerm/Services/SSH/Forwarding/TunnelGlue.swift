import Foundation
import NIOCore
import os

/// 一条隧道的累计收发字节（线程安全）。在转泵热循环里每块累加，故用 `OSAllocatedUnfairLock`
/// 做内部可变性而非 actor —— 避免每个 chunk 跳隔离域。`Sendable`，可自由跨 actor / Task 传递。
/// 多个连接（同一规则的多条 socket）共享同一个计数器，于是得到的是**该规则**的合计流量。
/// 上行 = 本地→远端（客户端发出）；下行 = 远端→本地（返回）。`-R` 走 Citadel 内部转发，
/// 不经本计数器，故远程转发恒为 0（UI 标「不统计」）。
nonisolated final class TunnelByteCounter: Sendable {
    private let state = OSAllocatedUnfairLock<(up: UInt64, down: UInt64)>(initialState: (0, 0))

    func addUp(_ n: Int) {
        guard n > 0 else { return }
        state.withLock { $0.up &+= UInt64(n) }
    }
    func addDown(_ n: Int) {
        guard n > 0 else { return }
        state.withLock { $0.down &+= UInt64(n) }
    }
    var snapshot: (up: UInt64, down: UInt64) { state.withLock { $0 } }
}

/// 双向把两个 `NIOAsyncChannel<ByteBuffer, ByteBuffer>` 粘合起来（A↔B 全双工）。
///
/// 仿 Citadel `runRemotePortForward` 内部的粘合写法：`withThrowingTaskGroup`
/// 跑两个方向（A→B、B→A）的转泵循环。**优雅半关**：某方向读到 EOF 时只半关对端写端
/// （`outbound.finish()`），另一方向继续把缓冲 / 在途字节排空，直到它也读到 EOF；两个方向
/// **都**收尾后才返回，两端的 `executeThenClose` 随之关闭通道。两个通道在闭包返回时都被关闭，
/// 因此调用方无需再手动关 —— 防止 socket/通道泄漏。
///
/// 不要在第一个方向结束时就 `cancelAll()`：那会把仍在流动的对向（NIO 水位生产者缓冲 + pipeline
/// 里的在途字节）连根拔掉，截断仍在传输的响应。只有某方向**抛错**时才取消整组并把错误抛出。
///
/// `pipe` 不抛错：所有错误（连接被对端重置等）都视作隧道正常结束，吞掉后返回。
enum TunnelGlue {

    /// 全双工粘合 `a` 与 `b`，直到**两个**方向都读到 EOF / 出错。返回时两端均已关闭。
    /// `counter`（可选）按方向计字节：A→B 记上行、B→A 记下行（调用方约定 a=本地、b=远端）。
    static func pipe(
        _ a: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        _ b: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        counter: TunnelByteCounter? = nil
    ) async {
        do {
            try await a.executeThenClose { inboundA, outboundA in
                try await b.executeThenClose { inboundB, outboundB in
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        // A → B（本地 → 远端 = 上行）
                        group.addTask {
                            for try await chunk in inboundA {
                                counter?.addUp(chunk.readableBytes)
                                try await outboundB.write(chunk)
                            }
                            // A 侧 EOF：半关 B 的写端，让 B→A 继续把在途字节排空、自然收尾。
                            outboundB.finish()
                        }
                        // B → A（远端 → 本地 = 下行）
                        group.addTask {
                            for try await chunk in inboundB {
                                counter?.addDown(chunk.readableBytes)
                                try await outboundA.write(chunk)
                            }
                            outboundA.finish()
                        }
                        // 优雅排空：等**两个**方向都正常结束（各返回一次）。某方向先到 EOF 只半关
                        // 对端写端、不取消对向，让仍在流动的响应排空。任一方向抛错才取消整组并把
                        // 错误抛出（交由外层 catch 吞掉），避免泄漏未结束的子任务。
                        do {
                            while try await group.next() != nil {}
                        } catch {
                            group.cancelAll()
                            throw error
                        }
                    }
                }
            }
        } catch {
            // 隧道任一端被重置 / 出错 —— 视作正常结束，吞掉。
        }
    }
}
