import Foundation
import SwiftTerm

/// 后端输出 → SwiftTerm 的泵。mac `TerminalSession` 与 iOS `MobileTerminalController` 共用这一份。
///
/// 分两段，中间隔一个有界缓冲（`TerminalOutputBuffer`）：
/// - 入站：detached 任务把 `outputStream` 的块塞进缓冲，不为每个块跳一次主线程；
/// - 喂入：主线程上的循环按 `TerminalFlushPacer` 的节拍从缓冲取字节、`feedPaced` 给终端视图；
///   没字节时挂起在 `waitForData()`（0 CPU），一字节到达即恢复——这取代了旧的 100ms 轮询，
///   那 100ms 是回显字符最坏的可见延迟，是「输入不跟手」的根因。
///
/// 代次（`generation`）：`reset()` 递增，上一条连接残留的字节在入站和喂入两端都被拒收。
///
/// 两端只在三处不同，都做成了属性，别为平台再抄一份循环：
/// - `pacing`：mac 固定 `.desktop`；iOS 按前后台在 `.foreground` / `.background` 间换；
/// - `terminalView`：iOS 的视图可能晚于建连才挂上，没挂上时字节留在缓冲里，低频重试；
/// - `onFed`：每拍喂完后的钩子（mac 的远控镜像与 holder 检查点要按喂入顺序拿到同一批字节）。
///
/// 循环在两拍之间只弱引用泵：拥有者释放后泵随之释放，`deinit` 清缓冲唤醒挂起的循环让它退出。
@MainActor
final class TerminalOutputPump {
    let buffer: TerminalOutputBuffer
    private(set) var generation = 0
    /// 每拍开始时读一次；换档后预算回到新档下限（`TerminalFlushPacer.use`）。
    var pacing: TerminalFlushPacing
    weak var terminalView: SwiftTerm.TerminalView?
    /// 紧跟在 `feedPaced` 之后调用，参数就是这一拍喂进去的字节。不计入这一拍的解析耗时。
    var onFed: (@MainActor (ArraySlice<UInt8>) -> Void)?

    private var ingressTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?

    /// 视图还没挂上时多久再看一次。
    private static let viewlessRetryMs = TerminalFlushPacing.foreground.intervalMs

    init(pacing: TerminalFlushPacing, capacityBytes: Int = 4 * 1024 * 1024) {
        self.pacing = pacing
        buffer = TerminalOutputBuffer(capacityBytes: capacityBytes)
    }

    /// 喂入循环在跑（`start` 之后、`reset` 之前）。
    var isRunning: Bool { flushTask != nil }

    /// 代次 +1，停掉入站与喂入，丢掉缓冲里的字节。代次必须先递增，旧字节才会被两端可靠地拒收。
    func reset() {
        generation &+= 1
        ingressTask?.cancel()
        ingressTask = nil
        flushTask?.cancel()
        flushTask = nil
        buffer.clear()
    }

    /// 按当前代次开始泵 `output`。调用方先 `reset()`。
    func start(_ output: AsyncStream<Data>) {
        let generation = generation
        let buffer = buffer
        ingressTask?.cancel()
        // detached：不被主线程上的工作（SwiftUI 渲染、别的窗格的喂入）卡住。
        ingressTask = Task.detached(priority: .userInitiated) {
            for await chunk in output {
                if Task.isCancelled { break }
                buffer.append(chunk, generation: generation)
            }
        }
        startFlushLoop()
    }

    /// 重起喂入循环，截断正在进行的等待（iOS 切回前台时不必等完后台那一拍）。没在跑就什么也不做。
    func restartFlushLoop() {
        guard isRunning else { return }
        startFlushLoop()
    }

    private enum Beat {
        case stop
        case idle
        case wait(ms: Int)
    }

    private func startFlushLoop() {
        flushTask?.cancel()
        let generation = generation
        let buffer = buffer
        flushTask = Task { [weak self] in
            var pacer = TerminalFlushPacer(pacing: self?.pacing ?? .desktop)
            while !Task.isCancelled {
                switch self?.beat(generation: generation, pacer: &pacer) ?? .stop {
                case .stop:
                    return
                case .idle:
                    await buffer.waitForData()
                case .wait(let ms):
                    // 活跃路径：让短时间内陆续到达的字节合批一次性喂。
                    try? await Task.sleep(for: .milliseconds(ms))
                }
            }
        }
    }

