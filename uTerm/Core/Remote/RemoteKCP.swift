import CKCP
import Foundation

/// 对 `ikcp` 的薄封装。不是线程安全的，全部调用都在同一条队列上。
///
/// 用消息模式、每条不超过一个 MSS，所以一次 `send` 恰好占一个序号，发送完成回调才能按 `snd_una` 算。
nonisolated final class RemoteKCP {
    private final class Box {
        var output: (Data) -> Void = { _ in }
    }

    /// 协议里的会话号。这条连接独占这条数据报通道，用不着区分，写死。
    private static let conversation: UInt32 = 0x7554_524D

    private let kcp: UnsafeMutablePointer<ikcpcb>
    private let box: Unmanaged<Box>
    private(set) var nextSequence: UInt32 = 0

    init(mtu: Int, output: @escaping (Data) -> Void) {
        let holder = Box()
        holder.output = output
        box = Unmanaged.passRetained(holder)
        kcp = ikcp_create(Self.conversation, box.toOpaque())
        kcp.pointee.stream = 0
        ikcp_setmtu(kcp, Int32(mtu))
        // 快速模式：关退避翻倍、10 ms 一拍、两次跳过就重传。不用它的拥塞窗口，窗口由 `setWindow` 按带宽时延积给，
        // 节奏由 `RemoteDatagramPacer` 控：它的拥塞控制把随机丢包当拥塞，正是这里要避开的。
        ikcp_nodelay(kcp, 1, 10, 2, 1)
        ikcp_wndsize(kcp, 256, 2048)
        ikcp_setoutput(kcp) { buffer, length, _, user in
            guard let buffer, let user, length > 0 else { return 0 }
            let holder = Unmanaged<Box>.fromOpaque(user).takeUnretainedValue()
            holder.output(Data(bytes: buffer, count: Int(length)))
            return 0
        }
    }

    deinit {
        ikcp_release(kcp)
        box.release()
    }

    /// 单条消息的上限。
    var maximumSegment: Int { Int(kcp.pointee.mss) }

    /// 对端确认到哪个序号（不含）。
    var acknowledgedThrough: UInt32 { kcp.pointee.snd_una }

    /// 平滑往返（毫秒）。
    var roundTripMillis: Int { Int(kcp.pointee.rx_srtt) }

    var waitingSegments: Int { Int(ikcp_waitsnd(kcp)) }

    /// 重传太多次还没确认：链路死了。
    var isDead: Bool { kcp.pointee.state == UInt32.max }

    /// 这条消息的序号。`data` 不能超过 `maximumSegment`。
    func send(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { bytes in
            _ = ikcp_send(kcp, bytes.bindMemory(to: CChar.self).baseAddress, Int32(bytes.count))
        }
        defer { nextSequence &+= 1 }
        return nextSequence
    }

    func input(_ data: Data) {
        data.withUnsafeBytes { bytes in
            _ = ikcp_input(kcp, bytes.bindMemory(to: CChar.self).baseAddress, bytes.count)
        }
    }

    /// 取下一条按序到达的消息。
    func receive() -> Data? {
        let size = ikcp_peeksize(kcp)
        guard size > 0 else { return nil }
        var data = Data(count: Int(size))
        let count = data.withUnsafeMutableBytes { bytes in
            ikcp_recv(kcp, bytes.bindMemory(to: CChar.self).baseAddress, size)
        }
        return count > 0 ? data : nil
    }

    func update(nowMillis: UInt32) {
        ikcp_update(kcp, nowMillis)
    }

    /// 下一次要 `update` 的时刻（毫秒）。
    func nextUpdate(nowMillis: UInt32) -> UInt32 {
        ikcp_check(kcp, nowMillis)
    }

    func flush() {
        ikcp_flush(kcp)
    }

    func setWindow(segments: Int) {
        ikcp_wndsize(kcp, Int32(segments), 2048)
    }
}
