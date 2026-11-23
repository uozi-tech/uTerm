import Foundation

/// 实时跟随一份还在写的对话：多久看一次、读不到时怎么退避、多久算「正在更新」。两端共用，平台只说看不看得见。
///
/// 只在看得见（窗口开着、标签在前台、App 不在后台）且对话的末尾已经读过的时候看；看一次 = 一次 `stat`，变长了才读新增的字节。
/// 读失败（断线）不报错，按 `delay(afterFailures:)` 安静地拉长间隔，恢复后回到 `interval`。
nonisolated struct AgentTranscriptFollowTiming: Sendable {
    /// 正常节奏：两次 `stat` 之间隔多久。
    var interval: Duration
    /// 连续失败时间隔翻倍，最多拉到这么长。
    var maxBackoff: Duration
    /// 最近这么久里读到过新内容，标题处显示「正在更新」。
    var activeWindow: Duration
    /// 会话还开着、派子代理的调用还没对上记录时，隔多久再列一次 `subagents/`（记录可能比调用晚一点写出来）。
    var subagentRelist: Duration
    /// 睡一段（测试换成不真睡的）。被取消时抛错。
    var sleep: @Sendable (Duration) async throws -> Void
    var now: @Sendable () -> ContinuousClock.Instant

    static let standard = AgentTranscriptFollowTiming(
        interval: .seconds(2), maxBackoff: .seconds(30), activeWindow: .seconds(60), subagentRelist: .seconds(5),
        sleep: { try await Task.sleep(for: $0) }, now: { ContinuousClock.now })

    /// 连续失败 `failures` 次之后隔多久再看：0 次是 `interval`，之后 4 秒、8 秒、16 秒……封顶 `maxBackoff`。
    func delay(afterFailures failures: Int) -> Duration {
        guard failures > 0 else { return interval }
        var delay = interval
        for _ in 0..<min(failures, 16) {
            delay *= 2
            if delay >= maxBackoff { return maxBackoff }
        }
        return delay
    }
}

/// 一次看文件末尾最多读这么多；一下子长了更多的，下一拍马上接着读（不等 `interval`）。
nonisolated enum AgentTranscriptFollowLimits {
    static let bytesPerPoll = 4 * 1024 * 1024
}