    /// 无条件 feed —— 后台（非活动）标签也照样解析 VT，这是**有意保留**的（iOS 后台只是降频，
    /// 见 `TerminalFlushPacing.background`，字节一样不少）。
    ///
    /// 2026-09-01 量过它的成本结构，别再凭「批量化能省」的直觉来改这里。
    /// 测法：同进程内交替翻转块大小做配对测量（这台机器 load 在 4–14 乱跳，
    /// 跨进程不可比），6 个 `TerminalView` 交错喂同一份 `script(1)` 录的真实
    /// 语料（带色 git log/ls -laR + vim 进出 alternate screen + top 全屏重绘），
    /// 每轮正逆序交替、7 轮取中位数，Release 构建。
    ///
    ///   每次 feed 的块大小    调用次数    6.57 MB 总耗时
    ///   64 B                 107 719     176.8 ms
    ///   433 B（线上实测均值）  15 922      157.4 ms
    ///   32 KB                211         153.3 ms
    ///   256 KB               27          153.9 ms
    ///
    /// 拟合出来：**每次调用的固定开销只有 0.21 µs，按字节的解析是 23.3 ms/MB**
    /// （随内容在 9–27 ms/MB 之间浮动）。也就是说线上那 433 B 的包里，固定开销
    /// 只占 feed 总耗时的 2.6%；把 flush 从 433 B 攒到 32 KB 就只能省这 2.6%，
    /// 连 64 B → 256 KB 的极端全跨度也只有 13%。批量化在这里省不到 CPU。预算放大
    /// （`TerminalFlushPacing`）要解决的是积压时的吞吐，不是省 CPU；没有积压时每拍
    /// 只有几百字节，预算多大都一样，也就不影响 echo 延迟。
    ///
    /// 绝对量级也不值得动：6 个后台标签合计 142 KB/s 的输出，在 Release 下
    /// ≈ 3.3 ms/s 主线程时间（0.3% 单核）。`uAppKit/docs/pane-groups-design.md`
    /// §6-2 记的 31.5–65 ms/s 是 **Debug** 构建（`-Onone`）量的，不代表发布版：
    /// 同一份语料同一套测法，Debug 224.8 ms/MB vs Release 23.9 ms/MB，差 9.4×。
    ///
    /// 再往下就只剩「后台标签先不解析、切回来再补」。它省不到 CPU（字节一个不少
    /// 还是要解析，只是挪到切回来的那一刻，反而制造一次卡顿），却必然改变行为：
    /// 补 feed 之前若发生过 resize，积压字节会按新 cols 重排，切回来的内容与不
    /// 优化时不再逐字相同。为 3.3 ms/s 付这个代价不划算。
    ///
    /// 顺带钉住一条：SwiftTerm 的解析器对分块边界是中立的 —— 上面五种块大小
    /// 喂完同一份语料后，主屏/alt 屏全文、逐格字符与属性、scrollback、光标位置
    /// 全部逐字相同（实测比对过指纹）。所以将来真要改批量策略，正确性这一侧
    /// 是安全的，不安全的只有上面那条「延迟到可见时再补」。
    ///
    /// 一拍：取一批字节喂给终端，返回接下来怎么等。
    private func beat(generation: Int, pacer: inout TerminalFlushPacer) -> Beat {
        guard self.generation == generation else { return .stop }
        guard let terminalView else { return .wait(ms: Self.viewlessRetryMs) }
        pacer.use(pacing)
        let chunk = buffer.drain(maxBytes: pacer.budget, generation: generation)
        guard !chunk.isEmpty else { return .idle }

        let bytes = ArraySlice([UInt8](chunk))
        let backlogged = pacer.isBacklogged(fed: bytes.count, hasMore: buffer.hasBufferedBytes)
        let start = CFAbsoluteTimeGetCurrent()
        terminalView.feedPaced(bytes, backlogged: backlogged)
        let end = CFAbsoluteTimeGetCurrent()
        onFed?(bytes)
        return .wait(ms: pacer.didFeed(bytes: bytes.count, elapsedMs: (end - start) * 1000,
                                       backlogged: backlogged, nowMs: end * 1000))
    }

    deinit {
        ingressTask?.cancel()
        flushTask?.cancel()
        buffer.clear()
    }
}
