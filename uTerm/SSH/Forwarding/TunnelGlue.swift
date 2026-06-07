import Foundation
import NIOCore

/// 双向把两个 `NIOAsyncChannel<ByteBuffer, ByteBuffer>` 粘合起来（A↔B 全双工）。
///
/// 仿 Citadel `runRemotePortForward` 内部的粘合写法：`withThrowingTaskGroup`
/// 跑两个方向（A→B、B→A）的转泵循环，任一方向结束/出错就 `cancelAll()`，
/// 两端的 `executeThenClose` 随之收尾关闭通道。两个通道在闭包返回时都被关闭，
/// 因此调用方无需再手动关 —— 防止 socket/通道泄漏。
///
/// `pipe` 不抛错：所有错误（连接被对端重置等）都视作隧道正常结束，吞掉后返回。
enum TunnelGlue {

    /// 全双工粘合 `a` 与 `b`，直到任一方向关闭/出错。返回时两端均已关闭。
    static func pipe(
        _ a: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        _ b: NIOAsyncChannel<ByteBuffer, ByteBuffer>
    ) async {
        do {
            try await a.executeThenClose { inboundA, outboundA in
                try await b.executeThenClose { inboundB, outboundB in
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        // A → B
                        group.addTask {
                            for try await chunk in inboundA {
                                try await outboundB.write(chunk)
                            }
                            // A 侧 EOF：半关 B 的写端，让 B→A 自然收尾。
                            outboundB.finish()
                        }
                        // B → A
                        group.addTask {
                            for try await chunk in inboundB {
                                try await outboundA.write(chunk)
                            }
                            outboundA.finish()
                        }
                        // 任一方向结束（含 EOF / 出错）即取消另一方向，收尾两端。
                        defer { group.cancelAll() }
                        try await group.next()
                    }
                }
            }
        } catch {
            // 隧道任一端被重置 / 出错 —— 视作正常结束，吞掉。
        }
    }
}
