import CoreGraphics
import Foundation

/// 终端尺寸「停稳再提交」的判定（macOS / iOS 共用）。
///
/// 终端一见到新尺寸就重排缓冲区，全屏程序（vim、Claude Code）却要等 SIGWINCH 才知道，这段时间差里
/// 它照旧按旧尺寸增量绘制；尺寸变过去又变回来时 PTY 尺寸没变、连 SIGWINCH 都没有，屏幕就一直错位。
/// 所以尺寸（iOS 还有字号）停稳 `settleDelay` 才提交：重排和 SIGWINCH 同时发生，中途的尺寸不碰缓冲区。
///
/// 这里只管「现在提交 / 先等着 / 不跟了」与顺延计时；终端 frame 怎么摆（等待期间 mac 贴左上、iOS 往上挪到光标留在屏上，
/// mac 的远控钉住尺寸与内边距、iOS 不在屏上不跟尺寸）留在各端容器。
@MainActor
final class TerminalResizeSettler {
    /// 尺寸或字号停止变化多久后才提交给终端。连续变化期间不断顺延。
    static let settleDelay: Duration = .milliseconds(80)

    /// 终端要跟上的布局。`fontSize` 为 nil = 这一端不跟字号（mac）。
    struct Target: Equatable {
        var size: CGSize
        var fontSize: CGFloat?

        init(size: CGSize, fontSize: CGFloat? = nil) {
            self.size = size
            self.fontSize = fontSize
        }

        /// 尺寸逐点相等、字号差 0.1pt 以内算同一个布局（字号由浮点算出来，留一点容差）。
        func matches(_ other: Target) -> Bool {
            guard size == other.size else { return false }
            switch (fontSize, other.fontSize) {
            case (nil, nil): return true
            case let (a?, b?): return abs(a - b) <= 0.1
            default: return false
            }
        }
    }

    enum Decision: Equatable {
        /// 立刻把终端摆到目标布局（停稳了 / 首次挂载 / 本来就是这个布局）。等着的那次已取消。
        case commit
        /// 先保持旧布局，停稳后会调 `onSettled`。`started` = 这次换了目标、重新开始计时（日志用）。
        case hold(started: Bool)
        /// 没有可跟的目标（没有可用空间 / 不在屏上 / 被钉住）：不动终端，等着的那次已取消。
        case cancel
    }

    private let delay: Duration
    /// 正在等待停稳的目标；nil = 没有在等。
    private(set) var held: Target?
    private var task: Task<Void, Never>?

    init(delay: Duration = TerminalResizeSettler.settleDelay) {
        self.delay = delay
    }

    /// 布局变了一次（容器 layout / 字号变化 / 计时到点）时调。
    ///
    /// - target: 终端该跟上的布局；nil = 现在没有可跟的目标。
    /// - current: 终端此刻的布局。
    /// - isFirstMount: 终端还没在任何容器里排过版——首挂直接提交，不然会先按 .zero 起一个空终端。
    ///   只给挂上时还没有程序在画的一端用（iOS 建连前就挂）；mac 连上才挂，传 false。
    /// - settled: 计时已到点（`onSettled` 里回调进来时传 true），或调用方要求立刻提交。
    /// - onSettled: 停稳后要做的事（一般是用 `settled: true` 重新走一遍布局）。只在返回 `.hold(started: true)` 时记下。
    func decide(target: Target?,
                current: Target,
                isFirstMount: Bool,
                settled: Bool,
                onSettled: @escaping @MainActor () -> Void) -> Decision {
        guard let target else {
            cancel()
            return .cancel
        }
        if settled || isFirstMount || current.matches(target) {
            cancel()
            return .commit
        }
        guard held != target else { return .hold(started: false) }
        held = target
        task?.cancel()
        let delay = self.delay
        task = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            onSettled()
        }
        return .hold(started: true)
    }

    /// 放弃正在等的那次（容器摘掉终端、被收起、改成钉住尺寸时）。
    func cancel() {
        task?.cancel()
        task = nil
        held = nil
    }
}
