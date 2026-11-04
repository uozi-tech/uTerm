import Foundation
import SwiftTerm

/// 每拍喂给 SwiftTerm 的字节预算：按这一拍实际花了多少主线程时间自适应（AIMD）。
///
/// 固定 32KB/16ms 时吞吐硬顶在 ≈2MB/s：局域网里 `cat` 大文件超过它，4MB 缓冲两秒就满，
/// `TerminalOutputBuffer` 只能整块丢掉最旧的字节——会截断转义序列，颜色 / 光标状态随之错乱。
/// 但也不能只看积压放大：机器忙、SwiftTerm 解析跟不上时积压一直高，每拍都喂满，主线程被终端
/// 独占（iOS 探针 `term-bg` 实测整段 8s 只剩 17 拍）。所以按耗时调：这一拍超过 `targetMs` 就
/// 减半，远低于目标且积压没喂完就翻倍，夹在 [base, max] 之间。下限就是改前的固定值，最差情况
/// 等于改前；解析跟得上时才放大吞吐。
nonisolated struct TerminalFlushPacing: Equatable {
    let intervalMs: Int
    let baseBytes: Int
    let maxBytes: Int
    let targetMs: Double
    /// 积压刚出现时两拍之间等多久。等于 `intervalMs` 表示不追赶。
    let catchUpDelayMs: Int
    /// 一段积压最多追赶多久。程序改尺寸后的重发很快就喂完，持续刷屏（`cat` 大文件）过了这段就回到
    /// `intervalMs`，主线程不会一直被终端占满。
    let catchUpWindowMs: Double = 1_000

    init(intervalMs: Int, baseBytes: Int, maxBytes: Int, targetMs: Double, catchUpDelayMs: Int? = nil) {
        self.intervalMs = intervalMs
        self.baseBytes = baseBytes
        self.maxBytes = maxBytes
        self.targetMs = targetMs
        self.catchUpDelayMs = catchUpDelayMs ?? intervalMs
    }

    /// iOS 前台。
    static let foreground = TerminalFlushPacing(intervalMs: 16, baseBytes: 32 * 1024,
                                                maxBytes: 256 * 1024, targetMs: 4, catchUpDelayMs: 2)
    /// iOS 后台。旧方案是 250ms 一次喂 512KB（前台标签每 250ms 卡一下）；现在 64ms 一拍、
    /// 最多 128KB，吞吐上限与旧方案相同（2MB/s），单次 feed 的停顿小四倍。看不见的终端不追赶。
    static let background = TerminalFlushPacing(intervalMs: 64, baseBytes: 32 * 1024,
                                                 maxBytes: 128 * 1024, targetMs: 4)
    /// Mac。Claude Code 改尺寸、清屏后会重发整段对话，这时积压才会上去。
    static let desktop = TerminalFlushPacing(intervalMs: 16, baseBytes: 32 * 1024,
                                             maxBytes: 512 * 1024, targetMs: 8, catchUpDelayMs: 2)

    /// 下一拍的预算。`filled`：这一拍喂满了预算（说明还有积压）。
    func nextBudget(after budget: Int, elapsedMs: Double, filled: Bool) -> Int {
        if elapsedMs > targetMs { return max(baseBytes, budget / 2) }
        if filled, elapsedMs < targetMs / 2 { return min(maxBytes, budget * 2) }
        return min(maxBytes, max(baseBytes, budget))
    }
}

/// 一条 flush 循环的节拍状态：这一拍喂多少、喂完等多久。
///
/// 程序改尺寸后重发整段内容时，时间不是花在解析上。Release 探针、4MB 语料、Mac 185×56：解析约 120ms，
/// 绘制约 200ms（一次 10～18ms），其余都在等节拍。所以积压时少等、少画（`feedPaced`），改前 → 改后：
/// Mac 4MB 约 700 → 205ms，draw 18 → 3 次；iOS 模拟器（优化构建，402×874）1MB 约 1350 → 345ms，
/// draw 30 → 3 次；4MB 约 5200 → 1000ms，draw 100 → 9 次。
nonisolated struct TerminalFlushPacer {
    private(set) var pacing: TerminalFlushPacing
    private(set) var budget: Int
    private var backlogStartMs: Double?

    init(pacing: TerminalFlushPacing) {
        self.pacing = pacing
        budget = pacing.baseBytes
    }

    /// 换档时预算回到新档的下限。
    mutating func use(_ pacing: TerminalFlushPacing) {
        guard pacing != self.pacing else { return }
        self.pacing = pacing
        budget = pacing.baseBytes
    }

    /// 这一拍喂满了预算、缓冲区里还有字节才算积压。只看「还有字节」不行：持续的小流量喂的时候总有新字节
    /// 到达，判断会来回翻转，每翻回一次就补画一帧，反而超过 60 fps。
    func isBacklogged(fed bytes: Int, hasMore: Bool) -> Bool {
        hasMore && bytes >= budget
    }

    /// 记下这一拍的结果，返回下一拍前要等的毫秒数。
    /// 解析已经超过 `targetMs` 说明机器忙，这时也按 `intervalMs` 等，让主线程喘口气。
    mutating func didFeed(bytes: Int, elapsedMs: Double, backlogged: Bool, nowMs: Double) -> Int {
        let filled = bytes >= budget
        budget = pacing.nextBudget(after: budget, elapsedMs: elapsedMs, filled: filled)
        guard backlogged else {
            backlogStartMs = nil
            return pacing.intervalMs
        }
        let start = backlogStartMs ?? nowMs
        backlogStartMs = start
        let keepsUp = elapsedMs <= pacing.targetMs
        return keepsUp && nowMs - start < pacing.catchUpWindowMs ? pacing.catchUpDelayMs : pacing.intervalMs
    }
}

extension SwiftTerm.TerminalView {
    /// 还有积压时每秒最多画 10 帧：字节马上会把屏幕再改一遍，中间帧画了也是白画。
    private static let backlogDisplayThrottleNanoseconds: UInt64 = 100_000_000

    /// 喂一拍。积压喂完的那一拍立刻画最后一帧，不用等节流。
    func feedPaced(_ bytes: ArraySlice<UInt8>, backlogged: Bool) {
        let normal = Self.defaultDisplayThrottleNanoseconds
        let wasThrottled = displayThrottleNanoseconds != normal
        displayThrottleNanoseconds = backlogged ? Self.backlogDisplayThrottleNanoseconds : normal
        feed(byteArray: bytes)
        if wasThrottled, !backlogged { flushPendingDisplay() }
    }
}
