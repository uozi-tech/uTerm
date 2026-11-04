import Foundation

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

    /// iOS 前台。
    static let foreground = TerminalFlushPacing(intervalMs: 16, baseBytes: 32 * 1024,
                                                maxBytes: 256 * 1024, targetMs: 4)
    /// iOS 后台。旧方案是 250ms 一次喂 512KB（前台标签每 250ms 卡一下）；现在 64ms 一拍、
    /// 最多 128KB，吞吐上限与旧方案相同（2MB/s），单次 feed 的停顿小四倍。
    static let background = TerminalFlushPacing(intervalMs: 64, baseBytes: 32 * 1024,
                                                 maxBytes: 128 * 1024, targetMs: 4)
    /// Mac。Claude Code 改尺寸、清屏后会重发整段对话，这时积压才会上去。同一份 4MB 语料、
    /// 185×53 窗格、Release 探针（改前 → 改后）：墙钟 2616 → 821ms（−69%），draw 102 → 25 次，
    /// 单次 feed 最长约 8ms。
    static let desktop = TerminalFlushPacing(intervalMs: 16, baseBytes: 32 * 1024,
                                             maxBytes: 512 * 1024, targetMs: 8)

    /// 下一拍的预算。`filled`：这一拍喂满了预算（说明还有积压）。
    func nextBudget(after budget: Int, elapsedMs: Double, filled: Bool) -> Int {
        if elapsedMs > targetMs { return max(baseBytes, budget / 2) }
        if filled, elapsedMs < targetMs / 2 { return min(maxBytes, budget * 2) }
        return min(maxBytes, max(baseBytes, budget))
    }
}
